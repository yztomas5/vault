return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local VAULT = "ReplicatedStorage.Packages.Vault"
	local MARKET = "ReplicatedStorage.Packages.Market"
	local COINS, BOOST, VIP, VIP_GIFT, MONTHLY = 101, 102, 201, 103, "EXP-1"

	local CATALOG = {
		Coins = { Kind = "Product", Id = COINS, Giftable = true, DisplayName = "100 Coins" },
		Boost = { Kind = "Product", Id = BOOST },
		VIP = { Kind = "Pass", Id = VIP, GiftProduct = VIP_GIFT, DisplayName = "VIP" },
		Monthly = { Kind = "Subscription", Id = MONTHLY },
	}

	local function vaultConfig(): any
		return {
			template = { DataVersion = 1, Cash = 0 },
			migrations = {},
			versionPath = { "DataVersion" },
			baseVersion = 1,
			keyPrefix = "plr_",
			stores = { production = "Prod", studio = "Dev" },
			loadSeconds = 60,
			snapshotSeconds = 8,
			messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
			packets = { snapshot = {}, changes = { FireClient = function() end } },
		}
	end

	local function world(seed: number?)
		local cluster = api.cluster({ seed = seed or 81 })
		local market = api.marketplace(cluster.scheduler)
		local self = { cluster = cluster, market = market, cloud = cluster.cloud }

		function self.server(name: string, options: any?)
			local opts = options or {}
			local service = market.service(nil)
			local server = cluster.server(name, { studio = opts.studio, services = { MarketplaceService = service } })
			server.service = service
			server.vault = server.require(VAULT)
			server.market = server.require(MARKET)
			server.packets = { buy = {}, gift = {} }
			server.notices = {}
			server.granted = {}
			server.failNext = 0
			server.passEvents = {}
			server.subscriptionEvents = {}
			local market = server.market.server
			market.start({
				catalog = CATALOG,
				packets = server.packets,
				notify = function(player: any, notice: any)
					table.insert(server.notices, { player = player, text = notice.Text, kind = notice.Kind })
				end,
			})
			market.product("Coins", function(player: any): boolean
				if server.failNext > 0 then
					server.failNext -= 1
					return false
				end
				server.granted[player.UserId] = (server.granted[player.UserId] or 0) + 1
				return server.vault.server.update(player, "Cash", function(cash: number): number
					return cash + 100
				end) ~= nil
			end)
			market.product("Boost", function(): boolean
				return true
			end)
			market.pass("VIP", function(player: any, owned: boolean)
				table.insert(server.passEvents, { userId = player.UserId, owned = owned })
			end)
			market.subscription("Monthly", function(player: any, active: boolean)
				table.insert(server.subscriptionEvents, { userId = player.UserId, active = active })
			end)
			server.spawn(server.vault.server.start, vaultConfig())

			function server.join(userId: number, wait: number?): any
				local player = server.addPlayer(userId)
				cluster.run(wait or 3)
				return player
			end

			function server.receipt(userId: number, productId: number, purchaseId: string?): (string, string)
				local id = purchaseId or cluster.cloud.epoch .. "-" .. math.floor(cluster.scheduler.random() * 1e9)
				local decision = server.await(60, function(): any
					return service.ProcessReceipt({ PurchaseId = id, PlayerId = userId, ProductId = productId })
				end)
				return decision.Name, id
			end

			function server.gift(player: any, name: string, userId: number): (boolean, string?)
				return server.await(30, function(): (boolean, string?)
					return server.packets.gift.OnServerInvoke(player, name, userId)
				end)
			end

			function server.buy(player: any, name: string): (boolean, string?)
				return server.await(30, function(): (boolean, string?)
					return server.packets.buy.OnServerInvoke(player, name)
				end)
			end

			function server.market_(player: any): any
				return server.vault.server.get(player, "Market")
			end

			function server.noticesFor(player: any): { string }
				local list = {}
				for _, notice in server.notices do
					if notice.player == player then
						table.insert(list, notice.text)
					end
				end
				return list
			end

			return server
		end

		function self.stored(userId: number): any
			local record = cluster.cloud.read("Prod", `plr_{userId}`)
			return if record then record.Data else nil
		end

		return self
	end

	describe("products", function()
		it("grant once, keep the purchase in the profile and answer granted after a save", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			local decision, id = a.receipt(1, COINS)
			expect(decision).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(1)
			expect(table.find(w.stored(1).Market.Receipts, id) ~= nil).toBe(true)
			expect(w.stored(1).Cash).toBe(100)
			expect((a.receipt(1, COINS, id))).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(1)
			local _, snapshot = a.await(10, function(): (number, any)
				return a.vault.server.snapshot(buyer)
			end)
			expect(snapshot.Market).toBe(nil)
		end)

		it("leave the receipt for later when the grant does not apply", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.failNext = 1
			local decision, id = a.receipt(1, COINS)
			expect(decision).toBe("NotProcessedYet")
			expect(#a.noticesFor(buyer)).toBe(1)
			expect((a.receipt(1, COINS, id))).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(1)
		end)

		it("answer not yet for a buyer who is not here or a product nobody handles", function()
			local w = world()
			local a = w.server("a")
			a.join(1)
			expect((a.receipt(55, COINS))).toBe("NotProcessedYet")
			expect((a.receipt(1, 999))).toBe("NotProcessedYet")
		end)

		it("deliver a purchase made outside the game when the buyer joins", function()
			local w = world()
			local a = w.server("a")
			local decision, id = a.receipt(1, COINS)
			expect(decision).toBe("NotProcessedYet")
			a.join(1)
			expect((a.receipt(1, COINS, id))).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(1)
		end)

		it("open the prompt only for products", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			expect((a.buy(buyer, "Coins"))).toBe(true)
			expect(w.market.prompts[1].id).toBe(COINS)
			expect((a.buy(buyer, "VIP"))).toBe(false)
			expect((a.buy(buyer, "Nothing"))).toBe(false)
		end)
	end)

	describe("gifts", function()
		it("refuse what cannot be gifted, with a reason", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			for _, case in { { "Nothing", 2 }, { "Boost", 2 }, { "Monthly", 2 }, { "Coins", 1 }, { "Coins", 77 } } do
				local ok, reason = a.gift(buyer, case[1], case[2])
				if ok or type(reason) ~= "string" then
					error(`gift of {case[1]} to {case[2]} was not refused`)
				end
			end
			expect(#w.market.prompts).toBe(0)
		end)

		it("refuse gifts from a cheaper region and when price levels cannot be read", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			w.market.levels[1] = 40
			w.market.levels[2] = 100
			expect((a.gift(buyer, "Coins", 2))).toBe(false)
			w.market.levels[1] = 100
			w.market.failLevels = true
			local refused, reason = a.gift(buyer, "Coins", 2)
			expect(refused).toBe(false)
			expect(reason).toBe(a.market.Settings.Refusals.Busy)
			w.market.failLevels = false
			expect((a.gift(buyer, "Coins", 2))).toBe(true)
		end)

		it("deliver a gifted product to the recipient only and tell both", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			local recipient = a.join(2)
			a.gift(buyer, "Coins", 2)
			local decision, id = a.receipt(1, COINS)
			w.cluster.run(3)
			expect(decision).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(nil)
			expect(a.granted[2]).toBe(1)
			expect(table.find(a.market_(recipient).Received, id) ~= nil).toBe(true)
			expect(next(a.market_(buyer).Intent)).toBe(nil)
			expect(a.noticesFor(buyer)[1]).toBe("You gifted 100 Coins to Player2!")
			expect(a.noticesFor(recipient)[1]).toBe("Player1 gifted you 100 Coins!")
		end)

		it("reach a recipient who moved to another server before the receipt", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local buyer = a.join(1)
			local recipient = a.join(2)
			a.gift(buyer, "Coins", 2)
			a.removePlayer(recipient)
			w.cluster.run(5)
			b.join(2, 5)
			expect((a.receipt(1, COINS))).toBe("PurchaseGranted")
			w.cluster.run(20)
			expect(b.granted[2]).toBe(1)
			expect(a.granted[2]).toBe(nil)
		end)

		it("apply a gift once when the receipt comes back after a crash", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			a.gift(buyer, "Coins", 2)
			local _, id = a.receipt(1, COINS)
			w.cluster.run(3)
			a.vault.server.set(buyer, { "Market", "Receipts" }, {})
			a.gift(buyer, "Coins", 2)
			a.receipt(1, COINS, id)
			w.cluster.run(3)
			expect(a.granted[2]).toBe(1)
		end)

		it("keep a gift the recipient's server could not apply", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local buyer = a.join(1)
			local recipient = a.join(2)
			a.gift(buyer, "Coins", 2)
			a.failNext = 1
			expect((a.receipt(1, COINS))).toBe("PurchaseGranted")
			w.cluster.run(3)
			expect(a.granted[2]).toBe(nil)
			a.removePlayer(recipient)
			w.cluster.run(5)
			b.join(2, 8)
			expect(b.granted[2]).toBe(1)
		end)

		it("drop the intent when the prompt is cancelled", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			a.gift(buyer, "Coins", 2)
			a.service.PromptProductPurchaseFinished:Fire(1, COINS, false)
			w.cluster.run(1)
			a.receipt(1, COINS)
			expect(a.granted[1]).toBe(1)
			expect(a.granted[2]).toBe(nil)
		end)

		it("save the intent before the prompt and refuse when it cannot", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			w.cloud.outage(40)
			local ok = a.gift(buyer, "Coins", 2)
			expect(ok).toBe(false)
			expect(#w.market.prompts).toBe(0)
			w.cluster.run(41)
			expect((a.gift(buyer, "Coins", 2))).toBe(true)
			expect(w.stored(1).Market.Intent.RecipientId).toBe(2)
		end)

		it("keep the intent when the prompt ends in a purchase", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			a.gift(buyer, "Coins", 2)
			a.service.PromptProductPurchaseFinished:Fire(1, COINS, true)
			w.cluster.run(1)
			expect(a.market_(buyer).Intent.RecipientId).toBe(2)
		end)

		it("treat a receipt as the buyer's own after a plain buy or an hour later", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.join(2)
			a.gift(buyer, "Coins", 2)
			a.buy(buyer, "Coins")
			a.receipt(1, COINS)
			expect(a.granted[1]).toBe(1)
			a.gift(buyer, "Coins", 2)
			local intent = a.market_(buyer).Intent
			intent.At -= 3601
			a.vault.server.set(buyer, { "Market", "Intent" }, intent)
			a.receipt(1, COINS)
			expect(a.granted[1]).toBe(2)
			expect(a.granted[2]).toBe(nil)
		end)

		it("ignore a second copy of a receipt still being processed", function()
			local w = world()
			local a = w.server("a")
			a.join(1)
			w.cloud.outage(10)
			local first: any = nil
			a.spawn(function()
				first = a.service.ProcessReceipt({ PurchaseId = "dup", PlayerId = 1, ProductId = COINS })
			end)
			w.cluster.run(1)
			local second = a.await(10, function(): any
				return a.service.ProcessReceipt({ PurchaseId = "dup", PlayerId = 1, ProductId = COINS })
			end)
			expect(second.Name).toBe("NotProcessedYet")
			w.cluster.run(40)
			expect(first.Name).toBe("PurchaseGranted")
			expect(a.granted[1]).toBe(1)
		end)

		it("gift a pass through its gift product, and keep it across servers", function()
			local w = world()
			local a, b = w.server("a"), w.server("b")
			local buyer = a.join(1)
			local recipient = a.join(2)
			expect(a.market.server.owns(recipient, "VIP")).toBe(false)
			expect((a.gift(buyer, "VIP", 2))).toBe(true)
			expect(w.market.prompts[1].id).toBe(VIP_GIFT)
			a.receipt(1, VIP_GIFT)
			w.cluster.run(3)
			expect(a.market.server.owns(recipient, "VIP")).toBe(true)
			expect(recipient:GetAttribute("MarketPass_VIP")).toBe(true)
			expect(a.passEvents[#a.passEvents].userId).toBe(2)
			expect((a.gift(buyer, "VIP", 2))).toBe(false)
			a.removePlayer(recipient)
			w.cluster.run(5)
			local back = b.join(2, 8)
			expect(b.market.server.owns(back, "VIP")).toBe(true)
		end)

		it("give the pass to the buyer who bought its gift product for themselves", function()
			local w = world()
			local a = w.server("a")
			local buyer = a.join(1)
			a.receipt(1, VIP_GIFT)
			expect(a.market.server.owns(buyer, "VIP")).toBe(true)
		end)
	end)

	describe("passes", function()
		it("read ownership on join and tell the listener once", function()
			local w = world()
			w.market.ownPass(1, VIP)
			local a = w.server("a")
			local owner = a.join(1)
			local other = a.join(2)
			expect(a.market.server.owns(owner, "VIP")).toBe(true)
			expect(a.market.server.owns(other, "VIP")).toBe(false)
			expect(owner:GetAttribute("MarketPass_VIP")).toBe(true)
			expect(#a.passEvents).toBe(1)
		end)

		it("take a pass bought during the session and ignore a cancelled prompt", function()
			local w = world()
			local a = w.server("a")
			local player = a.join(1)
			a.service.PromptGamePassPurchaseFinished:Fire(player, VIP, false)
			w.cluster.run(1)
			expect(a.market.server.owns(player, "VIP")).toBe(false)
			a.service.PromptGamePassPurchaseFinished:Fire(player, VIP, true)
			w.cluster.run(1)
			expect(a.market.server.owns(player, "VIP")).toBe(true)
			a.service.PromptGamePassPurchaseFinished:Fire(player, VIP, true)
			w.cluster.run(1)
			expect(#a.passEvents).toBe(1)
		end)

		it("retry a failed ownership lookup, and give up after its attempts", function()
			local w = world()
			w.market.ownPass(1, VIP)
			w.market.failPasses = 2
			local a = w.server("a")
			local owner = a.join(1, 10)
			expect(a.market.server.owns(owner, "VIP")).toBe(true)
			w.market.ownPass(2, VIP)
			w.market.failPasses = 3
			local unlucky = a.join(2, 10)
			expect(a.market.server.owns(unlucky, "VIP")).toBe(false)
		end)
	end)

	describe("subscriptions", function()
		it("read the status on join and follow its changes", function()
			local w = world()
			w.market.setSubscription(1, MONTHLY, true)
			local a = w.server("a")
			local subscriber = a.join(1)
			local other = a.join(2)
			expect(a.market.server.subscribed(subscriber, "Monthly")).toBe(true)
			expect(a.market.server.subscribed(other, "Monthly")).toBe(false)
			expect(subscriber:GetAttribute("MarketSub_Monthly")).toBe(true)
			w.market.setSubscription(2, MONTHLY, true)
			a.players.UserSubscriptionStatusChanged:Fire(other, MONTHLY)
			w.cluster.run(2)
			expect(a.market.server.subscribed(other, "Monthly")).toBe(true)
			w.market.setSubscription(1, MONTHLY, false)
			a.players.UserSubscriptionStatusChanged:Fire(subscriber, MONTHLY)
			w.cluster.run(2)
			expect(a.market.server.subscribed(subscriber, "Monthly")).toBe(false)
			expect(subscriber:GetAttribute("MarketSub_Monthly")).toBe(false)
			local last = a.subscriptionEvents[#a.subscriptionEvents]
			expect(last.userId).toBe(1)
			expect(last.active).toBe(false)
		end)

		it("ignore changes for subscriptions it does not sell", function()
			local w = world()
			local a = w.server("a")
			local player = a.join(1)
			local before = #a.subscriptionEvents
			a.players.UserSubscriptionStatusChanged:Fire(player, "EXP-OTHER")
			w.cluster.run(2)
			expect(#a.subscriptionEvents).toBe(before)
			a.players.UserSubscriptionStatusChanged:Fire(player, MONTHLY)
			w.cluster.run(2)
			expect(#a.subscriptionEvents).toBe(before)
		end)
	end)

	describe("client", function()
		local function client()
			local w = world()
			local service = w.market.service(nil)
			local attributes: { [string]: any } = {}
			local watchers: { [string]: any } = {}
			local localPlayer = { UserId = 1, Name = "Player1" }
			function localPlayer.GetAttribute(_: any, key: string): any
				return attributes[key]
			end
			function localPlayer.GetAttributeChangedSignal(_: any, key: string): any
				local listeners = watchers[key] or {}
				watchers[key] = listeners
				return {
					Connect = function(_: any, fn: () -> ())
						table.insert(listeners, fn)
						return { Disconnect = function() end }
					end,
				}
			end
			local function setAttribute(key: string, value: any)
				attributes[key] = value
				for _, fn in watchers[key] or {} do
					fn()
				end
			end
			local server = w.cluster.server("client", {
				services = { MarketplaceService = service, Players = { LocalPlayer = localPlayer } },
			})
			local sent = {}
			local packets = {
				buy = { Fire = function(_: any, name: string): (boolean, string?)
					table.insert(sent, { "buy", name })
					return true, nil
				end },
				gift = { Fire = function(_: any, name: string, userId: number): (boolean, string?)
					table.insert(sent, { "gift", name, userId })
					return false, "nope"
				end },
			}
			local Client = server.require("ReplicatedStorage.Packages.Market.Client")
			Client.start({ catalog = CATALOG, packets = packets })
			return { w = w, server = server, client = Client, sent = sent, set = setAttribute }
		end

		it("prompt passes and subscriptions directly and ask the server for products", function()
			local c = client()
			expect((c.server.await(5, function(): any
				return c.client.buy("VIP")
			end))).toBe(true)
			c.server.await(5, function(): any
				return c.client.buy("Monthly")
			end)
			c.server.await(5, function(): any
				return c.client.buy("Coins")
			end)
			local prompts = c.w.market.prompts
			expect(prompts[1].kind).toBe("Pass")
			expect(prompts[2].kind).toBe("Subscription")
			expect(prompts[2].id).toBe(MONTHLY)
			expect(#prompts).toBe(2)
			expect(c.sent[1][2]).toBe("Coins")
		end)

		it("refuse gifts that cannot exist and pass the server's answer back", function()
			local c = client()
			local ok, reason = c.server.await(5, function(): any
				return c.client.gift("Boost", 2)
			end)
			expect(ok).toBe(false)
			expect(reason ~= nil).toBe(true)
			expect(#c.sent).toBe(0)
			local answer, why = c.server.await(5, function(): any
				return c.client.gift("Coins", 2)
			end)
			expect(answer).toBe(false)
			expect(why).toBe("nope")
		end)

		it("read and follow ownership from the attributes the server sets", function()
			local c = client()
			expect(c.client.owns("VIP")).toBe(false)
			local seen = {}
			c.server.await(5, function(): any
				return c.client.observe("VIP", function(owned: boolean)
					table.insert(seen, owned)
				end)
			end)
			c.set("MarketPass_VIP", true)
			expect(c.client.owns("VIP")).toBe(true)
			expect(seen[#seen]).toBe(true)
			c.set("MarketSub_Monthly", true)
			expect(c.client.owns("Monthly")).toBe(true)
			expect(c.client.owns("Coins")).toBe(false)
		end)
	end)

	describe("catalog and setup", function()
		it("refuse broken catalogs", function()
			local w = world()
			local a = w.cluster.server("bare")
			local Catalog = a.require("ReplicatedStorage.Packages.Market.Catalog")
			local broken = {
				{ ["bad name"] = { Kind = "Product", Id = 1 } },
				{ Thing = { Kind = "Hat", Id = 1 } },
				{ One = { Kind = "Product", Id = 1 }, Two = { Kind = "Product", Id = 1 } },
				{ Sub = { Kind = "Subscription", Id = 5 } },
				{ Sub = { Kind = "Subscription", Id = "EXP-1", Giftable = true } },
				{ Pass = { Kind = "Pass", Id = 2, GiftProduct = 1 }, Coins = { Kind = "Product", Id = 1 } },
				{ Product = { Kind = "Product", Id = 1.5 } },
			}
			for index, catalog in broken do
				if pcall(Catalog.check, catalog) then
					error(`broken catalog {index} was accepted`)
				end
			end
			expect(pcall(Catalog.check, CATALOG)).toBe(true)
		end)

		it("work when Vault started first, and refuse to extend after a player joined", function()
			local w = world()
			local service = w.market.service(nil)
			local a = w.cluster.server("late", { services = { MarketplaceService = service } })
			local vault = a.require(VAULT)
			local market = a.require(MARKET)
			a.spawn(vault.server.start, vaultConfig())
			w.cluster.run(1)
			market.server.start({ catalog = CATALOG })
			market.server.product("Coins", function(): boolean
				return true
			end)
			local player = a.addPlayer(1)
			w.cluster.run(3)
			expect(type(vault.server.get(player, "Market"))).toBe("table")
			expect(pcall(vault.server.extend, "Other", {}, true)).toBe(false)
		end)

		it("refuse a field that clashes with the game's template", function()
			local w = world()
			local a = w.cluster.server("clash")
			local vault = a.require(VAULT)
			vault.server.extend("Cash", 5)
			local config = vaultConfig()
			expect(pcall(vault.server.start, config)).toBe(false)
		end)
	end)
end
