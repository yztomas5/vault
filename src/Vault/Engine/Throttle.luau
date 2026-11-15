--!strict
export type Kind = "Experience" | "Server"

local Throttle = {}

local JITTER = 0.25
local SERVER_MARKS = { "GameServerThrottled", "Throttle", "throttled", "request dropped" }

function Throttle.kind(message: string): Kind?
	if string.find(message, "ExperienceThrottled", 1, true) then
		return "Experience"
	end
	for _, mark in SERVER_MARKS do
		if string.find(message, mark, 1, true) then
			return "Server"
		end
	end
	return nil
end

function Throttle.jitter(context: any, seconds: number): number
	return seconds * (1 + context.env.random() * JITTER)
end

function Throttle.note(context: any, message: any)
	local kind = Throttle.kind(tostring(message))
	if not kind then
		return
	end
	local settings = context.settings
	local seconds = if kind == "Experience" then settings.ExperienceThrottleSeconds else settings.ServerThrottleSeconds
	context.throttledUntil = math.max(context.throttledUntil, context.env.clock() + Throttle.jitter(context, seconds))
end

function Throttle.pause(context: any)
	while not context.closing and context.env.clock() < context.throttledUntil do
		task.wait()
	end
end

return Throttle
