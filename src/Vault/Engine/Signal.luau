--!strict
export type Signal<T...> = {
	connect: (listener: (T...) -> ()) -> () -> (),
	fire: (T...) -> (),
}

local Signal = {}

function Signal.new<T...>(): Signal<T...>
	local listeners: { (T...) -> () } = {}

	local function connect(listener: (T...) -> ()): () -> ()
		table.insert(listeners, listener)
		return function()
			local index = table.find(listeners, listener)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	local function fire(...: T...)
		for _, listener in table.clone(listeners) do
			task.spawn(listener, ...)
		end
	end

	return { connect = connect, fire = fire }
end

return Signal
