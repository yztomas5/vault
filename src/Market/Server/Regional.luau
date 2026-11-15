--!strict
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Parent.Settings)

local Regional = {}

local function studioLevels(userIds: { number }): { [number]: number }
	local levels = {}
	for _, userId in userIds do
		local player = Players:GetPlayerByUserId(userId)
		local level = if player then player:GetAttribute(Settings.StudioPriceAttribute) else nil
		levels[userId] = if type(level) == "number" then level else Settings.StudioPriceLevel
	end
	return levels
end

function Regional.levels(userIds: { number }): { [number]: number }?
	if RunService:IsStudio() then
		return studioLevels(userIds)
	end
	local ok, result = pcall(function(): any
		return (MarketplaceService :: any):GetUsersPriceLevelsAsync(userIds)
	end)
	if not ok or type(result) ~= "table" then
		warn(`[Market] could not read price levels: {tostring(result)}`)
		return nil
	end
	local levels = {}
	for _, info in result do
		if type(info) == "table" and type(info.UserId) == "number" and type(info.PriceLevel) == "number" then
			levels[info.UserId] = info.PriceLevel
		end
	end
	return levels
end

function Regional.giftAllowed(sender: number, receiver: number): boolean?
	local levels = Regional.levels({ sender, receiver })
	if not levels or not levels[sender] or not levels[receiver] then
		return nil
	end
	return levels[sender] + Settings.RegionalThreshold >= levels[receiver]
end

return Regional
