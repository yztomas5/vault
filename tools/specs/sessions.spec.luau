return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local STORE = "Players"
	local KEY = "plr_1"

	local function template()
		return { Counter = 0, Items = {} }
	end

	for _, driverName in api.drivers.list do
		local function world(options: any?)
			local cluster = api.cluster(options or { seed = 11 })
			local watch = api.watch(cluster)
			local self = { cluster = cluster, cloud = cluster.cloud, watch = watch }

			function self.server(name: string, serverOptions: any?)
				local server = cluster.server(name, serverOptions)
				server.driver = api.drivers[driverName](server)
				server.store = server.driver.open(STORE, template())
				function server.start(key: string?, limit: number?, cancel: (() -> boolean)?)
					return server.await(limit or 20, function()
						return server.store.start(key or KEY, cancel)
					end)
				end
				return server
			end

			function self.stored(key: string?): any
				return cluster.cloud.read(STORE, key or KEY)
			end

			function self.holder(key: string?): string?
				return watch.holderOf(self.stored(key))
			end

			function self.clean()
				expect(#watch.violations).toBe(0)
				expect(#cluster.errors).toBe(0)
			end

			return self
		end

		describe(driverName, function()
			it("creates a profile from the template and holds the lock", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				expect(session ~= nil).toBe(true)
				expect(session.data.Counter).toBe(0)
				expect(session.loads).toBe(1)
				expect(w.holder()).toBe(a.jobId)
				expect(w.stored().Data.Counter).toBe(0)
				w.clean()
			end)

			it("saves the data and frees the lock on release", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				local ended = 0
				session.onEnd(function()
					ended += 1
				end)
				session.data.Counter = 5
				session.release()
				w.cluster.run(3)
				expect(w.stored().Data.Counter).toBe(5)
				expect(w.holder()).toBe(nil)
				expect(session.active()).toBe(false)
				expect(ended).toBe(1)
				w.clean()
			end)

			it("saves on demand without ending the session", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				local saved = nil
				session.onSaved(function(data)
					saved = data.Counter
				end)
				session.data.Counter = 2
				session.save()
				w.cluster.run(3)
				expect(saved).toBe(2)
				expect(w.stored().Data.Counter).toBe(2)
				expect(w.holder()).toBe(a.jobId)
				expect(session.active()).toBe(true)
				w.clean()
			end)

			it("hands the session to another server that asks for it", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local first = a.start()
				first.data.Counter = 3
				local started = w.cluster.now()
				local second = b.start(KEY, 30)
				expect(second ~= nil).toBe(true)
				expect(second.data.Counter).toBe(3)
				expect(second.loads).toBe(2)
				expect(first.active()).toBe(false)
				expect(w.holder()).toBe(b.jobId)
				expect(w.cluster.now() - started).toBeAtMost(8)
				w.clean()
			end)

			it("takes the profile after about 45 s when the other server never hears the request", function()
				local w = world()
				w.cloud.faults.messageLoss = 1
				local a, b = w.server("a"), w.server("b")
				local first = a.start()
				first.data.Counter = 3
				local started = w.cluster.now()
				local second = b.start(KEY, 90)
				local took = w.cluster.now() - started
				expect(second ~= nil).toBe(true)
				expect(took).toBeAtLeast(40)
				expect(took).toBeAtMost(50)
				expect(second.data.Counter).toBe(0)
				second.data.Counter = 10
				w.cluster.run(400)
				expect(first.active()).toBe(false)
				expect(second.active()).toBe(true)
				expect(w.stored().Data.Counter).toBe(10)
				expect(w.holder()).toBe(b.jobId)
				w.clean()
			end)

			it("takes the profile of a crashed server after the steal delay", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local first = a.start()
				first.data.Counter = 4
				first.save()
				w.cluster.run(3)
				a.kill()
				local started = w.cluster.now()
				local second = b.start(KEY, 90)
				expect(second ~= nil).toBe(true)
				expect(second.data.Counter).toBe(4)
				expect(w.cluster.now() - started).toBeAtMost(60)
				w.clean()
			end)

			it("takes the profile at once when its server has been silent past the dead limit", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				a.start()
				a.kill()
				w.cluster.run(700)
				local started = w.cluster.now()
				local second = b.start(KEY, 30)
				expect(second ~= nil).toBe(true)
				expect(w.cluster.now() - started).toBeAtMost(3)
				w.clean()
			end)

			it("keeps loading through a short data store outage", function()
				local w = world()
				local a = w.server("a")
				w.cloud.outage(30)
				local started = w.cluster.now()
				local session = a.start(KEY, 90)
				expect(session ~= nil).toBe(true)
				expect(w.cluster.now() - started).toBeAtLeast(30)
				expect(#w.watch.violations).toBe(0)
			end)

			it("gives up loading when the data store stays down", function()
				local w = world()
				local a = w.server("a")
				w.cloud.outage(1000)
				local started = w.cluster.now()
				local session = a.start(KEY, 300)
				expect(session).toBe(nil)
				expect(w.cluster.now() - started).toBeAtLeast(120)
				expect(w.stored()).toBe(nil)
			end)

			it("retries the last save until it lands", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				session.data.Counter = 7
				w.cloud.outage(60)
				session.release()
				w.cluster.run(30)
				expect(w.stored().Data.Counter).toBe(0)
				expect(w.holder()).toBe(a.jobId)
				w.cluster.run(120)
				expect(w.stored().Data.Counter).toBe(7)
				expect(w.holder()).toBe(nil)
				expect(#w.watch.violations).toBe(0)
			end)

			it("saves every open profile when the server shuts down", function()
				local w = world()
				local a = w.server("a")
				for index = 1, 3 do
					local session = a.start(`plr_{index}`)
					session.data.Counter = index
				end
				expect(a.shutdown()).toBe(true)
				for index = 1, 3 do
					expect(w.stored(`plr_{index}`).Data.Counter).toBe(index)
					expect(w.holder(`plr_{index}`)).toBe(nil)
				end
				w.clean()
			end)

			it("refuses new sessions once the server is shutting down", function()
				local w = world()
				local a = w.server("a")
				a.start()
				a.close()
				expect(a.driver.closing()).toBe(true)
				local late: any = "pending"
				a.spawn(function()
					late = a.store.start("plr_2")
				end)
				w.cluster.run(35)
				expect(late).toBe(nil)
				expect(w.stored("plr_2")).toBe(nil)
			end)

			it("returns nothing and writes nothing when the load is cancelled during errors", function()
				local w = world()
				local a = w.server("a")
				w.cloud.outage(20)
				local cancelled = false
				local result: any = "pending"
				a.spawn(function()
					result = a.store.start(KEY, function()
						return cancelled
					end)
				end)
				w.cluster.run(5)
				cancelled = true
				w.cluster.run(40)
				expect(result).toBe(nil)
				expect(w.stored()).toBe(nil)
			end)

			it("frees the lock when the load is cancelled while the request is in flight", function()
				local w = world()
				w.cloud.faults.latency = { 2, 2 }
				local a = w.server("a")
				local cancelled = false
				local result: any = "pending"
				a.spawn(function()
					result = a.store.start(KEY, function()
						return cancelled
					end)
				end)
				w.cluster.run(1.5)
				cancelled = true
				w.cluster.run(20)
				expect(result).toBe(nil)
				expect(w.holder()).toBe(nil)
				w.clean()
			end)

			it("recovers a profile whose lock was taken by a load that was cancelled after its answer got lost", function()
				local w = world()
				w.cloud.faults.latency = { 2, 2 }
				w.cloud.faults.loseNext = 1
				local a, b = w.server("a"), w.server("b")
				local cancelled = false
				local result: any = "pending"
				a.spawn(function()
					result = a.store.start(KEY, function()
						return cancelled
					end)
				end)
				w.cluster.run(1.5)
				cancelled = true
				w.cluster.run(20)
				expect(result).toBe(nil)
				if api.drivers.traits[driverName].ghostLocks then
					expect(w.holder()).toBe(a.jobId)
				else
					expect(w.holder()).toBe(nil)
				end
				w.cloud.faults.latency = { 0.05, 0.2 }
				local started = w.cluster.now()
				local session = b.start(KEY, 90)
				expect(session ~= nil).toBe(true)
				expect(w.cluster.now() - started).toBeAtMost(60)
				expect(#w.watch.violations).toBe(0)
			end)

			it("lets only the last server that asked take a profile two servers want", function()
				local w = world()
				w.cloud.faults.messageLoss = 1
				local a, b, c = w.server("a"), w.server("b"), w.server("c")
				a.start()
				local holders: { [string]: true } = {}
				w.cloud.onCommit(function(_: string, _: string, _: any, after: any)
					local holder = w.watch.holderOf(after)
					if holder then
						holders[holder] = true
					end
				end)
				local first: any = "pending"
				local second: any = "pending"
				b.spawn(function()
					first = b.store.start(KEY)
				end)
				w.cluster.run(40)
				c.spawn(function()
					second = c.store.start(KEY)
				end)
				w.cluster.run(120)
				expect(first).toBe(nil)
				expect(second ~= nil and second ~= "pending").toBe(true)
				expect(holders[b.jobId]).toBe(nil)
				expect(w.holder()).toBe(c.jobId)
				w.clean()
			end)

			it("saves by itself within the auto save period", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				session.data.Counter = 8
				w.cluster.run(200)
				expect(w.stored().Data.Counter).toBe(0)
				w.cluster.run(110)
				expect(w.stored().Data.Counter).toBe(8)
				expect(session.active()).toBe(true)
				w.clean()
			end)

			it("views a profile without touching its lock", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local session = a.start()
				session.data.Counter = 4
				session.save()
				w.cluster.run(3)
				local commits = w.watch.commits
				local seen = b.await(20, function()
					return b.store.view(KEY)
				end)
				expect(seen.Counter).toBe(4)
				expect(w.watch.commits).toBe(commits)
				expect(w.holder()).toBe(a.jobId)
				expect(session.active()).toBe(true)
				expect(b.await(20, function()
					return b.store.view("plr_missing")
				end)).toBe(nil)
				expect(w.stored("plr_missing")).toBe(nil)
				w.clean()
			end)

			it("removes a key", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				session.release()
				w.cluster.run(3)
				expect(a.await(20, function()
					return a.store.remove(KEY)
				end)).toBe(true)
				expect(w.stored()).toBe(nil)
				local again = a.start()
				expect(again.data.Counter).toBe(0)
				expect(again.loads).toBe(1)
				w.clean()
			end)

			it("ends the session when its key was removed under it", function()
				local w = world()
				local a, admin = w.server("a"), w.server("admin")
				local session = a.start()
				local ended = 0
				session.onEnd(function()
					ended += 1
				end)
				admin.await(20, function()
					return admin.store.remove(KEY)
				end)
				session.data.Counter = 5
				session.save()
				w.cluster.run(5)
				if api.drivers.traits[driverName].stuckOnRemovedKeys then
					expect(session.active()).toBe(true)
					return
				end
				expect(session.active()).toBe(false)
				expect(ended).toBe(1)
				expect(w.stored()).toBe(nil)
				expect(a.shutdown()).toBe(true)
				w.clean()
			end)

			it("releases as soon as one of its saves sees another server's request", function()
				local w = world()
				w.cloud.faults.messageLoss = 1
				local a, b = w.server("a"), w.server("b")
				local first = a.start()
				first.data.Counter = 3
				local started = w.cluster.now()
				local second: any = "pending"
				b.spawn(function()
					second = b.store.start(KEY)
				end)
				w.cluster.run(8)
				first.save()
				w.cluster.run(12)
				expect(second ~= nil and second ~= "pending").toBe(true)
				expect(second.data.Counter).toBe(3)
				expect(first.active()).toBe(false)
				expect(w.cluster.now() - started).toBeAtMost(21)
				w.clean()
			end)

			it("gives the session to the newest of two loads started at once in one server", function()
				local w = world()
				w.cloud.faults.latency = { 2, 2 }
				local a = w.server("a")
				local first: any = "pending"
				local second: any = "pending"
				a.spawn(function()
					first = a.store.start(KEY)
				end)
				w.cluster.run(0.5)
				a.spawn(function()
					second = a.store.start(KEY)
				end)
				w.cluster.run(10)
				expect(first).toBe(nil)
				expect(second ~= nil and second ~= "pending").toBe(true)
				expect(second.active()).toBe(true)
				expect(w.holder()).toBe(a.jobId)
				expect(w.stored().MetaData.SessionLoadCount).toBe(1)
				w.clean()
			end)

			it("pushes the next auto save back after a manual save", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				w.cluster.run(250)
				session.data.Counter = 1
				session.save()
				w.cluster.run(5)
				local commits = w.watch.commits
				session.data.Counter = 2
				w.cluster.run(200)
				expect(w.watch.commits).toBe(commits)
				expect(w.stored().Data.Counter).toBe(1)
				w.cluster.run(120)
				expect(w.stored().Data.Counter).toBe(2)
				w.clean()
			end)

			it("waits at shutdown for a release that was already in flight", function()
				local w = world()
				local a = w.server("a")
				local session = a.start()
				session.data.Counter = 6
				w.cloud.faults.latency = { 4, 4 }
				session.release()
				w.cluster.run(1)
				expect(a.shutdown()).toBe(true)
				expect(w.stored().Data.Counter).toBe(6)
				expect(w.holder()).toBe(nil)
				w.clean()
			end)

			it("keeps the newest data when the same server reloads the profile right away", function()
				local w = world()
				local a = w.server("a")
				local first = a.start()
				first.data.Counter = 1
				first.release()
				local second = a.start(KEY, 30)
				expect(second ~= nil).toBe(true)
				expect(second.data.Counter).toBe(1)
				expect(second.loads).toBe(2)
				w.cluster.run(5)
				expect(w.holder()).toBe(a.jobId)
				w.clean()
			end)

			it("replaces a corrupted key with a fresh profile", function()
				local w = world()
				w.cloud.write(STORE, KEY, "garbage")
				local a = w.server("a")
				local session = a.start()
				expect(session ~= nil).toBe(true)
				expect(session.data.Counter).toBe(0)
				expect(w.holder()).toBe(a.jobId)
			end)
		end)

		describe(driverName .. " messages", function()
			it("delivers a message sent while the player was offline", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local sent = b.await(20, function()
					return b.store.message(KEY, { Amount = 5 })
				end)
				expect(sent).toBe(true)
				local session = a.start()
				local seen = 0
				session.onMessage(function(message, processed)
					seen += 1
					session.data.Counter += message.Amount
					processed()
				end)
				w.cluster.run(1)
				expect(seen).toBe(1)
				session.release()
				w.cluster.run(3)
				expect(w.stored().Data.Counter).toBe(5)
				expect(#w.stored().GlobalUpdates[2]).toBe(0)
				w.clean()
			end)

			it("delivers a message within seconds to a session on another server", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local session = a.start()
				local seen = 0
				session.onMessage(function(_, processed)
					seen += 1
					processed()
				end)
				w.cluster.run(10)
				b.await(20, function()
					return b.store.message(KEY, { Amount = 1 })
				end)
				w.cluster.run(15)
				expect(seen).toBe(1)
				expect(session.active()).toBe(true)
				w.clean()
			end)

			it("shows an unprocessed message once per session, however many saves happen", function()
				local w = world()
				local a = w.server("a")
				a.await(20, function()
					return a.store.message(KEY, { Amount = 1 })
				end)
				local session = a.start()
				local seen = 0
				session.onMessage(function()
					seen += 1
				end)
				for _ = 1, 3 do
					session.save()
					w.cluster.run(3)
				end
				expect(seen).toBe(1)
				expect(#w.stored().GlobalUpdates[2]).toBe(1)
				w.clean()
			end)

			it("stops at the first handler that processes a message", function()
				local w = world()
				local a, b = w.server("a"), w.server("b")
				local session = a.start()
				local calls = {}
				session.onMessage(function()
					table.insert(calls, "ignores")
				end)
				session.onMessage(function(_, processed)
					table.insert(calls, "takes")
					processed()
				end)
				session.onMessage(function()
					table.insert(calls, "late")
				end)
				w.cluster.run(10)
				b.await(20, function()
					return b.store.message(KEY, { Amount = 1 })
				end)
				w.cluster.run(15)
				expect(table.concat(calls, ",")).toBe("ignores,takes")
				w.clean()
			end)

			it("does not offer a handler a message another handler already took", function()
				local w = world()
				local a = w.server("a")
				a.await(20, function()
					return a.store.message(KEY, { Amount = 1 })
				end)
				local session = a.start()
				local late = 0
				session.onMessage(function(_, processed)
					processed()
				end)
				session.onMessage(function()
					late += 1
				end)
				w.cluster.run(1)
				expect(late).toBe(0)
				w.clean()
			end)

			it("offers a message again until a handler marks it processed", function()
				local w = world()
				local a = w.server("a")
				a.await(20, function()
					return a.store.message(KEY, { Amount = 1 })
				end)
				local first = a.start()
				local seen = 0
				first.onMessage(function()
					seen += 1
				end)
				w.cluster.run(1)
				first.release()
				w.cluster.run(3)
				local second = a.start()
				second.onMessage(function(_, processed)
					seen += 1
					processed()
				end)
				w.cluster.run(1)
				expect(seen).toBe(2)
				expect(#w.stored().GlobalUpdates[2]).toBe(1)
				second.release()
				w.cluster.run(3)
				expect(#w.stored().GlobalUpdates[2]).toBe(0)
				w.clean()
			end)
		end)
	end
end
