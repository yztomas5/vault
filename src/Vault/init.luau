--!strict
local RunService = game:GetService("RunService")

local Client = require(script.Client)
local Migrations = require(script.Migrations)
local Replica = require(script.Replica)
local Types = require(script.Types)

export type Path = Types.Path
export type PathLike = Types.PathLike
export type Migration = Types.Migration
export type StudioData = Types.StudioData
export type ServerConfig = Types.ServerConfig
export type ClientConfig = Types.ClientConfig
export type Server = typeof(require(script.Server).new())
export type Shared = typeof(require(script.Global).new(nil :: any, nil :: any).shared("", nil))
export type Counter = typeof(require(script.Global).new(nil :: any, nil :: any).counter("", nil))
export type Leaderboard = typeof(require(script.Global).new(nil :: any, nil :: any).leaderboard("", nil))

local CHOICE_WAIT_SECONDS = 15

local function newServer(): Server
	return require(script.Server).new()
end

local server = (if RunService:IsServer() then newServer() else nil) :: Server
local global: any = nil

local function resolveMode(): string
	local GlobalModule = require(script.Global)
	if not RunService:IsStudio() then
		return "Live"
	end
	local deadline = os.clock() + CHOICE_WAIT_SECONDS
	while not server.choice() and os.clock() < deadline do
		task.wait()
	end
	local choice = server.choice()
	if not choice then
		warn("[Vault] global data was used before Vault.server started; this Studio session keeps it in memory")
	end
	return GlobalModule.Mode.fromChoice(true, choice, server.stores())
end

local function globalData(): any
	if not RunService:IsServer() then
		error("[Vault] global data is only available on the server", 3)
	end
	if not global then
		local Engine = require(script.Engine)
		global = require(script.Global).new(Engine.shared(), resolveMode :: any)
		server.onWipe(global.wipe)
	end
	return global
end

return {
	server = server,
	client = Client,
	new = newServer,
	Replica = Replica,
	Migrations = Migrations,
	shared = function(name: string, options: any?): Shared
		return globalData().shared(name, options)
	end,
	counter = function(name: string, options: any?): Counter
		return globalData().counter(name, options)
	end,
	leaderboard = function(name: string, options: any?): Leaderboard
		return globalData().leaderboard(name, options)
	end,
}
