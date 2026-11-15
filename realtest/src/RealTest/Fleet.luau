local Fleet = {}

local FAST = {
	FirstLoadRepeatSeconds = 3,
	LoadRepeatSeconds = 3,
	StealSeconds = 6,
	DeadSeconds = 20,
}

Fleet.settings = FAST

function Fleet.new(Engine: any, storeName: string, template: { [string]: any })
	local live = Engine.Platform.live()
	local fleet = {}
	local count = 0

	function fleet.server(label: string, realTimings: boolean?)
		count += 1
		local alive = true
		local platform = table.clone(live)
		platform.jobId = `vault-realtest-{label}-{count}-{live.guid()}`

		local function hang()
			coroutine.yield()
		end

		platform.heartbeat = function(fn: (dt: number) -> ())
			return live.heartbeat(function(dt: number)
				if alive then
					fn(dt)
				end
			end)
		end

		platform.subscribe = function(topic: string, callback: (message: any) -> ())
			return live.subscribe(topic, function(message: any)
				if alive then
					callback(message)
				end
			end)
		end

		platform.publish = function(topic: string, message: any)
			if alive then
				live.publish(topic, message)
			end
		end

		platform.bindToClose = function(fn: () -> ())
			live.bindToClose(function()
				if alive then
					fn()
				end
			end)
		end

		platform.dataStore = function(name: string)
			local real = live.dataStore(name)
			local proxy = {}
			function proxy.GetAsync(_: any, key: string)
				if not alive then
					hang()
				end
				return real:GetAsync(key)
			end
			function proxy.SetAsync(_: any, key: string, value: any)
				if not alive then
					hang()
				end
				return real:SetAsync(key, value)
			end
			function proxy.RemoveAsync(_: any, key: string)
				if not alive then
					hang()
				end
				return real:RemoveAsync(key)
			end
			function proxy.UpdateAsync(_: any, key: string, transform: (any, any) -> ...any)
				if not alive then
					hang()
				end
				return real:UpdateAsync(key, function(...: any): ...any
					if not alive then
						return nil
					end
					return transform(...)
				end)
			end
			return proxy
		end

		local engine = Engine.new(platform, if realTimings then nil else FAST)
		return {
			label = label,
			jobId = platform.jobId,
			engine = engine,
			store = engine.open(storeName, template),
			kill = function()
				alive = false
			end,
		}
	end

	return fleet
end

return Fleet
