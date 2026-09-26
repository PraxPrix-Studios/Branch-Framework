--!strict
--!optimize 2

--[[
	Branch — segment framework for Roblox.

	A segment is a ModuleScript that returns a table. Branch requires every
	segment under the roots you give it, runs `Init` in dependency order,
	then `Start` for each one in its own thread.

		-- ServerScriptService/Main
		local Branch = require(ReplicatedStorage.Packages.Branch)
		Branch:Start(ServerScriptService.Services)

		-- a segment
		local Shop = { Dependencies = { "PlayerService" } }
		function Shop:Init() end                    -- sequential, may yield
		function Shop:Start() end                   -- spawned, after every Init
		function Shop:PlayerAdded(player) end       -- current + future players
		function Shop:PlayerRemoving(player) end
		function Shop:Heartbeat(dt) end             -- one shared connection per hook
		return Shop

	Discovery (SegmentRule, "Suffix" by default): every ModuleScript under
	the roots whose name ends with Service (server) / Controller (client),
	at any depth and in any casing, is a segment; other modules are helpers.
	The "Folders" rule instead takes modules directly under a root or under
	Folders inside it. Branch Studio sets the rule as the SegmentRule
	attribute on this module; Branch:Start(root, { SegmentRule = ... })
	overrides it.

	Branch.Network / Branch.Data load on first use. Branch Studio keeps the
	block between the BRANCH_GENERATED markers in sync with your project.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Types = require(script.Types)

-- BRANCH_GENERATED_START
-- Managed by Branch Studio; edits between these markers are overwritten.
type NetworkApi = any
-- BRANCH_GENERATED_END

export type Phase = "Idle" | "Loading" | "Initializing" | "Started"

export type SegmentReport = {
	Name: string,
	Path: string,
	Status: "Loaded" | "Initialized" | "Failed" | "Started",
	InitMs: number,
}

export type Branch = {
	Version: string,
	Start: (self: Branch, ...any) -> (), -- roots, then optionally { SegmentRule = "Suffix" | "Folders" }
	GetSegment: Types.GetSegment,
	LocateSegments: (self: Branch, names: { string }) -> { [string]: any },
	GetPhase: (self: Branch) -> Phase,
	AwaitStart: (self: Branch) -> (),
	GetReport: (self: Branch) -> { SegmentReport },
	Network: NetworkApi,
	Data: typeof(require(script.Data)),
}

-- Segment registry (Structure of Arrays; index = load order).
local names: { string } = {}
local modules: { any } = {}
local paths: { string } = {}
local statuses: { string } = {}
local initTimes: { number } = {}
local count = 0
local byName: { [string]: any } = {}

local phase: Phase = "Idle"
local waiting: { thread } = {}

-- Hooks: one engine connection per hook type, walking parallel arrays.
local HOOK_SIGNALS: { [string]: RBXScriptSignal? } = {
	Heartbeat = RunService.Heartbeat,
	PreSimulation = RunService.PreSimulation,
	PreRender = if RunService:IsClient() then RunService.PreRender else nil,
}

local branch = {
	Version = "2.0.0",
}

local function fail(message: string)
	-- Red in the output with a traceback, without stopping the caller.
	task.spawn(error, "[Branch] " .. message, 0)
end

-- Which modules are segments:
--   "Suffix"  (default) any ModuleScript at any depth whose name ends with
--             Service (server) / Controller (client), in any casing:
--             ShopService, shopService, shop_service, SHOP_SERVICE. Every
--             other module is a helper, so services can nest inside services.
--   "Folders" modules directly under a root or under Folders inside it; a
--             module parented to another module is its private helper.
export type SegmentRule = "Suffix" | "Folders"
local SUFFIX = if RunService:IsServer() then "service" else "controller"

local function isSegmentName(name: string): boolean
	local plain = string.lower((string.gsub(name, "[_%-%s]", "")))
	return #plain >= #SUFFIX and string.sub(plain, -#SUFFIX) == SUFFIX
end

local function discover(root: Instance, found: { ModuleScript }, rule: SegmentRule)
	if rule == "Suffix" then
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("ModuleScript") and isSegmentName(descendant.Name) then
				table.insert(found, descendant)
			end
		end
		return
	end
	for _, child in root:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(found, child)
		elseif child:IsA("Folder") then
			discover(child, found, rule)
		end
	end
end

-- Runs `action`, warning once if it is still running after 5 s (a require or
-- Init that waits forever would otherwise stall the whole start silently).
local function watched<T...>(label: string, action: () -> T...): T...
	local finished = false
	local watcher = task.delay(5, function()
		if not finished then
			warn(`[Branch] {label} is still running after 5 s; every segment after it is waiting (a WaitForChild or DataStore call that never returns?)`)
		end
	end)
	local results = table.pack(action())
	finished = true
	if coroutine.status(watcher) == "suspended" then
		task.cancel(watcher)
	end
	return table.unpack(results, 1, results.n)
end

local function load(module: ModuleScript)
	local ok, result = watched(`require({module:GetFullName()})`, function()
		return pcall(require, module)
	end)
	if not ok then
		fail(`{module:GetFullName()} failed to load: {result}`)
		return
	end
	if type(result) ~= "table" then
		fail(`{module:GetFullName()} must return a table (got {typeof(result)}); skipped`)
		return
	end

	local name = module.Name
	local existing = byName[name]
	if existing ~= nil then
		local index = table.find(modules, existing)
		fail(`two segments are named "{name}": {if index then paths[index] else "?"} and {module:GetFullName()}; the second was skipped`)
		return
	end

	count += 1
	names[count] = name
	modules[count] = result
	paths[count] = module:GetFullName()
	statuses[count] = "Loaded"
	initTimes[count] = 0
	byName[name] = result
end

-- Dependency order: a segment's Init runs after the Init of everything in
-- its `Dependencies` list. Ties keep discovery order.
local function initOrder(): { number }
	local order: { number } = table.create(count)
	local state: { [number]: number } = {} -- 1 = visiting, 2 = done
	local indexOf: { [string]: number } = {}
	for index = 1, count do
		indexOf[names[index]] = index
	end

	local function visit(index: number, trail: { string })
		if state[index] == 2 then
			return
		elseif state[index] == 1 then
			fail(`dependency cycle: {table.concat(trail, " -> ")} -> {names[index]}`)
			return
		end
		state[index] = 1
		local dependencies = modules[index].Dependencies
		if type(dependencies) == "table" then
			for _, dependency in dependencies do
				local target = indexOf[dependency]
				if target then
					table.insert(trail, names[index])
					visit(target, trail)
					table.remove(trail)
				else
					fail(`{names[index]} depends on "{tostring(dependency)}", which is not a segment`)
				end
			end
		end
		state[index] = 2
		table.insert(order, index)
	end

	for index = 1, count do
		visit(index, {})
	end
	return order
end

local function connectHooks()
	for hookName, signal in HOOK_SIGNALS do
		local fns: { (any, number) -> () } = {}
		local selves: { any } = {}
		local labels: { string } = {}
		local lastWarn: { number } = {}

		for index = 1, count do
			local fn = modules[index][hookName]
			if type(fn) == "function" and statuses[index] ~= "Failed" then
				table.insert(fns, fn)
				table.insert(selves, modules[index])
				table.insert(labels, names[index])
				table.insert(lastWarn, -math.huge)
			end
		end

		if #fns > 0 and signal then
			local total = #fns
			signal:Connect(function(dt: number)
				for index = 1, total do
					local ok, problem = pcall(fns[index], selves[index], dt)
					if not ok then
						local now = os.clock()
						if now - lastWarn[index] > 5 then
							lastWarn[index] = now
							fail(`{labels[index]}:{hookName} errored: {problem}`)
						end
					end
				end
			end)
		end
	end

	local joined: { any } = {}
	local left: { any } = {}
	for index = 1, count do
		if statuses[index] ~= "Failed" then
			local segment = modules[index]
			if type(segment.PlayerAdded) == "function" then
				table.insert(joined, segment)
			end
			if type(segment.PlayerRemoving) == "function" then
				table.insert(left, segment)
			end
		end
	end

	if #joined > 0 then
		local function added(player: Player)
			for _, segment in joined do
				task.spawn(segment.PlayerAdded, segment, player)
			end
		end
		Players.PlayerAdded:Connect(added)
		for _, player in Players:GetPlayers() do
			added(player)
		end
	end
	if #left > 0 then
		Players.PlayerRemoving:Connect(function(player: Player)
			for _, segment in left do
				task.spawn(segment.PlayerRemoving, segment, player)
			end
		end)
	end
end

function branch.Start(self: Branch, ...: Instance)
	if phase ~= "Idle" then
		error("Branch:Start can only be called once", 2)
	end
	-- Roots, then an optional options table: { SegmentRule = "Suffix" | "Folders" }.
	-- Check everything first: a bad argument must not leave Branch half-started
	-- (Start refused forever, AwaitStart waiting forever).
	local roots: { Instance } = {}
	local options: { SegmentRule: SegmentRule? } = {}
	local count_ = select("#", ...)
	for index = 1, count_ do
		local argument = select(index, ...)
		if index == count_ and type(argument) == "table" and typeof(argument) ~= "Instance" then
			-- a list of roots is an easy slip, and would otherwise load nothing
			if #argument > 0 then
				error("Branch:Start takes roots as separate arguments: Branch:Start(folderA, folderB), not a table of them", 2)
			end
			for key in argument do
				if key ~= "SegmentRule" then
					error(`Branch:Start got an unknown option "{tostring(key)}" (the only option is SegmentRule)`, 2)
				end
			end
			options = argument :: any
		elseif typeof(argument) == "Instance" then
			table.insert(roots, argument)
		else
			error(`Branch:Start argument #{index} must be an Instance (or a final options table)`, 2)
		end
	end
	local rule: SegmentRule = options.SegmentRule or (script:GetAttribute("SegmentRule") :: SegmentRule?) or "Suffix"
	if rule ~= "Suffix" and rule ~= "Folders" then
		error(`Branch:Start SegmentRule must be "Suffix" or "Folders", got {tostring(rule)}`, 2)
	end
	if #roots == 0 then
		warn("[Branch] Start was given no roots, so no segments were loaded: Branch:Start(script.Parent.Services)")
	end
	phase = "Loading"

	local found: { ModuleScript } = {}
	for _, root in roots do
		discover(root, found, rule)
	end
	for _, module in found do
		load(module)
	end

	phase = "Initializing"
	local indexOf: { [string]: number } = {}
	for index = 1, count do
		indexOf[names[index]] = index
	end
	for _, index in initOrder() do
		local dependencies = modules[index].Dependencies
		if type(dependencies) == "table" then
			for _, dependency in dependencies do
				local target = indexOf[dependency]
				if target and statuses[target] == "Failed" then
					fail(`{names[index]} depends on {dependency}, whose Init failed; {names[index]} still starts, but may not work`)
				end
			end
		end
		local init = modules[index].Init
		if type(init) == "function" then
			local started = os.clock()
			local ok, problem = watched(`{names[index]}:Init`, function()
				return pcall(init, modules[index])
			end)
			initTimes[index] = (os.clock() - started) * 1000
			if ok then
				statuses[index] = "Initialized"
			else
				statuses[index] = "Failed"
				fail(`{names[index]}:Init failed: {problem}`)
			end
		else
			statuses[index] = "Initialized"
		end
	end

	for index = 1, count do
		if statuses[index] ~= "Failed" then
			statuses[index] = "Started"
			local start = modules[index].Start
			if type(start) == "function" then
				task.spawn(start, modules[index])
			end
		end
	end

	connectHooks()

	phase = "Started"
	for _, thread in waiting do
		task.spawn(thread)
	end
	table.clear(waiting)
end

function branch.GetSegment(self: Branch, name: string): any
	local found = byName[name]
	if found ~= nil then
		return found
	end
	error(`Branch: segment "{name}" not found (phase {phase}). Look segments up in :Init() or later, not at module top level.`, 2)
end

function branch.LocateSegments(self: Branch, list: { string }): { [string]: any }
	local found = {}
	for _, name in list do
		found[name] = self:GetSegment(name)
	end
	return found
end

function branch.GetPhase(self: Branch): Phase
	return phase
end

-- Yields until every segment has been initialised and started.
function branch.AwaitStart(self: Branch)
	if phase ~= "Started" then
		table.insert(waiting, coroutine.running())
		coroutine.yield()
	end
end

function branch.GetReport(self: Branch): { SegmentReport }
	local report = table.create(count)
	for index = 1, count do
		report[index] = {
			Name = names[index],
			Path = paths[index],
			Status = statuses[index] :: any,
			InitMs = initTimes[index],
		}
	end
	return report
end

-- Network / Data load lazily so games that do not use them pay nothing.
setmetatable(branch, {
	__index = function(self: any, key: string): any
		if key == "Network" then
			local module = script:FindFirstChild("Network")
			if not module then
				error("Branch.Network is not compiled: turn on Network in Branch Studio and declare Service.Network tables", 2)
			end
			local network = require(module :: ModuleScript)
			rawset(self, "Network", network)
			return network
		elseif key == "Data" then
			local data = require(script.Data)
			rawset(self, "Data", data)
			return data
		end
		error(`Branch.{tostring(key)} does not exist`, 2)
	end,
})

return (branch :: any) :: Branch
