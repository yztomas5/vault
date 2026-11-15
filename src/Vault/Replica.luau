--!strict
local Types = require(script.Parent.Types)

type Key = Types.Key
type Path = Types.Path
type Listener = Types.Listener

type Node = {
	path: Path,
	listeners: { [{}]: Listener },
	children: { [Key]: Node },
	parent: Node?,
	key: Key?,
}

export type Replica = {
	data: { [any]: any },
	root: Node,
	get: (self: Replica, path: Path) -> any,
	apply: (self: Replica, changes: { Types.Change }) -> any,
	replace: (self: Replica, data: { [any]: any }) -> (),
	observe: (self: Replica, path: Path, listener: Listener) -> Types.Disconnect,
}

local Replica = {}
Replica.__index = Replica

local function newNode(path: Path, parent: Node?, key: Key?): Node
	return { path = path, listeners = {}, children = {}, parent = parent, key = key }
end

function Replica.path(path: Types.PathLike): Path
	if type(path) == "string" then
		return if path == "" then {} else string.split(path, ".")
	end
	return path
end

function Replica.describe(path: Path): string
	local parts = table.create(#path)
	for index, key in path do
		parts[index] = tostring(key)
	end
	return if #parts == 0 then "<root>" else table.concat(parts, ".")
end

function Replica.prefix(prefix: Path, path: Path): boolean
	if #prefix > #path then
		return false
	end
	for index, key in prefix do
		if path[index] ~= key then
			return false
		end
	end
	return true
end

function Replica.allowed(template: { [any]: any }, path: Path): boolean
	local node: any = template
	for _, key in path do
		if type(node) ~= "table" then
			return false
		end
		if next(node) == nil then
			return true
		end
		node = node[key]
		if node == nil then
			return false
		end
	end
	return true
end

function Replica.hidden(private: { Path }, path: Path): boolean
	for _, hidden in private do
		if Replica.prefix(hidden, path) then
			return true
		end
	end
	return false
end

function Replica.strip(private: { Path }, path: Path, value: any): any
	if type(value) ~= "table" then
		return value
	end
	for _, hidden in private do
		if #hidden > #path and Replica.prefix(path, hidden) then
			local rest = table.move(hidden, #path + 1, #hidden, 1, {})
			local parent = Replica.read(value, table.move(rest, 1, #rest - 1, 1, {}))
			if type(parent) == "table" then
				parent[rest[#rest]] = nil
			end
		end
	end
	return value
end

function Replica.copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = Replica.copy(child)
	end
	return result
end

function Replica.read(data: any, path: Path): any
	local value = data
	for _, key in path do
		if type(value) ~= "table" then
			return nil
		end
		value = value[key]
	end
	return value
end

local function containerOf(data: { [any]: any }, path: Path, create: boolean): ({ [any]: any }?, Key?)
	local parent = data
	for index = 1, #path - 1 do
		local key = path[index]
		local child = parent[key]
		if type(child) ~= "table" then
			if not create then
				return nil, nil
			end
			child = {}
			parent[key] = child
		end
		parent = child
	end
	return parent, path[#path]
end

function Replica.write(data: { [any]: any }, path: Path, op: Types.Op, value: any, index: number?): any
	assert(#path > 0, "[Vault] the root cannot be written")
	local parent, key = containerOf(data, path, op ~= "remove")
	if not parent or key == nil then
		return nil
	end
	if op == "set" then
		parent[key] = value
		return nil
	end
	local list = parent[key]
	if type(list) ~= "table" then
		if op == "remove" then
			return nil
		end
		list = {}
		parent[key] = list
	end
	if op == "insert" then
		if index then
			table.insert(list, math.clamp(index, 1, #list + 1), value)
		else
			table.insert(list, value)
		end
		return nil
	end
	local at = index or #list
	if at < 1 or at > #list then
		return nil
	end
	return table.remove(list, at)
end

local function collect(root: Node, path: Path, into: { Node }, seen: { [Node]: true })
	local function add(node: Node)
		if not seen[node] then
			seen[node] = true
			table.insert(into, node)
		end
	end
	local node = root
	for _, key in path do
		add(node)
		local child = node.children[key]
		if not child then
			return
		end
		node = child
	end
	local stack = { node }
	while #stack > 0 do
		local current = table.remove(stack) :: Node
		add(current)
		for _, child in current.children do
			table.insert(stack, child)
		end
	end
end

local function notify(self: Replica, nodes: { Node })
	for _, node in nodes do
		if next(node.listeners) ~= nil then
			local value = Replica.read(self.data, node.path)
			for _, listener in table.clone(node.listeners) do
				task.spawn(listener, value)
			end
		end
	end
end

local function prune(node: Node)
	local current: Node? = node
	while current and current.parent and next(current.listeners) == nil and next(current.children) == nil do
		local parent = current.parent :: Node
		parent.children[current.key :: Key] = nil
		current = parent
	end
end

function Replica.new(data: { [any]: any }?): Replica
	local self = setmetatable({
		data = data or {},
		root = newNode({}),
	}, Replica)
	return (self :: any) :: Replica
end

function Replica.get(self: Replica, path: Path): any
	return Replica.read(self.data, path)
end

function Replica.apply(self: Replica, changes: { Types.Change }): any
	local nodes: { Node } = {}
	local seen: { [Node]: true } = {}
	local result = nil
	for _, change in changes do
		local path = change[1] :: Path
		result = Replica.write(self.data, path, change[2] :: Types.Op, change[3], change[4] :: number?)
		collect(self.root, path, nodes, seen)
	end
	notify(self, nodes)
	return result
end

function Replica.replace(self: Replica, data: { [any]: any })
	self.data = data
	local nodes: { Node } = {}
	collect(self.root, {}, nodes, {})
	notify(self, nodes)
end

function Replica.observe(self: Replica, path: Path, listener: Listener): Types.Disconnect
	local node = self.root
	for index, key in path do
		local child = node.children[key]
		if not child then
			child = newNode(table.move(path, 1, index, 1, {}), node, key)
			node.children[key] = child
		end
		node = child
	end
	local token = {}
	node.listeners[token] = listener
	task.spawn(listener, Replica.read(self.data, path))
	local connected = true
	return function()
		if not connected then
			return
		end
		connected = false
		node.listeners[token] = nil
		prune(node)
	end
end

return Replica
