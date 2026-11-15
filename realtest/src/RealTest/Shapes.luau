local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Shapes = {}

local STORE = "VaultRealTestShapes"
local PREVIEW = 70

local function cases(): { { name: string, value: any } }
	local cyclic = {}
	cyclic.Self = cyclic
	return {
		{ name = "text keys and number keys together", value = { 1, 2, Name = "x" } },
		{ name = "a list with a gap", value = { [1] = "a", [3] = "c" } },
		{ name = "a single high number key", value = { [5] = true } },
		{ name = "number keys that are not whole", value = { [1.5] = "a" } },
		{ name = "a number that is not a number", value = { Speed = 0 / 0 } },
		{ name = "an infinite number", value = { Speed = math.huge } },
		{ name = "text that is not UTF-8", value = { Name = "bad \255 text" } },
		{ name = "a key that is not UTF-8", value = { ["bad \255 key"] = 1 } },
		{ name = "a true/false key", value = { [true] = 1 } },
		{ name = "a function", value = { Callback = function() end } },
		{ name = "an Instance", value = { Part = game } },
		{ name = "a table that contains itself", value = cyclic },
		{ name = "a buffer", value = { Bytes = buffer.create(4) } },
		{ name = "an empty table", value = {} },
		{ name = "one megabyte of text", value = { Text = string.rep("x", 1000000) } },
		{ name = "more than the key limit", value = { Text = string.rep("x", 4300000) } },
	}
end

local function preview(value: any): string
	local ok, encoded = pcall(function(): string
		return HttpService:JSONEncode(value)
	end)
	local text = if ok then encoded else `<{tostring(encoded)}>`
	return if #text > PREVIEW then `{string.sub(text, 1, PREVIEW)}...` else text
end

function Shapes.run(report: any)
	report.section("what the real data store does with odd values")
	local store = DataStoreService:GetDataStore(STORE)
	local run = os.time() % 10000000
	for index, case in cases() do
		local key = `shape{run}_{index}`
		local saved, err = pcall(function()
			store:SetAsync(key, case.value)
		end)
		if not saved then
			report.info(`{case.name}: refused, {string.sub(tostring(err), 1, 90)}`)
		else
			local read, back = pcall(function(): any
				return store:GetAsync(key)
			end)
			report.info(`{case.name}: saved, comes back as {if read then preview(back) else "<read failed>"}`)
			pcall(function()
				store:RemoveAsync(key)
			end)
		end
	end
end

return Shapes
