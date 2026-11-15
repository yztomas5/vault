--!strict
local Vault = require(script.Parent.Parent.Parent.Vault)

local Settings = require(script.Parent.Parent.Settings)

local Data = {}

export type Field = "Receipts" | "Intent" | "Received" | "Passes"

local DEFAULTS = { Receipts = {}, Intent = {}, Received = {}, Passes = {} }

local function server(): any
	return Vault.server
end

local function path(field: Field): { string }
	return { Settings.DataKey, field }
end

function Data.setup(onGift: (player: Player, data: any) -> boolean?)
	server().extend(Settings.DataKey, DEFAULTS, true)
	server().onMessage(Settings.GiftMessage, onGift)
end

function Data.loaded(player: Player): boolean
	return server().loaded(player)
end

function Data.ready(player: Player, timeout: number?): boolean
	return server().ready(player, timeout)
end

function Data.get(player: Player, field: Field): any
	return server().get(player, path(field))
end

function Data.set(player: Player, field: Field, value: any): boolean
	return server().set(player, path(field), value)
end

function Data.update(player: Player, field: Field, transform: (any) -> any): any
	return server().update(player, path(field), transform)
end

function Data.save(player: Player)
	server().save(player)
end

function Data.saveConfirmed(player: Player, confirmed: (market: any) -> boolean, timeout: number?): boolean
	return server().saveConfirmed(player, function(saved: any): boolean
		local market = if type(saved) == "table" then saved[Settings.DataKey] else nil
		return type(market) == "table" and confirmed(market)
	end, timeout or Settings.SaveConfirmSeconds)
end

function Data.send(userId: number, payload: any): boolean
	return server().sendMessage(userId, Settings.GiftMessage, payload)
end

function Data.remember(player: Player, field: Field, id: string): boolean
	local written = Data.update(player, field, function(current: any): any
		local list = {}
		for _, entry in if type(current) == "table" then current else {} do
			table.insert(list, entry)
		end
		while #list >= Settings.LedgerSize do
			table.remove(list, 1)
		end
		table.insert(list, id)
		return list
	end)
	return written ~= nil
end

function Data.listed(player: Player, field: Field, id: string): boolean
	local list = Data.get(player, field)
	return type(list) == "table" and table.find(list, id) ~= nil
end

return Data
