--!strict
local Backend = require(script.Parent.Backend)
local Saver = require(script.Parent.Saver)

local Shutdown = {}

local function close(context: any)
	context.closing = true
	local pending = 0
	for _, closer in table.clone(context.closers) do
		pending += 1
		task.spawn(function()
			local ok, err = pcall(closer)
			if not ok then
				warn(`[Vault] a shutdown task failed: {tostring(err)}`)
			end
			pending -= 1
		end)
	end
	if context.state ~= "Access" then
		while pending > 0 do
			task.wait()
		end
		return
	end
	for _, session in table.clone(context.wheel.list) do
		if session.active() then
			pending += 1
			task.spawn(function()
				Saver.save(context, session, true, "Shutdown")
				pending -= 1
			end)
		end
	end
	while pending > 0 or context.loadJobs > 0 or context.saveJobs > 0 do
		task.wait()
	end
end

function Shutdown.bind(context: any)
	task.spawn(function()
		Backend.ready(context)
		context.env.bindToClose(function()
			close(context)
		end)
	end)
end

return Shutdown
