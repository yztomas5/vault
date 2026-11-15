local Cloud = {}

type Record = { value: any, version: number, userIds: { number }?, metadata: any, created: number, updated: number }

export type Faults = {
	errorRate: number,
	lostResponseRate: number,
	retryRate: number,
	outageUntil: number,
	failNext: number,
	loseNext: number,
	errorText: string?,
	latency: { number },
	messageLoss: number,
	messageDown: boolean,
	messageLatency: { number },
	budget: number,
	readDelay: number,
}

local EPOCH = 1762560000
local DATA_ERROR = "502: API Services rejected request with error. HTTP 500 (Internal Server Error)"
local MESSAGE_ERROR = "MessagingService: request failed"

local function isArray(value: { [any]: any }): boolean
	local count = 0
	for _ in value do
		count += 1
	end
	if count == 0 then
		return true
	end
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true
end

function Cloud.copy(value: any, where: string?): any
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "string" or kind == "buffer" then
		return value
	end
	if kind == "number" then
		assert(value == value and math.abs(value) ~= math.huge, `cannot store a non finite number at {where or "root"}`)
		return value
	end
	assert(kind == "table", `cannot store a {kind} at {where or "root"}`)
	local out = {}
	if isArray(value) then
		for index, item in value do
			out[index] = Cloud.copy(item, `{where or "root"}[{index}]`)
		end
		return out
	end
	for key, item in value do
		assert(type(key) == "string", `cannot store a table with mixed or non string keys at {where or "root"}`)
		out[key] = Cloud.copy(item, `{where or "root"}.{key}`)
	end
	return out
end

function Cloud.same(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if not Cloud.same(value, b[key]) then
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

function Cloud.new(scheduler: any)
	local cloud = {}
	local stores: { [string]: { [string]: Record } } = {}
	local orderedStores: { [string]: { [string]: number } } = {}
	local observers: { (store: string, key: string, before: any, after: any, owner: any) -> () } = {}
	local subscriptions: { { owner: any, topic: string, callback: (any) -> (), connected: boolean } } = {}

	local faults: Faults = {
		errorRate = 0,
		lostResponseRate = 0,
		retryRate = 0,
		outageUntil = 0,
		failNext = 0,
		loseNext = 0,
		latency = { 0.05, 0.2 },
		messageLoss = 0,
		messageDown = false,
		messageLatency = { 0.05, 0.3 },
		budget = 1000,
		readDelay = 0,
	}

	cloud.faults = faults
	cloud.calls = { read = 0, write = 0, publish = 0, ordered = 0, sorted = 0 }

	local function keysOf(name: string): { [string]: Record }
		local keys = stores[name]
		if not keys then
			keys = {}
			stores[name] = keys
		end
		return keys
	end

	local function fails(): boolean
		if faults.failNext > 0 then
			faults.failNext -= 1
			return true
		end
		return scheduler.now() < faults.outageUntil or scheduler.random() < faults.errorRate
	end

	local function travel()
		scheduler.sleep(scheduler.between(faults.latency[1], faults.latency[2]) / 2)
	end

	local function request()
		travel()
		if fails() then
			error(faults.errorText or DATA_ERROR, 0)
		end
	end

	local function keyInfo(record: Record?): any
		if not record then
			return nil
		end
		local userIds = table.clone(record.userIds or {})
		local metadata = Cloud.copy(record.metadata or {})
		return {
			Version = tostring(record.version),
			CreatedTime = (EPOCH + record.created) * 1000,
			UpdatedTime = (EPOCH + record.updated) * 1000,
			GetUserIds = function(): { number }
				return userIds
			end,
			GetMetadata = function(): any
				return metadata
			end,
		}
	end

	local function commit(name: string, key: string, value: any, userIds: { number }?, metadata: any): Record
		local keys = keysOf(name)
		local before = keys[key]
		local record: Record = {
			value = Cloud.copy(value),
			version = (if before then before.version else 0) + 1,
			userIds = if userIds then table.clone(userIds) else nil,
			metadata = Cloud.copy(metadata),
			created = if before then before.created else scheduler.now(),
			updated = scheduler.now(),
		}
		keys[key] = record
		local owner = scheduler.current()
		for _, observer in observers do
			observer(name, key, if before then Cloud.copy(before.value) else nil, Cloud.copy(record.value), owner)
		end
		return record
	end

	local function transformOnce(transform: (any, any) -> ...any, record: Record?): (any, any, any)
		local thread = coroutine.create(transform)
		local ok, value, userIds, metadata = coroutine.resume(thread, if record then Cloud.copy(record.value) else nil, keyInfo(record))
		if not ok then
			error(value, 0)
		end
		assert(coroutine.status(thread) == "dead", "UpdateAsync transform functions cannot yield")
		return value, userIds, metadata
	end

	local function dataStore(name: string): any
		local store = {}
		local keys = keysOf(name)

		function store.GetAsync(_: any, key: string): (any, any)
			cloud.calls.read += 1
			request()
			local record = keys[key]
			local seen = if record then Cloud.copy(record.value) else nil
			local info = keyInfo(record)
			if faults.readDelay > 0 then
				scheduler.sleep(faults.readDelay)
			end
			travel()
			return seen, info
		end

		function store.SetAsync(_: any, key: string, value: any, userIds: { number }?): string
			cloud.calls.write += 1
			request()
			local record = commit(name, key, value, userIds, nil)
			travel()
			return tostring(record.version)
		end

		function store.UpdateAsync(_: any, key: string, transform: (any, any) -> ...any): (any, any)
			cloud.calls.read += 1
			cloud.calls.write += 1
			request()
			while true do
				local seen = keys[key]
				local value, userIds, metadata = transformOnce(transform, seen)
				if scheduler.random() < faults.retryRate then
					value, userIds, metadata = transformOnce(transform, seen)
				end
				if value == nil then
					travel()
					return nil, nil
				end
				travel()
				if keys[key] == seen then
					if fails() then
						error(DATA_ERROR, 0)
					end
					local record = commit(name, key, value, userIds, metadata)
					if faults.loseNext > 0 then
						faults.loseNext -= 1
						error(DATA_ERROR, 0)
					end
					if scheduler.random() < faults.lostResponseRate then
						error(DATA_ERROR, 0)
					end
					return Cloud.copy(record.value), keyInfo(record)
				end
			end
		end

		function store.RemoveAsync(_: any, key: string): (any, any)
			cloud.calls.write += 1
			request()
			local record = keys[key]
			if record then
				keys[key] = nil
				local owner = scheduler.current()
				for _, observer in observers do
					observer(name, key, Cloud.copy(record.value), nil, owner)
				end
			end
			travel()
			return if record then Cloud.copy(record.value) else nil, keyInfo(record)
		end

		function store.GetVersionAsync()
			error("GetVersionAsync is not simulated", 0)
		end

		function store.ListVersionsAsync()
			error("ListVersionsAsync is not simulated", 0)
		end

		return store
	end

	local function orderedStore(name: string): any
		local store = {}
		local entries = orderedStores[name]
		if not entries then
			entries = {}
			orderedStores[name] = entries
		end

		function store.SetAsync(_: any, key: string, value: any)
			cloud.calls.ordered += 1
			request()
			assert(type(value) == "number" and value % 1 == 0, "OrderedDataStore values must be integers")
			entries[key] = value
			travel()
		end

		function store.RemoveAsync(_: any, key: string)
			cloud.calls.ordered += 1
			request()
			entries[key] = nil
			travel()
		end

		function store.GetSortedAsync(_: any, ascending: boolean, pageSize: number): any
			cloud.calls.sorted += 1
			request()
			assert(pageSize >= 1 and pageSize <= 100, "PageSize must be within a predefined range")
			local rows = {}
			for key, value in entries do
				table.insert(rows, { key = key, value = value })
			end
			table.sort(rows, function(a: any, b: any): boolean
				if a.value ~= b.value then
					return if ascending then a.value < b.value else a.value > b.value
				end
				return a.key < b.key
			end)
			local page = {}
			for index = 1, math.min(pageSize, #rows) do
				page[index] = rows[index]
			end
			travel()
			return {
				IsFinished = true,
				GetCurrentPage = function(): { any }
					return page
				end,
			}
		end

		return store
	end

	function cloud.dataStoreService(): any
		local opened: { [string]: any } = {}
		local sorted: { [string]: any } = {}
		return {
			GetDataStore = function(_: any, name: string): any
				if not opened[name] then
					opened[name] = dataStore(name)
				end
				return opened[name]
			end,
			GetOrderedDataStore = function(_: any, name: string): any
				if not sorted[name] then
					sorted[name] = orderedStore(name)
				end
				return sorted[name]
			end,
			GetRequestBudgetForRequestType = function(): number
				return faults.budget
			end,
		}
	end

	function cloud.readOrdered(name: string): { [string]: number }
		return table.clone(orderedStores[name] or {})
	end

	function cloud.messagingService(owner: any): any
		return {
			SubscribeAsync = function(_: any, topic: string, callback: (any) -> ()): any
				scheduler.sleep(scheduler.between(faults.messageLatency[1], faults.messageLatency[2]))
				if faults.messageDown then
					error(MESSAGE_ERROR, 0)
				end
				local subscription = { owner = owner, topic = topic, callback = callback, connected = true }
				table.insert(subscriptions, subscription)
				return {
					Disconnect = function()
						subscription.connected = false
						local index = table.find(subscriptions, subscription)
						if index then
							table.remove(subscriptions, index)
						end
					end,
				}
			end,
			PublishAsync = function(_: any, topic: string, message: any)
				cloud.calls.publish += 1
				scheduler.sleep(scheduler.between(faults.messageLatency[1], faults.messageLatency[2]))
				if faults.messageDown then
					error(MESSAGE_ERROR, 0)
				end
				for _, subscription in table.clone(subscriptions) do
					if subscription.topic == topic and scheduler.random() >= faults.messageLoss then
						local delay = scheduler.between(faults.messageLatency[1], faults.messageLatency[2])
						scheduler.delay(subscription.owner, delay, function()
							if subscription.connected then
								subscription.callback({ Data = Cloud.copy(message), Sent = EPOCH + scheduler.now() })
							end
						end)
					end
				end
			end,
		}
	end

	function cloud.forget(owner: any)
		for index = #subscriptions, 1, -1 do
			if subscriptions[index].owner == owner then
				subscriptions[index].connected = false
				table.remove(subscriptions, index)
			end
		end
	end

	function cloud.onCommit(observer: (store: string, key: string, before: any, after: any, owner: any) -> ())
		table.insert(observers, observer)
	end

	function cloud.read(name: string, key: string): any
		local record = keysOf(name)[key]
		return if record then Cloud.copy(record.value) else nil
	end

	function cloud.write(name: string, key: string, value: any)
		commit(name, key, value, nil, nil)
	end

	function cloud.outage(seconds: number)
		faults.outageUntil = scheduler.now() + seconds
	end

	cloud.epoch = EPOCH

	return cloud
end

return Cloud
