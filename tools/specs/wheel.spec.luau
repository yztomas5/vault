return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local Wheel = api.cluster().server("unit").require("ReplicatedStorage.Packages.Vault.Engine.Wheel")

	local PERIOD = 300

	local function world()
		local self = { now = 0, saved = {} :: { { name: string, at: number } } }
		local context = {
			env = {
				clock = function(): number
					return self.now
				end,
			},
			settings = { AutoSaveSeconds = PERIOD },
			sessions = {},
			wheel = Wheel.new(0),
		}
		self.context = context

		function self.session(name: string)
			local session = { name = name, internal = { token = name, loadTimestamp = self.now } }
			Wheel.add(context, session)
			return session
		end

		function self.step()
			Wheel.step(context, function(session: any)
				table.insert(self.saved, { name = session.name, at = self.now })
			end)
		end

		function self.run(seconds: number)
			for _ = 1, seconds do
				self.now += 1
				self.step()
			end
		end

		function self.count(name: string): number
			local total = 0
			for _, entry in self.saved do
				total += if entry.name == name then 1 else 0
			end
			return total
		end

		return self
	end

	describe("auto save wheel", function()
		it("saves a lone session once per period", function()
			local w = world()
			w.session("a")
			w.run(PERIOD)
			expect(#w.saved).toBe(0)
			w.run(PERIOD * 3)
			expect(#w.saved).toBe(3)
			expect(w.saved[2].at - w.saved[1].at).toBe(PERIOD)
		end)

		it("spreads several sessions evenly over the period", function()
			local w = world()
			for _, name in { "a", "b", "c" } do
				w.session(name)
			end
			w.run(PERIOD * 10 + 5)
			for _, name in { "a", "b", "c" } do
				expect(w.count(name)).toBeAtLeast(9)
				expect(w.count(name)).toBeAtMost(10)
			end
			for index = 2, #w.saved do
				expect(w.saved[index].at - w.saved[index - 1].at).toBe(PERIOD / 3)
				expect(w.saved[index].name ~= w.saved[index - 1].name).toBe(true)
			end
		end)

		it("skips a session that loaded less than half a period ago", function()
			local w = world()
			w.session("old")
			w.run(PERIOD - 20)
			w.session("fresh")
			w.run(60)
			expect(w.count("fresh")).toBe(0)
			expect(w.count("old")).toBeAtLeast(1)
			w.run(PERIOD)
			expect(w.count("fresh")).toBeAtLeast(1)
		end)

		it("catches up after a long frame instead of dropping turns", function()
			local w = world()
			for _, name in { "a", "b", "c" } do
				w.session(name)
			end
			w.now = PERIOD * 2
			w.step()
			expect(#w.saved).toBeAtLeast(3)
		end)

		it("keeps turning after sessions leave", function()
			local w = world()
			local sessions = {}
			for _, name in { "a", "b", "c", "d" } do
				sessions[name] = w.session(name)
			end
			w.run(PERIOD + 80)
			Wheel.remove(w.context, sessions.a)
			Wheel.remove(w.context, sessions.c)
			local before = #w.saved
			w.run(PERIOD * 4)
			for index = before + 1, #w.saved do
				local name = w.saved[index].name
				expect(name == "b" or name == "d").toBe(true)
				if index > before + 1 then
					expect(name ~= w.saved[index - 1].name).toBe(true)
				end
			end
			expect(#w.saved - before).toBeAtLeast(7)
			Wheel.remove(w.context, sessions.b)
			Wheel.remove(w.context, sessions.d)
			w.run(PERIOD)
			expect(#w.context.wheel.list).toBe(0)
		end)

		it("gives the next turn to the right session after an earlier one leaves", function()
			local function order(leaves: number?): { string }
				local w = world()
				local sessions = {}
				for _, name in { "a", "b", "c", "d" } do
					sessions[name] = w.session(name)
				end
				while #w.saved < 2 do
					w.run(1)
				end
				if leaves then
					Wheel.remove(w.context, sessions[w.saved[leaves].name])
				end
				while #w.saved < 6 do
					w.run(1)
				end
				local names = {}
				for index, entry in w.saved do
					names[index] = entry.name
				end
				return names
			end
			local full = order(nil)
			expect(full[5]).toBe(full[1])
			for _, leaves in { 1, 2 } do
				local short = order(leaves)
				local expected = {}
				for index = 3, 8 do
					local name = full[(index - 1) % 4 + 1]
					if name ~= full[leaves] then
						table.insert(expected, name)
					end
				end
				for index = 3, 6 do
					expect(short[index]).toBe(expected[index - 2])
				end
			end
		end)

		it("tracks which sessions are open by token", function()
			local w = world()
			local session = w.session("a")
			expect(w.context.sessions.a).toBe(session)
			Wheel.remove(w.context, session)
			expect(w.context.sessions.a).toBe(nil)
			Wheel.remove(w.context, session)
			expect(#w.context.wheel.list).toBe(0)
		end)
	end)
end
