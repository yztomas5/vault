local Cloud = require("./Cloud")

local Watch = {}

local function holderOf(record: any): string?
	local meta = if type(record) == "table" then record.MetaData else nil
	local session = if type(meta) == "table" then meta.ActiveSession else nil
	return if type(session) == "table" then session[2] else nil
end

function Watch.new(cluster: any)
	local watch = { violations = {} :: { string }, commits = 0 }

	cluster.cloud.onCommit(function(store: string, key: string, before: any, after: any, owner: any)
		watch.commits += 1
		if type(before) ~= "table" or type(after) ~= "table" or type(before.Data) ~= "table" then
			return
		end
		if Cloud.same(before.Data, after.Data) then
			return
		end
		local writer = if owner then owner.jobId else "world"
		local holder = holderOf(before)
		if holder ~= writer then
			table.insert(
				watch.violations,
				`{writer} changed the data of {store}/{key} at {cluster.now()} while {tostring(holder)} held the lock`
			)
		end
		local was, is = before.Data.Counter, if type(after.Data) == "table" then after.Data.Counter else nil
		if type(was) == "number" and type(is) == "number" and is < was then
			table.insert(watch.violations, `{store}/{key} went back from {was} to {is} at {cluster.now()}`)
		end
	end)

	watch.holderOf = holderOf

	return watch
end

return Watch
