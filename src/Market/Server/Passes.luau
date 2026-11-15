--!strict
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Catalog = require(script.Parent.Parent.Catalog)
local Settings = require(script.Parent.Parent.Settings)

local Data = require(script.Parent.Data)
local State = require(script.Parent.State)

local Passes = {}

local _owned: { [Player]: { [string]: boolean } } = {}

local function present(player: Player): boolean
	return player.Parent == Players
end

local function ownedBy(player: Player): { [string]: boolean }
	local owned = _owned[player]
	if not owned then
		owned = {}
		_owned[player] = owned
	end
	return owned
end

local function mark(player: Player, name: string)
	if not present(player) then
		return
	end
	local owned = ownedBy(player)
	if owned[name] then
		return
	end
	owned[name] = true
	player:SetAttribute(Settings.PassAttribute .. name, true)
	for _, listener in table.clone(State.passListeners[name] or {}) do
		task.spawn(listener, player, true)
	end
end

local function lookup(player: Player, passId: number): boolean
	for attempt = 1, Settings.LookupAttempts do
		local ok, owns = pcall(function(): boolean
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			return owns == true
		end
		if attempt < Settings.LookupAttempts then
			task.wait(Settings.LookupRetrySeconds)
		end
	end
	warn(`[Market] could not check pass {passId} for {player.Name}`)
	return false
end

function Passes.gifted(player: Player, name: string): boolean
	local gifted = Data.get(player, "Passes")
	return type(gifted) == "table" and gifted[name] == true
end

function Passes.refresh(player: Player, name: string)
	if Passes.gifted(player, name) then
		mark(player, name)
	end
end

function Passes.owns(player: Player, name: string): boolean
	local owned = _owned[player]
	return owned ~= nil and owned[name] == true
end

function Passes.grantGift(player: Player, name: string): boolean
	local written = Data.update(player, "Passes", function(current: any): any
		local passes = if type(current) == "table" then current else {}
		passes[name] = true
		return passes
	end)
	if written == nil then
		return false
	end
	mark(player, name)
	return true
end

local function check(player: Player)
	for name, item in State.catalog do
		if item.Kind == "Pass" then
			task.spawn(function()
				if lookup(player, item.Id :: number) then
					mark(player, name)
				end
			end)
		end
	end
	task.defer(function()
		if Data.ready(player) and present(player) then
			for name, item in State.catalog do
				if item.Kind == "Pass" then
					Passes.refresh(player, name)
				end
			end
		end
	end)
end

local function purchased(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	local name = Catalog.byPass(State.catalog, passId)
	if name then
		mark(player, name)
	end
end

function Passes.start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(purchased)
	Players.PlayerAdded:Connect(check)
	Players.PlayerRemoving:Connect(function(player: Player)
		_owned[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		check(player)
	end
end

return Passes
