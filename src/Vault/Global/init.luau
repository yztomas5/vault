--!strict
local Counter = require(script.Counter)
local Leaderboard = require(script.Leaderboard)
local Mode = require(script.Mode)
local Shared = require(script.Shared)

export type Mode = Mode.Mode
export type Shared = Shared.Shared
export type SharedOptions = Shared.Options
export type Counter = Counter.Counter
export type CounterOptions = Counter.Options
export type Leaderboard = Leaderboard.Leaderboard
export type LeaderboardOptions = Leaderboard.Options
export type LeaderboardRow = Leaderboard.Row

export type Global = {
	shared: (name: string, options: Shared.Options?) -> Shared,
	counter: (name: string, options: Counter.Options?) -> Counter,
	leaderboard: (name: string, options: Leaderboard.Options?) -> Leaderboard,
	mode: () -> Mode,
	wipe: (userId: number) -> boolean,
}

local Global = {}

Global.Mode = Mode

function Global.new(engine: any, resolve: () -> Mode): Global
	local context = { engine = engine, resolve = resolve, mode = nil :: Mode? }
	local opened: { [string]: { [string]: any } } = { shared = {}, counter = {}, leaderboard = {} }

	local function open(kind: string, build: (any, string, any) -> any, name: string, options: any): any
		local found = opened[kind][name]
		if found then
			return found
		end
		local made = build(context, name, options)
		opened[kind][name] = made
		return made
	end

	return {
		shared = function(name: string, options: Shared.Options?): Shared
			return open("shared", Shared.new, name, options)
		end,
		counter = function(name: string, options: Counter.Options?): Counter
			return open("counter", Counter.new, name, options)
		end,
		leaderboard = function(name: string, options: Leaderboard.Options?): Leaderboard
			return open("leaderboard", Leaderboard.new, name, options)
		end,
		mode = function(): Mode
			return Mode.current(context)
		end,
		wipe = function(userId: number): boolean
			local clean = true
			for _, board in opened.leaderboard do
				clean = board.wipe(userId) and clean
			end
			return clean
		end,
	}
end

return Global
