--!strict
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Catalog = require(script.Parent.Catalog)
local Settings = require(script.Parent.Settings)

export type Config = {
	catalog: Catalog.Catalog,
	packets: { buy: any, gift: any },
}

local Client = {}

local _config: Config? = nil

local function config(): Config
	return assert(_config, "[Market] start the client before using it")
end

local function attributeOf(item: Catalog.Item, name: string): string?
	if item.Kind == "Pass" then
		return Settings.PassAttribute .. name
	end
	return if item.Kind == "Subscription" then Settings.SubscriptionAttribute .. name else nil
end

local function ask(run: () -> (any, any)): (boolean, string?)
	local ok, accepted, reason = pcall(run)
	if not ok or accepted == nil then
		return false, Settings.Refusals.Busy
	end
	return accepted == true, if type(reason) == "string" then reason else nil
end

local function prompt(run: () -> ()): (boolean, string?)
	local ok, err = pcall(function()
		run()
	end)
	if not ok then
		warn(`[Market] could not open the purchase prompt: {tostring(err)}`)
		return false, Settings.Refusals.Busy
	end
	return true, nil
end

function Client.start(given: Config)
	assert(_config == nil, "[Market] the client is already started")
	Catalog.check(given.catalog)
	_config = given
end

function Client.buy(name: string): (boolean, string?)
	local item = config().catalog[name]
	if not item then
		return false, Settings.Refusals.Unknown
	end
	local player = Players.LocalPlayer
	if item.Kind == "Pass" then
		return prompt(function()
			MarketplaceService:PromptGamePassPurchase(player, item.Id :: number)
		end)
	end
	if item.Kind == "Subscription" then
		return prompt(function()
			(MarketplaceService :: any):PromptSubscriptionPurchase(player, item.Id)
		end)
	end
	return ask(function(): (any, any)
		return config().packets.buy:Fire(name)
	end)
end

function Client.gift(name: string, userId: number): (boolean, string?)
	local item = config().catalog[name]
	if not item then
		return false, Settings.Refusals.Unknown
	end
	if not Catalog.giftable(item) then
		return false, Settings.Refusals.NotGiftable
	end
	return ask(function(): (any, any)
		return config().packets.gift:Fire(name, userId)
	end)
end

function Client.owns(name: string): boolean
	local item = config().catalog[name]
	local attribute = item and attributeOf(item, name)
	local player = Players.LocalPlayer
	return attribute ~= nil and player ~= nil and player:GetAttribute(attribute) == true
end

function Client.observe(name: string, listener: (owned: boolean) -> ()): () -> ()
	local item = config().catalog[name]
	local attribute = item and attributeOf(item, name)
	assert(attribute, `[Market] only passes and subscriptions can be observed, {name} is not one`)
	local player = Players.LocalPlayer
	local connection = player:GetAttributeChangedSignal(attribute :: string):Connect(function()
		listener(player:GetAttribute(attribute :: string) == true)
	end)
	task.spawn(listener, player:GetAttribute(attribute :: string) == true)
	return function()
		connection:Disconnect()
	end
end

return Client
