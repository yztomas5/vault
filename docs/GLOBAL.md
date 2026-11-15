# Global data

Data that belongs to no single player: what every server shares, or what lives on with nobody online. Player data
stays in profiles (`Vault.server`). Everything here is server only and runs on the same engine as the profiles, so it
shares their queue per key, retries, throttling pauses and health signals.

## What to use for what

| You need | Use | Not this |
|---|---|---|
| a value all servers read and some write (event state, a clan, a world record) | `Vault.shared` | |
| a number every server adds to (how many relics exist, total visits) | `Vault.counter(...).add` | |
| "only N of these exist" | `Vault.counter(...).claim` | |
| a ranking between players | `Vault.leaderboard` | |
| a gift or message to one player, online or not | `Vault.server.sendMessage` (profile messages) | a store of its own |
| values you change from the Creator Hub without publishing | Roblox Experience Configs (`ConfigService`) | Vault |
| bans | `Players:BanAsync` | Vault |
| old versions of a key | Data Stores Manager in the Creator Hub | Vault |
| short lived state between servers (matchmaking, server lists) | MemoryStore, in the game | Vault, for now |

## Shared documents

```lua
local Events = Vault.shared("Events", { template = { Night = false, Boss = 0 } })

local night = Events.get("Night")
local ok, value = Events.update("Night", function(current)
	current.Night = true
	return current
end)
local stop = Events.observe("Night", function(value) end)
```

- A shared store holds documents by key. `get` yields the first time a key is read and then answers from memory.
  It returns `(value, loaded)` and always hands out a copy.
- `update` is atomic: the transform gets a copy of the current value and returns the new one, or nil to write
  nothing. It must not yield, and it can run more than once. It answers `(written, value)`. A retry after an
  answer was lost does not apply the change twice.
- After an update every server that holds the key hears about it within seconds through MessagingService. Values
  up to 900 encoded bytes travel in the message; bigger ones are read again by each server.
- Every `refreshSeconds` (default 60) each server reads its keys again, in case a message was lost. Each read is a
  data store request, so this is for documents that change now and then, not every frame.
- Stored as `{ Version, Data, Ids }`. A newer version never gets replaced by an older one, whatever order messages
  and reads arrive in.

## Counters

```lua
local Stock = Vault.counter("RelicStock", { flushSeconds = 30 })

Stock.add("GoldenBanana", 1)
local total = Stock.get("GoldenBanana")

local granted, reason = Stock.claim("Crown", 50)
local left = Stock.remaining("Crown", 50)
```

- **`add`** never yields. Adds collect in memory and every `flushSeconds` (default 30) each key gets one write with
  the sum, and the rest is sent at shutdown. A server that crashes loses only what it had not sent yet, the same
  window profiles have. A write retried after a lost answer is not counted twice: each batch carries an id, and the
  key remembers the last 128.
- **`get`** answers the stored total plus what this server has not sent, reading the store again at most every
  `refreshSeconds` (default 60).
- **`claim`** takes one unit from a cap and never hands out more than the cap. The cap is split over up to 16 keys
  (one per 25 units) so many servers can claim at once. A claim retried after a lost answer is not granted twice.
  It answers `false, "full"` at once, with no request, after this server has seen every part full. When it answers
  `false, "failed"` the unit may still have been used. The cap is per call: the same key with a different cap is
  a different count.
- `pending()` tells how much this server holds unsent.

## Leaderboards

```lua
local Richest = Vault.leaderboard("Cash", { window = "All" })
local Weekly = Vault.leaderboard("Relics", { window = "Week" })

Richest.submit(player, cash)
for _, row in Richest.top(10) do
	print(row.rank, row.userId, row.value)
end
```

- `window` is `All`, `Day` or `Week`. Days and weeks change at 00:00 UTC, and weeks start on Monday. Each window is
  its own OrderedDataStore (`Cash_All`, `Relics_W2915`), so a new one starts empty.
- `submit` never yields. It keeps the last value per player and sends it every `submitSeconds` (default 60), and
  only if it changed. Values are floored and must stay below 2^53.
- `top` reads at most every `topSeconds` (default 60) and shares that read with every caller. If a read fails it
  keeps answering the last one. Up to 100 rows.
- `ascending = true` ranks lowest first, for times.
- `Vault.server.wipe(userId)` also takes the player out of every leaderboard this server opened: the current window
  and the last `keep` windows (default 8).

## Priorities

Every server has one request budget for everything. Counter flushes and leaderboard submits are low priority: when
the budget left drops to 10 requests or fewer they wait (up to 10 s, then they try again on the next round), so they
never take the requests a player's save needs. Shared updates and claims go ahead, because someone is waiting on
them. During shutdown nothing waits.

## Studio

Global data follows what Vault does with profiles in that session:

| Profiles in Studio | Global data |
|---|---|
| in memory (`Mock`, the default) | in memory |
| Studio store | the same names with `_Studio` at the end |
| production read only | reads the real stores, writes nothing |
| production session (`studioProduction`) | the real stores |
| Vault never started (15 s) | in memory, with a warning |

Live servers always use the real stores. Names: up to 43 characters (34 for leaderboards). Keys: up to 50 characters
(46 for claims).

## Proven how

`tools/specs/global_shared.spec.luau`, `global_counter.spec.luau` and `global_leaderboard.spec.luau` run on the
simulated servers with errors, lost answers, repeated transforms, late reads, lost messages, crashes and shutdowns.
They check that no shared update is lost or applied twice, that sums land exactly once, that a claim never goes past
its cap, and that rankings and windows are right. Calibration: 39 deliberate bugs, 38 caught; the one left is a
check that only saves a read. The real server test has a section for global data (`docs/REALTEST.md`).
