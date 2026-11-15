local Breaks = require("./Breaks")
local Cluster = require("./Cluster")
local Drivers = require("./Drivers")
local Watch = require("./Watch")

local Soak = {}

export type Options = { broken: string?, trace: boolean? }

local STORE = "Players"
local MINUTES = 30
local KEYS = 5
local SERVERS = 3
local FRAME = 1 / 10
local HOP_RATE = 0.35
local ZOMBIE_SECONDS = 400
local MESSAGE_LOSS = 0.2
local REACH_SECONDS = 90

function Soak.template(): { [string]: any }
	return { Counter = 0, Gifts = 0 }
end

function Soak.message(): { [string]: any }
	return { Amount = 1 }
end

function Soak.run(placePath: string, driverName: string, seed: number, options: Options?)
	local settings = options or {}
	local broken = settings.broken
	local cluster = Cluster.new(placePath, { seed = seed, frame = FRAME })
	local scheduler = cluster.scheduler
	local watch = Watch.new(cluster)
	local commits = if settings.trace then cluster.trace() else {}
	local faults = cluster.cloud.faults
	local servers: { any } = {}
	local crashed: { [string]: true } = {}
	local acked: { [string]: number } = {}
	local stats = { sessions = 0, refused = 0, crashes = 0, closes = 0, increments = 0, hops = 0, mail = 0, gifts = 0 }
	local unbalanced: { string } = {}

	cluster.cloud.onCommit(function(_: string, key: string, _: any, after: any)
		if type(after) ~= "table" or type(after.GlobalUpdates) ~= "table" then
			return
		end
		local gifts = if type(after.Data) == "table" then after.Data.Gifts or 0 else 0
		local sent, pending = after.GlobalUpdates[1], #after.GlobalUpdates[2]
		if gifts + pending ~= sent then
			table.insert(unbalanced, `{key} at {cluster.now()}: {sent} messages sent, {gifts} applied, {pending} pending`)
		end
	end)
	local stopping = false

	faults.errorRate = 0.05
	faults.lostResponseRate = 0.03
	faults.retryRate = 0.1
	faults.messageLoss = MESSAGE_LOSS

	local fleet = if driverName == "Mixed" then Drivers.list else { driverName }
	local made = 0

	local function addServer()
		made += 1
		local name = fleet[(made - 1) % #fleet + 1]
		local server = cluster.server(nil, { patches = Breaks.patches(name, broken) })
		server.store = Drivers[name](server).open(STORE, Soak.template())
		table.insert(servers, server)
	end

	local open: { [string]: { [any]: any } } = {}

	local function pick(key: string): any
		local held = open[key] or {}
		local choices = {}
		for _, server in servers do
			local session = held[server]
			if not session or not session.active() then
				table.insert(choices, server)
			end
		end
		return choices[math.floor(scheduler.between(1, #choices + 1 - 1e-9))]
	end

	local function linger(server: any, session: any)
		local deadline = scheduler.now() + ZOMBIE_SECONDS
		while server.alive() and session.active() and scheduler.now() < deadline and not stopping do
			scheduler.sleep(scheduler.between(5, 60))
			if server.alive() and session.active() then
				session.data.Counter += 1
				server.spawn(session.save)
			end
		end
		if server.alive() and session.active() then
			server.spawn(session.release)
		end
	end

	local function play(key: string, server: any): boolean?
		local session: any = nil
		local done = false
		local deadline = scheduler.now() + 90
		server.spawn(function()
			session = server.store.start(key, function(): boolean
				return stopping or scheduler.now() > deadline
			end)
			done = true
		end)
		while not done and server.alive() do
			scheduler.sleep(0.2)
		end
		if not session or not server.alive() then
			stats.refused += 1
			return nil
		end
		stats.sessions += 1
		open[key] = open[key] or {}
		open[key][server] = session
		session.onSaved(function(data: any)
			acked[key] = math.max(acked[key] or 0, data.Counter)
		end)
		session.onMessage(function(message: any, processed: () -> ())
			session.data.Gifts += message.Amount
			stats.gifts += 1
			processed()
		end)
		for _ = 1, math.floor(scheduler.between(1, 12)) do
			scheduler.sleep(scheduler.between(0.5, 30))
			if stopping or not server.alive() or not session.active() then
				break
			end
			session.data.Counter += 1
			stats.increments += 1
			if scheduler.random() < 0.3 then
				server.spawn(session.save)
			end
		end
		if not server.alive() or not session.active() then
			return nil
		end
		if not stopping and scheduler.random() < HOP_RATE then
			stats.hops += 1
			scheduler.spawn(nil, linger, server, session)
			return true
		end
		server.spawn(session.release)
		return false
	end

	local function player(key: string)
		local hopped = false
		while not stopping do
			scheduler.sleep(if hopped then scheduler.between(0, 3) else scheduler.between(1, 20))
			local server = pick(key)
			hopped = false
			if not stopping and server then
				hopped = play(key, server) == true
			end
		end
	end

	local function chaos()
		while not stopping do
			scheduler.sleep(scheduler.between(60, 200))
			if stopping then
				break
			end
			local index = math.floor(scheduler.between(1, #servers + 1 - 1e-9))
			local server = table.remove(servers, index)
			if scheduler.random() < 0.5 then
				crashed[server.jobId] = true
				stats.crashes += 1
				server.kill()
			else
				stats.closes += 1
				server.close()
			end
			addServer()
		end
	end

	local function outages()
		while not stopping do
			scheduler.sleep(scheduler.between(120, 400))
			if not stopping then
				cluster.cloud.outage(scheduler.between(5, 40))
			end
		end
	end

	local function mail()
		while not stopping do
			scheduler.sleep(scheduler.between(20, 90))
			local server = servers[math.floor(scheduler.between(1, #servers + 1 - 1e-9))]
			if not stopping and server then
				local key = `plr_{math.floor(scheduler.between(1, KEYS + 1 - 1e-9))}`
				stats.mail += 1
				server.spawn(function()
					server.store.message(key, Soak.message())
				end)
			end
		end
	end

	local function deafness()
		while not stopping do
			scheduler.sleep(scheduler.between(100, 300))
			faults.messageLoss = 1
			scheduler.sleep(scheduler.between(60, 150))
			faults.messageLoss = MESSAGE_LOSS
		end
	end

	for _ = 1, SERVERS do
		addServer()
	end
	for index = 1, KEYS do
		scheduler.spawn(nil, player, `plr_{index}`)
	end
	scheduler.spawn(nil, chaos)
	scheduler.spawn(nil, outages)
	scheduler.spawn(nil, deafness)
	scheduler.spawn(nil, mail)

	cluster.run(MINUTES * 60)
	stopping = true
	faults.errorRate = 0
	faults.lostResponseRate = 0
	faults.outageUntil = 0
	faults.messageLoss = 0
	cluster.run(120)
	for _, server in servers do
		server.close()
	end
	cluster.run(40)

	local stuck = {}
	for index = 1, KEYS do
		local key = `plr_{index}`
		local holder = watch.holderOf(cluster.cloud.read(STORE, key))
		if holder and not crashed[holder] then
			table.insert(stuck, `{key} held by {holder}`)
		end
	end

	local last = cluster.server()
	last.store = Drivers[fleet[1]](last).open(STORE, Soak.template())
	local reached: { [string]: boolean } = {}
	for index = 1, KEYS do
		local key = `plr_{index}`
		last.spawn(function()
			reached[key] = last.store.start(key) ~= nil
		end)
	end
	cluster.run(REACH_SECONDS)

	local lost = {}
	local unreachable = {}
	for index = 1, KEYS do
		local key = `plr_{index}`
		local stored = cluster.cloud.read(STORE, key)
		local counter = if type(stored) == "table" and type(stored.Data) == "table" then stored.Data.Counter else 0
		if not reached[key] then
			table.insert(unreachable, `{key} could not be opened by a new server within {REACH_SECONDS} s`)
		end
		if counter < (acked[key] or 0) then
			table.insert(lost, `{key} stored {counter}, acknowledged {acked[key]}`)
		end
	end

	return {
		violations = watch.violations,
		errors = cluster.errors,
		stuck = stuck,
		lost = lost,
		stats = stats,
		unbalanced = unbalanced,
		unreachable = unreachable,
		placeId = Cluster.placeId,
		commits = commits,
		epoch = cluster.cloud.epoch,
	}
end

return Soak
