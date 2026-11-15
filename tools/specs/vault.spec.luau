return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local PRODUCTION = "Prod"
	local STUDIO = "Dev"
	local KEY = "plr_1"

	local function world()
		local cluster = api.cluster({ seed = 31 })
		local watch = api.watch(cluster)
		local self = { cluster = cluster, cloud = cluster.cloud, watch = watch }

		function self.server(name: string, overrides: { [string]: any }?, serverOptions: any?, prepare: ((vault: any) -> ())?)
			local server = cluster.server(name, serverOptions)
			local vault = server.require("ReplicatedStorage.Packages.Vault").server
			local fired = {}
			local snapshot = {}
			local config = {
				template = { DataVersion = 1, Cash = 0, Items = {}, Secret = { Code = 1 }, Settings = { Music = true } },
				migrations = {},
				versionPath = { "DataVersion" },
				baseVersion = 1,
				private = { { "Secret" } },
				keyPrefix = "plr_",
				stores = { production = PRODUCTION, studio = STUDIO },
				loadSeconds = 70,
				snapshotSeconds = 8,
				messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
				packets = {
					snapshot = snapshot,
					changes = {
						FireClient = function(_: any, player: any, sequence: number, changes: any)
							table.insert(fired, { player = player, sequence = sequence, changes = changes })
						end,
					},
				},
			}
			for key, value in overrides or {} do
				config[key] = value
			end
			if prepare then
				prepare(vault)
			end
			server.spawn(vault.start, config)
			server.vault = vault
			server.fired = fired

			function server.join(userId: number?, wait: number?)
				local player = server.addPlayer(userId or 1)
				cluster.run(wait or 2)
				return player
			end

			function server.snapshot(player: any): (number, any)
				return server.await(20, function()
					return snapshot.OnServerInvoke(player)
				end)
			end

			return server
		end

		function self.stored(store: string?, key: string?): any
			return cluster.cloud.read(store or PRODUCTION, key or KEY)
		end

		function self.holder(store: string?, key: string?): string?
			return watch.holderOf(self.stored(store, key))
		end

		function self.clean()
			expect(#watch.violations).toBe(0)
			expect(#cluster.errors).toBe(0)
		end

		return self
	end

	describe("player data", function()
		it("loads a new player from the template and saves on leave", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			expect(a.vault.loaded(player)).toBe(true)
			expect(a.vault.get(player, "Cash")).toBe(0)
			expect(a.vault.set(player, "Cash", 5)).toBe(true)
			expect(a.vault.update(player, "Cash", function(cash: number): number
				return cash + 1
			end)).toBe(6)
			expect(w.holder()).toBe(a.jobId)
			a.removePlayer(player)
			w.cluster.run(3)
			expect(a.vault.loaded(player)).toBe(false)
			expect(w.stored().Data.Cash).toBe(6)
			expect(w.holder()).toBe(nil)
			expect(w.stored().UserIds[1]).toBe(1)
			w.clean()
		end)

		it("writes lists, removes from them and tells observers", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			local seen = {}
			local stop = a.vault.observe(player, "Items", function(items: any)
				table.insert(seen, #items)
			end)
			a.vault.insert(player, "Items", "sword")
			a.vault.insert(player, "Items", "shield", 1)
			expect(a.vault.get(player, "Items")[1]).toBe("shield")
			expect(a.vault.remove(player, "Items", 1)).toBe("shield")
			expect(#a.vault.get(player, "Items")).toBe(1)
			stop()
			a.vault.insert(player, "Items", "bow")
			expect(seen[#seen]).toBe(1)
			expect(#seen).toBe(4)
			expect(a.vault.set(player, "NotInTemplate", 1)).toBe(false)
			expect(a.vault.get(player, "NotInTemplate")).toBe(nil)
		end)

		it("keeps the caller's table out of the saved data", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			local bag = { "a" }
			a.vault.set(player, "Items", bag)
			bag[1] = "changed"
			expect(a.vault.get(player, "Items")[1]).toBe("a")
		end)

		it("fills fields added to the template into an old save", function()
			local w = world()
			local old = w.server("old", { template = { DataVersion = 1, Cash = 0 } })
			local player = old.join()
			old.vault.set(player, "Cash", 5)
			old.removePlayer(player)
			w.cluster.run(3)
			expect(w.stored().Data.Settings).toBe(nil)
			local new = w.server("new")
			local again = new.join()
			expect(new.vault.get(again, "Cash")).toBe(5)
			expect(new.vault.get(again, "Settings.Music")).toBe(true)
			expect(#new.vault.get(again, "Items")).toBe(0)
		end)

		it("moves a player to another server with the data and kicks the old copy", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local first = a.join()
			a.vault.set(first, "Cash", 5)
			local second = b.join(1, 15)
			expect(b.vault.loaded(second)).toBe(true)
			expect(b.vault.get(second, "Cash")).toBe(5)
			expect(first.kicked).toBe("stolen")
			expect(a.vault.loaded(first)).toBe(false)
			expect(w.holder()).toBe(b.jobId)
			w.clean()
		end)

		it("gives the data back when the player rejoins the same server at once", function()
			local w = world()
			local a = w.server("a")
			local first = a.join()
			a.vault.set(first, "Cash", 3)
			a.removePlayer(first)
			local second = a.join(1, 5)
			expect(a.vault.loaded(second)).toBe(true)
			expect(a.vault.get(second, "Cash")).toBe(3)
			expect(first.kicked).toBe(nil)
			w.clean()
		end)

		it("waits for the data in ready and answers false when the player left first", function()
			local w = world()
			w.cloud.faults.latency = { 4, 4 }
			local a = w.server("a")
			local player = a.addPlayer(1)
			local answer: any = "pending"
			a.spawn(function()
				answer = a.vault.ready(player)
			end)
			w.cluster.run(1)
			expect(answer).toBe("pending")
			w.cluster.run(6)
			expect(answer).toBe(true)
			local late = a.addPlayer(2)
			local second: any = "pending"
			a.spawn(function()
				second = a.vault.ready(late)
			end)
			w.cluster.run(1)
			a.removePlayer(late)
			w.cluster.run(1)
			expect(second).toBe(false)
			w.cluster.run(20)
			expect(w.holder(PRODUCTION, "plr_2")).toBe(nil)
		end)

		it("kicks the player when the data cannot load in time", function()
			local w = world()
			local a = w.server("a", { loadSeconds = 20 })
			w.cloud.outage(500)
			local player = a.join(1, 60)
			expect(player.kicked).toBe("failed")
			expect(a.vault.loaded(player)).toBe(false)
			expect(w.stored()).toBe(nil)
		end)

		it("saves every player when the server shuts down", function()
			local w = world()
			local a = w.server("a")
			for id = 1, 3 do
				local player = a.join(id)
				a.vault.set(player, "Cash", id * 10)
			end
			expect(a.shutdown()).toBe(true)
			for id = 1, 3 do
				expect(w.stored(PRODUCTION, `plr_{id}`).Data.Cash).toBe(id * 10)
				expect(w.holder(PRODUCTION, `plr_{id}`)).toBe(nil)
			end
			w.clean()
		end)
	end)

	describe("saving on demand", function()
		it("confirms a save only once it landed", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			a.vault.set(player, "Cash", 4)
			local function landed(saved: any): boolean
				return saved.Cash == 4
			end
			expect(a.await(20, function()
				return a.vault.saveConfirmed(player, landed, 10)
			end)).toBe(true)
			expect(w.stored().Data.Cash).toBe(4)
			a.vault.set(player, "Cash", 9)
			w.cloud.outage(60)
			expect(a.await(20, function()
				return a.vault.saveConfirmed(player, function(saved: any): boolean
					return saved.Cash == 9
				end, 5)
			end)).toBe(false)
			expect(w.stored().Data.Cash).toBe(4)
		end)

		it("reports how a save ended", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			a.vault.set(player, "Cash", 2)
			expect(a.await(20, function()
				return a.vault.saveNow(player)
			end)).toBe("Saved")
			expect(w.stored().Data.Cash).toBe(2)
			w.cloud.outage(30)
			expect(a.await(20, function()
				return a.vault.saveNow(player)
			end)).toBe("Failed")
			expect(a.vault.save(player)).toBe(true)
			a.removePlayer(player)
			expect(a.vault.save(player)).toBe(false)
			expect(a.vault.saveNow(player)).toBe("Failed")
		end)
	end)

	describe("migrations", function()
		local function tenfold(data: any)
			data.Cash *= 10
		end

		it("runs on load and stamps the version", function()
			local w = world()
			local old = w.server("old")
			local player = old.join()
			old.vault.set(player, "Cash", 1)
			old.removePlayer(player)
			w.cluster.run(3)
			expect(w.stored().Data.DataVersion).toBe(1)
			local new = w.server("new", { migrations = { tenfold } })
			local again = new.join()
			expect(new.vault.get(again, "Cash")).toBe(10)
			expect(new.vault.get(again, "DataVersion")).toBe(2)
			new.removePlayer(again)
			w.cluster.run(3)
			local third = new.join()
			expect(new.vault.get(third, "Cash")).toBe(10)
			w.clean()
		end)

		it("kicks, frees the lock and leaves the save alone when a migration fails", function()
			local w = world()
			local old = w.server("old")
			local player = old.join()
			old.vault.set(player, "Cash", 1)
			old.removePlayer(player)
			w.cluster.run(3)
			local new = w.server("new", {
				migrations = {
					function(data: any)
						data.Cash = 999
						error("broken migration")
					end,
				},
			})
			local again = new.join(1, 5)
			expect(again.kicked).toBe("failed")
			expect(new.vault.loaded(again)).toBe(false)
			expect(w.stored().Data.Cash).toBe(1)
			expect(w.stored().Data.DataVersion).toBe(1)
			expect(w.holder()).toBe(nil)
		end)

		it("shows a migrated copy to inspect without touching the lock", function()
			local w = world()
			local old = w.server("old")
			local player = old.join()
			old.vault.set(player, "Cash", 2)
			old.vault.save(player)
			w.cluster.run(3)
			local new = w.server("new", { migrations = { tenfold } })
			local seen = new.await(20, function()
				return new.vault.inspect(1)
			end)
			expect(seen.Cash).toBe(20)
			expect(w.stored().Data.Cash).toBe(2)
			expect(w.holder()).toBe(old.jobId)
			expect(new.await(20, function()
				return new.vault.inspect(404)
			end)).toBe(nil)
		end)
	end)

	describe("messages", function()
		local function gifts(log: { any }): (vault: any) -> ()
			return function(vault: any)
				vault.onMessage("gift", function(player: any, data: any): boolean?
					table.insert(log, data.Amount)
					if data.Amount < 0 then
						return false
					end
					vault.update(player, "Cash", function(cash: number): number
						return cash + data.Amount
					end)
					return true
				end)
			end
		end

		it("reach an offline player on the next join and an online one in seconds", function()
			local w = world()
			local log = {}
			local a = w.server("a", nil, nil, gifts(log))
			local b = w.server("b", nil, nil, gifts({}))
			expect(b.await(20, function()
				return b.vault.sendMessage(1, "gift", { Amount = 3 })
			end)).toBe(true)
			local player = a.join()
			expect(a.vault.get(player, "Cash")).toBe(3)
			w.cluster.run(10)
			b.await(20, function()
				return b.vault.sendMessage(1, "gift", { Amount = 4 })
			end)
			w.cluster.run(15)
			expect(a.vault.get(player, "Cash")).toBe(7)
			a.removePlayer(player)
			w.cluster.run(3)
			expect(w.stored().Data.Cash).toBe(7)
			expect(#w.stored().GlobalUpdates[2]).toBe(0)
			expect(#log).toBe(2)
			w.clean()
		end)

		it("stay for a later session when the handler refuses them", function()
			local w = world()
			local log = {}
			local a = w.server("a", nil, nil, gifts(log))
			a.await(20, function()
				return a.vault.sendMessage(1, "gift", { Amount = -1 })
			end)
			local player = a.join()
			a.removePlayer(player)
			w.cluster.run(3)
			expect(#w.stored().GlobalUpdates[2]).toBe(1)
			a.join()
			expect(#log).toBe(2)
		end)

		it("are not sent without a handler", function()
			local w = world()
			local a = w.server("a")
			expect(a.await(20, function()
				return a.vault.sendMessage(1, "unknown", {})
			end)).toBe(false)
			expect(w.stored()).toBe(nil)
		end)
	end)

	describe("wipe", function()
		it("kicks the player, removes the key and runs the extra wipers", function()
			local w = world()
			local wiped = {}
			local a = w.server("a", nil, nil, function(vault: any)
				vault.onWipe(function(userId: number)
					table.insert(wiped, userId)
				end)
			end)
			local player = a.join()
			a.vault.set(player, "Cash", 5)
			expect(a.await(60, function()
				return a.vault.wipe(1)
			end)).toBe(true)
			expect(player.kicked).toBe("wiped")
			expect(w.stored()).toBe(nil)
			expect(wiped[1]).toBe(1)
			local again = a.join()
			expect(a.vault.get(again, "Cash")).toBe(0)
		end)

		it("reports a wipe the data store refused", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			a.removePlayer(player)
			w.cluster.run(3)
			w.cloud.outage(60)
			expect(a.await(60, function()
				return a.vault.wipe(1)
			end)).toBe(false)
			expect(w.stored() ~= nil).toBe(true)
		end)
	end)

	describe("write checks", function()
		it("refuses a value that would break every later save", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			a.vault.set(player, "Items", { "sword" })
			expect(a.vault.set(player, "Items", { function() end })).toBe(false)
			expect(a.vault.insert(player, "Items", newproxy(false))).toBe(false)
			expect(a.vault.update(player, "Items", function(): any
				return { Bad = coroutine.create(function() end) }
			end)).toBe(nil)
			expect(#a.vault.get(player, "Items")).toBe(1)
			expect(a.vault.get(player, "Items")[1]).toBe("sword")
			expect(a.await(20, function()
				return a.vault.saveNow(player)
			end)).toBe("Saved")
			expect(a.vault.size(player)).toBeAtLeast(10)
			local rejected = 0
			for _, warning in a.warnings do
				rejected += if string.find(warning, "rejected", 1, true) then 1 else 0
			end
			expect(rejected).toBe(3)
		end)

		it("raises in Studio so the mistake is seen at once, and warns about risky shapes", function()
			local w = world()
			local a = w.server("studio", nil, { studio = true })
			local player = a.join()
			expect(pcall(a.vault.set, player, "Items", { function() end })).toBe(false)
			expect(a.vault.set(player, "Items", { 1, 2, Name = "mixed" })).toBe(true)
			local warned = false
			for _, warning in a.warnings do
				warned = warned or string.find(warning, "mixes", 1, true) ~= nil
			end
			expect(warned).toBe(true)
			local live = world().server("live")
			local other = live.join()
			expect(live.vault.set(other, "Items", { 1, 2, Name = "mixed" })).toBe(true)
			expect(#live.warnings).toBe(0)
		end)
	end)

	describe("replication", function()
		it("sends a snapshot without private fields and then only public changes", function()
			local w = world()
			local a = w.server("a")
			local player = a.join()
			a.vault.set(player, "Cash", 1)
			w.cluster.run(1)
			expect(#a.fired).toBe(0)
			local sequence, data = a.snapshot(player)
			expect(sequence).toBe(0)
			expect(data.Cash).toBe(1)
			expect(data.Secret).toBe(nil)
			a.vault.set(player, "Cash", 7)
			a.vault.set(player, "Secret.Code", 99)
			a.vault.insert(player, "Items", "sword")
			w.cluster.run(1)
			expect(#a.fired).toBe(1)
			expect(a.fired[1].player).toBe(player)
			expect(a.fired[1].sequence).toBe(1)
			expect(#a.fired[1].changes).toBe(2)
			expect(a.fired[1].changes[1][1][1]).toBe("Cash")
			expect(a.fired[1].changes[1][3]).toBe(7)
			expect(a.fired[1].changes[2][2]).toBe("insert")
			a.vault.set(player, "Cash", 8)
			w.cluster.run(1)
			expect(a.fired[2].sequence).toBe(2)
			expect(a.vault.get(player, "Secret.Code")).toBe(99)
		end)

		it("answers an empty snapshot for a player whose data never loads", function()
			local w = world()
			local a = w.server("a", { snapshotSeconds = 3, loadSeconds = 200 })
			w.cloud.outage(500)
			local player = a.addPlayer(1)
			local sequence, data = a.snapshot(player)
			expect(sequence).toBe(0)
			expect(data).toBe(nil)
		end)
	end)

	describe("Studio", function()
		local function studio(w: any, mode: string?, overrides: { [string]: any }?)
			local config = overrides or {}
			config.studioData = mode
			return w.server("studio", config, { studio = true })
		end

		it("keeps everything in memory by default", function()
			local w = world()
			local a = studio(w, nil)
			local player = a.join()
			a.vault.set(player, "Cash", 5)
			a.removePlayer(player)
			w.cluster.run(3)
			expect(a.vault.choice().kind).toBe("Mock")
			expect(w.stored(PRODUCTION)).toBe(nil)
			expect(w.stored(STUDIO)).toBe(nil)
			local again = a.join()
			expect(a.vault.get(again, "Cash")).toBe(5)
		end)

		it("saves to the studio store when asked", function()
			local w = world()
			local a = studio(w, "Studio")
			local player = a.join()
			a.vault.set(player, "Cash", 5)
			a.removePlayer(player)
			w.cluster.run(3)
			expect(w.stored(STUDIO).Data.Cash).toBe(5)
			expect(w.stored(PRODUCTION)).toBe(nil)
		end)

		it("reads production without ever writing or locking it", function()
			local w = world()
			local live = w.server("live")
			local real = live.join()
			live.vault.set(real, "Cash", 5)
			live.removePlayer(real)
			w.cluster.run(3)
			local before = w.watch.commits
			local a = studio(w, "ProductionReadOnly")
			local player = a.join()
			expect(a.vault.get(player, "Cash")).toBe(5)
			a.vault.set(player, "Cash", 9)
			expect(a.vault.get(player, "Cash")).toBe(9)
			expect(a.vault.save(player)).toBe(false)
			expect(a.vault.saveNow(player)).toBe("Failed")
			expect(a.vault.size(player)).toBe(0)
			a.removePlayer(player)
			w.cluster.run(3)
			expect(w.stored(PRODUCTION).Data.Cash).toBe(5)
			expect(w.holder(PRODUCTION)).toBe(nil)
			expect(w.watch.commits).toBe(before + 1)
			local stranger = a.join(77)
			expect(a.vault.get(stranger, "Cash")).toBe(0)
			expect(w.stored(PRODUCTION, "plr_77")).toBe(nil)
		end)

		it("refuses a production session unless the config allows it", function()
			local w = world()
			local a = studio(w, "Production")
			local player = a.join(1, 5)
			expect(a.vault.loaded(player)).toBe(false)
			expect(#w.cluster.errors).toBeAtLeast(1)
			expect(w.stored(PRODUCTION)).toBe(nil)
			local w2 = world()
			local allowed = studio(w2, "Production", { studioProduction = true })
			local other = allowed.join()
			expect(allowed.vault.loaded(other)).toBe(true)
			expect(w2.holder(PRODUCTION)).toBe(allowed.jobId)
		end)

		it("falls back to memory when Studio has no API access", function()
			local w = world()
			w.cloud.faults.errorText = "HTTP 403 (Forbidden)"
			w.cloud.outage(10000)
			local a = studio(w, "Studio")
			local player = a.join(1, 5)
			expect(a.vault.loaded(player)).toBe(true)
			expect(a.vault.choice().kind).toBe("Mock")
			expect(w.stored(STUDIO)).toBe(nil)
		end)
	end)
end
