--!strict
-- Loads Roblox-style ModuleScripts from a Rojo-layout folder under Lune.
-- `script`, `script.Parent`, `script.Child` and `require(node)` behave like
-- in Roblox, so plugin/runtime modules run unchanged in tests.
-- (Lune's fs calls yield, so the tree is scanned eagerly, never from a metamethod.)

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Loader = {}

export type Node = any

local cache: { [string]: any } = {}

local function stripSuffix(entry: string): (string, boolean)
	for _, suffix in { ".server.luau", ".client.luau", ".luau" } do
		if string.sub(entry, -#suffix) == suffix then
			return string.sub(entry, 1, -#suffix - 1), true
		end
	end
	return entry, false
end

local function newNode(name: string, parent: Node?, file: string?): Node
	local children: { [string]: Node } = {}
	local attributes: { [string]: any } = {}
	local node = { __children = children, __file = file, __name = name, __parent = parent, __attributes = attributes }
	return setmetatable(node, {
		__index = function(_, key: string)
			if key == "Name" then
				return name
			elseif key == "Parent" then
				return parent
			elseif key == "WaitForChild" or key == "FindFirstChild" then
				return function(_, childName: string)
					return children[childName]
				end
			elseif key == "GetChildren" then
				return function()
					local list = {}
					for _, child in children do
						table.insert(list, child)
					end
					table.sort(list, function(a, b)
						return a.__name < b.__name
					end)
					return list
				end
			elseif key == "GetDescendants" then
				return function(self)
					local list = {}
					local function walk(current)
						for _, child in current:GetChildren() do
							table.insert(list, child)
							walk(child)
						end
					end
					walk(self)
					return list
				end
			elseif key == "GetAttribute" then
				return function(_, attribute: string)
					return attributes[attribute]
				end
			elseif key == "SetAttribute" then
				return function(_, attribute: string, value: any)
					attributes[attribute] = value
				end
			elseif key == "GetFullName" then
				return function()
					local parts = { name }
					local node = parent
					while node do
						table.insert(parts, 1, node.__name)
						node = node.__parent
					end
					return table.concat(parts, ".")
				end
			elseif key == "IsA" then
				return function(_, className: string)
					return className == "ModuleScript" and file ~= nil or className == "Folder" and file == nil
				end
			end
			return children[key]
		end,
		__tostring = function()
			return "Node(" .. name .. ")"
		end,
	})
end

local function scan(dir: string, node: Node)
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			local init: string? = nil
			for _, candidate in { "init.luau", "init.server.luau", "init.client.luau" } do
				if fs.isFile(path .. "/" .. candidate) then
					init = path .. "/" .. candidate
				end
			end
			local child = newNode(entry, node, init)
			node.__children[entry] = child
			scan(path, child)
		else
			local base, isSource = stripSuffix(entry)
			if isSource and base ~= "init" then
				node.__children[base] = newNode(base, node, path)
			end
		end
	end
end

function Loader.root(path: string): Node
	local name = string.match(path, "([^/]+)$") :: string
	local init: string? = nil
	for _, candidate in { "init.luau", "init.server.luau", "init.client.luau" } do
		if fs.isFile(path .. "/" .. candidate) then
			init = path .. "/" .. candidate
		end
	end
	local node = newNode(name, nil, init)
	scan(path, node)
	return node
end

local sources: { [string]: string } = {}

local function readSource(file: string): string
	local source = sources[file]
	if not source then
		source = fs.readFile(file)
		sources[file] = source
	end
	return source
end

-- Pre-reads every source under a node so `require` never touches fs later.
function Loader.preload(node: Node)
	if node.__file then
		readSource(node.__file)
	end
	for _, child in node.__children do
		Loader.preload(child)
	end
end

function Loader.require(node: Node, globals: { [string]: any }?): any
	local file = assert(node.__file, "node has no source: " .. tostring(node))
	if globals == nil and cache[file] ~= nil then
		return cache[file]
	end

	local env = {}
	for key, value in globals or {} do
		env[key] = value
	end
	env.script = node
	env.require = function(target: any)
		if type(target) == "table" and target.__children then
			return Loader.require(target, globals)
		end
		return require(target)
	end

	local chunk = luau.load(readSource(file), { debugName = file, environment = env })
	local result = chunk()
	if globals == nil then
		cache[file] = result
	end
	return result
end

function Loader.loadSource(source: string, debugName: string, env: { [string]: any }): any
	local chunk = luau.load(source, { debugName = debugName, environment = env })
	return chunk()
end

return Loader
