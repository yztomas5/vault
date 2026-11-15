local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

local Breaks = require("../lune/Breaks")
local Cloud = require("../lune/Cloud")
local Cluster = require("../lune/Cluster")
local Drivers = require("../lune/Drivers")
local Marketplace = require("../lune/Marketplace")
local Replay = require("../lune/Replay")
local Soak = require("../lune/Soak")
local Watch = require("../lune/Watch")

local SPEC_SUFFIX = ".spec.luau"
local SPEC_FOLDER = process.env.VAULT_SPECS or "tools/specs"

local placePath = process.args[1]
if not placePath then
	error("usage: lune run tools/specs/run.luau <place.rbxl> [filter]")
end
local filter = process.args[2]
local realPlacePath = (string.gsub(placePath, "[^/\\]+$", "realtest.rbxl"))

local function deepEqual(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function describeValue(value: any): string
	if type(value) == "number" then
		return string.format("%.6g", value)
	end
	return tostring(value)
end

local function expect(actual: any)
	local function fail(text: string)
		error(text, 3)
	end
	return {
		toBe = function(expected: any)
			if actual ~= expected then
				fail(string.format("expected %s, got %s", describeValue(expected), describeValue(actual)))
			end
		end,
		toEqual = function(expected: any)
			if not deepEqual(actual, expected) then
				fail("tables differ")
			end
		end,
		toBeNear = function(expected: number, tolerance: number?)
			local limit = tolerance or 1e-6
			if type(actual) ~= "number" or math.abs(actual - expected) > limit then
				fail(string.format("expected %s within %s, got %s", describeValue(expected), describeValue(limit), describeValue(actual)))
			end
		end,
		toBeAtMost = function(limit: number)
			if type(actual) ~= "number" or actual > limit then
				fail(string.format("expected at most %s, got %s", describeValue(limit), describeValue(actual)))
			end
		end,
		toBeAtLeast = function(limit: number)
			if type(actual) ~= "number" or actual < limit then
				fail(string.format("expected at least %s, got %s", describeValue(limit), describeValue(actual)))
			end
		end,
		toBeTruthy = function()
			if not actual then
				fail("expected a truthy value, got " .. describeValue(actual))
			end
		end,
		toBeFalsy = function()
			if actual then
				fail("expected a falsy value, got " .. describeValue(actual))
			end
		end,
	}
end

local passed, failed = 0, 0
local started = os.clock()
local slowest: { { name: string, seconds: number } } = {}

local names = {}
for _, name in fs.readDir(SPEC_FOLDER) do
	if string.sub(name, -#SPEC_SUFFIX) == SPEC_SUFFIX and (not filter or string.find(name, filter, 1, true)) then
		table.insert(names, name)
	end
end
table.sort(names)

for _, name in names do
	local prefix = string.sub(name, 1, -#SPEC_SUFFIX - 1)
	local stack: { string } = { prefix }
	local api = {
		cluster = function(options: Cluster.Options?)
			return Cluster.new(placePath, options)
		end,
		realCluster = function(options: Cluster.Options?)
			return Cluster.new(realPlacePath, options)
		end,
		breaks = Breaks,
		cloud = Cloud,
		marketplace = Marketplace.new,
		drivers = Drivers,
		watch = Watch.new,
		explain = Replay.explain,
		placeId = Cluster.placeId,
		soakTemplate = Soak.template,
		soakMessage = Soak.message,
		soak = function(driverName: string, seed: number, options: Soak.Options?)
			return Soak.run(placePath, driverName, seed, options)
		end,
		expect = expect,
		clock = os.clock,
		describe = function(label: string, body: () -> ())
			table.insert(stack, label)
			body()
			table.remove(stack)
		end,
		it = function(label: string, body: () -> ())
			local full = table.concat(stack, " > ") .. " > " .. label
			local begin = os.clock()
			local ok, err = pcall(body)
			table.insert(slowest, { name = full, seconds = os.clock() - begin })
			if ok then
				passed += 1
			else
				failed += 1
				print("FAIL " .. full .. ": " .. tostring(err))
			end
		end,
	}
	local source = fs.readFile(SPEC_FOLDER .. "/" .. name)
	local ok, err = pcall(function()
		local spec = luau.load(source, { debugName = name })()
		spec(api)
	end)
	if not ok then
		failed += 1
		print("FAIL " .. prefix .. " (load): " .. tostring(err))
	end
end

table.sort(slowest, function(a, b)
	return a.seconds > b.seconds
end)
for index = 1, math.min(3, #slowest) do
	print(string.format("slow: %.3f s  %s", slowest[index].seconds, slowest[index].name))
end
print(string.format("tests: %d passed, %d failed, %d spec files, %.2f s", passed, failed, #names, os.clock() - started))
process.exit(if failed > 0 then 1 else 0)
