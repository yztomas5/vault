return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local STORE = "Players"
	local KEY = "plr_1"
	local PAIRS = {
		{ old = "ProfileStore", new = "Engine" },
		{ old = "Engine", new = "ProfileStore" },
	}

	local function world()
		local cluster = api.cluster({ seed = 17 })
		local watch = api.watch(cluster)
		local self = { cluster = cluster, cloud = cluster.cloud, watch = watch }

		function self.server(name: string, driverName: string)
			local server = cluster.server(name)
			server.store = api.drivers[driverName](server).open(STORE, { Counter = 0 })
			function server.start(limit: number?)
				return server.await(limit or 20, function()
					return server.store.start(KEY)
				end)
			end
			return server
		end

		function self.stored(): any
			return cluster.cloud.read(STORE, KEY)
		end

		function self.holder(): string?
			return watch.holderOf(self.stored())
		end

		function self.clean()
			expect(#watch.violations).toBe(0)
			expect(#cluster.errors).toBe(0)
		end

		return self
	end

	for _, pair in PAIRS do
		describe(`a server on {pair.old} and a server on {pair.new}`, function()
			it("hand the session over within seconds", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				local first = a.start()
				first.data.Counter = 3
				local started = w.cluster.now()
				local second = b.start(30)
				expect(second ~= nil).toBe(true)
				expect(second.data.Counter).toBe(3)
				expect(second.loads).toBe(2)
				expect(first.active()).toBe(false)
				expect(w.holder()).toBe(b.jobId)
				expect(w.cluster.now() - started).toBeAtMost(15)
				w.clean()
			end)

			it("take the profile after the steal delay when the request is never heard", function()
				local w = world()
				w.cloud.faults.messageLoss = 1
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				local first = a.start()
				first.data.Counter = 3
				local started = w.cluster.now()
				local second = b.start(90)
				local took = w.cluster.now() - started
				expect(second ~= nil).toBe(true)
				expect(took).toBeAtLeast(40)
				expect(took).toBeAtMost(60)
				second.data.Counter = 10
				w.cluster.run(400)
				expect(first.active()).toBe(false)
				expect(w.stored().Data.Counter).toBe(10)
				expect(w.holder()).toBe(b.jobId)
				w.clean()
			end)

			it("recover the profile of a crashed server", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				local first = a.start()
				first.data.Counter = 4
				first.save()
				w.cluster.run(3)
				a.kill()
				local started = w.cluster.now()
				local second = b.start(90)
				expect(second ~= nil).toBe(true)
				expect(second.data.Counter).toBe(4)
				expect(w.cluster.now() - started).toBeAtMost(60)
				w.clean()
			end)

			it("take over at once past the dead limit", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				a.start()
				a.kill()
				w.cluster.run(700)
				local started = w.cluster.now()
				expect(b.start(30) ~= nil).toBe(true)
				expect(w.cluster.now() - started).toBeAtMost(3)
				w.clean()
			end)

			it("open right after the other one shut down cleanly", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				local first = a.start()
				first.data.Counter = 6
				expect(a.shutdown()).toBe(true)
				local started = w.cluster.now()
				local second = b.start(30)
				expect(second.data.Counter).toBe(6)
				expect(w.cluster.now() - started).toBeAtMost(3)
				w.clean()
			end)

			it("read and write each other's saves back and forth", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				local first = a.start()
				first.data.Counter = 1
				first.release()
				w.cluster.run(3)
				local second = b.start()
				expect(second.data.Counter).toBe(1)
				second.data.Counter = 2
				second.release()
				w.cluster.run(3)
				local third = a.start()
				expect(third.data.Counter).toBe(2)
				expect(third.loads).toBe(3)
				expect(a.await(20, function()
					return a.store.view(KEY)
				end).Counter).toBe(2)
				w.clean()
			end)

			it("deliver messages to each other, online and offline", function()
				local w = world()
				local a, b = w.server("a", pair.old), w.server("b", pair.new)
				b.await(20, function()
					return b.store.message(KEY, { Amount = 5 })
				end)
				local first = a.start()
				local seen = 0
				first.onMessage(function(message, processed)
					seen += message.Amount
					processed()
				end)
				w.cluster.run(10)
				expect(seen).toBe(5)
				b.await(20, function()
					return b.store.message(KEY, { Amount = 2 })
				end)
				w.cluster.run(15)
				expect(seen).toBe(7)
				first.release()
				w.cluster.run(3)
				expect(#w.stored().GlobalUpdates[2]).toBe(0)
				expect(w.stored().GlobalUpdates[1]).toBe(2)
				w.clean()
			end)
		end)
	end

	describe("a fleet with both engines", function()
		for seed = 1, 15 do
			it(`keeps every profile consistent in a random run, seed {seed}`, function()
				local result = api.soak("Mixed", seed)
				for _, list in { result.violations, result.errors, result.lost, result.unbalanced, result.unreachable } do
					if #list > 0 then
						error(list[1], 0)
					end
				end
				expect(result.stats.sessions).toBeAtLeast(20)
				expect(result.stats.hops).toBeAtLeast(5)
				expect(result.stats.gifts).toBeAtLeast(5)
			end)
		end
	end)
end
