return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local STORE = "Players"
	local KEY = "plr_1"

	for _, driverName in api.drivers.list do
		local function world(broken: string?)
			local cluster = api.cluster({ seed = 11 })
			local watch = api.watch(cluster)
			local self = { cluster = cluster, cloud = cluster.cloud, watch = watch }
			function self.server(name: string, breakIt: boolean?)
				local patches = if breakIt then api.breaks.patches(driverName, broken) else nil
				local server = cluster.server(name, { patches = patches })
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
			return self
		end

		describe(driverName .. " broken on purpose", function()
			it("is caught writing over a profile it lost", function()
				local w = world("ownership")
				w.cloud.faults.messageLoss = 1
				local a, b = w.server("a", true), w.server("b")
				local first = a.start()
				first.data.Counter = 3
				local second = b.start(90)
				second.data.Counter = 10
				second.save()
				w.cluster.run(400)
				expect(#w.watch.violations).toBeAtLeast(1)
			end)

			it("is caught leaving locks behind at shutdown", function()
				local w = world("shutdown")
				local a = w.server("a", true)
				local session = a.start()
				session.data.Counter = 9
				a.shutdown()
				expect(w.watch.holderOf(w.stored())).toBe(a.jobId)
				expect(w.stored().Data.Counter).toBe(0)
			end)

			it("is caught waiting on a server that died long ago", function()
				local w = world("deadLimit")
				local a, b = w.server("a"), w.server("b", true)
				a.start()
				a.kill()
				w.cluster.run(700)
				local started = w.cluster.now()
				b.start(90)
				expect(w.cluster.now() - started).toBeAtLeast(40)
			end)

			it("is caught dropping the last save during an outage", function()
				local w = world("lastSave")
				local a = w.server("a", true)
				local session = a.start()
				session.data.Counter = 7
				w.cloud.outage(60)
				session.release()
				w.cluster.run(200)
				expect(w.stored().Data.Counter).toBe(0)
			end)
		end)
	end
end
