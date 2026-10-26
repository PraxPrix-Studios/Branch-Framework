--!strict
--!native
--!optimize 2

--[=[
	@name Scythe

	@desc Cleanup scopes without objects. A scope is a plain number; everything
	added to it is disposed newest first when the scope is cleaned.

		local scope = Scythe.scope()
		Scythe.add(scope, workspace.Part)                -- :Destroy()
		Scythe.add(scope, humanoid.Died:Connect(onDied)) -- :Disconnect()
		Scythe.add(scope, task.spawn(loop))              -- task.cancel()
		Scythe.add(scope, function() print("bye") end)   -- called
		Scythe.add(scope, Scythe.scope())                -- a sub-scope, destroyed with it

		Scythe.clean(scope)   -- dispose everything, the scope stays usable
		Scythe.destroy(scope) -- dispose everything, give the handle back

	@notes
		* `add` only stores the value; how to dispose it is worked out when the
		  scope is cleaned. A value with no way to be cleaned is reported then.
		* A destroyed handle is recycled for the next scope: drop it after `destroy`.
		* Every item is disposed even if some disposers error; the first error is
		  raised once the scope is empty. Disposers must not yield.

	@version 2.0
	@author checcerr, fridayqx (1.0); venexs, mycxm (1.3); mycxm (2.0)
	@license MPL-2.0
]=]

export type Scope = number

type Cleanup = (any) -> ()

const itemsOf = table.create(64) :: { { any } }
const lens = table.create(64) :: { number }
const bases = table.create(64) :: { number }
const flags = table.create(64) :: { number } -- 0 free, 1 live, 2 cleaning, 3 destroy after cleaning
const free = table.create(64) :: { number }
local scopeCount = 16
local freeLen = 16

for i = 1, 16 do
	itemsOf[i] = { nil, nil, nil, nil, nil, nil, nil, nil }
	lens[i] = 0
	bases[i] = 1
	flags[i] = 0
	free[17 - i] = i
end

const methodCache: { [any]: Cleanup } = setmetatable({}, { __mode = "k" }) :: any

local destroyScope: (id: number) -> ()

local function findClassMethod(meta: any): Cleanup?
	local holder = rawget(meta, "__index")
	for _ = 1, 16 do
		if type(holder) ~= "table" then
			return nil
		end
		const method = rawget(holder, "Destroy") or rawget(holder, "Disconnect")
		if method ~= nil then
			return if type(method) == "function" then method else nil
		end
		const above = getmetatable(holder)
		if type(above) ~= "table" then
			return nil
		end
		holder = rawget(above, "__index")
	end
	return nil
end

local function disposeTable(object: any, meta: any)
	const method: any = object.Destroy or object.Disconnect
	if type(method) == "function" then
		if type(meta) == "table" then
			const classMethod = findClassMethod(meta)
			if classMethod then
				methodCache[meta] = classMethod
			end
		end
		method(object)
	else
		warn(`Scythe: {object} has no Destroy or Disconnect method and cannot be cleaned`)
	end
end

local function cancelLater(target: thread)
	if coroutine.status(target) == "suspended" then
		task.cancel(target)
	end
end

-- Items are taken out before they are disposed, so after an error the drain can
-- simply run again and carries on with what is left.
local function drain(id: number)
	const items = itemsOf[id]
	local bottom = bases[id] - 1
	local top = lens[id]
	local peak = top

	while top > bottom do
		for i = top, bottom + 1, -1 do
			const value = items[i]
			items[i] = nil

			const kind = typeof(value)
			if kind == "RBXScriptConnection" then
				value:Disconnect()
			elseif kind == "Instance" then
				value:Destroy()
			elseif kind == "function" then
				value()
			elseif kind == "table" then
				const meta = getmetatable(value)
				const method = methodCache[meta]
				if method then
					method(value)
				else
					disposeTable(value, meta)
				end
			elseif kind == "thread" then
				const status = coroutine.status(value)
				if status == "suspended" then
					task.cancel(value)
				elseif status ~= "dead" then
					task.defer(cancelLater, value)
				end
			elseif kind == "number" then
				destroyScope(value)
			elseif kind == "userdata" then
				const target = value :: any
				const method = target.Destroy or target.Disconnect
				if type(method) == "function" then
					method(target)
				end
			elseif kind ~= "nil" then
				warn(`Scythe: cannot clean a {kind}`)
			end
		end

		bottom = top
		top = lens[id]
		if top > peak then
			peak = top
		end
	end

	lens[id] = 0
	bases[id] = 1

	if peak > 4096 then
		itemsOf[id] = { nil, nil, nil, nil, nil, nil, nil, nil }
	end
end

-- One protected call per clean, not per item: a disposer that errors cannot
-- strand the rest or leave the scope stuck mid-clean. Returns the first error.
local function drainAll(id: number): any
	local ok, problem = pcall(drain, id)
	if ok then
		return nil
	end
	repeat
		ok = pcall(drain, id)
	until ok
	return problem
end

local function newScope(): Scope
	local id: number

	if freeLen > 0 then
		id = free[freeLen]
		freeLen -= 1
	else
		scopeCount += 1
		id = scopeCount
		itemsOf[id] = { nil, nil, nil, nil, nil, nil, nil, nil }
		bases[id] = 1
	end

	lens[id] = 0
	flags[id] = 1

	return id
end

local function add<T>(scope: Scope, value: T): T
	const len = lens[scope] + 1
	itemsOf[scope][len] = value
	lens[scope] = len
	return value
end

local function addBulk(scope: Scope, ...: unknown)
	const n = select("#", ...)
	if n == 0 then
		return
	end

	const items = itemsOf[scope]
	local len = lens[scope]

	for i = 1, n do
		len += 1
		items[len] = (select(i, ...))
	end

	lens[scope] = len
end

local function remove(scope: Scope, value: unknown): boolean
	const len = lens[scope]
	if len == 0 or value == nil then
		return false
	end

	const items = itemsOf[scope]
	local base = bases[scope]

	if flags[scope] ~= 1 then
		for i = len, base, -1 do
			if items[i] == value then
				items[i] = nil
				return true
			end
		end
		return false
	end

	if items[len] == value then
		items[len] = nil
		if len == base then
			lens[scope] = 0
			bases[scope] = 1
		else
			lens[scope] = len - 1
		end
		return true
	end

	if items[base] == value then
		items[base] = nil
		base += 1

		if base > 64 and base * 2 > len then
			const live = len - base + 1
			table.move(items, base, len, 1)
			for i = live + 1, len do
				items[i] = nil
			end
			lens[scope] = live
			bases[scope] = 1
		else
			bases[scope] = base
		end
		return true
	end

	for i = len - 1, base + 1, -1 do
		if items[i] == value then
			items[i] = items[len]
			items[len] = nil
			lens[scope] = len - 1
			return true
		end
	end

	return false
end

local function release(scope: number)
	flags[scope] = 0
	freeLen += 1
	free[freeLen] = scope
end

local function clean(scope: Scope)
	if lens[scope] == 0 or flags[scope] ~= 1 then
		return
	end

	flags[scope] = 2
	local problem = drainAll(scope)

	if flags[scope] == 3 then
		release(scope)
	else
		flags[scope] = 1
	end

	if problem ~= nil then
		error(problem, 0)
	end
end

function destroyScope(scope: number)
	const state = flags[scope]
	if state ~= 1 then
		if state == 2 then
			flags[scope] = 3
		end
		return
	end

	local problem = nil
	if lens[scope] ~= 0 then
		flags[scope] = 2
		problem = drainAll(scope)
	end

	release(scope)

	if problem ~= nil then
		error(problem, 0)
	end
end

local function count(scope: Scope): number
	const len = lens[scope]
	if len == 0 then
		return 0
	end
	return len - bases[scope] + 1
end

local function isAlive(scope: Scope): boolean
	return type(scope) == "number" and flags[scope] ~= nil and flags[scope] ~= 0
end

return table.freeze({
	scope = newScope,
	add = add,
	addBulk = addBulk,
	remove = remove,
	clean = clean,
	destroy = destroyScope,
	count = count,
	isAlive = isAlive,
})
