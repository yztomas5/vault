return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local MAIN = "ServerScriptService.RealTest.Main"

	local function lines(server: any): { string }
		local out = {}
		for _, text in server.output do
			local line = string.match(text, "^%[VaultRealTest%] (.*)$")
			if line then
				table.insert(out, line)
			end
		end
		return out
	end

	local function find(server: any, pattern: string): string?
		for _, line in lines(server) do
			if string.find(line, pattern) then
				return line
			end
		end
		return nil
	end

	local function failures(server: any): { string }
		local out = {}
		for _, line in lines(server) do
			if string.sub(line, 1, 4) == "FAIL" then
				table.insert(out, line)
			end
		end
		return out
	end

	describe("real test place, run on simulated servers", function()
		it("passes its suite in Studio", function()
			local cluster = api.realCluster({ seed = 41 })
			local server = cluster.server("studio", { studio = true, services = { PrivateServerId = "" } })
			server.spawn(server.require(MAIN).run)
			cluster.runUntil(function(): boolean
				return find(server, "^SUITE RESULT") ~= nil
			end, 1200)
			local failed = failures(server)
			if #failed > 0 then
				error(failed[1], 0)
			end
			local result = find(server, "^SUITE RESULT")
			expect(result ~= nil).toBe(true)
			local passed = tonumber(string.match(result :: string, "(%d+) passed"))
			expect(passed).toBeAtLeast(35)
			expect(find(server, "comes back as") ~= nil).toBe(true)
			expect(#cluster.errors).toBe(0)
		end)

		it("stops with instructions when Studio has no access to the data store", function()
			local cluster = api.realCluster({ seed = 42 })
			cluster.cloud.faults.errorText = "HTTP 403 (Forbidden)"
			cluster.cloud.outage(100000)
			local server = cluster.server("studio", { studio = true, services = { PrivateServerId = "" } })
			server.spawn(server.require(MAIN).run)
			cluster.run(30)
			expect(find(server, "^No access to the data store %(NoAccess%)") ~= nil).toBe(true)
			expect(find(server, "Enable Studio Access to API Services") ~= nil).toBe(true)
			expect(find(server, "^SUITE RESULT")).toBe(nil)
			expect(find(server, "^Running the suite")).toBe(nil)
		end)

		it("carries a player through four servers in the hop test", function()
			local cluster = api.realCluster({ seed = 43 })
			local byOwner: { [any]: any } = {}
			local servers: { any } = {}
			local teleport = {}

			local function open(reserved: boolean)
				local server = cluster.server(nil, {
					services = { PrivateServerId = if reserved then "reserved" else "", TeleportService = teleport },
				})
				byOwner[server.owner] = server
				table.insert(servers, server)
				server.population = 0
				server.spawn(server.require(MAIN).run)
				return server
			end

			function teleport.TeleportAsync(_: any, _: number, players: { any }, options: any)
				local from = byOwner[cluster.scheduler.current()]
				local data = options.TeleportData
				local reserve = options.ShouldReserveServer == true
				for _, player in players do
					cluster.scheduler.delay(nil, 2, function()
						from.removePlayer(player)
						from.population -= 1
						if from.population == 0 then
							from.close()
						end
						local target = open(reserve)
						cluster.scheduler.delay(nil, 3, function()
							target.population += 1
							target.addPlayer(player.UserId, { TeleportData = data })
						end)
					end)
				end
			end

			local first = open(false)
			first.population = 1
			first.addPlayer(7)
			cluster.runUntil(function(): boolean
				return find(servers[#servers], "^HOP TEST") ~= nil
			end, 2400)

			expect(#servers).toBe(4)
			for _, server in servers do
				local failed = failures(server)
				if #failed > 0 then
					error(`{server.name}: {failed[1]}`, 0)
				end
			end
			expect(find(first, "^SUITE RESULT: %d+ passed, 0 failed") ~= nil).toBe(true)
			expect(find(servers[2], "^SUITE RESULT")).toBe(nil)
			expect(find(servers[4], "^HOP TEST PASSED") ~= nil).toBe(true)
			expect(find(servers[2], "hop 1: the data from the previous server arrived intact") ~= nil).toBe(true)
			expect(find(servers[4], "hop 3: the data from the previous server arrived intact") ~= nil).toBe(true)
			expect(find(first, "WITHOUT releasing") ~= nil).toBe(true)
			expect(find(servers[2], "after a normal release") ~= nil).toBe(true)
			expect(#cluster.errors).toBe(0)
		end)
	end)
end
