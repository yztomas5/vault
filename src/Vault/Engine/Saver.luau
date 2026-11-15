--!strict
local Backend = require(script.Parent.Backend)
local Health = require(script.Parent.Health)
local Inbox = require(script.Parent.Inbox)
local Lock = require(script.Parent.Lock)
local Record = require(script.Parent.Record)
local Throttle = require(script.Parent.Throttle)
local Wheel = require(script.Parent.Wheel)

export type Reason = "Manual" | "External" | "Shutdown"
export type Outcome = "Saved" | "Lost" | "Failed"

local Saver = {}

local RETRY_CAP_SECONDS = 20
local SHUTDOWN_RETRY_CAP_SECONDS = 8

local function unsubscribe(session: any)
	local subscription = session.internal.subscription
	if subscription then
		session.internal.subscription = nil
		subscription:Disconnect()
	end
end

local function lose(context: any, session: any)
	unsubscribe(session)
	if session.active() then
		Wheel.remove(context, session)
		session.onSessionEnd.fire()
	end
end

function Saver.save(context: any, session: any, ending: boolean, reason: Reason?): Outcome
	if type(session.data) ~= "table" then
		error(`[Vault] session data was set to a non table value (store {session.storeName}, key {session.key})`)
	end
	local internal = session.internal
	local env = context.env
	local me: Record.Identity = { placeId = env.placeId, jobId = env.jobId }

	session.onSave.fire()
	if ending then
		session.onLastSave.fire(reason or "Manual")
		unsubscribe(session)
		Wheel.remove(context, session)
		session.onSessionEnd.fire()
	end

	Health.measured(context, session)
	context.saveJobs += 1
	local outcome: Outcome = "Failed"
	local wrote = false
	local backoff = 1

	while true do
		local record, keyInfo, missing = Backend.write(
			context,
			internal.store,
			session.key,
			internal.mock,
			function(opened: Record.Stored, kind: Record.Kind): boolean
				if kind ~= "Existing" then
					return false
				end
				wrote = Lock.save(opened, {
					me = me,
					loadIndex = internal.loadIndex,
					now = env.time(),
					ending = ending,
					data = session.data,
					userIds = session.userIds,
					robloxMetaData = session.robloxMetaData,
					processed = internal.inbox.locked,
				})
				return true
			end
		)

		if record and keyInfo then
			local owns = Lock.owns(record, me, internal.loadIndex)
			local active = session.active()
			local landed = ending and Record.holder(record) == nil and Record.loadCount(record) == internal.loadIndex
			outcome = if wrote or landed then "Saved" else "Lost"
			if owns and Lock.releaseAsked(record, me) then
				if active then
					Saver.save(context, session, true, "External")
				end
				break
			end
			local fresh = Inbox.absorb(internal.inbox, record)
			session.keyInfo = keyInfo
			session.lastSaved = record.Data
			if not owns then
				lose(context, session)
			elseif active and not ending then
				Inbox.deliver(internal.inbox, fresh)
			end
			session.onAfterSave.fire(session.lastSaved)
			break
		end

		if missing then
			outcome = "Lost"
			lose(context, session)
			break
		end
		if not ending then
			break
		end
		task.wait(Throttle.jitter(context, backoff))
		backoff = math.min(if reason == "Shutdown" then SHUTDOWN_RETRY_CAP_SECONDS else RETRY_CAP_SECONDS, backoff * 2)
	end

	context.saveJobs -= 1
	return outcome
end

return Saver
