local Drivers = {}

export type Session = {
	data: { [string]: any },
	loads: number,
	active: () -> boolean,
	save: () -> (),
	release: () -> (),
	onEnd: (fn: () -> ()) -> (),
	onSaved: (fn: (data: any) -> ()) -> (),
	onMessage: (fn: (message: any, processed: () -> ()) -> ()) -> (),
}

export type Store = {
	start: (key: string, cancel: (() -> boolean)?) -> Session?,
	view: (key: string) -> any,
	message: (key: string, message: any) -> boolean,
	remove: (key: string) -> boolean,
}

export type Driver = {
	name: string,
	open: (name: string, template: { [string]: any }) -> Store,
	closing: () -> boolean,
}

Drivers.list = { "ProfileStore", "Engine" }

Drivers.traits = {
	ProfileStore = { ghostLocks = true, stuckOnRemovedKeys = true },
	Engine = { ghostLocks = false, stuckOnRemovedKeys = false },
}

function Drivers.ProfileStore(server: any): Driver
	local ProfileStore = server.require("ReplicatedStorage.Packages.ProfileStore")

	local function wrap(profile: any): Session
		return {
			data = profile.Data,
			loads = profile.SessionLoadCount,
			active = function(): boolean
				return profile:IsActive()
			end,
			save = function()
				profile:Save()
			end,
			release = function()
				profile:EndSession()
			end,
			onEnd = function(fn: () -> ())
				profile.OnSessionEnd:Connect(fn)
			end,
			onSaved = function(fn: (data: any) -> ())
				profile.OnAfterSave:Connect(fn)
			end,
			onMessage = function(fn: (message: any, processed: () -> ()) -> ())
				profile:MessageHandler(fn)
			end,
		}
	end

	return {
		name = "ProfileStore",
		open = function(name: string, template: { [string]: any }): Store
			local source = ProfileStore.New(name, template)
			return {
				start = function(key: string, cancel: (() -> boolean)?): Session?
					local profile = source:StartSessionAsync(key, if cancel then { Cancel = cancel } else nil)
					return if profile then wrap(profile) else nil
				end,
				view = function(key: string): any
					local profile = source:GetAsync(key)
					return if profile then profile.Data else nil
				end,
				message = function(key: string, message: any): boolean
					return source:MessageAsync(key, message)
				end,
				remove = function(key: string): boolean
					return source:RemoveAsync(key)
				end,
			}
		end,
		closing = function(): boolean
			return ProfileStore.IsClosing
		end,
	}
end

function Drivers.Engine(server: any): Driver
	local Engine = server.require("ReplicatedStorage.Packages.Vault.Engine")
	local engine = Engine.shared()

	local function wrap(session: any): Session
		return {
			data = session.data,
			loads = session.loadCount,
			active = session.active,
			save = session.save,
			release = session.release,
			onEnd = function(fn: () -> ())
				session.onSessionEnd.connect(fn)
			end,
			onSaved = function(fn: (data: any) -> ())
				session.onAfterSave.connect(fn)
			end,
			onMessage = session.onMessage,
		}
	end

	return {
		name = "Engine",
		open = function(name: string, template: { [string]: any }): Store
			local source = engine.open(name, template)
			return {
				start = function(key: string, cancel: (() -> boolean)?): Session?
					local session = source.start(key, if cancel then { cancel = cancel } else nil)
					return if session then wrap(session) else nil
				end,
				view = function(key: string): any
					local view = source.view(key)
					return if view then view.data else nil
				end,
				message = source.message,
				remove = source.remove,
			}
		end,
		closing = engine.closing,
	}
end

return Drivers
