--!strict
export type Mode = "Live" | "Studio" | "Memory" | "ReadOnly"

export type Choice = { kind: string, name: string }
export type Stores = { production: string, studio: string }

local Mode = {}

local STUDIO_SUFFIX = "_Studio"

Mode.nameLength = 50 - #STUDIO_SUFFIX

function Mode.storeName(mode: Mode, name: string): string
	return if mode == "Studio" then name .. STUDIO_SUFFIX else name
end

function Mode.mock(mode: Mode): boolean
	return mode == "Memory"
end

function Mode.writable(mode: Mode): boolean
	return mode ~= "ReadOnly"
end

function Mode.fromChoice(studio: boolean, choice: Choice?, stores: Stores?): Mode
	if not studio then
		return "Live"
	end
	if not choice or choice.kind == "Mock" then
		return "Memory"
	end
	if choice.kind == "ReadOnly" then
		return "ReadOnly"
	end
	return if stores and choice.name == stores.production then "Live" else "Studio"
end

function Mode.current(context: any): Mode
	if not context.mode then
		context.mode = context.resolve()
	end
	return context.mode
end

function Mode.checkName(name: any, limit: number?)
	local most = limit or Mode.nameLength
	if type(name) ~= "string" or #name == 0 then
		error("[Vault] a global data name must be a non empty string", 3)
	end
	if #name > most then
		error(`[Vault] the global data name {name} is longer than {most} characters`, 3)
	end
end

function Mode.checkKey(key: any, limit: number)
	if type(key) ~= "string" or #key == 0 then
		error("[Vault] a global data key must be a non empty string", 3)
	end
	if #key > limit then
		error(`[Vault] the global data key {key} is longer than {limit} characters`, 3)
	end
end

return Mode
