--!strict
export type Wheel = {
	list: { any },
	index: number,
	last: number,
}

local Wheel = {}

function Wheel.new(now: number): Wheel
	return { list = {}, index = 1, last = now }
end

function Wheel.add(context: any, session: any)
	local wheel: Wheel = context.wheel
	context.sessions[session.internal.token] = session
	table.insert(wheel.list, wheel.index, session)
	if #wheel.list > 1 then
		wheel.index += 1
	else
		wheel.last = context.env.clock()
	end
end

function Wheel.remove(context: any, session: any)
	local wheel: Wheel = context.wheel
	context.sessions[session.internal.token] = nil
	local index = table.find(wheel.list, session)
	if not index then
		return
	end
	table.remove(wheel.list, index)
	if index < wheel.index then
		wheel.index -= 1
	end
	if wheel.list[wheel.index] == nil then
		wheel.index = 1
	end
end

local function advance(wheel: Wheel)
	wheel.index += 1
	if wheel.index > #wheel.list then
		wheel.index = 1
	end
end

function Wheel.step(context: any, save: (session: any) -> ())
	local wheel: Wheel = context.wheel
	local count = #wheel.list
	if count == 0 then
		return
	end
	local period = context.settings.AutoSaveSeconds
	local pace = period / count
	local now = context.env.clock()
	while now - wheel.last > pace do
		wheel.last += pace
		local session = wheel.list[wheel.index]
		if now - session.internal.loadTimestamp < period / 2 then
			session = nil
			for _ = 1, count - 1 do
				advance(wheel)
				session = wheel.list[wheel.index]
				if now - session.internal.loadTimestamp >= period / 2 then
					break
				end
				session = nil
			end
		end
		advance(wheel)
		if session then
			save(session)
		end
	end
end

return Wheel
