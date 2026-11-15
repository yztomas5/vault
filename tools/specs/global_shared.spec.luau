return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local VAULT = "ReplicatedStorage.Packages.Vault"
	local STORE = "Events"
	local TEMPLATE = { Night = false, Count = 0, Tags = {} }

	local function world(seed: number?, options: any?)
		local cluster = api.cluster({ seed = seed or 51 })
		local self = { cluster = cluster, cloud = cluster.cloud }

		function self.server(name: string, serverOptions: any?)
			local server = cluster.server(name, serverOptions)
			server.vault = server.require(VAULT)
			server.events = server.vault.shared(STORE, options or { template = TEMPLATE, refreshSeconds = 20 })
			return server
		end

		function self.stored(key: string, store: string?): any
			return cluster.cloud.read(store or STORE, key)
		end

		return self
	end

	local function bump(current: any): any
		current.Count += 1
		return current
	end

	describe("shared documents", function()
		it("start from the template without writing anything", function()
			local w = world()
			local a = w.server("a")
			local value, loaded = a.await(20, function()
				return a.events.get("Night")
			end)
			expect(loaded).toBe(true)
			expect(value.Count).toBe(0)
			expect(type(value.Tags)).toBe("table")
			expect(w.stored("Night")).toBe(nil)
			expect(w.cloud.calls.write).toBe(0)
		end)

		it("hand out copies, so a caller cannot change the cache", function()
			local w = world()
			local a = w.server("a")
			local value = a.await(20, function()
				return a.events.get("Night")
			end)
			value.Count = 99
			local again = a.await(20, function()
				return a.events.get("Night")
			end)
			expect(again.Count).toBe(0)
		end)

		it("fill template fields that an older value is missing", function()
			local w = world()
			w.cloud.write(STORE, "Night", { Version = 3, Data = { Count = 7 } })
			local a = w.server("a")
			local value = a.await(20, function()
				return a.events.get("Night")
			end)
			expect(value.Count).toBe(7)
			expect(value.Night).toBe(false)
		end)

		it("never lose an update when many servers write at once, even with errors and lost answers", function()
			for seed = 1, 6 do
				local w = world(seed)
				w.cloud.faults.errorRate = 0.1
				w.cloud.faults.lostResponseRate = 0.15
				w.cloud.faults.retryRate = 0.3
				w.cloud.faults.latency = { 0.1, 1.5 }
				local confirmed = 0
				local servers = { w.server("a"), w.server("b"), w.server("c") }
				for _, server in servers do
					for _ = 1, 12 do
						server.spawn(function()
							w.cluster.scheduler.sleep(w.cluster.scheduler.between(0, 20))
							local ok = server.events.update("Night", bump)
							if ok then
								confirmed += 1
							end
						end)
					end
				end
				w.cluster.run(200)
				local stored = w.stored("Night")
				local count = if stored then stored.Data.Count else 0
				if count < confirmed or count > 36 then
					error(`seed {seed}: {count} stored, {confirmed} confirmed`)
				end
				expect(stored.Version).toBe(count)
			end
		end)

		it("reach a watching server within seconds", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local seen = {}
			b.events.observe("Night", function(value: any)
				table.insert(seen, value.Count)
			end)
			w.cluster.run(3)
			expect(seen[1]).toBe(0)
			local reads = w.cloud.calls.read
			a.await(20, function()
				return a.events.update("Night", bump)
			end)
			w.cluster.run(3)
			expect(seen[#seen]).toBe(1)
			expect(w.cloud.calls.read - reads).toBeAtMost(1)
		end)

		it("send only the key for a big value and let the other servers read it", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local seen: any = nil
			b.events.observe("Night", function(value: any)
				seen = value
			end)
			w.cluster.run(3)
			a.await(20, function()
				return a.events.update("Night", function(current: any): any
					current.Tags = { string.rep("x", 2000) }
					return current
				end)
			end)
			w.cluster.run(5)
			expect(#seen.Tags).toBe(1)
			expect(#seen.Tags[1]).toBe(2000)
		end)

		it("catch up through the refresh when every message is lost", function()
			local w = world()
			w.cloud.faults.messageLoss = 1
			local a, b = w.server("a"), w.server("b")
			local latest = -1
			b.events.observe("Night", function(value: any)
				latest = value.Count
			end)
			w.cluster.run(3)
			a.await(20, function()
				return a.events.update("Night", bump)
			end)
			w.cluster.run(5)
			expect(latest).toBe(0)
			w.cluster.run(25)
			expect(latest).toBe(1)
		end)

		it("end on the newest value when messages arrive out of order", function()
			for seed = 1, 5 do
				local w = world(seed)
				w.cloud.faults.messageLatency = { 0.05, 4 }
				local a, b = w.server("a"), w.server("b")
				local latest = -1
				b.events.observe("Night", function(value: any)
					latest = value.Count
				end)
				w.cluster.run(3)
				for _ = 1, 5 do
					a.await(20, function()
						return a.events.update("Night", bump)
					end)
				end
				w.cluster.run(10)
				if latest ~= 5 then
					error(`seed {seed}: the watcher ended on {latest}`)
				end
			end
		end)

		it("keep a newer value when a slow read answers with what it saw before", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local latest = -1
			b.events.observe("Night", function(value: any)
				latest = value.Count
			end)
			w.cluster.run(3)
			w.cloud.faults.readDelay = 10
			w.cluster.run(18)
			w.cloud.faults.readDelay = 0
			for _ = 1, 2 do
				a.await(20, function()
					return a.events.update("Night", bump)
				end)
			end
			w.cluster.run(3)
			expect(latest).toBe(2)
			w.cluster.run(12)
			expect(latest).toBe(2)
		end)

		it("write nothing when the transform returns nil, and answer the current value", function()
			local w = world()
			local a = w.server("a")
			a.await(20, function()
				return a.events.update("Night", bump)
			end)
			local ok, value = a.await(20, function()
				return a.events.update("Night", function(): any
					return nil
				end)
			end)
			expect(ok).toBe(false)
			expect(value.Count).toBe(1)
			expect(w.stored("Night").Version).toBe(1)
		end)

		it("refuse values that cannot be stored and transforms that fail", function()
			local w = world()
			local a = w.server("a")
			local broken = a.await(20, function()
				return a.events.update("Night", function(current: any): any
					current.Bad = function() end
					return current
				end)
			end)
			local failing = a.await(20, function()
				return a.events.update("Night", function(): any
					error("boom")
				end)
			end)
			expect(broken).toBe(false)
			expect(failing).toBe(false)
			expect(w.stored("Night")).toBe(nil)
			local rejected = 0
			for _, warning in a.warnings do
				rejected += if string.find(warning, "rejected", 1, true) then 1 else 0
			end
			expect(rejected).toBe(2)
		end)

		it("return the same object for the same name", function()
			local w = world()
			local a = w.server("a")
			expect(a.vault.shared(STORE)).toBe(a.events)
			expect(pcall(a.vault.shared, "")).toBe(false)
			expect(pcall(a.vault.shared, string.rep("n", 44))).toBe(false)
			expect(pcall(a.events.get, "")).toBe(false)
		end)
	end)

	describe("shared documents in Studio", function()
		local function config(mode: string?): any
			return {
				template = { DataVersion = 1 },
				migrations = {},
				versionPath = { "DataVersion" },
				baseVersion = 1,
				keyPrefix = "plr_",
				stores = { production = "Prod", studio = "Dev" },
				studioData = mode,
				studioProduction = mode == "Production",
				loadSeconds = 60,
				snapshotSeconds = 8,
				messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
				packets = { snapshot = {}, changes = { FireClient = function() end } },
				players = false,
			}
		end

		local function studio(w: any, mode: string?)
			local server = w.server("studio", { studio = true })
			if mode then
				server.spawn(server.vault.server.start, config(mode))
			end
			return server
		end

		it("keep everything in memory when Vault keeps profiles in memory", function()
			local w = world()
			local a = studio(w, "Mock")
			a.await(30, function()
				return a.events.update("Night", bump)
			end)
			expect(a.vault.shared(STORE).get("Night").Count).toBe(1)
			expect(w.stored("Night")).toBe(nil)
			expect(w.stored("Night", STORE .. "_Studio")).toBe(nil)
			expect(w.cloud.calls.publish).toBe(0)
		end)

		it("use the Studio copy of the store when Vault uses the Studio store", function()
			local w = world()
			local a = studio(w, "Studio")
			a.await(30, function()
				return a.events.update("Night", bump)
			end)
			expect(w.stored("Night", STORE .. "_Studio").Data.Count).toBe(1)
			expect(w.stored("Night")).toBe(nil)
		end)

		it("read the real store and write nothing in read only mode", function()
			local w = world()
			w.cloud.write(STORE, "Night", { Version = 1, Data = { Count = 4 } })
			local a = studio(w, "ProductionReadOnly")
			local ok = a.await(30, function()
				return a.events.update("Night", bump)
			end)
			expect(ok).toBe(false)
			expect(a.await(30, function()
				return a.events.get("Night")
			end).Count).toBe(4)
			expect(w.stored("Night").Data.Count).toBe(4)
		end)

		it("fall back to memory with a warning when Vault never starts", function()
			local w = world()
			local a = studio(w, nil)
			a.await(40, function()
				return a.events.update("Night", bump)
			end)
			expect(a.vault.shared(STORE).get("Night").Count).toBe(1)
			expect(w.stored("Night")).toBe(nil)
			local warned = false
			for _, warning in a.warnings do
				warned = warned or string.find(warning, "before Vault.server started", 1, true) ~= nil
			end
			expect(warned).toBe(true)
		end)
	end)
end
