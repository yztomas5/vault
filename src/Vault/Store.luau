--!strict
local Engine = require(script.Parent.Engine)
local Types = require(script.Parent.Types)

export type Handle = {
	choice: Types.Choice,
	source: Engine.Keys,
}

local Store = {}

function Store.choose(studio: boolean, wanted: Types.StudioData?, access: boolean, stores: Types.Stores): Types.Choice
	if not studio then
		return { kind = "Session", name = stores.production }
	end
	local mode = wanted or "Mock"
	if mode == "Mock" then
		return { kind = "Mock", name = stores.studio }
	end
	if not access then
		return {
			kind = "Mock",
			name = stores.studio,
			reason = `Studio has no API access, StudioData {mode} falls back to Mock`,
		}
	end
	if mode == "Studio" then
		return { kind = "Session", name = stores.studio }
	end
	if mode == "ProductionReadOnly" then
		return { kind = "ReadOnly", name = stores.production }
	end
	if mode == "Production" then
		return { kind = "Session", name = stores.production }
	end
	return { kind = "Mock", name = stores.studio, reason = `unknown StudioData {tostring(mode)}, using Mock` }
end

function Store.guard(studio: boolean, choice: Types.Choice, stores: Types.Stores, allowProduction: boolean?)
	assert(stores.studio ~= stores.production, "[Vault] the Studio store must not be the production store")
	assert(
		allowProduction == true or not (studio and choice.kind == "Session" and choice.name == stores.production),
		"[Vault] Studio can never open a session on the production store"
	)
end

function Store.access(): boolean
	return Engine.shared().ready() == "Access"
end

function Store.open(choice: Types.Choice, template: { [string]: any }): Handle
	local store = Engine.shared().open(choice.name, template)
	return {
		choice = choice,
		source = if choice.kind == "Mock" then store.mock else store,
	}
end

return Store
