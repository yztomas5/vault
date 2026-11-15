local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Hop = require(script.Parent.Hop)
local Report = require(script.Parent.Report)
local Shapes = require(script.Parent.Shapes)
local Suite = require(script.Parent.Suite)

local Main = {}

function Main.run()
	local packages = ReplicatedStorage:FindFirstChild("Packages")
	local Vault = require(packages.Vault)
	local Engine = require(packages.Vault.Engine)
	local ProfileStore = require(packages.ProfileStore)
	local Global = require(packages.Vault.Global)

	local report = Report.new()
	local suite: "idle" | "running" | "done" = "idle"

	local function runSuite()
		if suite == "idle" then
			suite = "running"
			report.line("Running the suite against the real data store. It takes about three minutes.")
			Suite.run(report, Engine, Vault, ProfileStore, Global)
			Shapes.run(report)
			local passed, failed = report.totals()
			report.line("")
			report.line(`SUITE RESULT: {passed} passed, {failed} failed`)
			suite = "done"
		end
		while suite ~= "done" do
			task.wait(0.5)
		end
	end

	report.line(`Vault real test, {if RunService:IsStudio() then "Studio" else "live server"}`)
	local access = Engine.shared().ready()
	if access ~= "Access" then
		report.line(`No access to the data store ({access}).`)
		report.line("Publish this place, then turn on Game Settings > Security > Enable Studio Access to API Services.")
		return
	end
	if RunService:IsStudio() then
		runSuite()
		report.line("Publish this place and join it from Roblox to run the hop test across real servers.")
		return
	end

	Hop.start(report, Vault, function(_: any, arrivedByHop: boolean)
		if not arrivedByHop then
			runSuite()
			report.line("")
			report.line("Starting the hop test: you will be teleported through four servers. Do not leave.")
		end
	end)
end

return Main
