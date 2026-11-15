--!strict
local Record = require(script.Parent.Record)

type Identity = Record.Identity
type Stored = Record.Stored

export type Verdict = "Owned" | "Waiting" | "Refused" | "Free"

export type StartIntent = {
	me: Identity,
	sessionId: string,
	now: number,
	template: { [string]: any },
	ask: boolean,
	steal: boolean,
	cancelled: boolean,
	deadSeconds: number,
}

export type SaveIntent = {
	me: Identity,
	loadIndex: number,
	now: number,
	ending: boolean,
	data: { [string]: any },
	userIds: { number }?,
	robloxMetaData: any,
	processed: { [number]: true },
}

local Lock = {}

local function take(meta: { [string]: any }, intent: StartIntent)
	meta.ActiveSession = { intent.me.placeId, intent.me.jobId, intent.sessionId } :: { any }
	meta.ForceLoadSession = nil
end

local function claim(meta: { [string]: any }, intent: StartIntent)
	local active = meta.ActiveSession
	if active == nil then
		take(meta, intent)
		return
	end
	if type(active) ~= "table" then
		return
	end
	if Record.isSession(active, intent.me) then
		meta.ForceLoadSession = nil
		return
	end
	local last = meta.LastUpdate
	if last ~= nil and intent.now - last > intent.deadSeconds then
		take(meta, intent)
		return
	end
	if intent.steal then
		if Record.isSession(meta.ForceLoadSession, intent.me) then
			take(meta, intent)
		end
	elseif intent.ask then
		meta.ForceLoadSession = { intent.me.placeId, intent.me.jobId } :: { any }
	end
end

function Lock.start(record: Stored, kind: Record.Kind, intent: StartIntent)
	if kind ~= "Existing" then
		record.Data = Record.copy(intent.template)
		record.MetaData = {
			ProfileCreateTime = intent.now,
			SessionLoadCount = 0,
			MetaTags = {},
		}
		if not intent.cancelled then
			take(record.MetaData, intent)
		end
	elseif not intent.cancelled then
		claim(record.MetaData, intent)
	end
	if intent.cancelled then
		return
	end
	local meta = record.MetaData
	if Record.isSession(meta.ActiveSession, intent.me) then
		meta.SessionLoadCount = Record.loadCount(record) + 1
		meta.LastUpdate = intent.now
	end
end

function Lock.verdict(record: Stored, me: Identity): Verdict
	local meta = record.MetaData
	local active = if type(meta) == "table" then meta.ActiveSession else nil
	if type(active) ~= "table" then
		return "Free"
	end
	if Record.isSession(active, me) then
		return "Owned"
	end
	return if Record.isSession(meta.ForceLoadSession, me) then "Waiting" else "Refused"
end

function Lock.owns(record: Stored, me: Identity, loadIndex: number): boolean
	local meta = record.MetaData
	return type(meta) == "table" and Record.isSession(meta.ActiveSession, me) and meta.SessionLoadCount == loadIndex
end

function Lock.releaseAsked(record: Stored, me: Identity): boolean
	local meta = record.MetaData
	local asked = if type(meta) == "table" then meta.ForceLoadSession else nil
	return type(asked) == "table" and not Record.isSession(asked, me)
end

function Lock.save(record: Stored, intent: SaveIntent): boolean
	if not Lock.owns(record, intent.me, intent.loadIndex) then
		return false
	end
	Record.dropMessages(record, intent.processed)
	record.Data = intent.data
	record.RobloxMetaData = intent.robloxMetaData
	record.UserIds = intent.userIds
	record.MetaData.LastUpdate = intent.now
	if intent.ending then
		record.MetaData.ActiveSession = nil
	end
	return true
end

return Lock
