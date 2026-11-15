--!strict
local Catalog = require(script.Parent.Parent.Catalog)

export type Notice = { Text: string, Kind: string }
export type Grant = (player: Player) -> boolean
export type Listener = (player: Player, active: boolean) -> ()

local State = {
	catalog = {} :: Catalog.Catalog,
	grants = {} :: { [string]: Grant },
	passListeners = {} :: { [string]: { Listener } },
	subscriptionListeners = {} :: { [string]: { Listener } },
	notify = function(_player: Player, _notice: Notice) end,
	started = false,
}

function State.item(name: any): Catalog.Item?
	return if type(name) == "string" then State.catalog[name] else nil
end

function State.tell(player: Player, notice: Notice)
	local ok, err = pcall(function()
		State.notify(player, notice)
	end)
	if not ok then
		warn(`[Market] the notify callback failed: {tostring(err)}`)
	end
end

return State
