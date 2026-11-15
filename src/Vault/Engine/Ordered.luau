--!strict
local Backend = require(script.Parent.Backend)
local Budget = require(script.Parent.Budget)
local Health = require(script.Parent.Health)
local Throttle = require(script.Parent.Throttle)

export type Row = { key: string, value: number }

local Ordered = {}

local PAGE_LIMIT = 100

local function inMemory(context: any, mock: boolean): boolean
	return mock or context.state ~= "Access"
end

local function space(context: any, mock: boolean, name: string): { [string]: number }
	local root = if mock then context.memory.orderedUser else context.memory.orderedFallback
	local entries = root[name]
	if not entries then
		entries = {}
		root[name] = entries
	end
	return entries
end

local function live(context: any, name: string): any
	local store = context.orderedStores[name]
	if not store then
		store = context.env.orderedStore(name)
		context.orderedStores[name] = store
	end
	return store
end

local function token(context: any, name: string, key: string, mock: boolean): string
	local prefix = if mock then "UO_" elseif context.state ~= "Access" then "MO_" else "O_"
	return `{prefix}{name}\0{key}`
end

local function call(context: any, name: string, key: string, mock: boolean, run: () -> ()): boolean
	local leave = context.queue.enter(token(context, name, key, mock))
	local ok, err = pcall(function()
		run()
	end)
	leave()
	if not ok then
		Throttle.note(context, err)
		Health.failed(context, err, name, key)
	end
	return ok
end

function Ordered.set(context: any, name: string, key: string, value: number, mock: boolean, priority: Budget.Priority?): boolean
	Backend.checkKey(context, key)
	if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge or value % 1 ~= 0 then
		error("[Vault] an ordered value must be a whole number", 2)
	end
	Backend.ready(context)
	if not Budget.wait(context, "ordered", priority) then
		return false
	end
	return call(context, name, key, mock, function()
		if inMemory(context, mock) then
			space(context, mock, name)[key] = value
			task.wait()
		else
			Throttle.pause(context)
			live(context, name):SetAsync(key, value)
		end
	end)
end

function Ordered.remove(context: any, name: string, key: string, mock: boolean): boolean
	Backend.checkKey(context, key)
	Backend.ready(context)
	return call(context, name, key, mock, function()
		if inMemory(context, mock) then
			space(context, mock, name)[key] = nil
			task.wait()
		else
			Throttle.pause(context)
			live(context, name):RemoveAsync(key)
		end
	end)
end

function Ordered.top(context: any, name: string, count: number, ascending: boolean, mock: boolean): (boolean, { Row }?)
	Backend.ready(context)
	local size = math.clamp(math.floor(count), 1, PAGE_LIMIT)
	local rows: { Row } = {}
	local ok, err = pcall(function()
		if inMemory(context, mock) then
			for key, value in space(context, mock, name) do
				table.insert(rows, { key = key, value = value })
			end
			table.sort(rows, function(a: Row, b: Row): boolean
				if a.value ~= b.value then
					return if ascending then a.value < b.value else a.value > b.value
				end
				return a.key < b.key
			end)
			while #rows > size do
				table.remove(rows)
			end
			task.wait()
		else
			Throttle.pause(context)
			local page = live(context, name):GetSortedAsync(ascending, size):GetCurrentPage()
			for _, entry in page do
				if type(entry.value) == "number" then
					table.insert(rows, { key = tostring(entry.key), value = entry.value })
				end
			end
		end
	end)
	if not ok then
		Throttle.note(context, err)
		Health.failed(context, err, name, "<top>")
		return false, nil
	end
	return true, rows
end

return Ordered
