--!strict
local Replica = require(script.Parent.Replica)
local Types = require(script.Parent.Types)

type Batch = { sequence: number, changes: { Types.Change } }

local Client = {}

local DEFAULT_RETRY_SECONDS = 1

local _config: Types.ClientConfig? = nil
local _replica = Replica.new({})
local _ready = false
local _sequence = 0
local _early: { Batch } = {}
local _waiting: { thread } = {}
local _requests: { [string]: number } = {}
local _arrivals: { [string]: number } = {}

local function settings(): Types.ClientConfig
	return assert(_config, "[Vault] start the client before using it")
end

local function settingKeyOf(path: any): string?
	if type(path) ~= "table" then
		return nil
	end
	local root: { any } = (_config and _config.settingsPath) or { "settings" }
	for index, name in root do
		if path[index] ~= name then
			return nil
		end
	end
	local key = path[#root + 1]
	return if type(key) == "string" then key else nil
end

local function noteArrivals(changes: { Types.Change })
	for _, change in changes do
		local key = settingKeyOf(change[1])
		if key then
			_arrivals[key] = (_arrivals[key] or 0) + 1
		end
	end
end

local function applyBatch(sequence: number, changes: { Types.Change })
	if sequence <= _sequence then
		return
	end
	_sequence = sequence
	noteArrivals(changes)
	_replica:apply(changes)
end

local function receive(sequence: number, changes: any)
	if type(changes) ~= "table" then
		return
	end
	if _ready then
		applyBatch(sequence, changes)
	else
		table.insert(_early, { sequence = sequence, changes = changes })
	end
end

local function boot(config: Types.ClientConfig)
	local sequence, data
	while true do
		sequence, data = config.packets.snapshot:Fire()
		if type(data) == "table" then
			break
		end
		task.wait(config.retrySeconds or DEFAULT_RETRY_SECONDS)
	end
	_sequence = if type(sequence) == "number" then sequence else 0
	_replica:replace(data)
	table.sort(_early, function(a: Batch, b: Batch): boolean
		return a.sequence < b.sequence
	end)
	for _, batch in _early do
		applyBatch(batch.sequence, batch.changes)
	end
	table.clear(_early)
	_ready = true
	local waiting = _waiting
	_waiting = {}
	for _, thread in waiting do
		task.spawn(thread)
	end
end

function Client.start(config: Types.ClientConfig)
	assert(_config == nil, "[Vault] the client is already started")
	_config = config
	config.packets.changes.OnClientEvent:Connect(receive)
	task.spawn(boot, config)
end

function Client.loaded(): boolean
	return _ready
end

function Client.ready(): boolean
	if not _ready then
		table.insert(_waiting, coroutine.running())
		coroutine.yield()
	end
	return true
end

function Client.get(path: Types.PathLike): any
	return _replica:get(Replica.path(path))
end

function Client.observe(path: Types.PathLike, listener: Types.Listener): Types.Disconnect
	return _replica:observe(Replica.path(path), listener)
end

type Pending = { value: any, origin: any, due: number, scheduled: boolean }

local _pending: { [string]: Pending } = {}

local function settingPath(key: string): { any }
	local path = table.clone(settings().settingsPath or { "settings" })
	table.insert(path, key)
	return path
end

local function send(key: string)
	local pending = _pending[key]
	if not pending then
		return
	end
	_pending[key] = nil
	local number = _requests[key]
	local arrivals = _arrivals[key] or 0
	local ok, current = (settings().packets.setting :: any):Fire(key, pending.value)
	if _requests[key] ~= number or ok == true then
		return
	end
	if ok == nil and (_arrivals[key] or 0) ~= arrivals then
		return
	end
	local restored = if ok == false and current ~= nil then current else pending.origin
	if restored ~= nil then
		_replica:apply({ { settingPath(key), "set", restored } })
	end
end

local function schedule(key: string, pending: Pending)
	if pending.scheduled then
		return
	end
	pending.scheduled = true
	task.spawn(function()
		while _pending[key] == pending do
			local remaining = pending.due - os.clock()
			if remaining <= 0 then
				break
			end
			task.wait(remaining)
		end
		Client.ready()
		if _pending[key] == pending then
			send(key)
		end
	end)
end

function Client.setSetting(key: string, value: any)
	local config = settings()
	assert(config.packets.setting, "[Vault] no setting packet configured")
	_requests[key] = (_requests[key] or 0) + 1
	local path = settingPath(key)
	local pending = _pending[key]
	if not pending then
		pending = { value = value, origin = _replica:get(path), due = 0, scheduled = false }
		_pending[key] = pending
	end
	pending.value = value
	pending.due = os.clock() + (config.settingDelay or 0)
	if _ready then
		_replica:apply({ { path, "set", value } })
	end
	schedule(key, pending)
end

function Client.flushSetting(key: string)
	local pending = _pending[key]
	if not pending then
		return
	end
	pending.due = 0
	if _ready then
		task.spawn(send, key)
	end
end

function Client.flushSettings()
	for key in _pending do
		Client.flushSetting(key)
	end
end

return Client
