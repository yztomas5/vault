return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local STORE = "Players"
	local KEY = "plr_1"

	local function world(serverOptions: any?)
		local cluster = api.cluster({ seed = 23 })
		local self = { cluster = cluster, cloud = cluster.cloud }

		function self.server(name: string, options: any?)
			local server = cluster.server(name, options or serverOptions)
			local Engine = server.require("ReplicatedStorage.Packages.Vault.Engine")
			server.engine = Engine.shared()
			server.store = server.engine.open(STORE, { Counter = 0, Bag = {} })
			function server.start(key: string?, limit: number?)
				return server.await(limit or 20, function()
					return server.store.start(key or KEY)
				end)
			end
			return server
		end

		function self.stored(key: string?): any
			return cluster.cloud.read(STORE, key or KEY)
		end

		return self
	end

	describe("sessions", function()
		it("refuses to open a profile twice in the same server", function()
			local w = world()
			local a = w.server("a")
			a.start()
			local ok = pcall(a.start)
			expect(ok).toBe(false)
		end)

		it("rejects bad keys, store names and templates", function()
			local w = world()
			local a = w.server("a")
			for _, key in { "", 5, string.rep("k", 51) } do
				expect(pcall(a.start, key)).toBe(false)
			end
			expect(pcall(a.engine.open, "")).toBe(false)
			expect(pcall(a.engine.open, string.rep("s", 51))).toBe(false)
			expect(pcall(a.engine.open, "Fine", 5)).toBe(false)
		end)

		it("tells whether a save landed, failed or found the profile lost", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local session = a.start()
			session.data.Counter = 3
			expect(a.await(20, session.saveNow)).toBe("Saved")
			expect(w.stored().Data.Counter).toBe(3)
			w.cloud.outage(30)
			session.data.Counter = 4
			expect(a.await(20, session.saveNow)).toBe("Failed")
			expect(w.stored().Data.Counter).toBe(3)
			w.cluster.run(31)
			w.cloud.faults.messageLoss = 1
			b.start(KEY, 90)
			session.data.Counter = 9
			expect(a.await(20, session.saveNow)).toBe("Lost")
			expect(session.active()).toBe(false)
			expect(a.await(20, session.saveNow)).toBe("Lost")
			expect(w.stored().Data.Counter).toBe(3)
		end)

		it("warns instead of saving a session that already ended", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			session.release()
			w.cluster.run(3)
			local writes = w.cloud.calls.write
			session.save()
			w.cluster.run(3)
			expect(w.cloud.calls.write).toBe(writes)
			expect(#a.warnings).toBeAtLeast(1)
		end)

		it("fills new template fields on request and keeps user ids with the key", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			session.data.Bag = nil
			session.reconcile()
			expect(type(session.data.Bag)).toBe("table")
			session.addUserId(55)
			session.addUserId(55)
			session.addUserId(-3)
			session.addUserId(1.5)
			session.release()
			w.cluster.run(3)
			expect(#w.stored().UserIds).toBe(1)
			expect(w.stored().UserIds[1]).toBe(55)
		end)

		it("stops delivering messages to a session that ended", function()
			local w = world()
			local a = w.server("a")
			a.await(20, function()
				return a.store.message(KEY, { Amount = 1 })
			end)
			local session = a.start()
			session.release()
			w.cluster.run(3)
			local seen = 0
			session.onMessage(function()
				seen += 1
			end)
			w.cluster.run(3)
			expect(seen).toBe(0)
		end)
	end)

	describe("mock store", function()
		it("keeps data in memory and never touches the data store", function()
			local w = world()
			local a = w.server("a")
			local first = a.await(20, function()
				return a.store.mock.start(KEY)
			end)
			first.data.Counter = 7
			first.release()
			w.cluster.run(3)
			local second = a.await(20, function()
				return a.store.mock.start(KEY)
			end)
			expect(second.data.Counter).toBe(7)
			expect(second.loadCount).toBe(2)
			expect(w.stored()).toBe(nil)
			expect(w.cloud.calls.write).toBe(0)
			expect(w.cloud.calls.publish).toBe(0)
		end)

		it("stores a copy, so unsaved changes never leak into it", function()
			local w = world()
			local a = w.server("a")
			local session = a.await(20, function()
				return a.store.mock.start(KEY)
			end)
			session.data.Counter = 1
			session.data.Bag = { "sword" }
			a.await(20, session.saveNow)
			session.data.Counter = 2
			table.insert(session.data.Bag, "shield")
			local view = a.await(20, function()
				return a.store.mock.view(KEY)
			end)
			expect(view.data.Counter).toBe(1)
			expect(#view.data.Bag).toBe(1)
		end)

		it("is separate from the live profile with the same key", function()
			local w = world()
			local a = w.server("a")
			local live = a.start()
			live.data.Counter = 1
			local mock = a.await(20, function()
				return a.store.mock.start(KEY)
			end)
			expect(mock.data.Counter).toBe(0)
			mock.data.Counter = 2
			mock.release()
			live.release()
			w.cluster.run(3)
			expect(w.stored().Data.Counter).toBe(1)
			expect(a.await(20, function()
				return a.store.mock.view(KEY)
			end).data.Counter).toBe(2)
			expect(a.await(20, function()
				return a.store.mock.remove(KEY)
			end)).toBe(true)
			expect(a.await(20, function()
				return a.store.mock.view(KEY)
			end)).toBe(nil)
			expect(w.stored().Data.Counter).toBe(1)
		end)

		it("delivers messages between mock sessions", function()
			local w = world()
			local a = w.server("a")
			local session = a.await(20, function()
				return a.store.mock.start(KEY)
			end)
			local seen = 0
			session.onMessage(function(message, processed)
				seen += message.Amount
				processed()
			end)
			a.await(20, function()
				return a.store.mock.message(KEY, { Amount = 4 })
			end)
			w.cluster.run(3)
			expect(seen).toBe(4)
		end)
	end)

	describe("Studio", function()
		it("uses the data store when it has API access", function()
			local w = world({ studio = true })
			local a = w.server("a")
			expect(a.await(20, a.engine.ready)).toBe("Access")
			local session = a.start()
			session.data.Counter = 2
			session.release()
			w.cluster.run(3)
			expect(w.stored().Data.Counter).toBe(2)
		end)

		it("falls back to memory without API access and still works", function()
			local w = world({ studio = true })
			w.cloud.faults.errorText = "HTTP 403 (Forbidden)"
			w.cloud.outage(10000)
			local a = w.server("a")
			expect(a.engine.state()).toBe("NotReady")
			expect(a.await(20, a.engine.ready)).toBe("NoAccess")
			local writes = w.cloud.calls.write
			local session = a.start()
			session.data.Counter = 5
			session.release()
			w.cluster.run(3)
			local again = a.start()
			expect(again.data.Counter).toBe(5)
			expect(w.cloud.calls.write).toBe(writes)
			expect(w.stored()).toBe(nil)
			local started = w.cluster.now()
			expect(a.shutdown()).toBe(true)
			expect(w.cluster.now() - started).toBeAtMost(1)
		end)

		it("reports no internet apart from no access", function()
			local w = world({ studio = true })
			w.cloud.faults.errorText = "HttpError: ConnectFail"
			w.cloud.outage(10000)
			local a = w.server("a")
			expect(a.await(20, a.engine.ready)).toBe("NoInternet")
		end)
	end)

	describe("size", function()
		it("measures the data on every save and warns once per level", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			local reports = {}
			a.engine.onSize(function(_: string, key: string, bytes: number, limit: number)
				table.insert(reports, { key = key, share = bytes / limit })
			end)
			a.await(20, session.saveNow)
			expect(session.bytes).toBeAtLeast(10)
			expect(session.bytes).toBeAtMost(200)
			expect(#reports).toBe(0)
			session.data.Bag = { string.rep("x", 2200000) }
			a.await(20, session.saveNow)
			expect(session.bytes).toBeAtLeast(2200000)
			expect(#reports).toBe(1)
			expect(reports[1].key).toBe(KEY)
			a.await(20, session.saveNow)
			expect(#reports).toBe(1)
			session.data.Bag = { string.rep("x", 3900000) }
			a.await(20, session.saveNow)
			expect(#reports).toBe(2)
			expect(reports[2].share).toBeAtLeast(0.9)
			session.data.Bag = {}
			a.await(20, session.saveNow)
			session.data.Bag = { string.rep("x", 2200000) }
			a.await(20, session.saveNow)
			expect(#reports).toBe(3)
		end)

		it("says so when the data cannot be encoded at all", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			session.data.Bag = { function() end }
			expect(a.await(20, session.saveNow)).toBe("Failed")
			local found = false
			for _, warning in a.warnings do
				found = found or string.find(warning, "cannot be encoded", 1, true) ~= nil
			end
			expect(found).toBe(true)
			expect(w.stored().Data.Bag[1]).toBe(nil)
		end)
	end)

	describe("throttling", function()
		local function throttled(w: any, message: string)
			w.cloud.faults.errorText = message
			w.cloud.faults.failNext = 1
		end

		it("holds every request of the server for a while after a throttling error", function()
			local cases = {
				{ name = "StandardWriteGameServerThrottled: StandardWrite request hit the game server limits", least = 5, most = 9 },
				{ name = "StandardWriteExperienceThrottled: The standard write request rate exceeds the allowed maximum for the experience.", least = 15, most = 22 },
				{ name = "KeyThrottled: The request rate exceeds the allowed maximum for the key.", least = 5, most = 9 },
				{ name = "304: UpdateAsync request dropped. Request queue was full.", least = 5, most = 9 },
				{ name = "301: GetAsync request was throttled", least = 5, most = 9 },
			}
			for _, case in cases do
				local w = world()
				local a = w.server("a")
				throttled(w, case.name)
				local started = w.cluster.now()
				expect(a.start(KEY, 60) ~= nil).toBe(true)
				local took = w.cluster.now() - started
				if took < case.least or took > case.most then
					error(`{case.name}: took {took} s`)
				end
			end
		end)

		it("holds requests for other keys too", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			throttled(w, "StandardWriteGameServerThrottled")
			expect(a.await(20, session.saveNow)).toBe("Failed")
			local started = w.cluster.now()
			expect(a.start("plr_2", 60) ~= nil).toBe(true)
			expect(w.cluster.now() - started).toBeAtLeast(4)
		end)

		it("does not hold anything after an ordinary error", function()
			local w = world()
			local a = w.server("a")
			w.cloud.faults.failNext = 1
			local started = w.cluster.now()
			expect(a.start(KEY, 60) ~= nil).toBe(true)
			expect(w.cluster.now() - started).toBeAtMost(3)
		end)

		it("never holds the saves of a server that is shutting down", function()
			local w = world()
			local a = w.server("a")
			local session = a.start()
			session.data.Counter = 4
			throttled(w, "StandardWriteExperienceThrottled")
			a.await(20, session.saveNow)
			local started = w.cluster.now()
			expect(a.shutdown()).toBe(true)
			expect(w.cluster.now() - started).toBeAtMost(3)
			expect(w.stored().Data.Counter).toBe(4)
		end)
	end)

	describe("health", function()
		it("reports every data store error and a corrupted key", function()
			local w = world()
			local a = w.server("a")
			local errors, overwrites = 0, 0
			a.engine.onError(function()
				errors += 1
			end)
			a.engine.onOverwrite(function()
				overwrites += 1
			end)
			w.cloud.faults.failNext = 2
			a.start()
			expect(errors).toBe(2)
			w.cloud.write(STORE, "plr_2", "garbage")
			a.start("plr_2")
			expect(overwrites).toBe(1)
		end)

		it("enters a critical state after repeated errors and leaves it when they stop", function()
			local w = world()
			local a = w.server("a")
			local changes = {}
			a.engine.onCritical(function(critical: boolean)
				table.insert(changes, critical)
			end)
			w.cloud.outage(40)
			a.start(KEY, 120)
			expect(a.engine.critical()).toBe(true)
			w.cluster.run(250)
			expect(a.engine.critical()).toBe(false)
			expect(#changes).toBe(2)
			expect(changes[1]).toBe(true)
			expect(changes[2]).toBe(false)
		end)
	end)
end
