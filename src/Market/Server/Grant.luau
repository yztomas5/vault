--!strict
local Passes = require(script.Parent.Passes)
local State = require(script.Parent.State)

local Grant = {}

function Grant.ready(name: string): boolean
	local item = State.catalog[name]
	if not item then
		return false
	end
	if item.Kind == "Product" then
		return State.grants[name] ~= nil
	end
	return item.Kind == "Pass" and item.GiftProduct ~= nil
end

function Grant.apply(player: Player, name: string): boolean
	local item = State.catalog[name]
	if not item then
		return false
	end
	if item.Kind == "Pass" then
		return Passes.grantGift(player, name)
	end
	local handler = State.grants[name]
	if not handler then
		return false
	end
	return handler(player) == true
end

return Grant
