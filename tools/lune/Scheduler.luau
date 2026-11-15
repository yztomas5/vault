local Scheduler = {}

export type Owner = { alive: boolean, name: string, [string]: any }

type Timer = { at: number, order: number, owner: Owner?, thread: thread, args: { n: number, [number]: any } }

local DEFAULT_FRAME = 1 / 30
local MODULUS = 2147483647
local MULTIPLIER = 48271

function Scheduler.new(seed: number?, frame: number?)
	local scheduler = {}
	local now = 0
	local order = 0
	local state = math.max(1, (seed or 1) % MODULUS)
	local step = frame or DEFAULT_FRAME
	local timers: { Timer } = {}
	local deferred: { Timer } = {}
	local listeners: { { owner: Owner, fn: (number) -> () } } = {}
	local cancelled: { [thread]: true } = setmetatable({}, { __mode = "k" }) :: any
	local current: Owner? = nil
	local root = coroutine.running()

	scheduler.errors = {} :: { string }

	local function resume(owner: Owner?, thread: thread, ...: any)
		if (owner and not owner.alive) or cancelled[thread] or coroutine.status(thread) ~= "suspended" then
			return
		end
		local previous = current
		current = owner
		local ok, err = coroutine.resume(thread, ...)
		current = previous
		if not ok then
			table.insert(scheduler.errors, `{if owner then owner.name else "world"}: {tostring(err)}\n{debug.traceback(thread)}`)
		end
	end

	local function threadOf(target: any): thread
		return if type(target) == "thread" then target else coroutine.create(target)
	end

	local function schedule(list: { Timer }, at: number, owner: Owner?, thread: thread, ...: any)
		order += 1
		table.insert(list, { at = at, order = order, owner = owner, thread = thread, args = table.pack(...) })
	end

	function scheduler.now(): number
		return now
	end

	function scheduler.frame(): number
		return step
	end

	function scheduler.current(): Owner?
		return current
	end

	function scheduler.random(): number
		state = (state * MULTIPLIER) % MODULUS
		return (state - 1) / (MODULUS - 1)
	end

	function scheduler.between(low: number, high: number): number
		return low + (high - low) * scheduler.random()
	end

	function scheduler.spawn(owner: Owner?, target: any, ...: any): thread
		local thread = threadOf(target)
		resume(owner, thread, ...)
		return thread
	end

	function scheduler.defer(owner: Owner?, target: any, ...: any): thread
		local thread = threadOf(target)
		schedule(deferred, now, owner, thread, ...)
		return thread
	end

	function scheduler.delay(owner: Owner?, seconds: number, target: any, ...: any): thread
		local thread = threadOf(target)
		schedule(timers, now + math.max(seconds or 0, 0), owner, thread, ...)
		return thread
	end

	function scheduler.sleep(seconds: number?): number
		if coroutine.running() == root then
			error("simulated time can only pass inside a simulated server: run this call inside server.await", 2)
		end
		local started = now
		schedule(timers, now + math.max(seconds or 0, 0), current, coroutine.running())
		coroutine.yield()
		return now - started
	end

	function scheduler.cancel(thread: thread)
		cancelled[thread] = true
	end

	function scheduler.onFrame(owner: Owner, fn: (number) -> ()): () -> ()
		local entry = { owner = owner, fn = fn }
		table.insert(listeners, entry)
		return function()
			local index = table.find(listeners, entry)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	function scheduler.taskFor(owner: Owner)
		return {
			spawn = function(target: any, ...: any): thread
				return scheduler.spawn(owner, target, ...)
			end,
			defer = function(target: any, ...: any): thread
				return scheduler.defer(owner, target, ...)
			end,
			delay = function(seconds: number, target: any, ...: any): thread
				return scheduler.delay(owner, seconds, target, ...)
			end,
			wait = function(seconds: number?): number
				return scheduler.sleep(seconds)
			end,
			cancel = scheduler.cancel,
		}
	end

	local function flush()
		local guard = 0
		while #deferred > 0 do
			guard += 1
			assert(guard < 10000, "task.defer loop")
			local batch = deferred
			deferred = {}
			for _, item in batch do
				resume(item.owner, item.thread, table.unpack(item.args, 1, item.args.n))
			end
		end
	end

	function scheduler.step()
		now += step
		local due: { Timer } = {}
		local rest: { Timer } = {}
		for _, timer in timers do
			table.insert(if timer.at <= now then due else rest, timer)
		end
		timers = rest
		table.sort(due, function(a: Timer, b: Timer): boolean
			if a.at ~= b.at then
				return a.at < b.at
			end
			return a.order < b.order
		end)
		for _, timer in due do
			resume(timer.owner, timer.thread, table.unpack(timer.args, 1, timer.args.n))
		end
		flush()
		for _, entry in table.clone(listeners) do
			if entry.owner.alive then
				scheduler.spawn(entry.owner, entry.fn, step)
			end
		end
		flush()
	end

	function scheduler.run(seconds: number)
		local target = now + seconds
		while now < target do
			scheduler.step()
		end
	end

	function scheduler.runUntil(done: () -> boolean, limit: number): boolean
		local target = now + limit
		while not done() do
			if now >= target then
				return false
			end
			scheduler.step()
		end
		return true
	end

	return scheduler
end

return Scheduler
