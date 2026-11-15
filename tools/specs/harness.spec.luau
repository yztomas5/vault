return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local function open()
		local cluster = api.cluster({ seed = 7 })
		local server = cluster.server("a")
		local store = cluster.cloud.dataStoreService():GetDataStore("Test")
		return cluster, server, store
	end

	describe("fake data store", function()
		it("stores copies, never references", function()
			local cluster, server, store = open()
			local value = { Items = { 1, 2 } }
			server.await(5, function()
				store:SetAsync("k", value)
			end)
			value.Items[1] = 99
			expect(cluster.cloud.read("Test", "k").Items[1]).toBe(1)
		end)

		it("refuses values a real data store cannot keep", function()
			local _, server, store = open()
			local cases = {
				{ 1, 2, Name = "mixed" },
				{ [1] = "a", [3] = "gap" },
				{ Fn = function() end },
				{ Bad = 0 / 0 },
			}
			for _, case in cases do
				local ok = pcall(server.await, 5, function()
					store:SetAsync("k", case)
				end)
				expect(ok).toBe(false)
			end
		end)

		it("runs the transform again when another write lands first", function()
			local cluster = api.cluster({ seed = 3 })
			cluster.cloud.faults.latency = { 2, 2 }
			local a, b = cluster.server("a"), cluster.server("b")
			local store = cluster.cloud.dataStoreService():GetDataStore("Test")
			local runs = 0
			a.spawn(function()
				store:UpdateAsync("k", function(old)
					return (old or 0) + 1
				end)
			end)
			cluster.run(0.5)
			b.spawn(function()
				store:UpdateAsync("k", function(old)
					runs += 1
					return (old or 0) + 10
				end)
			end)
			cluster.run(10)
			expect(cluster.cloud.read("Test", "k")).toBe(11)
			expect(runs).toBe(2)
		end)

		it("fails a transform that yields", function()
			local cluster, server, store = open()
			local ok = pcall(server.await, 5, function()
				store:UpdateAsync("k", function()
					cluster.scheduler.sleep(1)
					return 1
				end)
			end)
			expect(ok).toBe(false)
		end)

		it("errors during an outage and recovers after it", function()
			local cluster, server, store = open()
			cluster.cloud.outage(10)
			local failed = not pcall(server.await, 5, function()
				store:GetAsync("k")
			end)
			expect(failed).toBe(true)
			cluster.run(11)
			server.await(5, function()
				store:SetAsync("k", 1)
			end)
			expect(cluster.cloud.read("Test", "k")).toBe(1)
		end)

		it("never commits a write from a server that died mid request", function()
			local cluster, server, store = open()
			cluster.cloud.faults.latency = { 2, 2 }
			server.spawn(function()
				store:UpdateAsync("k", function()
					return 5
				end)
			end)
			cluster.run(0.2)
			server.kill()
			cluster.run(10)
			expect(cluster.cloud.read("Test", "k")).toBe(nil)
		end)
	end)

	describe("fake messaging", function()
		it("delivers to subscribers on other servers and stops after a kill", function()
			local cluster = api.cluster({ seed = 5 })
			local a, b = cluster.server("a"), cluster.server("b")
			local got = 0
			b.await(5, function()
				cluster.cloud.messagingService(b.owner):SubscribeAsync("topic", function(message)
					got += message.Data.Amount
				end)
			end)
			local messaging = cluster.cloud.messagingService(a.owner)
			a.await(5, function()
				messaging:PublishAsync("topic", { Amount = 2 })
			end)
			cluster.run(2)
			expect(got).toBe(2)
			b.kill()
			a.await(5, function()
				messaging:PublishAsync("topic", { Amount = 2 })
			end)
			cluster.run(2)
			expect(got).toBe(2)
		end)
	end)
end
