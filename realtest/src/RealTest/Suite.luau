local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Fleet = require(script.Parent.Fleet)

local Suite = {}

local STORE = "VaultRealTest"
local VAULT_STORES = { production = "VaultRealTestP", studio = "VaultRealTestS" }
local SCENARIO_SECONDS = 150
local READ_ATTEMPTS = 4
local GLOBAL_SHARED = "VaultRealTestGShared"
local GLOBAL_COUNTER = "VaultRealTestGCounter"
local GLOBAL_BOARD = "VaultRealTestGBoard"
local LISTEN_SECONDS = 5

local function template(): { [string]: any }
	return { Counter = 0, Bag = {} }
end

local function holderOf(value: any): string?
	local meta = if type(value) == "table" then value.MetaData else nil
	local tag = if type(meta) == "table" then meta.ActiveSession else nil
	return if type(tag) == "table" then tag[2] else nil
end

local function within(seconds: number, fn: () -> ()): (boolean, string?)
	local done = false
	local ok, err = true, nil
	task.spawn(function()
		ok, err = pcall(fn)
		done = true
	end)
	local deadline = os.clock() + seconds
	while not done and os.clock() < deadline do
		task.wait(0.1)
	end
	if not done then
		return false, `timed out after {seconds} s`
	end
	return ok, if ok then nil else tostring(err)
end

local function seconds(value: number): string
	return string.format("%.1f s", value)
end

local SCENARIOS: { { name: string, run: (ctx: any) -> () } } = {
	{
		name = "save, lock and release",
		run = function(ctx: any)
			local a = ctx.fleet.server("a")
			local key = ctx.key("basic")
			local session = a.store.start(key)
			ctx.check("a new profile starts from the template", session ~= nil and session.data.Counter == 0)
			session.data.Counter = 5
			local player = Players:GetPlayers()[1]
			if player then
				session.addUserId(player.UserId)
			end
			ctx.check("a save reports that it landed", session.saveNow() == "Saved")
			local stored, info = ctx.raw(STORE, key)
			ctx.check("the data store holds the saved data", stored.Data.Counter == 5)
			ctx.check("the lock names this server", holderOf(stored) == a.jobId)
			if player then
				ctx.check("the key carries the player's user id", table.find(info:GetUserIds(), player.UserId) ~= nil)
			end
			local encoded = #HttpService:JSONEncode(session.data)
			ctx.check("the size meter matches the encoded data", session.bytes == encoded, `{session.bytes} bytes`)
			session.release()
			ctx.waitFor(20, function(): boolean
				return holderOf(ctx.raw(STORE, key)) == nil
			end)
			ctx.check("release frees the lock", holderOf(ctx.raw(STORE, key)) == nil)
			ctx.check("and keeps the data", ctx.raw(STORE, key).Data.Counter == 5)
		end,
	},
	{
		name = "hand off between two servers",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local key = ctx.key("handoff")
			local first = a.store.start(key)
			first.data.Counter = 3
			local started = os.clock()
			local second = b.store.start(key)
			local took = os.clock() - started
			ctx.check("another server gets the session", second ~= nil, seconds(took))
			ctx.check("with what the first one had not saved yet", second.data.Counter == 3)
			ctx.check("within 15 seconds", took <= 15, seconds(took))
			ctx.check("the first session ended", not first.active())
			ctx.check("the load count went up", second.loadCount == 2)
			second.release()
		end,
	},
	{
		name = "take over from a dead server",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local key = ctx.key("crash")
			local first = a.store.start(key)
			first.data.Counter = 4
			first.saveNow()
			a.kill()
			local started = os.clock()
			local second = b.store.start(key)
			local took = os.clock() - started
			ctx.check("a new server takes the profile of a dead one", second ~= nil and second.data.Counter == 4, seconds(took))
			ctx.check("only after the steal delay", took >= Fleet.settings.StealSeconds and took <= 60, seconds(took))
			second.release()
		end,
	},
	{
		name = "dead server limit",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local key = ctx.key("dead")
			a.store.start(key)
			a.kill()
			task.wait(Fleet.settings.DeadSeconds + 3)
			local started = os.clock()
			local second = b.store.start(key)
			local took = os.clock() - started
			ctx.check("a profile silent past the limit is taken at once", second ~= nil and took <= 5, seconds(took))
			second.release()
		end,
	},
	{
		name = "messages",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local key = ctx.key("mail")
			ctx.check("a message can be sent to a profile that does not exist yet", b.store.message(key, { Amount = 5 }))
			local session = a.store.start(key)
			local got = 0
			session.onMessage(function(message: any, processed: () -> ())
				got += message.Amount
				processed()
			end)
			ctx.waitFor(5, function(): boolean
				return got == 5
			end)
			ctx.check("it arrives when the profile loads", got == 5)
			task.wait(LISTEN_SECONDS)
			local started = os.clock()
			b.store.message(key, { Amount = 2 })
			ctx.waitFor(30, function(): boolean
				return got == 7
			end)
			ctx.check("a message reaches an open session on another server", got == 7, seconds(os.clock() - started))
			session.saveNow()
			local stored = ctx.raw(STORE, key)
			ctx.check("processed messages leave the key", #stored.GlobalUpdates[2] == 0 and stored.GlobalUpdates[1] == 2)
			session.release()
		end,
	},
	{
		name = "view and remove",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local key = ctx.key("view")
			local session = a.store.start(key)
			session.data.Counter = 9
			session.saveNow()
			local view = b.store.view(key)
			ctx.check("a view reads the data", view ~= nil and view.data.Counter == 9)
			ctx.check("without taking the lock", holderOf(ctx.raw(STORE, key)) == a.jobId and session.active())
			ctx.check("a missing key views as nothing", b.store.view(ctx.key("nothing")) == nil)
			session.release()
			ctx.waitFor(20, function(): boolean
				return holderOf(ctx.raw(STORE, key)) == nil
			end)
			ctx.check("remove reports success", b.store.remove(key) == true)
			ctx.check("and the key is gone", ctx.raw(STORE, key) == nil)
		end,
	},
	{
		name = "reload in the same server",
		run = function(ctx: any)
			local a = ctx.fleet.server("a")
			local key = ctx.key("reload")
			local first = a.store.start(key)
			first.data.Counter = 1
			first.release()
			local second = a.store.start(key)
			ctx.check("the newest data comes back", second ~= nil and second.data.Counter == 1)
			ctx.check("as a new session", second.loadCount == 2)
			second.release()
		end,
	},
	{
		name = "ProfileStore and Vault on the same profile",
		run = function(ctx: any)
			local b = ctx.fleet.server("b", true)
			local key = ctx.key("mixed")
			local source = ctx.ProfileStore.New(STORE, template())
			local profile = source:StartSessionAsync(key)
			ctx.check("ProfileStore opens the profile", profile ~= nil)
			profile.Data.Counter = 1
			local started = os.clock()
			local session = b.store.start(key)
			ctx.check("Vault takes the session from ProfileStore", session ~= nil and session.data.Counter == 1, seconds(os.clock() - started))
			ctx.check("ProfileStore saw its session end", not profile:IsActive())
			session.data.Counter = 2
			started = os.clock()
			local back = source:StartSessionAsync(key)
			ctx.check("ProfileStore takes it back from Vault", back ~= nil and back.Data.Counter == 2, seconds(os.clock() - started))
			ctx.check("Vault saw its session end", not session.active())
			ctx.check("the load count kept growing", back.SessionLoadCount == 3)
			back:EndSession()
		end,
	},
	{
		name = "global data across two servers",
		run = function(ctx: any)
			local a, b = ctx.fleet.server("a"), ctx.fleet.server("b")
			local function live(): string
				return "Live"
			end
			local ga, gb = ctx.Global.new(a.engine, live), ctx.Global.new(b.engine, live)

			local docKey = ctx.key("doc")
			ctx.remember(GLOBAL_SHARED, docKey)
			local docA = ga.shared(GLOBAL_SHARED, { template = { Count = 0 } })
			local docB = gb.shared(GLOBAL_SHARED, { template = { Count = 0 } })
			local latest = -1
			docB.observe(docKey, function(value: any)
				latest = value.Count
			end)
			task.wait(3)
			local writers = 0
			for _, doc in { docA, docB } do
				for _ = 1, 5 do
					writers += 1
					task.spawn(function()
						doc.update(docKey, function(current: any): any
							current.Count += 1
							return current
						end)
						writers -= 1
					end)
				end
			end
			ctx.waitFor(60, function(): boolean
				return writers == 0
			end)
			local stored = ctx.raw(GLOBAL_SHARED, docKey)
			ctx.check("ten updates from two servers at once all landed", type(stored) == "table" and stored.Data.Count == 10, if type(stored) == "table" then `{stored.Data.Count}` else "nothing stored")
			ctx.waitFor(15, function(): boolean
				return latest == 10
			end)
			ctx.check("the other server saw the final value", latest == 10, `{latest}`)

			local sumKey = ctx.key("sum")
			ctx.remember(GLOBAL_COUNTER, sumKey)
			local countA, countB = ga.counter(GLOBAL_COUNTER), gb.counter(GLOBAL_COUNTER)
			for _ = 1, 30 do
				countA.add(sumKey, 1)
			end
			countB.add(sumKey, 4)
			countA.flush()
			countB.flush()
			local total = ctx.raw(GLOBAL_COUNTER, sumKey)
			ctx.check("sums from two servers add up", type(total) == "table" and total.Total == 34, if type(total) == "table" then `{total.Total}` else "nothing stored")

			local capKey = ctx.key("cap")
			ctx.remember(GLOBAL_COUNTER, `{capKey}#1`)
			local granted, pendingClaims = 0, 0
			for _, counter in { countA, countB } do
				for _ = 1, 4 do
					pendingClaims += 1
					task.spawn(function()
						if counter.claim(capKey, 5) then
							granted += 1
						end
						pendingClaims -= 1
					end)
				end
			end
			ctx.waitFor(60, function(): boolean
				return pendingClaims == 0
			end)
			ctx.check("eight claims against a cap of five grant exactly five", granted == 5, `{granted}`)
			ctx.check("and the store agrees", countA.remaining(capKey, 5) == 0)

			local boardA = ga.leaderboard(GLOBAL_BOARD, { topSeconds = 0 })
			local boardB = gb.leaderboard(GLOBAL_BOARD, { topSeconds = 0 })
			boardA.submit(-1, 10)
			boardB.submit(-2, 20)
			boardA.flush()
			boardB.flush()
			task.wait(5)
			local top = boardA.top(10)
			local first, second
			for _, row in top do
				if row.userId == -2 then
					first = row.rank
				elseif row.userId == -1 then
					second = row.rank
				end
			end
			ctx.check("the leaderboard ranks both servers' entries", first ~= nil and second ~= nil and first < second)
			boardA.wipe(-1)
			boardA.wipe(-2)
		end,
	},
	{
		name = "the whole Vault server",
		run = function(ctx: any)
			local vault = ctx.Vault.new()
			local prefix = `{ctx.key("vault")}_`
			vault.start({
				template = { DataVersion = 1, Cash = 0 },
				migrations = {},
				versionPath = { "DataVersion" },
				baseVersion = 1,
				keyPrefix = prefix,
				stores = VAULT_STORES,
				studioData = "Studio",
				loadSeconds = 60,
				snapshotSeconds = 8,
				messages = { failed = "failed", stolen = "stolen", wiped = "wiped" },
				packets = { snapshot = {}, changes = { FireClient = function() end } },
				players = false,
			})
			local player = { UserId = -1, Name = "VaultRealTest", Kick = function() end }
			vault.join(player)
			ctx.check("a player's data loads", vault.ready(player, 60))
			local choice = vault.choice()
			ctx.info(`Vault store: {choice.kind} on {choice.name}`)
			ctx.check("on a real data store, not in memory", choice.kind == "Session")
			vault.set(player, "Cash", 7)
			ctx.check("a save lands", vault.saveNow(player) == "Saved")
			ctx.check("the size is known", vault.size(player) > 0, `{vault.size(player)} bytes`)
			vault.leave(player)
			local key = `{prefix}-1`
			ctx.remember(choice.name, key)
			ctx.waitFor(20, function(): boolean
				return holderOf(ctx.raw(choice.name, key)) == nil
			end)
			ctx.check("leaving saves and frees the lock", ctx.raw(choice.name, key).Data.Cash == 7 and holderOf(ctx.raw(choice.name, key)) == nil)
			vault.join(player)
			ctx.check("the data is there on the next join", vault.ready(player, 60) and vault.get(player, "Cash") == 7)
			vault.leave(player)
		end,
	},
}

function Suite.run(report: any, Engine: any, Vault: any, ProfileStore: any, Global: any)
	local run = os.time() % 10000000
	local used: { { store: string, key: string } } = {}
	local stores: { [string]: any } = {}

	local function storeOf(name: string): any
		if not stores[name] then
			stores[name] = DataStoreService:GetDataStore(name)
		end
		return stores[name]
	end

	local ctx = {
		fleet = Fleet.new(Engine, STORE, template()),
		Vault = Vault,
		ProfileStore = ProfileStore,
		Global = Global,
		check = report.check,
		info = report.info,
	}

	function ctx.remember(store: string, key: string)
		table.insert(used, { store = store, key = key })
	end

	function ctx.key(name: string): string
		local key = `rt{run}_{name}`
		ctx.remember(STORE, key)
		return key
	end

	function ctx.raw(store: string, key: string): (any, any)
		local value, info
		for attempt = 1, READ_ATTEMPTS do
			local ok = pcall(function()
				value, info = storeOf(store):GetAsync(key)
			end)
			if ok then
				break
			end
			task.wait(attempt)
		end
		return value, info
	end

	function ctx.waitFor(limit: number, done: () -> boolean)
		local deadline = os.clock() + limit
		while not done() and os.clock() < deadline do
			task.wait(0.5)
		end
	end

	local started = os.clock()
	for _, scenario in SCENARIOS do
		report.section(scenario.name)
		local ok, err = within(SCENARIO_SECONDS, function()
			scenario.run(ctx)
		end)
		if not ok then
			report.check(`{scenario.name} ran to the end`, false, err)
		end
	end

	for _, entry in used do
		pcall(function()
			storeOf(entry.store):RemoveAsync(entry.key)
		end)
	end
	report.info(`suite took {seconds(os.clock() - started)}, test keys removed`)
end

return Suite
