return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local VAULT = "ReplicatedStorage.Packages.Vault"
	local DAY = 86400

	local function world(seed: number?, frame: number?)
		local cluster = api.cluster({ seed = seed or 71, frame = frame })
		local self = { cluster = cluster, cloud = cluster.cloud }

		function self.server(name: string, options: any?, serverOptions: any?)
			local server = cluster.server(name, serverOptions)
			server.vault = server.require(VAULT)
			server.board = server.vault.leaderboard("Cash", options or { submitSeconds = 10, topSeconds = 30 })
			function server.top(count: number?): { any }
				return server.await(20, function()
					return server.board.top(count)
				end)
			end
			return server
		end

		function self.entries(board: string): { [string]: number }
			return cluster.cloud.readOrdered(board)
		end

		return self
	end

	describe("leaderboards", function()
		it("send each player's value on an interval, and only when it changed", function()
			local w = world()
			local a = w.server("a")
			for value = 1, 20 do
				a.board.submit(1, value)
			end
			a.board.submit(2, 50)
			w.cluster.run(5)
			expect(w.cloud.calls.ordered).toBe(0)
			w.cluster.run(6)
			expect(w.cloud.calls.ordered).toBe(2)
			expect(w.entries("Cash_All")["1"]).toBe(20)
			a.board.submit(1, 20)
			w.cluster.run(11)
			expect(w.cloud.calls.ordered).toBe(2)
			a.board.submit(1, 21)
			w.cluster.run(11)
			expect(w.entries("Cash_All")["1"]).toBe(21)
		end)

		it("rank from every server, highest first", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			a.board.submit(1, 300)
			a.board.submit(2, 100)
			b.board.submit({ UserId = 3 }, 200)
			w.cluster.run(11)
			local top = a.top()
			expect(#top).toBe(3)
			expect(top[1].userId).toBe(1)
			expect(top[1].rank).toBe(1)
			expect(top[2].userId).toBe(3)
			expect(top[3].value).toBe(100)
			expect(#a.top(2)).toBe(2)
		end)

		it("rank lowest first when asked, for times and other scores that go down", function()
			local w = world()
			local a = w.server("a", { ascending = true, submitSeconds = 10 })
			a.board.submit(1, 90)
			a.board.submit(2, 45)
			w.cluster.run(11)
			expect(a.top()[1].userId).toBe(2)
		end)

		it("read the top once per period and share it", function()
			local w = world()
			local a = w.server("a")
			a.board.submit(1, 5)
			w.cluster.run(11)
			a.top()
			a.top(3)
			a.top()
			expect(w.cloud.calls.sorted).toBe(1)
			w.cluster.run(31)
			a.top()
			expect(w.cloud.calls.sorted).toBe(2)
		end)

		it("keep showing the last top when a read fails", function()
			local w = world()
			local a = w.server("a")
			a.board.submit(1, 5)
			w.cluster.run(11)
			expect(#a.top()).toBe(1)
			w.cluster.run(31)
			w.cloud.outage(30)
			expect(#a.top()).toBe(1)
		end)

		it("floor values and ignore numbers it cannot rank", function()
			local w = world()
			local a = w.server("a")
			a.board.submit(1, 12.9)
			a.board.submit(2, 0 / 0)
			a.board.submit(3, math.huge)
			a.board.submit(4, 2 ^ 60)
			w.cluster.run(11)
			local entries = w.entries("Cash_All")
			expect(entries["1"]).toBe(12)
			expect(entries["2"]).toBe(nil)
			expect(entries["3"]).toBe(nil)
			expect(entries["4"]).toBe(nil)
			expect(pcall(a.board.submit, "player", 1)).toBe(false)
		end)

		it("send what is left at shutdown", function()
			local w = world()
			local a = w.server("a")
			a.board.submit(1, 8)
			expect(a.shutdown()).toBe(true)
			expect(w.entries("Cash_All")["1"]).toBe(8)
		end)

		it("start a new daily board at midnight UTC", function()
			local w = world(71, 1)
			local a = w.server("a", { window = "Day", submitSeconds = 10, topSeconds = 1 }, { clockSkew = DAY - 30 })
			local today = a.board.board()
			a.board.submit(1, 100)
			w.cluster.run(11)
			expect(w.entries(today)["1"]).toBe(100)
			w.cluster.run(30)
			local tomorrow = a.board.board()
			expect(tomorrow ~= today).toBe(true)
			expect(#a.top()).toBe(0)
			a.board.submit(1, 100)
			w.cluster.run(11)
			expect(w.entries(tomorrow)["1"]).toBe(100)
			expect(a.board.board(1)).toBe(today)
		end)

		it("start a new weekly board on Monday and not on other days", function()
			local w = world(71, 1)
			local saturday = w.server("sat", { window = "Week" }, { clockSkew = DAY - 30 })
			local sunday = w.server("sun", { window = "Week" }, { clockSkew = 2 * DAY - 30 })
			local beforeSaturday = saturday.board.board()
			local beforeSunday = sunday.board.board()
			expect(beforeSaturday).toBe(beforeSunday)
			w.cluster.run(31)
			expect(saturday.board.board()).toBe(beforeSaturday)
			expect(sunday.board.board() ~= beforeSunday).toBe(true)
		end)

		it("rank lowest first in memory too, in a Studio session that keeps data in memory", function()
			local w = world()
			local a = w.server("a", { ascending = true, submitSeconds = 10 }, { studio = true })
			a.spawn(a.vault.server.start, {
				template = { DataVersion = 1 },
				migrations = {},
				versionPath = { "DataVersion" },
				baseVersion = 1,
				keyPrefix = "plr_",
				stores = { production = "Prod", studio = "Dev" },
				studioData = "Mock",
				loadSeconds = 60,
				snapshotSeconds = 8,
				messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
				packets = { snapshot = {}, changes = { FireClient = function() end } },
				players = false,
			})
			a.board.submit(1, 90)
			a.board.submit(2, 45)
			a.board.submit(3, 60)
			w.cluster.run(11)
			local top = a.top()
			expect(top[1].userId).toBe(2)
			expect(top[2].userId).toBe(3)
			expect(next(w.entries("Cash_All"))).toBe(nil)
		end)

		it("take a wiped player out of the current and recent boards", function()
			local w = world()
			local a = w.server("a", { window = "Day", submitSeconds = 10 })
			a.spawn(a.vault.server.start, {
				template = { DataVersion = 1 },
				migrations = {},
				versionPath = { "DataVersion" },
				baseVersion = 1,
				keyPrefix = "plr_",
				stores = { production = "Prod", studio = "Dev" },
				loadSeconds = 60,
				snapshotSeconds = 8,
				messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
				packets = { snapshot = {}, changes = { FireClient = function() end } },
				players = false,
			})
			local all = a.vault.leaderboard("Coins", { submitSeconds = 10 })
			a.board.submit(1, 10)
			a.board.submit(2, 20)
			all.submit(1, 5)
			w.cluster.run(11)
			local older = a.board.board(3)
			a.await(20, function()
				w.cloud.dataStoreService():GetOrderedDataStore(older):SetAsync("1", 7)
			end)
			expect(a.await(30, function()
				return a.vault.server.wipe(1)
			end)).toBe(true)
			expect(w.entries(a.board.board())["1"]).toBe(nil)
			expect(w.entries(a.board.board())["2"]).toBe(20)
			expect(w.entries(older)["1"]).toBe(nil)
			expect(w.entries("Coins_All")["1"]).toBe(nil)
		end)

		it("refuse names that do not fit with the window tag", function()
			local w = world()
			local a = w.server("a")
			expect(pcall(a.vault.leaderboard, string.rep("n", 35))).toBe(false)
			expect(pcall(a.vault.leaderboard, "Bad", { window = "Month" })).toBe(false)
		end)
	end)
end
