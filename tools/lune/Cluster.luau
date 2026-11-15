local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local Cloud = require("./Cloud")
local Scheduler = require("./Scheduler")

local Cluster = {}

export type Options = {
	seed: number?,
	frame: number?,
}

export type Commit = { key: string, before: any, after: any, jobId: string?, at: number }

export type ServerOptions = {
	placeId: number?,
	studio: boolean?,
	clockSkew: number?,
	uptime: number?,
	patches: { [string]: (source: string) -> string }?,
	services: { [string]: any }?,
}

local DEFAULT_PLACE_ID = 1001
local SHUTDOWN_SECONDS = 30
local DEFAULT_UPTIME = 600

local placeCache: { [string]: any } = {}

Cluster.placeId = DEFAULT_PLACE_ID

local function signal(scheduler: any, owner: any)
	local listeners: { (...any) -> () } = {}
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
	function self.Once(_: any, fn: (...any) -> ())
		local connection
		connection = self.Connect(self, function(...: any)
			connection.Disconnect()
			fn(...)
		end)
		return connection
	end
	function self.Fire(_: any, ...: any)
		for _, fn in table.clone(listeners) do
			scheduler.spawn(owner, fn, ...)
		end
	end
	return self
end

function Cluster.new(placePath: string, options: Options?)
	local opts = options or {}
	local place = placeCache[placePath]
	if not place then
		place = roblox.deserializePlace(fs.readFile(placePath))
		placeCache[placePath] = place
	end

	local scheduler = Scheduler.new(opts.seed, opts.frame)
	local cloud = Cloud.new(scheduler)
	local cluster = {}
	local guids = 0
	local servers = 0

	cluster.scheduler = scheduler
	cluster.cloud = cloud
	cluster.errors = scheduler.errors
	cluster.now = scheduler.now
	cluster.run = scheduler.run
	cluster.runUntil = scheduler.runUntil

	function cluster.trace(): { Commit }
		local commits: { Commit } = {}
		cloud.onCommit(function(_: string, key: string, before: any, after: any, owner: any)
			table.insert(commits, {
				key = key,
				before = before,
				after = after,
				jobId = if owner then owner.jobId else nil,
				at = scheduler.now(),
			})
		end)
		return commits
	end

	local function locate(text: string): any
		local node: any = place
		for name in string.gmatch(text, "[^%.]+") do
			local child = node:FindFirstChild(name)
			assert(child, `no {name} in {node:GetFullName()}`)
			node = child
		end
		return node
	end

	function cluster.server(name: string?, serverOptions: ServerOptions?)
		local settings = serverOptions or {}
		servers += 1
		local label = name or `server{servers}`
		local owner = { alive = true, name = label, jobId = `job-{servers}-{label}` }
		local server = { name = label, jobId = owner.jobId, owner = owner, warnings = {}, output = {} }
		local cache: { [any]: any } = {}
		local loading: { [any]: boolean } = {}
		local closers: { () -> () } = {}
		local closing = false
		local closed = false
		local heartbeat = signal(scheduler, owner)
		local playerAdded = signal(scheduler, owner)
		local playerRemoving = signal(scheduler, owner)
		local playerList: { any } = {}

		scheduler.onFrame(owner, function(dt: number)
			heartbeat:Fire(dt)
		end)

		local services: { [string]: any } = {
			DataStoreService = cloud.dataStoreService(),
			MessagingService = cloud.messagingService(owner),
			HttpService = {
				GenerateGUID = function(): string
					guids += 1
					return `guid-{guids}`
				end,
				JSONEncode = function(_: any, value: any): string
					return serde.encode("json", value)
				end,
				JSONDecode = function(_: any, text: string): any
					return serde.decode("json", text)
				end,
			},
			RunService = {
				Heartbeat = heartbeat,
				IsStudio = function(): boolean
					return settings.studio == true
				end,
				IsServer = function(): boolean
					return true
				end,
				IsClient = function(): boolean
					return false
				end,
			},
			Players = {
				PlayerAdded = playerAdded,
				PlayerRemoving = playerRemoving,
				UserSubscriptionStatusChanged = signal(scheduler, owner),
				GetPlayers = function(): { any }
					return table.clone(playerList)
				end,
				GetPlayerByUserId = function(_: any, userId: number): any
					for _, player in playerList do
						if player.UserId == userId then
							return player
						end
					end
					return nil
				end,
			},
		}
		server.players = services.Players

		for service, fake in settings.services or {} do
			services[service] = fake
		end

		local game = setmetatable({}, {
			__index = function(_: any, key: string): any
				if key == "GetService" then
					return function(_: any, service: string): any
						return services[service] or place:GetService(service)
					end
				end
				if key == "BindToClose" then
					return function(_: any, fn: () -> ())
						table.insert(closers, fn)
					end
				end
				if key == "PlaceId" then
					return settings.placeId or DEFAULT_PLACE_ID
				end
				if key == "JobId" then
					return owner.jobId
				end
				if key == "GameId" then
					return 1
				end
				return services[key] or place:GetService(key)
			end,
		})

		local function record(list: { string }, ...: any)
			local parts = {}
			for index = 1, select("#", ...) do
				parts[index] = tostring((select(index, ...)))
			end
			table.insert(list, table.concat(parts, " "))
		end

		local function load(module: any): any
			if cache[module] ~= nil then
				return cache[module]
			end
			assert(module and module:IsA("ModuleScript"), "require target is not a ModuleScript")
			assert(not loading[module], `cyclic require of {module:GetFullName()}`)
			loading[module] = true
			local source = module.Source
			local patch = settings.patches and settings.patches[module.Name]
			if patch then
				local patched = patch(source)
				assert(patched ~= source, `the patch for {module.Name} changed nothing`)
				source = patched
			end
			local environment: { [string]: any } = {
				script = module,
				game = game,
				task = scheduler.taskFor(owner),
				Enum = roblox.Enum,
				math = setmetatable({
					random = function(low: number?, high: number?): number
						local roll = scheduler.random()
						if low and high then
							return math.floor(low + roll * (high - low + 1))
						end
						return if low then math.floor(1 + roll * low) else roll
					end,
				}, { __index = math }),
				Instance = {
					new = function(className: string): any
						return setmetatable({ ClassName = className }, {
							__index = function(_: any, key: string): any
								local field = string.match(key, "^Set(%u.*)$")
								if field then
									return function(self: any, value: any)
										rawset(self, field, value)
									end
								end
								return function() end
							end,
						})
					end,
				},
				os = setmetatable({
					clock = function(): number
						return scheduler.now() + (settings.uptime or DEFAULT_UPTIME)
					end,
					time = function(): number
						return cloud.epoch + math.floor(scheduler.now()) + (settings.clockSkew or 0)
					end,
				}, { __index = os }),
				warn = function(...: any)
					record(server.warnings, ...)
				end,
				print = function(...: any)
					record(server.output, ...)
				end,
				require = load,
			}
			local chunk = luau.load(source, { debugName = module:GetFullName(), environment = environment })
			local result = chunk()
			loading[module] = nil
			cache[module] = result
			return result
		end

		function server.require(text: string): any
			local result
			local thread = scheduler.spawn(owner, function()
				result = load(locate(text))
			end)
			assert(coroutine.status(thread) == "dead", `{text} yielded while loading`)
			return result
		end

		function server.spawn(fn: (...any) -> (), ...: any): thread
			return scheduler.spawn(owner, fn, ...)
		end

		function server.await<T...>(limit: number, fn: () -> T...): T...
			local results: any = nil
			scheduler.spawn(owner, function()
				results = table.pack(pcall(fn))
			end)
			local finished = scheduler.runUntil(function(): boolean
				return results ~= nil
			end, limit)
			assert(finished, `{label} did not finish within {limit} s`)
			assert(results[1], `{label} failed: {tostring(results[2])}`)
			return table.unpack(results, 2, results.n)
		end

		function server.alive(): boolean
			return owner.alive
		end

		function server.removePlayer(player: any)
			local index = table.find(playerList, player)
			if index then
				table.remove(playerList, index)
				player.Parent = nil
				playerRemoving:Fire(player)
			end
		end

		function server.addPlayer(userId: number, joinData: any?): any
			local attributes: { [string]: any } = {}
			local watchers: { [string]: any } = {}
			local player = { UserId = userId, Name = `Player{userId}`, kicked = nil :: string?, Parent = services.Players }
			function player.GetJoinData(): any
				return joinData or {}
			end
			function player.GetAttribute(_: any, key: string): any
				return attributes[key]
			end
			function player.SetAttribute(_: any, key: string, value: any)
				attributes[key] = value
				if watchers[key] then
					watchers[key]:Fire()
				end
			end
			function player.GetAttributeChangedSignal(_: any, key: string): any
				if not watchers[key] then
					watchers[key] = signal(scheduler, owner)
				end
				return watchers[key]
			end
			function player.Kick(_: any, message: string?)
				player.kicked = message or ""
				scheduler.defer(owner, server.removePlayer, player)
			end
			table.insert(playerList, player)
			playerAdded:Fire(player)
			return player
		end

		function server.closed(): boolean
			return closed
		end

		function server.kill()
			owner.alive = false
			closed = true
			cloud.forget(owner)
		end

		function server.close()
			if closing then
				return
			end
			closing = true
			local pending = #closers
			for _, closer in closers do
				scheduler.spawn(owner, function()
					closer()
					pending -= 1
					if pending == 0 then
						server.kill()
					end
				end)
			end
			if pending == 0 then
				server.kill()
				return
			end
			scheduler.delay(nil, SHUTDOWN_SECONDS, function()
				if owner.alive then
					table.insert(server.warnings, "shutdown hit the 30 second limit")
					server.kill()
				end
			end)
		end

		function server.shutdown(): boolean
			server.close()
			scheduler.runUntil(server.closed, SHUTDOWN_SECONDS + 1)
			return not table.find(server.warnings, "shutdown hit the 30 second limit")
		end

		return server
	end

	return cluster
end

return Cluster
