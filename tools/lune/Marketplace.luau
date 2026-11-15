local Marketplace = {}

function Marketplace.new(scheduler: any)
	local market = {
		passes = {} :: { [number]: { [number]: boolean } },
		subscriptions = {} :: { [number]: { [string]: boolean } },
		levels = {} :: { [number]: number },
		prompts = {} :: { { kind: string, userId: number, id: any, server: any } },
		failLookups = 0,
		failPasses = 0,
		failLevels = false,
		servers = {} :: { any },
	}

	local function newSignal(owner: any)
		local listeners = {}
		local self = {}
		function self.Connect(_: any, fn: (...any) -> ())
			table.insert(listeners, fn)
			return {
				Disconnect = function()
					local index = table.find(listeners, fn)
					if index then
						table.remove(listeners, index)
					end
				end,
			}
		end
		function self.Fire(_: any, ...: any)
			for _, fn in table.clone(listeners) do
				scheduler.spawn(owner, fn, ...)
			end
		end
		return self
	end

	local function lookup()
		scheduler.sleep(scheduler.between(0.05, 0.2))
		if market.failLookups > 0 then
			market.failLookups -= 1
			error("HTTP 500 (Internal Server Error)", 0)
		end
	end

	function market.service(owner: any): any
		local service = {
			ProcessReceipt = nil :: any,
			PromptProductPurchaseFinished = newSignal(owner),
			PromptGamePassPurchaseFinished = newSignal(owner),
		}
		function service.PromptProductPurchase(_: any, player: any, productId: number)
			table.insert(market.prompts, { kind = "Product", userId = player.UserId, id = productId, server = service })
		end
		function service.PromptGamePassPurchase(_: any, player: any, passId: number)
			table.insert(market.prompts, { kind = "Pass", userId = player.UserId, id = passId, server = service })
		end
		function service.PromptSubscriptionPurchase(_: any, player: any, subscriptionId: string)
			table.insert(market.prompts, { kind = "Subscription", userId = player.UserId, id = subscriptionId, server = service })
		end
		function service.UserOwnsGamePassAsync(_: any, userId: number, passId: number): boolean
			lookup()
			if market.failPasses > 0 then
				market.failPasses -= 1
				error("HTTP 500 (Internal Server Error)", 0)
			end
			local owned = market.passes[userId]
			return owned ~= nil and owned[passId] == true
		end
		function service.GetUserSubscriptionStatusAsync(_: any, player: any, subscriptionId: string): any
			lookup()
			local states = market.subscriptions[player.UserId]
			local active = states ~= nil and states[subscriptionId] == true
			return { IsSubscribed = active, IsRenewing = active }
		end
		function service.GetUsersPriceLevelsAsync(_: any, userIds: { number }): any
			lookup()
			if market.failLevels then
				error("HTTP 500 (Internal Server Error)", 0)
			end
			local result = {}
			for _, userId in userIds do
				table.insert(result, { UserId = userId, PriceLevel = market.levels[userId] or 100 })
			end
			return result
		end
		table.insert(market.servers, service)
		return service
	end

	function market.ownPass(userId: number, passId: number)
		market.passes[userId] = market.passes[userId] or {}
		market.passes[userId][passId] = true
	end

	function market.setSubscription(userId: number, subscriptionId: string, active: boolean)
		market.subscriptions[userId] = market.subscriptions[userId] or {}
		market.subscriptions[userId][subscriptionId] = active
	end

	return market
end

return Marketplace
