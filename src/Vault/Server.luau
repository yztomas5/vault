--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Engine = require(script.Parent.Engine)
local Migrations = require(script.Parent.Migrations)
local Replica = require(script.Parent.Replica)
local Store = require(script.Parent.Store)
local Types = require(script.Parent.Types)

type Path = Types.Path
type PathLike = Types.PathLike

type Session = {
	profile: any,
	replica: Replica.Replica,
	readOnly: boolean,
}

export type Server = {
	start: (config: Types.ServerConfig) -> (),
	join: (player: Player) -> (),
	leave: (player: Player) -> (),
	ready: (player: Player, timeout: number?) -> boolean,
	loaded: (player: Player) -> boolean,
	get: (player: Player, path: PathLike) -> any,
	set: (player: Player, path: PathLike, value: any) -> boolean,
	update: (player: Player, path: PathLike, transform: (any) -> any) -> any,
	insert: (player: Player, path: PathLike, value: any, index: number?) -> boolean,
	remove: (player: Player, path: PathLike, index: number?) -> any,
	observe: (player: Player, path: PathLike, listener: Types.Listener) -> Types.Disconnect,
	save: (player: Player) -> boolean,
	saveNow: (player: Player) -> Engine.Outcome,
	size: (player: Player) -> number,
	saveConfirmed: (player: Player, confirmed: (any) -> boolean, timeout: number) -> boolean,
	onMessage: (key: string, handler: Types.Message) -> (),
	sendMessage: (userId: number, key: string, data: any) -> boolean,
	inspect: (userId: number) -> any,
	wipe: (userId: number) -> boolean,
	onWipe: (wiper: (number) -> ()) -> (),
	snapshot: (player: Player) -> (number, any),
	choice: () -> Types.Choice?,
	stores: () -> Types.Stores?,
	extend: (key: string, defaults: any, private: boolean?) -> (),
}

local Server = {}

local STUDIO = RunService:IsStudio()
local DEFAULT_SAVE_ATTEMPTS = 3
local DEFAULT_SAVE_RETRY_SECONDS = 2

local NONE: { Path } = {}

local function noop() end

function Server.new(): Server
	local config: Types.ServerConfig? = nil
	local handle: Store.Handle? = nil
	local storeWaiters: { thread } = {}
	local sessions: { [Player]: Session } = {}
	local present: { [Player]: true } = {}
	local settled: { [Player]: true } = {}
	local waiters: { [Player]: { () -> () } } = {}
	local leaving: { [Player]: true } = {}
	local subscribed: { [Player]: true } = {}
	local queues: { [Player]: { Types.Change } } = {}
	local sequences: { [Player]: number } = {}
	local handlers: { [string]: Types.Message } = {}
	local wipers: { (number) -> () } = {}
	local extensions: { { key: string, defaults: any, private: boolean } } = {}
	local joinedOnce = false
	local flushing = false

	local function settings(): Types.ServerConfig
		return assert(config, "[Vault] start the server before using it")
	end

	local function waitStore(): Store.Handle
		if not handle then
			table.insert(storeWaiters, coroutine.running())
			coroutine.yield()
		end
		return handle :: Store.Handle
	end

	local function keyOf(userId: number): string
		return settings().keyPrefix .. tostring(userId)
	end

	local function inTemplate(path: Path): boolean
		return Replica.allowed(settings().template, path)
	end

	local function validPath(action: string, path: Path): boolean
		if #path > 0 and inTemplate(path) then
			return true
		end
		local message = `[Vault] {action} rejected, {Replica.describe(path)} is not in the template`
		if STUDIO then
			error(message)
		end
		warn(message)
		return false
	end

	local function storable(action: string, path: Path, value: any): boolean
		local fatal, risks = Engine.Storable.check(value)
		if STUDIO then
			for _, risk in risks do
				warn(`[Vault] {action} at {Replica.describe(path)}: {risk}`)
			end
		end
		if not fatal then
			return true
		end
		local message = `[Vault] {action} rejected at {Replica.describe(path)}: {fatal}`
		if STUDIO then
			error(message)
		end
		warn(message)
		return false
	end

	local function isPrivate(path: Path): boolean
		return Replica.hidden(settings().private or NONE, path)
	end

	local function strip(path: Path, value: any): any
		return Replica.strip(settings().private or NONE, path, value)
	end

	local function flush()
		flushing = false
		local packet = settings().packets.changes
		for player, queue in queues do
			if #queue > 0 and subscribed[player] then
				local sequence = (sequences[player] or 0) + 1
				sequences[player] = sequence
				packet:FireClient(player, sequence, queue)
			end
		end
		table.clear(queues)
	end

	local function enqueue(player: Player, path: Path, op: Types.Op, value: any, index: number?)
		if not subscribed[player] or isPrivate(path) then
			return
		end
		local queue = queues[player]
		if not queue then
			queue = {}
			queues[player] = queue
		end
		local change: Types.Change = { table.clone(path) :: any, op, strip(path, Replica.copy(value)), index }
		table.insert(queue, change)
		if not flushing then
			flushing = true
			RunService.Heartbeat:Once(flush)
		end
	end

	local function settle(player: Player)
		if present[player] then
			settled[player] = true
		end
		local list = waiters[player]
		waiters[player] = nil
		if list then
			for _, resume in list do
				resume()
			end
		end
	end

	local function sessionFor(player: Player, action: string, path: Path): Session?
		local session = sessions[player]
		if not session then
			warn(`[Vault] {action} skipped, no data loaded for {tostring(player)} at {Replica.describe(path)}`)
		end
		return session
	end

	local function migrate(data: { [any]: any }): boolean
		local cfg = settings()
		local copy = Replica.copy(data)
		local ok, err = pcall(Migrations.run, copy, cfg.migrations, cfg.versionPath, cfg.baseVersion)
		if not ok then
			warn(`[Vault] migration failed: {tostring(err)}`)
			return false
		end
		table.clear(data)
		for key, value in copy do
			data[key] = value
		end
		return true
	end

	local function handleMessages(player: Player, profile: any)
		profile.onMessage(function(message: any, processed: () -> ())
			local key = if type(message) == "table" then message.key else nil
			local handler = if type(key) == "string" then handlers[key] else nil
			if not handler then
				warn(`[Vault] message {tostring(key)} for {tostring(player)} has no handler, left for a later session`)
				return
			end
			local ok, result = pcall(handler, player, message.data)
			if not ok then
				warn(`[Vault] message {key} failed for {tostring(player)}: {tostring(result)}`)
			elseif result ~= false then
				processed()
			end
		end)
	end

	local function attach(player: Player, profile: any, readOnly: boolean)
		local session: Session = { profile = profile, replica = Replica.new(profile.data), readOnly = readOnly }
		sessions[player] = session
		if readOnly then
			return
		end
		profile.addUserId(player.UserId)
		profile.onSessionEnd.connect(function()
			if sessions[player] == session then
				sessions[player] = nil
				subscribed[player] = nil
			end
			if leaving[player] then
				leaving[player] = nil
			elseif present[player] then
				player:Kick(settings().messages.stolen)
			end
		end)
		handleMessages(player, profile)
	end

	local function fetch(player: Player, store: Store.Handle): any
		local cfg = settings()
		local key = keyOf(player.UserId)
		local started = os.clock()
		local ok, profile = pcall(function(): any
			if store.choice.kind == "ReadOnly" then
				local view = store.source.view(key)
				return { data = if view then view.data else Replica.copy(cfg.template) }
			end
			return store.source.start(key, {
				cancel = function(): boolean
					return not present[player] or os.clock() - started > cfg.loadSeconds
				end,
			})
		end)
		if not ok then
			warn(`[Vault] load failed for {tostring(player)}: {tostring(profile)}`)
			return nil
		end
		return profile
	end

	local function open(player: Player)
		local store = waitStore()
		local readOnly = store.choice.kind == "ReadOnly"
		local profile = if present[player] then fetch(player, store) else nil
		if profile and (not present[player] or not migrate(profile.data)) then
			if not readOnly then
				profile.release()
			end
			profile = nil
		end
		if not profile then
			settle(player)
			if present[player] then
				player:Kick(settings().messages.failed)
			end
			return
		end
		Engine.Record.reconcile(profile.data, settings().template)
		attach(player, profile, readOnly)
		settle(player)
	end

	local function join(player: Player)
		if present[player] then
			return
		end
		present[player] = true
		joinedOnce = true
		task.spawn(open, player)
	end

	local function leave(player: Player)
		present[player] = nil
		local session = sessions[player]
		sessions[player] = nil
		subscribed[player] = nil
		queues[player] = nil
		sequences[player] = nil
		settle(player)
		settled[player] = nil
		if session and not session.readOnly then
			leaving[player] = true
			session.profile.release()
		end
	end

	local function ready(player: Player, timeout: number?): boolean
		if sessions[player] or settled[player] or not present[player] then
			return sessions[player] ~= nil
		end
		local thread = coroutine.running()
		local resumed = false
		local function resume()
			if not resumed then
				resumed = true
				task.spawn(thread)
			end
		end
		local list = waiters[player] or {}
		waiters[player] = list
		table.insert(list, resume)
		if timeout then
			task.delay(timeout, resume)
		end
		coroutine.yield()
		return sessions[player] ~= nil
	end

	local function write(
		player: Player,
		action: string,
		pathLike: PathLike,
		op: Types.Op,
		value: any,
		index: number?
	): (boolean, any)
		local path = Replica.path(pathLike)
		local session = sessionFor(player, action, path)
		if not session or not validPath(action, path) then
			return false, nil
		end
		if not storable(action, path, value) then
			return false, nil
		end
		local stored = Replica.copy(value)
		local result = session.replica:apply({ { path, op, stored, index } })
		enqueue(player, path, op, stored, index)
		return true, result
	end

	local function update(player: Player, pathLike: PathLike, transform: (any) -> any): any
		local path = Replica.path(pathLike)
		local session = sessionFor(player, "update", path)
		if not session or not validPath("update", path) then
			return nil
		end
		local value = transform(session.replica:get(path))
		local written = write(player, "update", path, "set", value)
		return if written then value else nil
	end

	local function trySave(player: Player, session: Session): boolean
		local ok, err = pcall(session.profile.save)
		if not ok then
			warn(`[Vault] save failed for {tostring(player)}: {tostring(err)}`)
		end
		return ok
	end

	local function retrySave(player: Player, session: Session)
		local attempts = settings().saveAttempts or DEFAULT_SAVE_ATTEMPTS
		local delay = settings().saveRetrySeconds or DEFAULT_SAVE_RETRY_SECONDS
		for attempt = 2, attempts do
			task.wait(delay * (attempt - 1))
			if sessions[player] ~= session or trySave(player, session) then
				return
			end
		end
	end

	local function save(player: Player): boolean
		local session = sessions[player]
		if not session or session.readOnly then
			return false
		end
		if trySave(player, session) then
			return true
		end
		task.spawn(retrySave, player, session)
		return false
	end

	local function saveNow(player: Player): Engine.Outcome
		local session = sessions[player]
		if not session or session.readOnly then
			return "Failed"
		end
		return session.profile.saveNow()
	end

	local function saveConfirmed(player: Player, confirmed: (any) -> boolean, timeout: number): boolean
		local session = sessions[player]
		if not session or session.readOnly then
			return false
		end
		local profile = session.profile
		if confirmed(profile.lastSaved) then
			return true
		end
		local ok = false
		local disconnect = profile.onAfterSave.connect(function(saved: any)
			if confirmed(saved) then
				ok = true
			end
		end)
		local started = pcall(profile.save)
		local deadline = os.clock() + timeout
		while started and not ok and os.clock() < deadline and sessions[player] == session do
			task.wait()
		end
		disconnect()
		return ok
	end

	local function onMessage(key: string, handler: Types.Message)
		assert(not joinedOnce, "[Vault] register message handlers before the first player joins")
		assert(handlers[key] == nil, `[Vault] message {key} already has a handler`)
		handlers[key] = handler
	end

	local function sendMessage(userId: number, key: string, data: any): boolean
		if not handlers[key] then
			warn(`[Vault] message {key} has no handler, not sent`)
			return false
		end
		local store = waitStore()
		if store.choice.kind == "ReadOnly" then
			warn(`[Vault] read-only data, message {key} not sent`)
			return false
		end
		local ok, sent = pcall(function(): any
			return store.source.message(keyOf(userId), { key = key, data = data })
		end)
		if not ok then
			warn(`[Vault] message {key} to {userId} failed: {tostring(sent)}`)
		end
		return ok and sent == true
	end

	local function inspect(userId: number): any
		local store = waitStore()
		local cfg = settings()
		local ok, view = pcall(function(): any
			return store.source.view(keyOf(userId))
		end)
		if not ok or not view then
			return nil
		end
		local copy = Replica.copy(view.data)
		if not pcall(Migrations.run, copy, cfg.migrations, cfg.versionPath, cfg.baseVersion) then
			return nil
		end
		return copy
	end

	local function wipe(userId: number): boolean
		local store = waitStore()
		if store.choice.kind == "ReadOnly" then
			warn(`[Vault] read-only data, {userId} not wiped`)
			return false
		end
		for player, session in sessions do
			if player.UserId == userId then
				local ended = false
				session.profile.onSessionEnd.connect(function()
					ended = true
				end)
				player:Kick(settings().messages.wiped)
				leave(player)
				local deadline = os.clock() + settings().loadSeconds
				while not ended and os.clock() < deadline do
					task.wait()
				end
			end
		end
		local ok, removed = pcall(function(): boolean
			return store.source.remove(keyOf(userId))
		end)
		if not ok or not removed then
			warn(`[Vault] wipe of {userId} failed: {tostring(removed)}`)
		end
		for _, wiper in wipers do
			local wiped, reason = pcall(function(): any
				wiper(userId)
				return nil
			end)
			if not wiped then
				warn(`[Vault] extra wipe of {userId} failed: {tostring(reason)}`)
			end
		end
		return ok and removed == true
	end

	local function snapshot(player: Player): (number, any)
		if not ready(player, settings().snapshotSeconds) then
			return 0, nil
		end
		local session = sessions[player] :: Session
		subscribed[player] = true
		queues[player] = nil
		return sequences[player] or 0, strip({}, Replica.copy(session.replica.data))
	end

	local function applyExtension(cfg: Types.ServerConfig, key: string, defaults: any, private: boolean)
		assert(cfg.template[key] == nil, `[Vault] the template already has a field named {key}`)
		cfg.template[key] = Replica.copy(defaults)
		if private then
			local list = cfg.private or {}
			table.insert(list, { key })
			cfg.private = list
		end
	end

	local function extend(key: string, defaults: any, private: boolean?)
		assert(type(key) == "string" and #key > 0, "[Vault] an extension needs a field name")
		assert(not joinedOnce, `[Vault] extend {key} before the first player joins`)
		for _, extension in extensions do
			assert(extension.key ~= key, `[Vault] {key} is already an extension`)
		end
		table.insert(extensions, { key = key, defaults = Replica.copy(defaults), private = private == true })
		if config then
			applyExtension(config, key, defaults, private == true)
		end
	end

	local function start(cfg: Types.ServerConfig)
		assert(config == nil, "[Vault] the server is already started")
		local own = table.clone(cfg)
		own.template = Replica.copy(cfg.template)
		if cfg.private then
			own.private = table.clone(cfg.private)
		end
		for _, extension in extensions do
			applyExtension(own, extension.key, extension.defaults, extension.private)
		end
		config = own
		cfg = own
		local serve = cfg.serve
			or function(
				packet: any,
				_label: string,
				handler: (any, ...any) -> ...any,
				_fallback: (any, ...any) -> ...any
			)
				packet.OnServerInvoke = handler
			end
		serve(cfg.packets.snapshot, "VaultSnapshot", snapshot, function(): (number, any)
			return 0, nil
		end)
		task.spawn(function()
			local wanted: Types.StudioData = cfg.studioData or "Mock"
			local access = if STUDIO and wanted ~= "Mock" then Store.access() else true
			local choice = Store.choose(STUDIO, wanted, access, cfg.stores)
			Store.guard(STUDIO, choice, cfg.stores, cfg.studioProduction)
			if choice.reason then
				warn(`[Vault] {choice.reason}`)
			end
			if STUDIO and cfg.players ~= false then
				print(`[Vault] Studio data: {choice.kind} on store {choice.name}`)
			end
			handle = Store.open(choice, cfg.template)
			local list = storeWaiters
			storeWaiters = {}
			for _, thread in list do
				task.spawn(thread)
			end
		end)
		if cfg.players ~= false then
			Players.PlayerAdded:Connect(join)
			Players.PlayerRemoving:Connect(leave)
			for _, player in Players:GetPlayers() do
				join(player)
			end
		end
	end

	return {
		start = start,
		join = join,
		leave = leave,
		ready = ready,
		loaded = function(player: Player): boolean
			return sessions[player] ~= nil
		end,
		get = function(player: Player, path: PathLike): any
			local session = sessions[player]
			return if session then session.replica:get(Replica.path(path)) else nil
		end,
		set = function(player: Player, path: PathLike, value: any): boolean
			return (write(player, "set", path, "set", value))
		end,
		update = update,
		insert = function(player: Player, path: PathLike, value: any, index: number?): boolean
			return (write(player, "insert", path, "insert", value, index))
		end,
		remove = function(player: Player, path: PathLike, index: number?): any
			local _, removed = write(player, "remove", path, "remove", nil, index)
			return removed
		end,
		observe = function(player: Player, path: PathLike, listener: Types.Listener): Types.Disconnect
			local session = sessionFor(player, "observe", Replica.path(path))
			return if session then session.replica:observe(Replica.path(path), listener) else noop
		end,
		save = save,
		saveNow = saveNow,
		size = function(player: Player): number
			local session = sessions[player]
			return if session and not session.readOnly then session.profile.bytes else 0
		end,
		saveConfirmed = saveConfirmed,
		onMessage = onMessage,
		sendMessage = sendMessage,
		inspect = inspect,
		wipe = wipe,
		onWipe = function(wiper: (number) -> ())
			table.insert(wipers, wiper)
		end,
		snapshot = snapshot,
		choice = function(): Types.Choice?
			return if handle then handle.choice else nil
		end,
		stores = function(): Types.Stores?
			return if config then config.stores else nil
		end,
		extend = extend,
	}
end

return Server
