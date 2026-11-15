--!strict
local Mode = require(script.Parent.Mode)

export type Options = {
	flushSeconds: number?,
	refreshSeconds: number?,
	buckets: number?,
}

export type Reason = "full" | "failed"

export type Counter = {
	name: string,
	add: (key: string, amount: number) -> (),
	get: (key: string) -> number?,
	flush: () -> (),
	pending: () -> number,
	claim: (key: string, cap: number) -> (boolean, Reason?),
	remaining: (key: string, cap: number) -> number?,
}

type Batch = { id: string, amount: number }

local Counter = {}

local SUM_KEY_LENGTH = 50
local CLAIM_KEY_LENGTH = 46
local FLUSH_SECONDS = 30
local REFRESH_SECONDS = 60
local REMEMBERED_IDS = 128
local PER_BUCKET = 25
local MAX_BUCKETS = 16
local CLAIM_ATTEMPTS = 3
local CLOSE_ATTEMPTS = 3

local function remember(list: { string }, id: string)
	table.insert(list, id)
	while #list > REMEMBERED_IDS do
		table.remove(list, 1)
	end
end

local function sumRecord(current: any): { Total: number, Batches: { string } }
	if type(current) == "table" and type(current.Total) == "number" then
		if type(current.Batches) ~= "table" then
			current.Batches = {}
		end
		return current
	end
	return { Total = 0, Batches = {} }
end

local function bucketRecord(current: any): { Used: number, Claims: { string } }
	if type(current) == "table" and type(current.Used) == "number" then
		if type(current.Claims) ~= "table" then
			current.Claims = {}
		end
		return current
	end
	return { Used = 0, Claims = {} }
end

local function checkCap(cap: any)
	if type(cap) ~= "number" or cap % 1 ~= 0 or cap < 0 then
		error("[Vault] a cap must be a whole number of zero or more", 3)
	end
end

function Counter.new(context: any, name: string, options: Options?): Counter
	Mode.checkName(name)
	local opts: Options = options or {}
	local flushSeconds = opts.flushSeconds or FLUSH_SECONDS
	local refreshSeconds = opts.refreshSeconds or REFRESH_SECONDS
	local maxBuckets = math.clamp(opts.buckets or MAX_BUCKETS, 1, MAX_BUCKETS)
	local engine = context.engine
	local pending: { [string]: number } = {}
	local inflight: { [string]: Batch } = {}
	local totals: { [string]: number } = {}
	local readAt: { [string]: number } = {}
	local full: { [string]: { [number]: true } } = {}
	local running = false

	local function store(): any
		local mode = Mode.current(context)
		return engine.plain(Mode.storeName(mode, name), Mode.mock(mode))
	end

	local function writable(): boolean
		return Mode.writable(Mode.current(context))
	end

	local function flushKey(key: string): boolean
		local batch = inflight[key]
		if not batch then
			local amount = pending[key]
			if not amount or amount == 0 then
				pending[key] = nil
				return true
			end
			pending[key] = nil
			batch = { id = engine.guid(), amount = amount }
			inflight[key] = batch
		end
		local current = batch :: Batch
		local ok, stored = store().update(key, function(raw: any): any
			local record = sumRecord(raw)
			if not table.find(record.Batches, current.id) then
				record.Total += current.amount
				remember(record.Batches, current.id)
			end
			return record
		end, "low")
		if ok and type(stored) == "table" then
			inflight[key] = nil
			totals[key] = stored.Total
			readAt[key] = os.clock()
			return true
		end
		return false
	end

	local function flush()
		if not writable() then
			table.clear(pending)
			table.clear(inflight)
			return
		end
		local keys: { [string]: true } = {}
		for key in pending do
			keys[key] = true
		end
		for key in inflight do
			keys[key] = true
		end
		for key in keys do
			flushKey(key)
		end
	end

	local function loop()
		while true do
			task.wait(flushSeconds)
			flush()
		end
	end

	local function start()
		if not running then
			running = true
			task.spawn(loop)
		end
	end

	engine.beforeClose(function()
		for _ = 1, CLOSE_ATTEMPTS do
			flush()
			if next(pending) == nil and next(inflight) == nil then
				return
			end
			task.wait(1)
		end
	end)

	local function add(key: string, amount: number)
		Mode.checkKey(key, SUM_KEY_LENGTH)
		if type(amount) ~= "number" or amount ~= amount or math.abs(amount) == math.huge then
			error("[Vault] a counter amount must be a finite number", 2)
		end
		if amount == 0 then
			return
		end
		pending[key] = (pending[key] or 0) + amount
		start()
	end

	local function unsent(key: string): number
		local batch = inflight[key]
		return (pending[key] or 0) + (if batch then batch.amount else 0)
	end

	local function get(key: string): number?
		Mode.checkKey(key, SUM_KEY_LENGTH)
		local fresh = readAt[key] ~= nil and os.clock() - readAt[key] < refreshSeconds
		if not fresh then
			local ok, stored = store().read(key)
			if ok then
				totals[key] = sumRecord(stored).Total
				readAt[key] = os.clock()
			elseif totals[key] == nil then
				return nil
			end
		end
		return (totals[key] :: number) + unsent(key)
	end

	local function pendingCount(): number
		local count = 0
		for key in pending do
			count += unsent(key)
		end
		for key, batch in inflight do
			if pending[key] == nil then
				count += batch.amount
			end
		end
		return count
	end

	local function bucketCount(cap: number): number
		return math.clamp(math.ceil(cap / PER_BUCKET), 1, maxBuckets)
	end

	local function capacity(cap: number, count: number, index: number): number
		return cap // count + (if index <= cap % count then 1 else 0)
	end

	local function knownFull(key: string, cap: number): { [number]: true }
		local id = `{key}\0{cap}`
		local found = full[id]
		if not found then
			found = {}
			full[id] = found
		end
		return found
	end

	local function claim(key: string, cap: number): (boolean, Reason?)
		Mode.checkKey(key, CLAIM_KEY_LENGTH)
		checkCap(cap)
		if not writable() then
			warn(`[Vault] {name} is read only in this Studio session, {key} not claimed`)
			return false, "failed"
		end
		local count = bucketCount(cap)
		local known = knownFull(key, cap)
		local id = engine.guid()
		while true do
			local open = {}
			for index = 1, count do
				if not known[index] and capacity(cap, count, index) > 0 then
					table.insert(open, index)
				end
			end
			if #open == 0 then
				return false, "full"
			end
			local index = open[math.random(1, #open)]
			local room = capacity(cap, count, index)
			local granted = false
			local landed = false
			local used = 0
			for attempt = 1, CLAIM_ATTEMPTS do
				local ok = store().update(`{key}#{index}`, function(raw: any): any
					local record = bucketRecord(raw)
					if table.find(record.Claims, id) then
						granted = true
						used = record.Used
						return nil
					end
					if record.Used >= room then
						granted = false
						used = record.Used
						return nil
					end
					record.Used += 1
					remember(record.Claims, id)
					granted = true
					used = record.Used
					return record
				end)
				if ok then
					landed = true
					break
				end
				task.wait(attempt)
			end
			if not landed then
				return false, "failed"
			end
			if used >= room then
				known[index] = true
			end
			if granted then
				return true, nil
			end
		end
	end

	local function remaining(key: string, cap: number): number?
		Mode.checkKey(key, CLAIM_KEY_LENGTH)
		checkCap(cap)
		local count = bucketCount(cap)
		local left = 0
		for index = 1, count do
			local ok, stored = store().read(`{key}#{index}`)
			if not ok then
				return nil
			end
			left += math.max(0, capacity(cap, count, index) - bucketRecord(stored).Used)
		end
		return left
	end

	return {
		name = name,
		add = add,
		get = get,
		flush = flush,
		pending = pendingCount,
		claim = claim,
		remaining = remaining,
	}
end

return Counter
