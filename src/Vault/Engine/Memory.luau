--!strict
local Record = require(script.Parent.Record)

type Entry = {
	Data: any,
	CreatedTime: number,
	UpdatedTime: number,
	VersionId: number,
	UserIds: { number },
	MetaData: any,
}

export type Space = { [string]: { [string]: Entry } }

local Memory = {}

local function keyInfo(entry: Entry): any
	local version = tostring(entry.VersionId)
	return {
		CreatedTime = entry.CreatedTime,
		UpdatedTime = entry.UpdatedTime,
		Version = `{string.rep("0", 16)}.{string.rep("0", 10 - #version)}{version}.{string.rep("0", 16)}.01`,
		GetMetadata = function(): any
			return Record.copy(entry.MetaData)
		end,
		GetUserIds = function(): { number }
			return Record.copy(entry.UserIds)
		end,
	}
end

function Memory.update(
	space: Space,
	storeName: string,
	key: string,
	transform: (any, any) -> (any, any, any),
	read: boolean,
	now: number
): (any, any)
	local keys = space[storeName]
	if not keys then
		keys = {}
		space[storeName] = keys
	end
	local stamp = math.floor(now * 1000)
	local entry = keys[key]
	local existed = entry ~= nil
	if not entry and not read then
		entry = { Data = nil, CreatedTime = stamp, UpdatedTime = stamp, VersionId = 0, UserIds = {}, MetaData = {} }
		keys[key] = entry
	end
	local value, userIds, metadata = transform(if entry then entry.Data else nil, if existed then keyInfo(entry) else nil)
	if value == nil then
		return nil, nil
	end
	if entry and not read then
		entry.Data = Record.copy(value)
		entry.UserIds = Record.copy(userIds or {})
		entry.MetaData = Record.copy(metadata or {})
		entry.VersionId += 1
		entry.UpdatedTime = stamp
	end
	return Record.copy(value), if entry then keyInfo(entry) else nil
end

function Memory.remove(space: Space, storeName: string, key: string)
	local keys = space[storeName]
	if keys then
		keys[key] = nil
		if next(keys) == nil then
			space[storeName] = nil
		end
	end
end

return Memory
