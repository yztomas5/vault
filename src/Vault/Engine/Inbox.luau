--!strict
local Backend = require(script.Parent.Backend)
local Record = require(script.Parent.Record)

export type Handler = (message: any, processed: () -> ()) -> ()

export type Inbox = {
	locked: { [number]: true },
	received: { [number]: true },
	handlers: { Handler },
	messages: { Record.Message },
}

local Inbox = {}

function Inbox.new(record: Record.Stored): Inbox
	local inbox: Inbox = { locked = {}, received = {}, handlers = {}, messages = Record.messages(record) }
	for _, message in inbox.messages do
		inbox.received[message.id] = true
	end
	return inbox
end

function Inbox.handle(inbox: Inbox, handler: Handler)
	table.insert(inbox.handlers, handler)
	for _, message in inbox.messages do
		if not inbox.locked[message.id] then
			task.spawn(handler, Record.copy(message.data), function()
				inbox.locked[message.id] = true
			end)
		end
	end
end

function Inbox.absorb(inbox: Inbox, record: Record.Stored): { Record.Message }
	local fresh = {}
	local pending: { [number]: true } = {}
	inbox.messages = Record.messages(record)
	for _, message in inbox.messages do
		if inbox.locked[message.id] then
			pending[message.id] = true
		elseif not inbox.received[message.id] then
			inbox.received[message.id] = true
			table.insert(fresh, message)
		end
	end
	for id in inbox.locked do
		if not pending[id] then
			inbox.locked[id] = nil
		end
	end
	return fresh
end

function Inbox.deliver(inbox: Inbox, fresh: { Record.Message })
	for _, message in fresh do
		for _, handler in inbox.handlers do
			local processed = false
			task.spawn(handler, Record.copy(message.data), function()
				processed = true
				inbox.locked[message.id] = true
			end)
			if processed then
				break
			end
		end
	end
end

function Inbox.send(context: any, store: any, key: string, mock: boolean, message: any): boolean
	Backend.checkKey(context, key)
	if type(message) ~= "table" then
		error("[Vault] a message must be a table", 2)
	end
	if context.closing then
		return false
	end
	Backend.ready(context)
	local env = context.env
	local backoff = 1
	while not context.closing do
		local record = Backend.write(context, store, key, mock, function(opened: Record.Stored): boolean
			Record.addMessage(opened, message, context.settings.MessageQueue)
			return true
		end)
		if record then
			local session = context.sessions[Backend.token(context, store, key, mock)]
			if session then
				session.save()
			else
				local sessionId = Record.sessionId(record)
				if sessionId then
					task.spawn(function()
						pcall(env.publish, `PS_{sessionId}`, { LoadCount = Record.loadCount(record) })
					end)
				end
			end
			return true
		end
		task.wait(backoff)
		backoff = math.min(20, backoff * 2)
	end
	return false
end

return Inbox
