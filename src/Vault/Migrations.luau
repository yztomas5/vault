--!strict
local Replica = require(script.Parent.Replica)
local Types = require(script.Parent.Types)

local Migrations = {}

function Migrations.versionOf(data: any, versionPath: Types.Path): number
	local version = Replica.read(data, versionPath)
	return if type(version) == "number" then version else 0
end

function Migrations.run(
	data: { [any]: any },
	list: { Types.Migration },
	versionPath: Types.Path,
	base: number?
): (number, number)
	local start = base or 0
	local from = Migrations.versionOf(data, versionPath)
	local target = start + #list
	if from >= target then
		return from, from
	end
	for version = math.max(from, start) + 1, target do
		list[version - start](data)
		Replica.write(data, versionPath, "set", version)
	end
	return from, target
end

return Migrations
