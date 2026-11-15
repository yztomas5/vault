--!strict
local Players = game:GetService("Players")

local Catalog = require(script.Parent.Parent.Catalog)
local Settings = require(script.Parent.Parent.Settings)

local Data = require(script.Parent.Data)
local Gifts = require(script.Parent.Gifts)
local Grant = require(script.Parent.Grant)
local Intents = require(script.Parent.Intents)
local Receipts = require(script.Parent.Receipts)
local State = require(script.Parent.State)

local Products = {}

export type Receipt = {
	PurchaseId: string | number,
	PlayerId: number,
	ProductId: number,
	[string]: any,
}

local _inFlight: { [string]: boolean } = {}

local function tell(player: Player, text: string, kind: string)
	if player.Parent == Players then
		State.tell(player, { Text = text, Kind = kind })
	end
end

local function settle(player: Player, name: string, receipt: Receipt, purchaseId: string): Enum.ProductPurchaseDecision
	local ready = Receipts.waitFor(function(): boolean
		return player.Parent ~= Players or Data.loaded(player)
	end, Settings.ReceiptLoadSeconds)
	if not ready or not Data.loaded(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local intent = Intents.current(player, receipt.ProductId)
	local outcome = Receipts.settle(player, purchaseId, function(): any
		if intent then
			return Gifts.send(player, name, intent, purchaseId)
		end
		return Grant.apply(player, name)
	end)
	if outcome.Problem then
		warn(`[Market] receipt {purchaseId} for {name} ({player.Name}): {outcome.Problem}`)
	end
	if outcome.Decision ~= Enum.ProductPurchaseDecision.PurchaseGranted then
		tell(player, Settings.Texts.Failed, "Error")
		return outcome.Decision
	end
	Intents.clear(player, receipt.ProductId)
	if intent and outcome.Granted then
		tell(player, string.format(Settings.Texts.GiftSent, Catalog.displayName(State.catalog, name), intent.RecipientName), "Success")
	end
	return outcome.Decision
end

function Products.processReceipt(receipt: Receipt): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local name = Catalog.byProduct(State.catalog, receipt.ProductId)
	if not name or not Grant.ready(name) then
		warn(`[Market] no handler for product {receipt.ProductId} ({player.Name})`)
		tell(player, Settings.Texts.Failed, "Error")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(receipt.PurchaseId)
	if _inFlight[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	_inFlight[purchaseId] = true
	local ok, decision = pcall(settle, player, name, receipt, purchaseId)
	_inFlight[purchaseId] = nil
	if not ok then
		warn(`[Market] receipt {purchaseId} failed for {player.Name}: {tostring(decision)}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

function Products.buy(player: Player, name: any): (boolean, string?)
	local item = State.item(name)
	if not item or item.Kind ~= "Product" or not Grant.ready(name) then
		return false, Settings.Refusals.Unknown
	end
	Intents.clear(player)
	if not Intents.prompt(player, item.Id :: number) then
		return false, Settings.Refusals.Busy
	end
	return true, nil
end

return Products
