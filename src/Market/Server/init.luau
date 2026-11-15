--!strict
local MarketplaceService = game:GetService("MarketplaceService")

local Catalog = require(script.Parent.Catalog)
local Settings = require(script.Parent.Settings)

local Data = require(script.Data)
local Gifts = require(script.Gifts)
local Intents = require(script.Intents)
local Passes = require(script.Passes)
local Products = require(script.Products)
local State = require(script.State)
local Subscriptions = require(script.Subscriptions)

export type Notice = State.Notice
export type Listener = State.Listener
export type Receipt = Products.Receipt

export type Config = {
	catalog: Catalog.Catalog,
	packets: { buy: any, gift: any }?,
	serve: ((packet: any, label: string, handler: (any, ...any) -> ...any, fallback: (any, ...any) -> ...any) -> ())?,
	notify: ((player: Player, notice: Notice) -> ())?,
}

local Server = {}

local function refused(): (boolean, string?)
	return false, Settings.Refusals.Busy
end

local function defaultServe(packet: any, _label: string, handler: (any, ...any) -> ...any)
	packet.OnServerInvoke = handler
end

local function itemOf(name: string, kind: Catalog.Kind): Catalog.Item
	local item = State.catalog[name]
	assert(item, `[Market] {name} is not in the catalog`)
	assert(item.Kind == kind, `[Market] {name} is a {item.Kind}, not a {kind}`)
	return item
end

function Server.start(config: Config)
	assert(not State.started, "[Market] the server is already started")
	Catalog.check(config.catalog)
	State.started = true
	State.catalog = table.clone(config.catalog)
	if config.notify then
		State.notify = config.notify
	end
	Data.setup(Gifts.receive)
	if config.packets then
		local serve: any = config.serve or defaultServe
		serve(config.packets.buy, "MarketBuy", Products.buy, refused)
		serve(config.packets.gift, "MarketGift", Gifts.request, refused)
	end
	MarketplaceService.ProcessReceipt = Products.processReceipt
	Intents.start()
	Passes.start()
	Subscriptions.start()
end

function Server.product(name: string, grant: State.Grant)
	itemOf(name, "Product")
	assert(type(grant) == "function", "[Market] a product grant must be a function")
	assert(State.grants[name] == nil, `[Market] {name} already has a grant`)
	State.grants[name] = grant
end

local function listen(list: { [string]: { Listener } }, name: string, listener: Listener)
	local listeners = list[name]
	if not listeners then
		listeners = {}
		list[name] = listeners
	end
	table.insert(listeners, listener)
end

function Server.pass(name: string, listener: Listener)
	itemOf(name, "Pass")
	listen(State.passListeners, name, listener)
end

function Server.subscription(name: string, listener: Listener)
	itemOf(name, "Subscription")
	listen(State.subscriptionListeners, name, listener)
end

Server.owns = Passes.owns
Server.subscribed = Subscriptions.active
Server.buy = Products.buy
Server.gift = Gifts.request
Server.processReceipt = Products.processReceipt

return Server
