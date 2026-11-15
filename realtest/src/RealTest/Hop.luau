local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")

local Hop = {}

local TARGET = 4
local STAY_SECONDS = 15
local LOAD_SECONDS = 90
local TELEPORT_ATTEMPTS = 3
local STORES = { production = "VaultRealTestHop", studio = "VaultRealTestHopStudio" }
local MARK = "VaultRealTest"

local function seconds(value: number): string
	return string.format("%.1f s", value)
end

local function serverName(): string
	local job = game.JobId
	local short = if #job > 8 then string.sub(job, 1, 8) else job
	return if game.PrivateServerId ~= "" then `{short} (reserved)` else short
end

local function chainOf(player: any): any
	local data = player:GetJoinData()
	local teleport = if type(data) == "table" then data.TeleportData else nil
	return if type(teleport) == "table" then teleport[MARK] else nil
end

local function send(player: any, hops: number): (boolean, string?)
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ [MARK] = { expected = hops } })
	if game.PrivateServerId == "" then
		options.ShouldReserveServer = true
	end
	local reason
	for attempt = 1, TELEPORT_ATTEMPTS do
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, { player }, options)
		end)
		if ok then
			return true, nil
		end
		reason = tostring(err)
		task.wait(attempt * 2)
	end
	return false, reason
end

function Hop.start(report: any, Vault: any, before: (player: any, arrivedByHop: boolean) -> ())
	local vault = Vault.new()
	local forgotten: { [any]: true } = {}

	vault.start({
		template = { DataVersion = 1, Hops = 0, History = {} },
		migrations = {},
		versionPath = { "DataVersion" },
		baseVersion = 1,
		keyPrefix = "hop_",
		stores = STORES,
		studioData = "Studio",
		loadSeconds = LOAD_SECONDS,
		snapshotSeconds = 8,
		messages = { failed = "Vault real test: the data did not load", stolen = "Vault real test: moved to another server", wiped = "wiped" },
		packets = { snapshot = {}, changes = { FireClient = function() end } },
		players = false,
	})

	local function present(player: any): boolean
		return table.find(Players:GetPlayers(), player) ~= nil
	end

	local function arrive(player: any)
		local chain = chainOf(player)
		before(player, chain ~= nil)
		if not present(player) then
			return
		end

		report.section(`hop test in server {serverName()}`)
		local started = os.clock()
		vault.join(player)
		local loaded = vault.ready(player, LOAD_SECONDS)
		local took = os.clock() - started
		if not report.check("the data loaded in this server", loaded, seconds(took)) then
			return
		end

		local hops = vault.get(player, "Hops")
		if chain then
			report.check(`hop {chain.expected}: the data from the previous server arrived intact`, hops == chain.expected, `stored {hops}`)
		else
			vault.set(player, "Hops", 0)
			vault.set(player, "History", {})
			hops = 0
		end

		hops += 1
		vault.set(player, "Hops", hops)
		vault.insert(player, "History", `server {hops}: {serverName()}, data loaded in {seconds(took)}`)
		for _, entry in vault.get(player, "History") do
			report.info(entry)
		end

		if hops >= TARGET then
			local _, failed = report.totals()
			report.line("")
			report.line(if failed == 0 then `HOP TEST PASSED: {TARGET} servers in a row kept the data` else "HOP TEST FAILED: see the FAIL lines above")
			return
		end

		task.wait(STAY_SECONDS)
		if not present(player) then
			return
		end
		local skipRelease = hops % 2 == 1
		forgotten[player] = if skipRelease then true else nil
		report.info(
			if skipRelease
				then "moving on WITHOUT releasing the data here: the next server has to ask this one for it"
				else "moving on after a normal release"
		)
		local sent, reason = send(player, hops)
		if not sent then
			report.check("the teleport to the next server started", false, reason)
		end
	end

	Players.PlayerAdded:Connect(function(player: any)
		task.spawn(arrive, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(arrive, player)
	end
	Players.PlayerRemoving:Connect(function(player: any)
		if forgotten[player] then
			forgotten[player] = nil
		else
			vault.leave(player)
		end
	end)
end

Hop.target = TARGET

return Hop
