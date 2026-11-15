--!strict
local Signal = require(script.Parent.Signal)

export type Health = {
	issues: { number },
	critical: boolean,
	criticalStart: number,
	onError: Signal.Signal<string, string, string>,
	onOverwrite: Signal.Signal<string, string>,
	onCritical: Signal.Signal<boolean>,
	onSize: Signal.Signal<string, string, number, number>,
}

local Health = {}

local ERROR_COUNT = 5
local ERROR_EXPIRE_SECONDS = 120
local CRITICAL_EXPIRE_SECONDS = 120

function Health.new(): Health
	return {
		issues = {},
		critical = false,
		criticalStart = 0,
		onError = Signal.new(),
		onOverwrite = Signal.new(),
		onCritical = Signal.new(),
		onSize = Signal.new(),
	}
end

function Health.failed(context: any, message: any, storeName: string, key: string)
	warn(`[Vault] data store error (store {storeName}, key {key}): {tostring(message)}`)
	table.insert(context.health.issues, context.env.clock())
	context.health.onError.fire(tostring(message), storeName, key)
end

function Health.overwritten(context: any, storeName: string, key: string)
	warn(`[Vault] an invalid profile was overwritten (store {storeName}, key {key})`)
	context.health.onOverwrite.fire(storeName, key)
end

function Health.measured(context: any, session: any)
	local ok, encoded = pcall(context.env.encode, session.data)
	if not ok then
		warn(`[Vault] the data cannot be encoded (store {session.storeName}, key {session.key}): {tostring(encoded)}`)
		return
	end
	local limit = context.settings.KeyBytes
	local bytes = #encoded
	local level = 0
	for index, share in context.settings.SizeWarnings do
		if bytes >= limit * share then
			level = index
		end
	end
	session.bytes = bytes
	if level > session.internal.sizeLevel then
		warn(`[Vault] the data uses {math.floor(bytes / limit * 100)} % of the key limit (store {session.storeName}, key {session.key})`)
		context.health.onSize.fire(session.storeName, session.key, bytes, limit)
	end
	session.internal.sizeLevel = level
end

function Health.step(context: any)
	local health: Health = context.health
	local now = context.env.clock()
	if #health.issues >= ERROR_COUNT then
		health.criticalStart = now
		if not health.critical then
			health.critical = true
			health.onCritical.fire(true)
			warn("[Vault] entered critical state")
		end
	elseif health.critical and now - health.criticalStart > CRITICAL_EXPIRE_SECONDS then
		health.critical = false
		health.onCritical.fire(false)
		warn("[Vault] critical state ended")
	end
	while health.issues[1] and now - health.issues[1] > ERROR_EXPIRE_SECONDS do
		table.remove(health.issues, 1)
	end
end

return Health
