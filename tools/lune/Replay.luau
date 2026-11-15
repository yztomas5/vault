local Cloud = require("./Cloud")

local Replay = {}

export type Context = {
	placeId: number,
	epoch: number,
	template: { [string]: any },
	message: any,
	deadSeconds: number,
	messageQueue: number,
}

local START_MODES = {
	{ label = "start", ask = false, steal = false, cancelled = false },
	{ label = "start asking", ask = true, steal = false, cancelled = false },
	{ label = "start stealing", ask = false, steal = true, cancelled = false },
	{ label = "start cancelled", ask = true, steal = false, cancelled = true },
}

local function messageIds(record: any): { [number]: true }
	local ids = {}
	local messages = if type(record) == "table" then record.GlobalUpdates else nil
	for _, entry in if type(messages) == "table" then messages[2] else {} do
		ids[entry[1]] = true
	end
	return ids
end

local function effect(before: any, after: any, jobId: string?, label: string): string
	local function holder(record: any): string?
		local meta = if type(record) == "table" then record.MetaData else nil
		local tag = if type(meta) == "table" then meta.ActiveSession else nil
		return if type(tag) == "table" then tag[2] else nil
	end
	local was, is = holder(before), holder(after)
	if label == "start" or label == "start asking" or label == "start stealing" then
		if is == jobId and was ~= jobId then
			return if was == nil then "start: took a free profile" else `{label}: took it from another server`
		end
		if is == jobId then
			return "start: already the holder"
		end
		return `{label}: left with the other server`
	end
	return label
end

function Replay.explain(Record: any, Lock: any, commit: any, context: Context): string?
	local before, after = commit.before, commit.after
	if after == nil then
		return "remove"
	end
	local me = { placeId = context.placeId, jobId = commit.jobId }
	local times = { context.epoch + math.floor(commit.at), context.epoch + math.floor(commit.at) - 1 }

	local function matches(build: (record: any, kind: string) -> boolean): boolean
		local record, kind = Record.open(Cloud.copy(before))
		if not build(record, kind) then
			return false
		end
		Record.close(record, kind)
		return Cloud.same(record, after)
	end

	if matches(function(record: any): boolean
		Record.addMessage(record, Cloud.copy(context.message), context.messageQueue)
		return true
	end) then
		return "message"
	end

	local processed = {}
	local kept = messageIds(after)
	for id in messageIds(before) do
		if not kept[id] then
			processed[id] = true
		end
	end
	for _, now in times do
		for _, ending in { false, true } do
			if matches(function(record: any, kind: string): boolean
				return kind == "Existing"
					and Lock.save(record, {
						me = me,
						loadIndex = Record.loadCount(record),
						now = now,
						ending = ending,
						data = after.Data,
						userIds = after.UserIds,
						robloxMetaData = after.RobloxMetaData,
						processed = processed,
					})
			end) then
				return if ending then "last save" else "save"
			end
		end
	end

	if matches(function(record: any, kind: string): boolean
		return kind == "Existing"
	end) then
		return "write that changed nothing"
	end

	local sessionId = Record.sessionId(after) or "none"
	for _, now in times do
		for _, mode in START_MODES do
			if matches(function(record: any, kind: string): boolean
				Lock.start(record, kind, {
					me = me,
					sessionId = sessionId,
					now = now,
					template = context.template,
					ask = mode.ask,
					steal = mode.steal,
					cancelled = mode.cancelled,
					deadSeconds = context.deadSeconds,
				})
				return true
			end) then
				return effect(before, after, commit.jobId, mode.label)
			end
		end
	end

	return nil
end

return Replay
