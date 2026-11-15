--!strict
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

export type Connection = { Disconnect: (self: any) -> () }

export type Env = {
	placeId: number,
	jobId: string,
	studio: boolean,
	clock: () -> number,
	time: () -> number,
	guid: () -> string,
	random: () -> number,
	encode: (value: any) -> string,
	dataStore: (name: string) -> any,
	orderedStore: (name: string) -> any,
	budget: (kind: string) -> number,
	subscribe: (topic: string, callback: (message: any) -> ()) -> Connection,
	publish: (topic: string, message: any) -> (),
	heartbeat: (fn: (dt: number) -> ()) -> Connection,
	bindToClose: (fn: () -> ()) -> (),
}

local Platform = {}

local REQUEST_TYPES = {
	read = { "StandardRead", "GetAsync" },
	write = { "StandardWrite", "UpdateAsync" },
	ordered = { "OrderedWrite", "SetIncrementSortedAsync" },
}

local function requestType(kind: string): any
	for _, name in REQUEST_TYPES[kind] or {} do
		local ok, item = pcall(function(): any
			return (Enum.DataStoreRequestType :: any)[name]
		end)
		if ok and item then
			return item
		end
	end
	return nil
end

function Platform.live(): Env
	return {
		placeId = game.PlaceId,
		jobId = game.JobId,
		studio = RunService:IsStudio(),
		clock = os.clock,
		time = os.time,
		guid = function(): string
			return HttpService:GenerateGUID(false)
		end,
		random = function(): number
			return math.random()
		end,
		encode = function(value: any): string
			return HttpService:JSONEncode(value)
		end,
		dataStore = function(name: string): any
			local options = Instance.new("DataStoreOptions")
			options:SetExperimentalFeatures({ v2 = true })
			return DataStoreService:GetDataStore(name, nil, options)
		end,
		orderedStore = function(name: string): any
			return DataStoreService:GetOrderedDataStore(name)
		end,
		budget = function(kind: string): number
			local item = requestType(kind)
			if not item then
				return math.huge
			end
			local ok, value = pcall(function(): number
				return DataStoreService:GetRequestBudgetForRequestType(item)
			end)
			return if ok then value else math.huge
		end,
		subscribe = function(topic: string, callback: (message: any) -> ()): Connection
			return MessagingService:SubscribeAsync(topic, callback)
		end,
		publish = function(topic: string, message: any)
			MessagingService:PublishAsync(topic, message)
		end,
		heartbeat = function(fn: (dt: number) -> ()): Connection
			return RunService.Heartbeat:Connect(fn)
		end,
		bindToClose = function(fn: () -> ())
			game:BindToClose(fn)
		end,
	}
end

return Platform
