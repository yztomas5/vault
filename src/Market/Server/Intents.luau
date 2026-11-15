--!strict
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Settings = require(script.Parent.Parent.Settings)

local Data = require(script.Parent.Data)

local Intents = {}

export type Intent = {
	ProductId: number,
	RecipientId: number,
	RecipientName: string,
	At: number,
}

local function valid(intent: any, productId: number): boolean
	return type(intent) == "table"
		and intent.ProductId == productId
		and type(intent.RecipientId) == "number"
		and type(intent.At) == "number"
		and os.time() - intent.At <= Settings.IntentSeconds
end

function Intents.current(player: Player, productId: number): Intent?
	local intent = Data.get(player, "Intent")
	return if valid(intent, productId) then intent else nil
end

function Intents.gift(player: Player, productId: number, recipient: Player): boolean
	local intent: Intent = {
		ProductId = productId,
		RecipientId = recipient.UserId,
		RecipientName = recipient.Name,
		At = os.time(),
	}
	if not Data.set(player, "Intent", intent) then
		return false
	end
	return Data.saveConfirmed(player, function(market: any): boolean
		local stored = market.Intent
		return type(stored) == "table" and stored.ProductId == productId and stored.RecipientId == recipient.UserId
	end, Settings.IntentSaveSeconds)
end

function Intents.clear(player: Player, productId: number?)
	local intent = Data.get(player, "Intent")
	if type(intent) ~= "table" or next(intent) == nil then
		return
	end
	if productId and intent.ProductId ~= productId then
		return
	end
	Data.set(player, "Intent", {})
	Data.save(player)
end

function Intents.prompt(player: Player, productId: number): boolean
	local ok, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId)
	end)
	if not ok then
		warn(`[Market] could not open the purchase prompt for {player.Name}: {tostring(err)}`)
	end
	return ok
end

local function finished(userId: number, productId: number, purchased: boolean)
	if purchased then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	if player and Data.loaded(player) then
		Intents.clear(player, productId)
	end
end

function Intents.start()
	MarketplaceService.PromptProductPurchaseFinished:Connect(finished)
end

return Intents
