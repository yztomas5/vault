--!strict
local Storable = {}

local FATAL_TYPES = { ["function"] = true, thread = true, userdata = true, vector = true }

local function describe(path: { string }): string
	return if #path == 0 then "the value" else table.concat(path, ".")
end

local function validText(text: string): boolean
	return utf8.len(text) ~= nil
end

local function walk(value: any, path: { string }, open: { [any]: true }, risks: { string }): string?
	local kind = type(value)
	if FATAL_TYPES[kind] then
		return `{describe(path)} is a {typeof(value)}, which a data store cannot keep`
	end
	if kind == "string" then
		return if validText(value) then nil else `{describe(path)} is not valid UTF-8 text`
	end
	if kind == "number" then
		if value ~= value or math.abs(value) == math.huge then
			table.insert(risks, `{describe(path)} is not a finite number`)
		end
		return nil
	end
	if kind ~= "table" then
		return nil
	end
	if open[value] then
		return `{describe(path)} contains itself`
	end
	open[value] = true
	local texts, numbers, highest = 0, 0, 0
	for key, child in value do
		local keyKind = type(key)
		if keyKind == "string" then
			texts += 1
			if not validText(key) then
				return `{describe(path)} has a key that is not valid UTF-8 text`
			end
		elseif keyKind == "number" then
			numbers += 1
			highest = math.max(highest, key)
			if key % 1 ~= 0 or key < 1 then
				table.insert(risks, `{describe(path)} has the number key {key}, which is not a list position`)
			end
		else
			return `{describe(path)} has a {typeof(key)} key, and keys must be text or numbers`
		end
		table.insert(path, tostring(key))
		local fatal = walk(child, path, open, risks)
		table.remove(path)
		if fatal then
			return fatal
		end
	end
	open[value] = nil
	if texts > 0 and numbers > 0 then
		table.insert(risks, `{describe(path)} mixes text keys and number keys`)
	elseif numbers > 0 and highest ~= numbers then
		table.insert(risks, `{describe(path)} is a list with gaps`)
	end
	return nil
end

function Storable.check(value: any): (string?, { string })
	local risks: { string } = {}
	return walk(value, {}, {}, risks), risks
end

return Storable
