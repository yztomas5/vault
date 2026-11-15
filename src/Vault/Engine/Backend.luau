--!strict
local Health = require(script.Parent.Health)
local Memory = require(script.Parent.Memory)
local Record = require(script.Parent.Record)
local Throttle = require(script.Parent.Throttle)

export type Edit = (record: Record.Stored, kind: Record.Kind) -> boolean

local Backend = {}

local PROBE_NAME = "____PS"

function Backend.ready(context: any)
	while context.state == "NotReady" do
		task.wait()
	end
end

function Backend.token(context: any, store: any, key: string, mock: boolean): string
	local prefix = if mock then "U_" elseif context.state ~= "Access" then "M_" else "L_"
	return `{prefix}{store.name}\0{key}`
end

function Backend.checkKey(context: any, key: any)
	if type(key) ~= "string" or #key == 0 then
		error("[Vault] the profile key must be a non empty string", 3)
	end
	if #key > context.settings.NameLength then
		error("[Vault] the profile key is too long", 3)
	end
end

local function live(context: any, store: any): any
	if not store.dataStore then
		store.dataStore = context.env.dataStore(store.name)
	end
	return store.dataStore
end

function Backend.write(context: any, store: any, key: string, mock: boolean, edit: Edit, read: boolean?): (Record.Stored?, any, boolean)
	local leave = context.queue.enter(Backend.token(context, store, key, mock))
	local reading = read == true
	local aborted = false
	local record, keyInfo

	local function transform(latest: any): (any, any, any)
		local opened, kind = Record.open(latest)
		aborted = not edit(opened, kind)
		if aborted then
			return nil
		end
		return Record.close(opened, kind)
	end

	local ok, err = pcall(function()
		if mock then
			record, keyInfo = Memory.update(context.memory.user, store.name, key, transform, reading, context.env.time())
			task.wait()
		elseif context.state ~= "Access" then
			record, keyInfo = Memory.update(context.memory.fallback, store.name, key, transform, reading, context.env.time())
			task.wait()
		elseif reading then
			Throttle.pause(context)
			local latest
			latest, keyInfo = live(context, store):GetAsync(key)
			record = transform(latest)
		else
			Throttle.pause(context)
			record, keyInfo = live(context, store):UpdateAsync(key, transform)
		end
	end)

	leave()
	if not ok then
		Throttle.note(context, err)
	end

	if ok and type(record) == "table" then
		if record.WasOverwritten == true and not reading then
			Health.overwritten(context, store.name, key)
		end
		return record, keyInfo, false
	end
	if ok and aborted then
		return nil, nil, true
	end
	Health.failed(context, if ok then "the data store returned nothing" else err, store.name, key)
	return nil, nil, false
end

function Backend.remove(context: any, store: any, key: string, mock: boolean): boolean
	local leave = context.queue.enter(Backend.token(context, store, key, mock))
	local removed = true
	if mock then
		Memory.remove(context.memory.user, store.name, key)
		task.wait()
	elseif context.state ~= "Access" then
		Memory.remove(context.memory.fallback, store.name, key)
		task.wait()
	else
		removed = pcall(function()
			live(context, store):RemoveAsync(key)
		end)
	end
	leave()
	return removed
end

function Backend.probe(context: any)
	local env = context.env
	if not env.studio then
		context.state = "Access"
		return
	end
	task.spawn(function()
		local ok, message = pcall(function()
			env.dataStore(PROBE_NAME):SetAsync(PROBE_NAME, env.time())
		end)
		local text = tostring(message)
		local offline = not ok and string.find(text, "ConnectFail", 1, true) ~= nil
		local refused = not ok
			and (string.find(text, "403", 1, true) ~= nil or string.find(text, "must publish", 1, true) ~= nil or offline)
		if offline then
			warn("[Vault] no internet access, check the network connection")
		end
		if refused then
			print("[Vault] Roblox API services unavailable, data will not be saved")
		else
			print("[Vault] Roblox API services available, data will be saved")
		end
		context.state = if offline then "NoInternet" elseif refused then "NoAccess" else "Access"
	end)
end

return Backend
