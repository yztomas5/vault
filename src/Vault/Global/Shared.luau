--!strict
local HttpService = game:GetService("HttpService")

local Engine = require(script.Parent.Parent.Engine)
local Mode = require(script.Parent.Mode)

local Record = Engine.Record
local Storable = Engine.Storable

export type Options = {
	template: any?,
	refreshSeconds: number?,
}

export type Shared = {
	name: string,
	get: (key: string) -> (any, boolean),
	update: (key: string, transform: (current: any) -> any) -> (boolean, any),
	observe: (key: string, listener: (value: any) -> ()) -> () -> (),
}

type Entry = {
	version: number,
	value: any,
	listeners: { (any) -> () },
	waiting: { thread }?,
}

local Shared = {}

local KEY_LENGTH = 50
local REFRESH_SECONDS = 60
local LOAD_ATTEMPTS = 3
local UPDATE_ATTEMPTS = 3
local MESSAGE_BYTES = 900
local TOPIC_PREFIX = "Vault_"
local REMEMBERED_IDS = 32

local function unwrap(stored: any): (number, any)
	if type(stored) == "table" and type(stored.Version) == "number" then
		return stored.Version, stored.Data
	end
	return 0, nil
end

local function fits(value: any): boolean
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(value)
	end)
	return ok and #encoded <= MESSAGE_BYTES
end

function Shared.new(context: any, name: string, options: Options?): Shared
	Mode.checkName(name)
	local opts: Options = options or {}
	if opts.template ~= nil then
		local fatal = Storable.check(opts.template)
		assert(fatal == nil, `[Vault] the template of {name} cannot be stored: {fatal}`)
	end
	local template = Record.copy(opts.template)
	local refreshSeconds = opts.refreshSeconds or REFRESH_SECONDS
	local engine = context.engine
	local entries: { [string]: Entry } = {}
	local listening = false

	local function mode(): Mode.Mode
		return Mode.current(context)
	end

	local function store(): any
		local current = mode()
		return engine.plain(Mode.storeName(current, name), Mode.mock(current))
	end

	local function shape(value: any): any
		if value == nil then
			return Record.copy(template)
		end
		if type(value) == "table" and type(template) == "table" then
			Record.reconcile(value, template)
		end
		return value
	end

	local function entry(key: string): Entry
		local found = entries[key]
		if not found then
			found = { version = -1, value = nil, listeners = {}, waiting = nil }
			entries[key] = found
		end
		return found
	end

	local function apply(key: string, version: number, value: any)
		local found = entry(key)
		if version <= found.version then
			return
		end
		found.version = version
		found.value = value
		for _, listener in table.clone(found.listeners) do
			task.spawn(listener, Record.copy(value))
		end
	end

	local function fetch(key: string): boolean
		for attempt = 1, LOAD_ATTEMPTS do
			local ok, stored = store().read(key)
			if ok then
				local version, data = unwrap(stored)
				apply(key, version, shape(data))
				return true
			end
			task.wait(attempt)
		end
		return false
	end

	local function topic(): string
		return TOPIC_PREFIX .. Mode.storeName(mode(), name)
	end

	local function onMessage(data: any)
		if type(data) ~= "table" or type(data.k) ~= "string" or type(data.v) ~= "number" then
			return
		end
		local found = entries[data.k]
		if not found or found.version < 0 or data.v <= found.version then
			return
		end
		if data.h then
			apply(data.k, data.v, shape(data.d))
		else
			task.spawn(fetch, data.k)
		end
	end

	local function refresh()
		while true do
			task.wait(refreshSeconds)
			for key, found in entries do
				if found.version >= 0 or #found.listeners > 0 then
					fetch(key)
				end
			end
		end
	end

	local function listen()
		if listening then
			return
		end
		listening = true
		if not Mode.mock(mode()) then
			task.spawn(engine.subscribe, topic(), onMessage)
		end
		task.spawn(refresh)
	end

	local function load(key: string): boolean
		local found = entry(key)
		if found.version >= 0 then
			return true
		end
		local waiting = found.waiting
		if waiting then
			table.insert(waiting, coroutine.running())
			coroutine.yield()
			return found.version >= 0
		end
		found.waiting = {}
		listen()
		local loaded = fetch(key)
		local resumed = found.waiting :: { thread }
		found.waiting = nil
		for _, thread in resumed do
			task.spawn(thread)
		end
		return loaded
	end

	local function announce(key: string, version: number, value: any)
		if Mode.mock(mode()) then
			return
		end
		local small = fits(value)
		engine.publish(topic(), { k = key, v = version, h = small, d = if small then value else nil })
	end

	local function get(key: string): (any, boolean)
		Mode.checkKey(key, KEY_LENGTH)
		local loaded = load(key)
		local found = entry(key)
		return if loaded then Record.copy(found.value) else nil, loaded
	end

	local function update(key: string, transform: (current: any) -> any): (boolean, any)
		Mode.checkKey(key, KEY_LENGTH)
		if not Mode.writable(mode()) then
			warn(`[Vault] {name} is read only in this Studio session, {key} not written`)
			return false, nil
		end
		listen()
		local id = engine.guid()
		for attempt = 1, UPDATE_ATTEMPTS do
			local fatal: string? = nil
			local seen: any = nil
			local already = false
			local seenVersion = 0
			local ok, stored = store().update(key, function(current: any): any
				local version, data = unwrap(current)
				seen = shape(data)
				seenVersion = version
				local ids = if type(current) == "table" and type(current.Ids) == "table" then current.Ids else {}
				already = table.find(ids, id) ~= nil
				if already then
					return nil
				end
				local computed, value = pcall(transform, Record.copy(seen))
				if not computed then
					fatal = `the transform failed: {tostring(value)}`
					return nil
				end
				if value == nil then
					return nil
				end
				local refused = Storable.check(value)
				if refused then
					fatal = refused
					return nil
				end
				local remembered = table.clone(ids)
				table.insert(remembered, id)
				while #remembered > REMEMBERED_IDS do
					table.remove(remembered, 1)
				end
				return { Version = version + 1, Data = value, Ids = remembered }
			end)
			if fatal then
				warn(`[Vault] update of {name}/{key} rejected: {fatal}`)
				return false, nil
			end
			if ok then
				if stored == nil and already then
					apply(key, seenVersion, seen)
					announce(key, seenVersion, seen)
					return true, Record.copy(seen)
				end
				if stored == nil then
					return false, Record.copy(seen)
				end
				local version, data = unwrap(stored)
				local value = shape(data)
				apply(key, version, value)
				announce(key, version, value)
				return true, Record.copy(value)
			end
			task.wait(attempt)
		end
		return false, nil
	end

	local function observe(key: string, listener: (value: any) -> ()): () -> ()
		Mode.checkKey(key, KEY_LENGTH)
		local found = entry(key)
		table.insert(found.listeners, listener)
		if found.version >= 0 then
			task.spawn(listener, Record.copy(found.value))
		else
			task.spawn(load, key)
		end
		return function()
			local index = table.find(found.listeners, listener)
			if index then
				table.remove(found.listeners, index)
			end
		end
	end

	return {
		name = name,
		get = get,
		update = update,
		observe = observe,
	}
end

return Shared
