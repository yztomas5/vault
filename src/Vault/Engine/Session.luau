--!strict
local Backend = require(script.Parent.Backend)
local Inbox = require(script.Parent.Inbox)
local Lock = require(script.Parent.Lock)
local Record = require(script.Parent.Record)
local Saver = require(script.Parent.Saver)
local Signal = require(script.Parent.Signal)
local Throttle = require(script.Parent.Throttle)
local Wheel = require(script.Parent.Wheel)

export type Params = {
	cancel: (() -> boolean)?,
}

export type Session = {
	data: { [string]: any },
	lastSaved: { [string]: any },
	firstSessionTime: number,
	loadCount: number,
	robloxMetaData: any,
	userIds: { number },
	keyInfo: any,
	bytes: number,
	key: string,
	storeName: string,
	onSave: Signal.Signal<()>,
	onLastSave: Signal.Signal<Saver.Reason>,
	onSessionEnd: Signal.Signal<()>,
	onAfterSave: Signal.Signal<any>,
	active: () -> boolean,
	save: () -> (),
	saveNow: () -> Saver.Outcome,
	release: () -> (),
	reconcile: () -> (),
	addUserId: (userId: number) -> (),
	removeUserId: (userId: number) -> (),
	onMessage: (handler: Inbox.Handler) -> (),
	internal: any,
}

local Session = {}

local RETRY_CAP_SECONDS = 20
local ABANDON_ATTEMPTS = 3

local function create(context: any, store: any, key: string, mock: boolean, token: string, record: Record.Stored, keyInfo: any): Session
	local meta = record.MetaData
	local session: Session
	local internal = {
		store = store,
		mock = mock,
		token = token,
		loadIndex = Record.loadCount(record),
		loadTimestamp = context.env.clock(),
		inbox = Inbox.new(record),
		subscription = nil,
		sizeLevel = 0,
	}

	local function active(): boolean
		return context.sessions[token] == session
	end

	local function validUserId(userId: any): boolean
		if type(userId) == "number" and userId % 1 == 0 then
			return true
		end
		warn(`[Vault] invalid user id {tostring(userId)}\n{debug.traceback()}`)
		return false
	end

	session = {
		data = record.Data,
		lastSaved = Record.copy(record.Data),
		firstSessionTime = meta.ProfileCreateTime or 0,
		loadCount = Record.loadCount(record),
		robloxMetaData = record.RobloxMetaData or {},
		userIds = record.UserIds or {},
		keyInfo = keyInfo,
		bytes = 0,
		key = key,
		storeName = store.name,
		onSave = Signal.new(),
		onLastSave = Signal.new(),
		onSessionEnd = Signal.new(),
		onAfterSave = Signal.new(),
		active = active,
		internal = internal,
		save = function()
			if not active() then
				warn(`[Vault] tried to save an ended session (store {store.name}, key {key})\n{debug.traceback()}`)
				return
			end
			Wheel.remove(context, session)
			Wheel.add(context, session)
			task.spawn(Saver.save, context, session, false)
		end,
		saveNow = function(): Saver.Outcome
			if not active() then
				return "Lost"
			end
			Wheel.remove(context, session)
			Wheel.add(context, session)
			return Saver.save(context, session, false)
		end,
		release = function()
			if active() then
				task.spawn(Saver.save, context, session, true, "Manual")
			end
		end,
		reconcile = function()
			Record.reconcile(session.data, store.template)
		end,
		addUserId = function(userId: number)
			if not validUserId(userId) then
				return
			end
			if userId < 0 and not mock and context.state == "Access" then
				return
			end
			if not table.find(session.userIds, userId) then
				table.insert(session.userIds, userId)
			end
		end,
		removeUserId = function(userId: number)
			if not validUserId(userId) then
				return
			end
			local index = table.find(session.userIds, userId)
			if index then
				table.remove(session.userIds, index)
			end
		end,
		onMessage = function(handler: Inbox.Handler)
			if type(handler) ~= "function" then
				error("[Vault] a message handler must be a function", 2)
			end
			if active() then
				Inbox.handle(internal.inbox, handler)
			end
		end,
	}
	return session
end

local function listen(context: any, session: Session, sessionId: string)
	local env = context.env
	local last = -math.huge
	local ok, subscription = pcall(env.subscribe, `PS_{sessionId}`, function(message: any)
		local data = message.Data
		if type(data) ~= "table" or data.LoadCount ~= session.loadCount then
			return
		end
		if env.clock() - last <= context.settings.MessageCooldownSeconds or not session.active() then
			return
		end
		last = env.clock()
		if data.EndSession == true then
			Saver.save(context, session, true, "External")
		else
			session.save()
		end
	end)
	if not ok then
		warn(`[Vault] could not listen for release requests (store {session.storeName}, key {session.key}): {tostring(subscription)}`)
	elseif session.active() then
		session.internal.subscription = subscription
	else
		subscription:Disconnect()
	end
end

local function abandon(context: any, store: any, key: string, mock: boolean, me: Record.Identity, uncertain: { [string]: true })
	local backoff = 1
	for attempt = 1, ABANDON_ATTEMPTS do
		local record, _, clean = Backend.write(context, store, key, mock, function(opened: Record.Stored, kind: Record.Kind): boolean
			local sessionId = Record.sessionId(opened)
			if kind ~= "Existing" or not sessionId or not uncertain[sessionId] then
				return false
			end
			if not Record.isSession(opened.MetaData.ActiveSession, me) then
				return false
			end
			opened.MetaData.ActiveSession = nil
			return true
		end)
		if record or clean or attempt == ABANDON_ATTEMPTS then
			return
		end
		task.wait(backoff)
		backoff *= 2
	end
end

function Session.start(context: any, store: any, key: string, mock: boolean, params: Params?): Session?
	Backend.checkKey(context, key)
	if params ~= nil and type(params) ~= "table" then
		error("[Vault] invalid session params", 2)
	end
	if context.closing then
		return nil
	end
	Backend.ready(context)

	local env = context.env
	local settings = context.settings
	local token = Backend.token(context, store, key, mock)
	if context.sessions[token] then
		error(`[Vault] the profile is already open in this server (store {store.name}, key {key})`, 2)
	end

	local me: Record.Identity = { placeId = env.placeId, jobId = env.jobId }
	local cancel = if params then params.cancel else nil
	local userCancelled = false
	local function cancelled(): boolean
		if not userCancelled and cancel then
			userCancelled = cancel() == true
		end
		return userCancelled
	end

	local jobs = if mock then store.mockLoadJobs else store.loadJobs
	local uncertain: { [string]: true } = {}
	local unsure = false
	local steps = 0
	local ask = true
	local steal = false
	local started = env.clock()
	local backoff = 1
	local result: Session? = nil

	context.loadJobs += 1

	while not context.closing and not cancelled() do
		context.loadIndex += 1
		local loadId = context.loadIndex
		local job = jobs[key]
		local sessionId = env.guid()
		local record, keyInfo

		if job then
			job.id = loadId
			while not job.done do
				task.wait()
			end
			if not job.record then
				uncertain[job.sessionId] = true
				unsure = true
			end
		else
			job = { id = loadId, done = false, sessionId = sessionId, record = nil, keyInfo = nil }
			jobs[key] = job
			job.record, job.keyInfo = Backend.write(context, store, key, mock, function(opened: Record.Stored, kind: Record.Kind): boolean
				Lock.start(opened, kind, {
					me = me,
					sessionId = sessionId,
					now = env.time(),
					template = store.template,
					ask = ask,
					steal = steal,
					cancelled = context.closing or cancelled(),
					deadSeconds = settings.DeadSeconds,
				})
				return true
			end)
			job.done = true
			if not job.record then
				uncertain[sessionId] = true
				unsure = true
			end
		end
		if job.id ~= loadId then
			unsure = false
			break
		end
		record, keyInfo = job.record, job.keyInfo
		jobs[key] = nil

		if record and keyInfo then
			unsure = false
			local verdict = Lock.verdict(record, me)
			if verdict == "Owned" then
				local session = create(context, store, key, mock, token, record, keyInfo)
				Wheel.add(context, session)
				local stored = Record.sessionId(record)
				if stored and not mock and context.state == "Access" then
					task.spawn(listen, context, session, stored)
				end
				if context.closing or cancelled() then
					Saver.save(context, session, true)
				else
					result = session
				end
				break
			end
			if verdict ~= "Waiting" or context.closing or cancelled() then
				break
			end
			if not ask then
				steps += 1
				if steps >= math.ceil(settings.StealSeconds / settings.LoadRepeatSeconds) then
					steal = true
				end
			end
			local holder = Record.sessionId(record)
			if holder then
				local request = { LoadCount = Record.loadCount(record), EndSession = true }
				task.spawn(function()
					pcall(env.publish, `PS_{holder}`, request)
				end)
			end
			local resume = env.clock() + if ask then settings.FirstLoadRepeatSeconds else settings.LoadRepeatSeconds
			repeat
				task.wait()
			until env.clock() >= resume or context.closing
			ask = false
		else
			local timedOut = cancel == nil and env.clock() - started >= settings.StartTimeoutSeconds
			if timedOut or context.closing or cancelled() then
				break
			end
			task.wait(Throttle.jitter(context, backoff))
			backoff = math.min(RETRY_CAP_SECONDS, backoff * 2)
		end
	end

	if unsure and not result then
		abandon(context, store, key, mock, me, uncertain)
	end
	context.loadJobs -= 1
	return result
end

return Session
