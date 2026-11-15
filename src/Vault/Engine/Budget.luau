--!strict
export type Kind = "read" | "write" | "ordered"
export type Priority = "normal" | "low"

local Budget = {}

local POLL_SECONDS = 1

function Budget.room(context: any, kind: Kind): boolean
	return context.env.budget(kind) > context.settings.GlobalReserve
end

function Budget.wait(context: any, kind: Kind, priority: Priority?): boolean
	if priority ~= "low" or context.closing then
		return true
	end
	local deadline = context.env.clock() + context.settings.LowPriorityWaitSeconds
	while not Budget.room(context, kind) do
		if context.closing then
			return true
		end
		if context.env.clock() >= deadline then
			return false
		end
		task.wait(POLL_SECONDS)
	end
	return true
end

return Budget
