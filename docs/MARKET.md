# Market

Every Robux purchase a game sells: developer products, passes, subscriptions, and gifts of products and passes. It
lives next to Vault and uses it directly: purchases are recorded in the player's profile, gifts travel as Vault
profile messages. Everything that talks to Vault is in `Server/Data.luau`.

## Setup

Server, in a service `Init` (any time before the first player joins, before or after Vault starts):

```lua
local Market = require(Packages.Market)

Market.server.start({
	catalog = {
		Coins = { Kind = "Product", Id = 111, Giftable = true, DisplayName = "100 Coins" },
		VIP = { Kind = "Pass", Id = 222, GiftProduct = 333, DisplayName = "VIP" },
		Monthly = { Kind = "Subscription", Id = "EXP-444" },
	},
	packets = { buy = Packets.Buy, gift = Packets.Gift },
	serve = NetworkService.serve,
	notify = function(player, notice) NotifyService.notify(player, notice) end,
})

Market.server.product("Coins", function(player)
	return DataManagerService.add(player, "Cash", 100) ~= nil
end)
Market.server.pass("VIP", function(player, owned) end)
Market.server.subscription("Monthly", function(player, active) end)
```

Client: `Market.client.start({ catalog = ..., packets = ... })`, then `buy(name)`, `gift(name, userId)`,
`owns(name)` and `observe(name, fn)` for passes and subscriptions.

`packets.buy` is a request taking the item name, `packets.gift` a request taking the name and a user id; both answer
`(ok, reason)`. `serve` is optional (without it Market sets `OnServerInvoke`), and so is `notify`.

## What it does

- **Products.** `ProcessReceipt` grants through the function registered with `product`, which answers `true` once the
  item is applied. The purchase id goes into the profile (`Market.Receipts`) and the save is confirmed before Roblox
  hears `PurchaseGranted`: a crash never charges without granting, and a retried receipt never grants twice. A grant
  that answers false or errors leaves the receipt for later. Purchases made outside the game (the experience page)
  are granted when the buyer joins.
- **Passes.** Ownership is read on join (`UserOwnsGamePassAsync`, retried), taken at once when a pass is bought in the
  session, and kept on the player as the attribute `MarketPass_<name>` so the client knows. The listener hears each
  pass once per session.
- **Subscriptions.** Status is read on join and again on `Players.UserSubscriptionStatusChanged`, kept as the
  attribute `MarketSub_<name>`; the listener hears every change, including the first inactive state on join. Prompts
  open on the client.
- **Gifts.** A product with `Giftable = true`, or a pass with a `GiftProduct` (a developer product that gives the pass,
  since Roblox has no way to gift passes). The server checks the recipient is in the server, is not the buyer and
  does not own the pass, and that the buyer's regional price level is not below the recipient's. It saves the intent
  in the buyer's profile, opens the prompt, and on the receipt sends the gift as a Vault message: it reaches the
  recipient in this server, in another one, or on their next join, and their ledger (`Market.Received`) applies it
  once. Gifted passes are kept in `Market.Passes` and count as owned everywhere. A cancelled prompt drops the intent;
  a plain buy replaces it; an intent older than an hour is ignored.

Vault adds the private `Market` field to every profile (`Vault.server.extend`), so the game's template needs nothing.

## Not done

- Products with a limited stock: Robux cannot be refunded, so the stock would have to be reserved before the prompt
  and released when it is cancelled. Not built.
- Revoking a pass bought and then refunded: Roblox ownership is read once per session.
- The client sees ownership through attributes; any player could read anyone's.

## Proven how

`tools/specs/market.spec.luau`: 29 specs on simulated servers with a simulated MarketplaceService (purchases,
outside purchases, retries, crashes between sending a gift and saving, recipients changing servers, lookups failing,
price levels, passes, subscriptions, the client). Calibration: 41 deliberate bugs, all caught. Not run on real Roblox
servers yet.
