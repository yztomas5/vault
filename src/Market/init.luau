--!strict
local RunService = game:GetService("RunService")

local Catalog = require(script.Catalog)
local Client = require(script.Client)
local Settings = require(script.Settings)

export type Item = Catalog.Item
export type Catalog = Catalog.Catalog
export type Notice = { Text: string, Kind: string }
export type Server = typeof(require(script.Server))

return {
	server = (if RunService:IsServer() then require(script.Server) else nil) :: Server,
	client = Client,
	Settings = Settings,
}
