--!strict
-- Branch runtime (segment loader, Data.Path) under Lune.

local process = require("@lune/process")
local task = require("@lune/task")

local T = require("./lib/T")
local Loader = require("./lib/Loader")

print("Branch runtime tests")

local function Signal()
	local signal = { handlers = {} :: { any } }
	function signal:Connect(fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	function signal:Fire(...)
		for _, handler in table.clone(self.handlers) do
			handler(...)
		end
	end
	return signal
end

local runtime = Loader.root("src")
Loader.preload(runtime)
local fixtures = Loader.root("tests/fixtures")
Loader.preload(fixtures)

local function newGame()
	local shared = { log = {}, beats = 0, zetaReady = false }
	local Players: any = { PlayerAdded = Signal(), PlayerRemoving = Signal(), list = {} }
	function Players:GetPlayers()
		return table.clone(self.list)
	end
	local RunService: any = { Heartbeat = Signal(), PreSimulation = Signal(), PreRender = Signal() }
	function RunService:IsClient()
		return false
	end
	function RunService:IsServer()
		return true
	end
	local errors = {}
	local env = {
		game = {
			GetService = function(_, name)
				return if name == "Players" then Players elseif name == "RunService" then RunService else error(name)
			end,
		},
		task = {
			spawn = function(fn, ...)
				if fn == error then
					table.insert(errors, (...))
					return
				end
				return task.spawn(fn, ...)
			end,
			defer = task.defer,
			delay = task.delay,
			cancel = task.cancel,
		},
		_G = shared,
		typeof = function(value: any): string
			if type(value) == "table" and rawget(value, "__children") then
				return "Instance"
			end
			return typeof(value)
		end,
		warn = print,
	}
	return env, shared, Players, RunService, errors
end

T.test("loads folders, skips helpers/duplicates, orders Init by Dependencies", function()
	local env, shared, Players, RunService, errors = newGame()
	table.insert(Players.list, { Name = "Early" })
	local Branch = Loader.require(runtime, env)
	Branch:Start(fixtures.Services, { SegmentRule = "Folders" })
	task.wait()

	local log = table.concat(shared.log, "\n")
	-- dependency order
	local zeta = string.find(log, "Zeta:Init", 1, true)
	local alpha = string.find(log, "Alpha:Init after Zeta=true", 1, true)
	T.truthy(zeta and alpha and zeta < alpha, log)
	-- folder segments load, helpers inside modules do not become segments
	T.truthy(string.find(log, "Sword:Init", 1, true), "segment in a folder was not loaded")
	T.truthy(string.find(log, "PlayerService:Init", 1, true), "module-with-children segment was not loaded")
	T.truthy(not string.find(log, "SHOULD NOT RUN", 1, true), log)
	-- players already in game get PlayerAdded, later ones too
	T.truthy(string.find(log, "Alpha:PlayerAdded Early", 1, true), log)
	Players.PlayerAdded:Fire({ Name = "Late" })
	T.truthy(string.find(table.concat(shared.log, "\n"), "Alpha:PlayerAdded Late", 1, true))

	-- errors: duplicate, init failure, non-table
	local problems = table.concat(errors, "\n")
	T.truthy(string.find(problems, "Broken:Init failed", 1, true), problems)
	T.truthy(string.find(problems, "must return a table", 1, true), problems)

	-- one shared Heartbeat connection; a failing hook does not stop others
	RunService.Heartbeat:Fire(1 / 60)
	RunService.Heartbeat:Fire(1 / 60)
	T.eq(shared.beats, 2)
	T.eq(#RunService.Heartbeat.handlers, 1)
	T.truthy(string.find(table.concat(errors, "\n"), "Zeta:Heartbeat errored", 1, true))

	-- lookups
	T.eq(Branch:GetSegment("PlayerService").helper, 42)
	T.errors(function()
		Branch:GetSegment("Nope")
	end, "not found")
	T.eq(Branch:GetPhase(), "Started")
	T.errors(function()
		Branch:Start(fixtures.Services, { SegmentRule = "Folders" })
	end, "only be called once")

	local report = Branch:GetReport()
	local statuses = {}
	for _, row in report do
		statuses[row.Name] = row.Status
	end
	T.eq(statuses.Broken, "Failed")
	T.eq(statuses.Alpha, "Started")

	T.errors(function()
		local _ = (Branch :: any).Netwrk
	end, "does not exist")
	T.errors(function()
		local _ = Branch.Network
	end, "not compiled")
end)

T.test("duplicate segment names: the second is skipped with an error", function()
	local env, shared, _, _, errors = newGame()
	local Branch = Loader.require(runtime, env)
	Branch:Start(fixtures.DupeRoot, { SegmentRule = "Folders" })
	T.eq(#shared.log, 1)
	local text = table.concat(errors, " | ")
	T.truthy(string.find(text, 'two segments are named "X"', 1, true), text)
end)

T.test("AwaitStart resumes waiting threads", function()
	local env = newGame()
	local Branch = Loader.require(runtime, env)
	local resumed = false
	task.spawn(function()
		Branch:AwaitStart()
		resumed = true
	end)
	T.eq(resumed, false)
	Branch:Start(fixtures.Services.Combat, { SegmentRule = "Folders" })
	task.wait()
	T.eq(resumed, true)
end)

T.test("Suffix rule: names ending in Service are segments at any depth, others are helpers", function()
	local env, shared, _, _, errors = newGame()
	local Branch = Loader.require(runtime, env)
	Branch:Start(fixtures.Suffix)
	task.wait()
	local log = table.concat(shared.log, "\n")
	for _, name in { "ShopService", "InventoryService", "bank_service", "tradeService" } do
		T.truthy(string.find(log, name .. ":Init", 1, true), name .. " was not loaded: " .. log)
	end
	T.truthy(not string.find(log, "SHOULD NOT RUN", 1, true), "a helper was loaded as a segment: " .. log)
	T.truthy(not string.find(log, "Util required", 1, true), "a helper was required: " .. log)
	T.eq(#errors, 0)
	T.errors(function()
		local _ = Loader.require(runtime, newGame()):Start(fixtures.Suffix, { SegmentRule = "Nope" })
	end, "SegmentRule")
end)

T.test("a bad Start argument leaves Branch startable", function()
	local env = newGame()
	local Branch = Loader.require(runtime, env)
	T.errors(function()
		Branch:Start("not an instance")
	end, "must be an Instance")
	T.eq(Branch:GetPhase(), "Idle")
	local resumed = false
	task.spawn(function()
		Branch:AwaitStart()
		resumed = true
	end)
	Branch:Start(fixtures.Services.Combat, { SegmentRule = "Folders" })
	task.wait()
	T.eq(resumed, true)
end)

T.test("Data.Path parses, caches, reads and checks against the template", function()
	local Path = Loader.require(runtime.Data.Path, { typeof = typeof })
	local parts = Path.parse("stats.kills")
	T.eq(parts, { "stats", "kills" })
	T.truthy(Path.parse("stats.kills") == parts, "parsed paths should be cached")
	T.eq(Path.parse("inventory.3"), { "inventory", 3 })
	local template = { coins = 0, stats = { kills = 0, name = "" }, bag = {} }
	Path.check(template, Path.parse("coins"), 5)
	Path.check(template, Path.parse("bag.1"), "sword") -- arrays are dynamic
	Path.check(template, Path.parse("extra.key"), true) -- unknown paths pass
	T.errors(function()
		Path.check(template, Path.parse("coins"), "5")
	end, "holds a number")
	T.errors(function()
		Path.check(template, Path.parse("stats.kills"), nil)
	end, "cannot be set to nil")
	T.eq(Path.read({ a = { b = { 7 } } }, Path.parse("a.b.1")), 7)
	T.eq(Path.read({ a = 1 }, Path.parse("a.b.c")), nil)
end)

T.test("Branch.Data refuses NaN and infinity before they reach a save", function()
	local DataFolder = Loader.root("src/Data")
	local Path = Loader.require(DataFolder.Path)
	local template = { coins = 0, stats = { kills = 0 }, inventory = {} }
	local function refused(parts: { any }, value: any): boolean
		local ok, problem = pcall(Path.check, template, parts, value)
		return not ok and string.find(tostring(problem), "NaN or infinity", 1, true) ~= nil
	end
	T.truthy(refused({ "coins" }, 0 / 0), "NaN accepted")
	T.truthy(refused({ "coins" }, math.huge), "inf accepted")
	T.truthy(refused({ "stats" }, { kills = -math.huge }), "nested -inf accepted")
	T.truthy(refused({ "inventory", 3 }, { price = 0 / 0 }), "NaN on a path outside the template accepted")
	T.truthy(pcall(Path.check, template, { "coins" }, 12.5), "a normal number was refused")
	T.truthy(pcall(Path.check, template, { "stats" }, { kills = 3 }), "a normal table was refused")
	T.truthy(not pcall(Path.assertFinite, { "coins" }, 1 / 0, 1), "assertFinite let inf through")
end)

T.test("Branch.Data: nested observers, string-keyed ids, deep template checks", function()
	local DataFolder = Loader.root("src/Data")
	local Path = Loader.require(DataFolder.Path)
	local DataClass = Loader.require(DataFolder.DataService.Data, { task = task })

	-- replacing a table notifies observers of paths under it; ancestors get old = nil
	local data = DataClass.new({ stats = { kills = 1, deaths = 2 }, coins = 0 })
	local kills, stats = {}, {}
	data:getChangedSignal({ "stats", "kills" }):Connect(function(new, old)
		table.insert(kills, { new, old })
	end)
	data:getChangedSignal({ "stats" }):Connect(function(_, old)
		table.insert(stats, old == nil)
	end)
	data:set({ "stats" }, { kills = 5, deaths = 2 })
	data:set({ "stats", "kills" }, 6)
	data:set({ "stats" }, { kills = 6, deaths = 3 }) -- kills unchanged: no extra call
	T.eq(kills, { { 5, 1 }, { 6, 5 } })
	T.eq(stats[2], true)

	-- numeric segments reach string keys in dictionaries, arrays stay numeric
	local profile = { friends = { ["12345"] = true, ["777"] = false }, list = { "a", "b" }, empty = {} }
	T.eq(Path.read(profile, Path.parse("friends.12345")), true)
	T.eq(Path.resolve(profile, Path.parse("friends.999")), { "friends", "999" })
	T.eq(Path.resolve(profile, Path.parse("list.2")), Path.parse("list.2"))
	T.eq(Path.resolve(profile, Path.parse("empty.1")), Path.parse("empty.1"))

	-- template shape is checked all the way down
	local template = { stats = { kills = 0, deaths = 0, best = { score = 0 } }, items = { { id = 0, name = "" } } }
	local function fails(fn: () -> (), text: string): boolean
		local ok, problem = pcall(fn)
		return not ok and string.find(tostring(problem), text, 1, true) ~= nil
	end
	T.truthy(fails(function()
		Path.check(template, { "stats" }, { kills = 1 })
	end, 'is missing (the template has it)'), "missing key accepted")
	T.truthy(fails(function()
		Path.check(template, { "stats" }, { kills = 1, deaths = 0, best = { score = "x" } })
	end, '"stats.best.score" holds a number'), "nested wrong type accepted")
	T.truthy(pcall(Path.check, template, { "stats" }, { kills = 1, deaths = 0, best = { score = 9 }, extra = true }), "valid table refused")
	T.truthy(fails(function()
		Path.checkElement(template, { "items" }, { id = "one", name = "" })
	end, '"items.id" holds a number'), "bad array element accepted")
	T.truthy(pcall(Path.checkElement, template, { "items" }, { id = 2, name = "Sword" }), "good array element refused")
end)

T.test("Timer: pause/resume, extending, stopping with waiters, failing callbacks", function()
	local clock = 0
	local presim = Signal()
	local reported = {}
	local env = {
		game = { GetService = function() return { PreSimulation = presim } end },
		time = function() return clock end,
		task = {
			spawn = function(fn: any, ...: any)
				if type(fn) == "thread" then
					return task.spawn(fn, ...)
				end
				local ok, problem = pcall(fn, ...)
				if not ok then
					table.insert(reported, problem)
				end
				return nil
			end,
		},
	}
	local Timer = Loader.require(runtime.Util.Timer, env)
	local function frame(at: number)
		clock = at
		presim:Fire()
	end

	-- the paused 8 s do not count
	local paused = Timer.new(5)
	paused:Start()
	frame(2)
	paused:Pause()
	frame(10)
	paused:Resume()
	T.truthy(math.abs(paused:GetRemaining() - 3) < 1e-9, "remaining after resume: " .. paused:GetRemaining())
	frame(12.5)
	T.eq(paused:GetState(), "Running")
	frame(13.1)
	T.eq(paused:GetState(), "Dead")

	-- extending one timer does not hold back another that is due
	clock = 20
	local a, b = Timer.new(5), Timer.new(3)
	a:Start()
	b:Start()
	b:IncrementTime(10)
	frame(25.1)
	T.eq(a:GetState(), "Dead")
	T.eq(b:GetState(), "Running")
	b:Stop()

	-- Stop wakes waiters; a second Stop runs nothing
	local c = Timer.new(10)
	local stops, woke = 0, nil
	c:OnStopped(function()
		stops += 1
	end)
	c:Start()
	task.spawn(function()
		woke = c:Wait()
	end)
	c:Stop()
	c:Stop()
	T.eq(woke, "Stopped")
	T.eq(stops, 1)
	T.eq(c:Wait(), "Stopped") -- a dead timer answers at once

	-- a failing callback is reported and the next timer still finishes
	local d, e = Timer.new(1), Timer.new(1)
	d:OnFinished(function()
		error("callback boom")
	end)
	d:Start()
	e:Start()
	frame(clock + 1.5)
	T.eq(d:GetState(), "Dead")
	T.eq(e:GetState(), "Dead")
	T.truthy(string.find(tostring(reported[1]), "callback boom", 1, true), "callback error was not reported")
end)

if not T.finish() then
	process.exit(1)
end
