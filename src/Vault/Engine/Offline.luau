--!strict
local Backend = require(script.Parent.Backend)
local Record = require(script.Parent.Record)

export type View = {
	data: { [string]: any },
	firstSessionTime: number,
	loadCount: number,
	holder: Record.Identity?,
	robloxMetaData: any,
	userIds: { number },
	keyInfo: any,
	messages: { Record.Message },
}

local Offline = {}

local RETRY_CAP_SECONDS = 20

function Offline.view(context: any, store: any, key: string, mock: boolean): View?
	Backend.checkKey(context, key)
	if context.closing then
		return nil
	end
	Backend.ready(context)
	local backoff = 1
	while not context.closing do
		local record, keyInfo = Backend.write(context, store, key, mock, function(opened: Record.Stored, kind: Record.Kind): boolean
			if kind ~= "Existing" then
				opened.Data = Record.copy(store.template)
				opened.MetaData = { ProfileCreateTime = context.env.time(), SessionLoadCount = 0, MetaTags = {} }
			end
			return true
		end, true)
		if record then
			if not keyInfo then
				return nil
			end
			return {
				data = record.Data,
				firstSessionTime = record.MetaData.ProfileCreateTime or 0,
				loadCount = Record.loadCount(record),
				holder = Record.holder(record),
				robloxMetaData = record.RobloxMetaData or {},
				userIds = record.UserIds or {},
				keyInfo = keyInfo,
				messages = Record.messages(record),
			}
		end
		task.wait(backoff)
		backoff = math.min(RETRY_CAP_SECONDS, backoff * 2)
	end
	return nil
end

function Offline.remove(context: any, store: any, key: string, mock: boolean): boolean
	Backend.checkKey(context, key)
	if context.closing then
		return false
	end
	Backend.ready(context)
	return Backend.remove(context, store, key, mock)
end

return Offline
