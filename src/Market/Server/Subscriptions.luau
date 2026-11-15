--!strict
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Catalog = require(script.Parent.Parent.Catalog)
local Settings = require(script.Parent.Parent.Settings)

local State = require(script.Parent.State)

local Subscriptions = {}

local _active: { [Player]: { [string]: boolean } } = {}
local _checks: { [Player]: { [string]: number } } = {}

local function present(player: Player): boolean
	return player.Parent == Players
end

local function status(player: Player, subscriptionId: string): boolean?
	for attempt = 1, Settings.LookupAttempts do
		local ok, result = pcall(function(): any
			return (MarketplaceService :: any):GetUserSubscriptionStatusAsync(player, subscriptionId)
		end)
		if ok and type(result) == "table" then
			return result.IsSubscribed == true
		end
		if attempt < Settings.LookupAttempts then
			task.wait(Settings.LookupRetrySeconds)
		end
	end
	warn(`[Market] could not check subscription {subscriptionId} for {player.Name}`)
	return nil
end

local function set(player: Player, name: string, active: boolean)
	local states = _active[player]
	if not states then
		states = {}
		_active[player] = states
	end
	if states[name] == active then
		return
	end
	states[name] = active
	player:SetAttribute(Settings.SubscriptionAttribute .. name, active)
	for _, listener in table.clone(State.subscriptionListeners[name] or {}) do
		task.spawn(listener, player, active)
	end
end

local function check(player: Player, name: string)
	local item = State.catalog[name]
	if not item or item.Kind ~= "Subscription" then
		return
	end
	local checks = _checks[player]
	if not checks then
		checks = {}
		_checks[player] = checks
	end
	local number = (checks[name] or 0) + 1
	checks[name] = number
	local active = status(player, item.Id :: string)
	if active == nil or not present(player) or checks[name] ~= number then
		return
	end
	set(player, name, active)
end

function Subscriptions.active(player: Player, name: string): boolean
	local states = _active[player]
	return states ~= nil and states[name] == true
end

local function join(player: Player)
	for name, item in State.catalog do
		if item.Kind == "Subscription" then
			task.spawn(check, player, name)
		end
	end
end

local function changed(player: Player, subscriptionId: string)
	local name = Catalog.bySubscription(State.catalog, subscriptionId)
	if name then
		task.spawn(check, player, name)
	end
end

function Subscriptions.start()
	(Players :: any).UserSubscriptionStatusChanged:Connect(changed)
	Players.PlayerAdded:Connect(join)
	Players.PlayerRemoving:Connect(function(player: Player)
		_active[player] = nil
		_checks[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		join(player)
	end
end

return Subscriptions
