--!strict
local Backend = require(script.Backend)
local Budget = require(script.Budget)
local Health = require(script.Health)
local Inbox = require(script.Inbox)
local Lock = require(script.Lock)
local Offline = require(script.Offline)
local Ordered = require(script.Ordered)
local Plain = require(script.Plain)
local Platform = require(script.Platform)
local Queue = require(script.Queue)
local Record = require(script.Record)
local Saver = require(script.Saver)
local Session = require(script.Session)
local Settings = require(script.Settings)
local Shutdown = require(script.Shutdown)
local Storable = require(script.Storable)
local Wheel = require(script.Wheel)

export type Env = Platform.Env
export type Identity = Record.Identity
export type Stored = Record.Stored
export type Session = Session.Session
export type View = Offline.View
export type Outcome = Saver.Outcome
export type State = "NotReady" | "NoInternet" | "NoAccess" | "Access"
export type Priority = Budget.Priority
export type Row = Ordered.Row

export type PlainStore = {
	update: (key: string, transform: Plain.Transform, priority: Priority?) -> (boolean, any),
	read: (key: string) -> (boolean, any),
	remove: (key: string) -> boolean,
}

export type OrderedStore = {
	set: (key: string, value: number, priority: Priority?) -> boolean,
	remove: (key: string) -> boolean,
	top: (count: number, ascending: boolean?) -> (boolean, { Row }?),
}

export type Keys = {
	start: (key: string, params: Session.Params?) -> Session?,
	view: (key: string) -> View?,
	message: (key: string, message: any) -> boolean,
	remove: (key: string) -> boolean,
}

export type Store = Keys & {
	name: string,
	mock: Keys,
}

export type Engine = {
	open: (name: string, template: { [string]: any }?) -> Store,
	state: () -> State,
	ready: () -> State,
	closing: () -> boolean,
	critical: () -> boolean,
	onError: (listener: (message: string, storeName: string, key: string) -> ()) -> () -> (),
	onOverwrite: (listener: (storeName: string, key: string) -> ()) -> () -> (),
	onCritical: (listener: (critical: boolean) -> ()) -> () -> (),
	onSize: (listener: (storeName: string, key: string, bytes: number, limit: number) -> ()) -> () -> (),
	plain: (name: string, mock: boolean?) -> PlainStore,
	ordered: (name: string, mock: boolean?) -> OrderedStore,
	publish: (topic: string, data: any) -> boolean,
	subscribe: (topic: string, listener: (data: any) -> ()) -> () -> (),
	beforeClose: (fn: () -> ()) -> (),
	guid: () -> string,
}

local Engine = {}

local shared: Engine? = nil

function Engine.new(platform: Env?, overrides: { [string]: any }?): Engine
	local env = platform or Platform.live()
	local settings: { [string]: any } = table.clone(Settings)
	for name, value in overrides or {} do
		assert(settings[name] ~= nil, `[Vault] unknown engine setting {name}`)
		settings[name] = value
	end
	local context = {
		env = env,
		settings = settings,
		state = "NotReady" :: State,
		closing = false,
		sessions = {},
		loadJobs = 0,
		saveJobs = 0,
		loadIndex = 0,
		throttledUntil = 0,
		queue = Queue.new(),
		health = Health.new(),
		wheel = Wheel.new(env.clock()),
		memory = { user = {}, fallback = {}, plainUser = {}, plainFallback = {}, orderedUser = {}, orderedFallback = {} },
		plainStores = {},
		orderedStores = {},
		closers = {},
	}

	Backend.probe(context)
	Shutdown.bind(context)
	env.heartbeat(function()
		Wheel.step(context, function(session: Session)
			task.spawn(Saver.save, context, session, false)
		end)
		Health.step(context)
	end)

	local function keys(store: any, mock: boolean): Keys
		return {
			start = function(key: string, params: Session.Params?): Session?
				return Session.start(context, store, key, mock, params)
			end,
			view = function(key: string): View?
				return Offline.view(context, store, key, mock)
			end,
			message = function(key: string, message: any): boolean
				return Inbox.send(context, store, key, mock, message)
			end,
			remove = function(key: string): boolean
				return Offline.remove(context, store, key, mock)
			end,
		}
	end

	local function checkName(name: any)
		if type(name) ~= "string" or #name == 0 then
			error("[Vault] the store name must be a non empty string", 3)
		end
		if #name > settings.NameLength then
			error("[Vault] the store name is too long", 3)
		end
	end

	local function plain(name: string, mock: boolean?): PlainStore
		checkName(name)
		local inMemory = mock == true
		return {
			update = function(key: string, transform: Plain.Transform, priority: Priority?): (boolean, any)
				return Plain.update(context, name, key, inMemory, transform, priority)
			end,
			read = function(key: string): (boolean, any)
				return Plain.read(context, name, key, inMemory)
			end,
			remove = function(key: string): boolean
				return Plain.remove(context, name, key, inMemory)
			end,
		}
	end

	local function ordered(name: string, mock: boolean?): OrderedStore
		checkName(name)
		local inMemory = mock == true
		return {
			set = function(key: string, value: number, priority: Priority?): boolean
				return Ordered.set(context, name, key, value, inMemory, priority)
			end,
			remove = function(key: string): boolean
				return Ordered.remove(context, name, key, inMemory)
			end,
			top = function(count: number, ascending: boolean?): (boolean, { Row }?)
				return Ordered.top(context, name, count, ascending == true, inMemory)
			end,
		}
	end

	local function publish(topic: string, data: any): boolean
		local ok, err = pcall(env.publish, topic, data)
		if not ok then
			warn(`[Vault] could not publish on {topic}: {tostring(err)}`)
		end
		return ok
	end

	local function subscribe(topic: string, listener: (data: any) -> ()): () -> ()
		local ok, connection = pcall(env.subscribe, topic, function(message: any)
			listener(message.Data)
		end)
		if not ok then
			warn(`[Vault] could not subscribe to {topic}: {tostring(connection)}`)
			return function() end
		end
		return function()
			connection:Disconnect()
		end
	end

	local function open(name: string, template: { [string]: any }?): Store
		if type(name) ~= "string" or #name == 0 then
			error("[Vault] the store name must be a non empty string", 2)
		end
		if #name > settings.NameLength then
			error("[Vault] the store name is too long", 2)
		end
		if template ~= nil and type(template) ~= "table" then
			error("[Vault] the template must be a table", 2)
		end
		local store = { name = name, template = template or {}, loadJobs = {}, mockLoadJobs = {}, dataStore = nil }
		local live = keys(store, false)
		return {
			name = name,
			start = live.start,
			view = live.view,
			message = live.message,
			remove = live.remove,
			mock = keys(store, true),
		}
	end

	return {
		open = open,
		state = function(): State
			return context.state
		end,
		ready = function(): State
			Backend.ready(context)
			return context.state
		end,
		closing = function(): boolean
			return context.closing
		end,
		critical = function(): boolean
			return context.health.critical
		end,
		onError = context.health.onError.connect,
		onOverwrite = context.health.onOverwrite.connect,
		onCritical = context.health.onCritical.connect,
		onSize = context.health.onSize.connect,
		plain = plain,
		ordered = ordered,
		publish = publish,
		subscribe = subscribe,
		beforeClose = function(fn: () -> ())
			table.insert(context.closers, fn)
		end,
		guid = env.guid,
	}
end

function Engine.shared(): Engine
	if not shared then
		shared = Engine.new()
	end
	return shared :: Engine
end

Engine.Lock = Lock
Engine.Platform = Platform
Engine.Record = Record
Engine.Settings = Settings
Engine.Storable = Storable

return Engine
