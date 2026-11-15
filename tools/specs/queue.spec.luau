return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	describe("per key queue", function()
		it("runs calls on the same key one after another and other keys at once", function()
			local cluster = api.cluster({ seed = 2 })
			local server = cluster.server("a")
			local queue = server.require("ReplicatedStorage.Packages.Vault.Engine.Queue").new()
			local order = {}

			local function job(name: string, token: string, seconds: number)
				server.spawn(function()
					local leave = queue.enter(token)
					table.insert(order, `{name} in`)
					cluster.scheduler.sleep(seconds)
					table.insert(order, `{name} out`)
					leave()
				end)
			end

			job("first", "key", 2)
			job("second", "key", 1)
			job("third", "key", 1)
			job("other", "another", 1)
			cluster.run(10)

			local function at(text: string): number
				return table.find(order, text) or error(`{text} never happened`)
			end
			expect(#order).toBe(8)
			expect(at("other in")).toBeAtMost(at("first out"))
			expect(at("second in")).toBeAtLeast(at("first out"))
			expect(at("third in")).toBeAtLeast(at("second out"))
		end)

		it("starts clean after the line empties", function()
			local cluster = api.cluster({ seed = 2 })
			local server = cluster.server("a")
			local queue = server.require("ReplicatedStorage.Packages.Vault.Engine.Queue").new()
			local entered = 0
			for _ = 1, 3 do
				server.spawn(function()
					local leave = queue.enter("key")
					entered += 1
					leave()
				end)
			end
			expect(entered).toBe(3)
		end)
	end)
end
