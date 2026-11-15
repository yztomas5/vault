return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local VAULT = "ReplicatedStorage.Packages.Vault"
	local STORE = "Stock"

	local function world(seed: number?)
		local cluster = api.cluster({ seed = seed or 61 })
		local self = { cluster = cluster, cloud = cluster.cloud }

		function self.server(name: string?, serverOptions: any?)
			local server = cluster.server(name, serverOptions)
			server.vault = server.require(VAULT)
			server.stock = server.vault.counter(STORE, { flushSeconds = 10, refreshSeconds = 30 })
			return server
		end

		function self.total(key: string): number
			local stored = cluster.cloud.read(STORE, key)
			return if stored then stored.Total else 0
		end

		function self.used(key: string, buckets: number): number
			local sum = 0
			for index = 1, buckets do
				local stored = cluster.cloud.read(STORE, `{key}#{index}`)
				sum += if stored then stored.Used else 0
			end
			return sum
		end

		return self
	end

	local function faulty(w: any)
		w.cloud.faults.errorRate = 0.1
		w.cloud.faults.lostResponseRate = 0.1
		w.cloud.faults.retryRate = 0.2
		w.cloud.faults.latency = { 0.1, 1 }
	end

	describe("sums", function()
		it("land every add exactly once from many servers, through errors and lost answers", function()
			for seed = 1, 5 do
				local w = world(seed)
				faulty(w)
				local servers = { w.server("a"), w.server("b"), w.server("c"), w.server("d") }
				for _, server in servers do
					server.spawn(function()
						for _ = 1, 150 do
							w.cluster.scheduler.sleep(w.cluster.scheduler.between(0.1, 2))
							server.stock.add("Relics", 1)
						end
					end)
				end
				w.cluster.run(300)
				w.cloud.faults.errorRate = 0
				w.cloud.faults.lostResponseRate = 0
				for _, server in servers do
					server.shutdown()
				end
				if w.total("Relics") ~= 600 then
					error(`seed {seed}: stored {w.total("Relics")} of 600`)
				end
			end
		end)

		it("write once per key per flush, not once per add", function()
			local w = world()
			local a = w.server("a")
			for _ = 1, 500 do
				a.stock.add("Relics", 1)
			end
			a.stock.add("Bones", 2)
			w.cluster.run(12)
			expect(w.total("Relics")).toBe(500)
			expect(w.total("Bones")).toBe(2)
			expect(w.cloud.calls.write).toBe(2)
		end)

		it("lose only what a crashed server had not sent", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			a.stock.add("Relics", 10)
			b.stock.add("Relics", 1)
			w.cluster.run(12)
			a.stock.add("Relics", 5)
			expect(a.stock.pending()).toBe(5)
			a.kill()
			b.stock.add("Relics", 1)
			w.cluster.run(12)
			expect(w.total("Relics")).toBe(12)
		end)

		it("send everything left at shutdown", function()
			local w = world()
			local a = w.server("a")
			a.stock.add("Relics", 7)
			a.stock.add("Relics", -2)
			expect(a.shutdown()).toBe(true)
			expect(w.total("Relics")).toBe(5)
		end)

		it("count what this server has not sent yet and refresh what others sent", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			a.stock.add("Relics", 3)
			expect(a.await(20, function()
				return a.stock.get("Relics")
			end)).toBe(3)
			w.cluster.run(12)
			b.stock.add("Relics", 4)
			w.cluster.run(12)
			expect(a.await(20, function()
				return a.stock.get("Relics")
			end)).toBe(3)
			w.cluster.run(31)
			expect(a.await(20, function()
				return a.stock.get("Relics")
			end)).toBe(7)
		end)

		it("wait for room in the request budget while player saves go ahead", function()
			local w = world()
			local a = w.server("a")
			local engine = a.require("ReplicatedStorage.Packages.Vault.Engine").shared()
			local profiles = engine.open("Players", { Cash = 0 })
			w.cloud.faults.budget = 5
			a.stock.add("Relics", 3)
			local session = a.await(20, function()
				return profiles.start("plr_1")
			end)
			session.data.Cash = 9
			expect(a.await(20, session.saveNow)).toBe("Saved")
			w.cluster.run(40)
			expect(w.total("Relics")).toBe(0)
			expect(a.stock.pending()).toBe(3)
			w.cloud.faults.budget = 1000
			w.cluster.run(12)
			expect(w.total("Relics")).toBe(3)
		end)

		it("refuse amounts that are not finite numbers", function()
			local w = world()
			local a = w.server("a")
			expect(pcall(a.stock.add, "Relics", 0 / 0)).toBe(false)
			expect(pcall(a.stock.add, "Relics", math.huge)).toBe(false)
			expect(pcall(a.stock.add, "Relics", "1")).toBe(false)
			expect(pcall(a.stock.add, string.rep("k", 51), 1)).toBe(false)
		end)
	end)

	describe("capped claims", function()
		it("never hand out more than the cap, through errors and lost answers", function()
			for seed = 1, 5 do
				local w = world(seed)
				faulty(w)
				local granted, failed = 0, 0
				local servers = {}
				for index = 1, 5 do
					servers[index] = w.server(`s{index}`)
				end
				for _, server in servers do
					for _ = 1, 30 do
						server.spawn(function()
							w.cluster.scheduler.sleep(w.cluster.scheduler.between(0, 30))
							local ok, reason = server.stock.claim("GoldenBanana", 50)
							if ok then
								granted += 1
							elseif reason == "failed" then
								failed += 1
							end
						end)
					end
				end
				w.cluster.run(200)
				local used = w.used("GoldenBanana", 2)
				if used > 50 or granted > used or used - granted > failed then
					error(`seed {seed}: {granted} granted, {used} used, {failed} failed`)
				end
				expect(granted).toBeAtLeast(40)
			end
		end)

		it("hand out exactly the cap when nothing fails, also when it does not split evenly", function()
			for _, cap in { 30, 52 } do
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local granted = 0
				for _, server in { a, b } do
					for _ = 1, 40 do
						server.spawn(function()
							if server.stock.claim("Crown", cap) then
								granted += 1
							end
						end)
					end
				end
				w.cluster.run(120)
				if granted ~= cap or w.used("Crown", 3) ~= cap then
					error(`cap {cap}: {granted} granted, {w.used("Crown", 3)} used`)
				end
			end
		end)

		it("answer full at once, with no request, after seeing every bucket full", function()
			local w = world()
			local a = w.server("a")
			for _ = 1, 3 do
				a.await(20, function()
					return a.stock.claim("Crown", 3)
				end)
			end
			local first, reason = a.await(20, function()
				return a.stock.claim("Crown", 3)
			end)
			expect(first).toBe(false)
			expect(reason).toBe("full")
			local writes = w.cloud.calls.write
			local again = a.await(20, function()
				return a.stock.claim("Crown", 3)
			end)
			expect(again).toBe(false)
			expect(w.cloud.calls.write).toBe(writes)
		end)

		it("tell how many are left", function()
			local w = world()
			local a = w.server("a")
			expect(a.await(20, function()
				return a.stock.remaining("Crown", 60)
			end)).toBe(60)
			for _ = 1, 7 do
				a.await(20, function()
					return a.stock.claim("Crown", 60)
				end)
			end
			expect(a.await(20, function()
				return a.stock.remaining("Crown", 60)
			end)).toBe(53)
		end)

		it("treat a cap of zero as full and refuse bad caps", function()
			local w = world()
			local a = w.server("a")
			local ok, reason = a.await(20, function()
				return a.stock.claim("Crown", 0)
			end)
			expect(ok).toBe(false)
			expect(reason).toBe("full")
			expect(pcall(a.stock.claim, "Crown", -1)).toBe(false)
			expect(pcall(a.stock.claim, "Crown", 1.5)).toBe(false)
			expect(pcall(a.stock.claim, string.rep("k", 47), 5)).toBe(false)
		end)
	end)

	describe("random runs with crashes", function()
		for seed = 1, 8 do
			it(`keep every sum between what was added and what crashed servers still held, seed {seed}`, function()
				local w = world(seed)
				faulty(w)
				local scheduler = w.cluster.scheduler
				local servers = {}
				local added = 0
				local lost = 0
				local stopping = false
				for index = 1, 3 do
					servers[index] = w.server()
				end
				local function worker()
					while not stopping do
						scheduler.sleep(scheduler.between(0.2, 3))
						local server = servers[math.floor(scheduler.between(1, #servers + 1 - 1e-9))]
						if server and server.alive() and not stopping then
							server.stock.add("Relics", 1)
							added += 1
						end
					end
				end
				local function chaos()
					while not stopping do
						scheduler.sleep(scheduler.between(30, 90))
						if stopping then
							break
						end
						local index = math.floor(scheduler.between(1, #servers + 1 - 1e-9))
						local server = table.remove(servers, index)
						if scheduler.random() < 0.5 then
							lost += server.stock.pending()
							server.kill()
						else
							server.close()
						end
						table.insert(servers, w.server())
					end
				end
				for _ = 1, 4 do
					scheduler.spawn(nil, worker)
				end
				scheduler.spawn(nil, chaos)
				w.cluster.run(600)
				stopping = true
				w.cloud.faults.errorRate = 0
				w.cloud.faults.lostResponseRate = 0
				w.cluster.run(5)
				for _, server in servers do
					server.close()
				end
				w.cluster.run(40)
				local total = w.total("Relics")
				if total > added or total < added - lost then
					error(`{total} stored, {added} added, up to {lost} lost in crashes`)
				end
				expect(added).toBeAtLeast(300)
				expect(#w.cluster.errors).toBe(0)
			end)
		end
	end)
end
