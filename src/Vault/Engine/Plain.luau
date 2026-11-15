--!strict
local Backend = require(script.Parent.Backend)
local Budget = require(script.Parent.Budget)
local Health = require(script.Parent.Health)
local Memory = require(script.Parent.Memory)
local Throttle = require(script.Parent.Throttle)

export type Transform = (current: any) -> any

local Plain = {}

local function inMemory(context: any, mock: boolean): boolean
	return mock or context.state ~= "Access"
end

local function space(context: any, mock: boolean): any
	return if mock then context.memory.plainUser else context.memory.plainFallback
end

local function token(context: any, name: string, key: string, mock: boolean): string
	local prefix = if mock then "UG_" elseif context.state ~= "Access" then "MG_" else "G_"
	return `{prefix}{name}\0{key}`
end

local function live(context: any, name: string): any
	local store = context.plainStores[name]
	if not store then
		store = context.env.dataStore(name)
		context.plainStores[name] = store
	end
	return store
end

function Plain.update(context: any, name: string, key: string, mock: boolean, transform: Transform, priority: Budget.Priority?): (boolean, any)
	Backend.checkKey(context, key)
	Backend.ready(context)
	if not Budget.wait(context, "write", priority) then
		return false, nil
	end
	local leave = context.queue.enter(token(context, name, key, mock))
	local result
	local ok, err = pcall(function()
		local function wrapped(current: any): any
			return transform(current)
		end
		if inMemory(context, mock) then
			result = Memory.update(space(context, mock), name, key, wrapped, false, context.env.time())
			task.wait()
		else
			Throttle.pause(context)
			result = live(context, name):UpdateAsync(key, wrapped)
		end
	end)
	leave()
	if not ok then
		Throttle.note(context, err)
		Health.failed(context, err, name, key)
		return false, nil
	end
	return true, result
end

function Plain.read(context: any, name: string, key: string, mock: boolean): (boolean, any)
	Backend.checkKey(context, key)
	Backend.ready(context)
	local result
	local ok, err = pcall(function()
		if inMemory(context, mock) then
			result = Memory.update(space(context, mock), name, key, function(current: any): any
				return current
			end, true, context.env.time())
			task.wait()
		else
			Throttle.pause(context)
			result = live(context, name):GetAsync(key)
		end
	end)
	if not ok then
		Throttle.note(context, err)
		Health.failed(context, err, name, key)
		return false, nil
	end
	return true, result
end

function Plain.remove(context: any, name: string, key: string, mock: boolean): boolean
	Backend.checkKey(context, key)
	Backend.ready(context)
	local leave = context.queue.enter(token(context, name, key, mock))
	local ok, err = pcall(function()
		if inMemory(context, mock) then
			Memory.remove(space(context, mock), name, key)
			task.wait()
		else
			Throttle.pause(context)
			live(context, name):RemoveAsync(key)
		end
	end)
	leave()
	if not ok then
		Throttle.note(context, err)
		Health.failed(context, err, name, key)
	end
	return ok
end

return Plain
