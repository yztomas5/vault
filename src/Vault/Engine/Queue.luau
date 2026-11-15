--!strict
export type Queue = {
	enter: (token: string) -> () -> (),
}

local Queue = {}

function Queue.new(): Queue
	local waiting: { [string]: { thread } } = {}

	local function enter(token: string): () -> ()
		local line = waiting[token]
		if line then
			table.insert(line, coroutine.running())
			coroutine.yield()
		else
			line = {}
			waiting[token] = line
		end
		return function()
			local following = table.remove(line :: { thread }, 1)
			if following then
				task.spawn(following)
			else
				waiting[token] = nil
			end
		end
	end

	return { enter = enter }
end

return Queue
