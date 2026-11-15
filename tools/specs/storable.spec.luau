return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local Storable = api.cluster().server("unit").require("ReplicatedStorage.Packages.Vault.Engine.Storable")

	describe("storable check", function()
		it("accepts everything a data store keeps", function()
			local shared = { 1, 2 }
			local cases = {
				5,
				"text",
				true,
				{},
				{ 1, 2, 3 },
				{ Cash = 1, Bag = { "a", "b" }, Deep = { Deeper = { Deepest = { 1 } } } },
				{ First = shared, Second = shared },
				buffer.create(4),
			}
			for index, case in cases do
				local fatal, risks = Storable.check(case)
				if fatal or #risks > 0 then
					error(`case {index}: {tostring(fatal or risks[1])}`)
				end
			end
			expect(Storable.check(nil)).toBe(nil)
		end)

		it("rejects what would make every later save fail and names where it is", function()
			local cycle = { Inner = {} }
			cycle.Inner.Back = cycle
			local cases = {
				{ value = function() end, where = "the value" },
				{ value = { Bag = { Callback = function() end } }, where = "Bag.Callback" },
				{ value = { Task = coroutine.create(function() end) }, where = "Task" },
				{ value = { Proxy = newproxy(false) }, where = "Proxy" },
				{ value = { [true] = 1 }, where = "the value" },
				{ value = { List = { [{}] = 1 } }, where = "List" },
				{ value = cycle, where = "Inner.Back" },
				{ value = { Name = "bad \255 text" }, where = "Name" },
				{ value = { ["bad \255 key"] = 1 }, where = "the value" },
			}
			for index, case in cases do
				local fatal = Storable.check(case.value)
				if not fatal then
					error(`case {index} was accepted`)
				end
				if not string.find(fatal, case.where, 1, true) then
					error(`case {index}: {fatal} does not mention {case.where}`)
				end
			end
		end)

		it("only warns about shapes that save but may come back different", function()
			local cases = {
				{ value = { Speed = 0 / 0 }, risk = "finite" },
				{ value = { Speed = math.huge }, risk = "finite" },
				{ value = { 1, 2, Name = "x" }, risk = "mixes" },
				{ value = { [1] = "a", [3] = "c" }, risk = "gaps" },
				{ value = { [0] = "a" }, risk = "list position" },
				{ value = { [1.5] = "a" }, risk = "list position" },
				{ value = { Slots = { [5] = true } }, risk = "Slots" },
			}
			for index, case in cases do
				local fatal, risks = Storable.check(case.value)
				if fatal then
					error(`case {index} was rejected: {fatal}`)
				end
				local found = false
				for _, risk in risks do
					found = found or string.find(risk, case.risk, 1, true) ~= nil
				end
				if not found then
					error(`case {index}: no warning about {case.risk}`)
				end
			end
		end)
	end)
end
