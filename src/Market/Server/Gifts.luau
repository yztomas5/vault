--!strict
local Players = game:GetService("Players")

local Catalog = require(script.Parent.Parent.Catalog)
local Settings = require(script.Parent.Parent.Settings)

local Data = require(script.Parent.Data)
local Grant = require(script.Parent.Grant)
local Intents = require(script.Parent.Intents)
local Passes = require(script.Parent.Passes)
local Regional = require(script.Parent.Regional)
local State = require(script.Parent.State)

local Gifts = {}

export type Message = {
	PurchaseId: string,
	Item: string,
	From: number,
	FromName: string,
}

local REFUSALS = Settings.Refusals

local function wellFormed(data: any): boolean
	return type(data) == "table"
		and type(data.PurchaseId) == "string"
		and type(data.Item) == "string"
		and type(data.From) == "number"
		and type(data.FromName) == "string"
end

function Gifts.receive(player: Player, data: any): boolean
	if not wellFormed(data) then
		warn(`[Market] dropped a malformed gift for {player.Name}`)
		return true
	end
	if Data.listed(player, "Received", data.PurchaseId) then
		return true
	end
	if not Grant.ready(data.Item) then
		warn(`[Market] the gift {data.Item} for {player.Name} has no handler, kept for later`)
		return false
	end
	local ok, granted = pcall(Grant.apply, player, data.Item)
	if not ok or granted ~= true then
		warn(`[Market] the gift {data.Item} for {player.Name} was not applied: {tostring(granted)}`)
		return false
	end
	Data.remember(player, "Received", data.PurchaseId)
	Data.save(player)
	State.tell(player, {
		Text = string.format(Settings.Texts.GiftReceived, data.FromName, Catalog.displayName(State.catalog, data.Item)),
		Kind = "Reward",
	})
	return true
end

function Gifts.request(buyer: Player, name: any, recipientId: any): (boolean, string?)
	local item = State.item(name)
	if not item or not Grant.ready(name) then
		return false, REFUSALS.Unknown
	end
	if not Catalog.giftable(item) then
		return false, REFUSALS.NotGiftable
	end
	if type(recipientId) ~= "number" or recipientId == buyer.UserId then
		return false, REFUSALS.Self
	end
	local recipient = Players:GetPlayerByUserId(recipientId)
	if not recipient then
		return false, REFUSALS.NoRecipient
	end
	if item.Kind == "Pass" and Passes.owns(recipient, name) then
		return false, REFUSALS.Owned
	end
	if not Data.loaded(buyer) then
		return false, REFUSALS.Busy
	end
	local allowed = Regional.giftAllowed(buyer.UserId, recipientId)
	if allowed == nil then
		return false, REFUSALS.Busy
	end
	if not allowed then
		return false, REFUSALS.Region
	end
	local productId = Catalog.productId(item) :: number
	if not Intents.gift(buyer, productId, recipient) then
		return false, REFUSALS.Busy
	end
	if not Intents.prompt(buyer, productId) then
		Intents.clear(buyer, productId)
		return false, REFUSALS.Busy
	end
	return true, nil
end

function Gifts.send(buyer: Player, name: string, intent: Intents.Intent, purchaseId: string): boolean
	local message: Message = {
		PurchaseId = purchaseId,
		Item = name,
		From = buyer.UserId,
		FromName = buyer.Name,
	}
	return Data.send(intent.RecipientId, message)
end

return Gifts
