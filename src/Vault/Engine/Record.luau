--!strict
export type Identity = { placeId: number, jobId: string }
export type Kind = "Existing" | "Missing" | "Overwritten"
export type Stored = { [string]: any }
export type Message = { id: number, data: any }

local Record = {}

local function noMessages(): { any }
	return { 0, {} }
end

function Record.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in value do
		out[key] = Record.copy(item)
	end
	return out
end

function Record.reconcile(target: { [any]: any }, template: { [any]: any })
	for key, value in template do
		if type(key) == "string" then
			if target[key] == nil then
				target[key] = Record.copy(value)
			elseif type(target[key]) == "table" and type(value) == "table" then
				Record.reconcile(target[key], value)
			end
		end
	end
end

function Record.open(stored: any): (Stored, Kind)
	if stored == nil then
		return { GlobalUpdates = noMessages() }, "Missing"
	end
	if type(stored) ~= "table" then
		return { GlobalUpdates = noMessages() }, "Overwritten"
	end
	local messages = stored.GlobalUpdates
	if type(messages) == "table" then
		if type(stored.Data) == "table" and type(stored.MetaData) == "table" then
			stored.WasOverwritten = false
			return stored, "Existing"
		end
		if stored.Data == nil and stored.MetaData == nil then
			return { GlobalUpdates = messages }, "Missing"
		end
	end
	return { GlobalUpdates = noMessages() }, "Overwritten"
end

function Record.close(record: Stored, kind: Kind): (Stored, any, any)
	if kind == "Overwritten" then
		record.WasOverwritten = true
	end
	return record, record.UserIds, record.RobloxMetaData
end

function Record.isSession(tag: any, identity: Identity): boolean
	return type(tag) == "table" and tag[1] == identity.placeId and tag[2] == identity.jobId
end

function Record.holder(record: Stored): Identity?
	local meta = record.MetaData
	local tag = if type(meta) == "table" then meta.ActiveSession else nil
	return if type(tag) == "table" then { placeId = tag[1], jobId = tag[2] } else nil
end

function Record.sessionId(record: Stored): string?
	local meta = record.MetaData
	local tag = if type(meta) == "table" then meta.ActiveSession else nil
	return if type(tag) == "table" and type(tag[3]) == "string" then tag[3] else nil
end

function Record.loadCount(record: Stored): number
	local meta = record.MetaData
	local count = if type(meta) == "table" then meta.SessionLoadCount else nil
	return if type(count) == "number" then count else 0
end

function Record.addMessage(record: Stored, message: any, limit: number)
	local messages = record.GlobalUpdates
	messages[1] += 1
	table.insert(messages[2], { messages[1], message })
	while #messages[2] > limit do
		table.remove(messages[2], 1)
	end
end

function Record.dropMessages(record: Stored, processed: { [number]: true })
	local list = record.GlobalUpdates[2]
	for index = #list, 1, -1 do
		if processed[list[index][1]] then
			table.remove(list, index)
		end
	end
end

function Record.messages(record: Stored): { Message }
	local out = {}
	local messages = record.GlobalUpdates
	for _, entry in if type(messages) == "table" and type(messages[2]) == "table" then messages[2] else {} do
		table.insert(out, { id = entry[1], data = entry[#entry] })
	end
	return out
end

return Record
