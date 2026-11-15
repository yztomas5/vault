--!strict
local Mode = require(script.Parent.Mode)

export type Window = "All" | "Day" | "Week"

export type Options = {
	window: Window?,
	ascending: boolean?,
	submitSeconds: number?,
	topSeconds: number?,
	size: number?,
	keep: number?,
}

export type Row = { rank: number, userId: number, value: number }

export type Leaderboard = {
	name: string,
	submit: (who: any, value: number) -> (),
	top: (count: number?) -> { Row },
	flush: () -> (),
	board: (offset: number?) -> string,
	wipe: (userId: number) -> boolean,
}

local Leaderboard = {}

local DAY = 86400
local WEEK = 7 * DAY
local MONDAY_OFFSET = 3 * DAY
local SUBMIT_SECONDS = 60
local TOP_SECONDS = 60
local PAGE_LIMIT = 100
local KEEP_WINDOWS = 8
local NAME_LENGTH = Mode.nameLength - 9
local WINDOW_TAGS = { All = "All", Day = "D", Week = "W" }
local LARGEST = 2 ^ 53

local function userIdOf(who: any): number
	local userId = if type(who) == "number" then who else (who :: any).UserId
	if type(userId) ~= "number" or userId % 1 ~= 0 then
		error("[Vault] a leaderboard entry needs a player or a whole user id", 3)
	end
	return userId
end

function Leaderboard.new(context: any, name: string, options: Options?): Leaderboard
	Mode.checkName(name, NAME_LENGTH)
	local opts: Options = options or {}
	local window: Window = opts.window or "All"
	assert(WINDOW_TAGS[window], `[Vault] unknown leaderboard window {tostring(window)}`)
	local ascending = opts.ascending == true
	local submitSeconds = opts.submitSeconds or SUBMIT_SECONDS
	local topSeconds = opts.topSeconds or TOP_SECONDS
	local size = math.clamp(opts.size or PAGE_LIMIT, 1, PAGE_LIMIT)
	local keep = opts.keep or KEEP_WINDOWS
	local engine = context.engine
	local queued: { [number]: number } = {}
	local written: { [string]: { [number]: number } } = {}
	local cache: { board: string, at: number, rows: { Row } }? = nil
	local running = false

	local function index(offset: number): number
		local now = os.time()
		if window == "Day" then
			return now // DAY - offset
		end
		return (now + MONDAY_OFFSET) // WEEK - offset
	end

	local function board(offset: number?): string
		if window == "All" then
			return `{name}_All`
		end
		return `{name}_{WINDOW_TAGS[window]}{index(offset or 0)}`
	end

	local function store(boardName: string): any
		local mode = Mode.current(context)
		return engine.ordered(Mode.storeName(mode, boardName), Mode.mock(mode))
	end

	local function flush()
		if next(queued) == nil then
			return
		end
		if not Mode.writable(Mode.current(context)) then
			table.clear(queued)
			return
		end
		local current = board(0)
		local sent = written[current]
		if not sent then
			sent = {}
			written[current] = sent
		end
		for userId, value in table.clone(queued) do
			if sent[userId] == value then
				queued[userId] = nil
			elseif store(current).set(tostring(userId), value, "low") then
				sent[userId] = value
				if queued[userId] == value then
					queued[userId] = nil
				end
			end
		end
	end

	local function loop()
		while true do
			task.wait(submitSeconds)
			flush()
		end
	end

	engine.beforeClose(flush)

	local function submit(who: any, value: number)
		local userId = userIdOf(who)
		if type(value) ~= "number" or value ~= value or math.abs(value) >= LARGEST then
			warn(`[Vault] leaderboard {name} ignored a value that is not a finite number below 2^53`)
			return
		end
		queued[userId] = math.floor(value)
		if not running then
			running = true
			task.spawn(loop)
		end
	end

	local function top(count: number?): { Row }
		local wanted = math.clamp(math.floor(count or size), 1, size)
		local current = board(0)
		local found = cache
		if not found or found.board ~= current or os.clock() - found.at >= topSeconds then
			local ok, rows = store(current).top(size, ascending)
			if ok and rows then
				local list: { Row } = {}
				for rank, row in rows do
					local userId = tonumber(row.key)
					if userId then
						table.insert(list, { rank = rank, userId = userId, value = row.value })
					end
				end
				found = { board = current, at = os.clock(), rows = list }
				cache = found
			elseif not found or found.board ~= current then
				return {}
			end
		end
		local out = {}
		for position = 1, math.min(wanted, #(found :: any).rows) do
			local row = (found :: any).rows[position]
			out[position] = { rank = row.rank, userId = row.userId, value = row.value }
		end
		return out
	end

	local function wipe(userId: number): boolean
		queued[userId] = nil
		local clean = true
		local windows = if window == "All" then 0 else keep
		for offset = 0, windows do
			local boardName = board(offset)
			if written[boardName] then
				written[boardName][userId] = nil
			end
			clean = store(boardName).remove(tostring(userId)) and clean
		end
		cache = nil
		return clean
	end

	return {
		name = name,
		submit = submit,
		top = top,
		flush = flush,
		board = board,
		wipe = wipe,
	}
end

return Leaderboard
