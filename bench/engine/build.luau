--!strict
-- Builds the in-engine benchmark place: Branch vs NetRay vs Blink.
--   lune run bench/engine/build.luau        (from the Branch repository)
-- writes bench/BranchBenchmark.rbxl. Open it in Studio and press Play: the
-- benchmarks run one after another and the Output shows the results.
--
-- Inputs, generated beforehand from the same schema by each library:
--   generated/engine/branch/{Server,Client}.luau   (Branch Studio, engine/Engine.network.luau)
--   generated/engine/netray/{Server,Client,Types}.luau  (NetRay CLI, engine/Engine.idl)
--   generated/engine/Blink{Server,Client}.luau          (Blink CLI, engine/Engine.blink)
--
-- Every module gets the SAME instrumentation: remote calls and payload bytes
-- are counted, the Heartbeat flush is timed, and the reliable receive handler
-- is exported so decode can be timed on a captured packet.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Instance = roblox.Instance
-- works from the Branch repository (bench/) and from Branch-Studio (tests/bench/)
local BASE = if fs.isDir("bench/engine") then "bench/" else "tests/bench/"
local IN = BASE .. "generated/engine"
local OUT = if BASE == "bench/" then "bench/BranchBenchmark.rbxl" else "build/bench/engine/BranchBenchmark.rbxl"

local function count(text: string, pattern: string): number
	local _, n = string.gsub(text, pattern, "")
	return n
end

local function instrument(source: string, label: string): string
	-- remote sends -> counted wrappers
	local calls = 0
	for _, method in { "FireServer", "FireClient", "FireAllClients", "InvokeServer" } do
		local n
		source, n = string.gsub(source, "([%w_]+):" .. method .. "%(", "__B." .. method .. "(%1, ")
		calls += n
	end
	assert(calls > 0, label .. ": no remote sends found")

	-- Heartbeat flush -> timed
	-- (Branch's Studio-only profiler also runs on Heartbeat: not part of the flush)
	local beats = 0
	source = string.gsub(source, "RunService%.Heartbeat:Connect%(([%w_]+)%)", function(handler: string)
		if handler == "publish" then
			return nil
		end
		beats += 1
		return `RunService.Heartbeat:Connect(__B.timed({handler}))`
	end)
	assert(beats == 1, label .. ": expected one Heartbeat flush, found " .. beats)

	-- export the reliable receive handler
	local exported = 0
	for _, side in { "Server", "Client" } do
		local connect = "Reliable.On" .. side .. "Event:Connect("
		-- plain find, skipping "Unreliable.On..." (the character before must not be a name)
		local at = string.find(source, connect .. "function(", 1, true)
		while at and at > 1 and string.find(string.sub(source, at - 1, at - 1), "[%w_]") do
			at = string.find(source, connect .. "function(", at + 1, true)
		end
		if at then
			-- anonymous handler block (NetRay, Blink) ending at the first top-level "end)"
			local stop = assert(string.find(source, "\nend)", at, true), label .. ": handler block end not found")
			source = string.sub(source, 1, at - 1)
				.. "local __benchRecv = function("
				.. string.sub(source, at + #connect + #"function(", stop)
				.. "end\n"
				.. connect
				.. "__benchRecv)\n__B.export(__benchRecv)"
				.. string.sub(source, stop + #"\nend)")
			exported += 1
		else
			-- named handler (Branch)
			local n
			source, n = string.gsub(source, "%f[%w_]Reliable%.On" .. side .. "Event:Connect%(([^\n]+)%)\n", function(handler: string)
				return `local __benchRecv = {handler}\n{connect}__benchRecv)\n__B.export(__benchRecv)\n`
			end)
			exported += n
		end
	end
	assert(exported == 1, label .. ": expected one reliable receive handler, found " .. exported)

	-- prelude right after the leading comment/directive block
	local prelude = string.gsub([[local __B = (function()
	local all = _G.__BENCH or {}
	_G.__BENCH = all
	local c = all["LABEL"] or { bytes = 0, calls = 0, flushCpu = 0, sendCpu = 0 }
	all["LABEL"] = c
	local function add(b)
		c.calls += 1
		if type(b) == "buffer" then
			c.bytes += buffer.len(b)
		end
	end
	return {
		FireServer = function(remote, b, ...)
			add(b)
			local t = os.clock()
			remote:FireServer(b, ...)
			c.sendCpu += os.clock() - t
		end,
		FireClient = function(remote, player, b, ...)
			add(b)
			local t = os.clock()
			remote:FireClient(player, b, ...)
			c.sendCpu += os.clock() - t
		end,
		FireAllClients = function(remote, b, ...)
			add(b)
			local t = os.clock()
			remote:FireAllClients(b, ...)
			c.sendCpu += os.clock() - t
		end,
		InvokeServer = function(remote, b, ...)
			add(b)
			return remote:InvokeServer(b, ...)
		end,
		timed = function(fn)
			return function(...)
				local t = os.clock()
				fn(...)
				c.flushCpu += os.clock() - t
			end
		end,
		export = function(fn)
			_G.__BENCH_RECV = _G.__BENCH_RECV or {}
			_G.__BENCH_RECV["LABEL"] = fn
		end,
	}
end)()
]], "LABEL", label)
	local lines = string.split(source, "\n")
	local insertAt = 1
	for index, text in lines do
		if string.sub(text, 1, 2) == "--" then
			insertAt = index + 1
		else
			break
		end
	end
	table.insert(lines, insertAt, prelude)
	source = table.concat(lines, "\n")
	luau.compile(source) -- throws on syntax errors or too many locals
	return source
end

local function module(name: string, source: string, parent: any)
	local node = Instance.new("ModuleScript")
	node.Name = name
	node.Source = source
	node.Parent = parent
	return node
end

local function folder(name: string, parent: any)
	local node = Instance.new("Folder")
	node.Name = name
	node.Parent = parent
	return node
end

-- sources ---------------------------------------------------------------

local branch = {
	Server = fs.readFile(IN .. "/branch/Server.luau"),
	Client = fs.readFile(IN .. "/branch/Client.luau"),
}
local netray = {
	Server = fs.readFile(IN .. "/netray/Server.luau"),
	Client = fs.readFile(IN .. "/netray/Client.luau"),
	Types = fs.readFile(IN .. "/netray/Types.luau"),
}
local blink = {
	Server = fs.readFile(IN .. "/BlinkServer.luau"),
	Client = fs.readFile(IN .. "/BlinkClient.luau"),
}

-- place -----------------------------------------------------------------

local game = Instance.new("DataModel")
local workspace = game:GetService("Workspace")
local replicated = game:GetService("ReplicatedStorage")
local serverScripts = game:GetService("ServerScriptService")
local starterPlayer = game:GetService("StarterPlayer")
game:GetService("Players")
game:GetService("Lighting")

local baseplate = Instance.new("Part")
baseplate.Name = "Baseplate"
baseplate.Anchored = true
baseplate.Size = roblox.Vector3.new(256, 4, 256)
baseplate.CFrame = roblox.CFrame.new(0, -2, 0)
baseplate.Parent = workspace

local spawn = Instance.new("SpawnLocation")
spawn.Anchored = true
spawn.Size = roblox.Vector3.new(6, 1, 6)
spawn.CFrame = roblox.CFrame.new(0, 0.5, 0)
spawn.Parent = workspace

local readme = Instance.new("Script")
readme.Name = "README"
readme.Disabled = true
readme.Source = [[
-- Branch vs NetRay vs Blink, in the engine.
-- Press Play (F5, not Run). The benchmarks run one after another, about a
-- minute in all; the Output shows every result, how much faster or slower
-- Branch is, and a summary at the end.
--
-- ReplicatedStorage.Bench holds each library's generated module, with the
-- same counters added to all three. The code that drives the benchmark is
-- ServerScriptService.BenchServer and StarterPlayerScripts.BenchClient.
-- Source: https://github.com/PraxPrix-Studios/Branch-Framework/tree/main/bench
]]
readme.Parent = workspace

local bench = folder("Bench", replicated)

local branchFolder = folder("Branch", bench)
module("Server", instrument(branch.Server, "Branch"), branchFolder)
module("Client", instrument(branch.Client, "Branch"), branchFolder)
local reliable = Instance.new("RemoteEvent")
reliable.Name = "Reliable"
reliable.Parent = branchFolder
local unreliable = Instance.new("UnreliableRemoteEvent")
unreliable.Name = "Unreliable"
unreliable.Parent = branchFolder
-- Branch's server half normally lives in ServerScriptService; here both
-- halves sit together, so the server one finds its remotes next to it.

local netrayFolder = folder("NetRay", bench)
module("Server", instrument(netray.Server, "NetRay"), netrayFolder)
module("Client", instrument(netray.Client, "NetRay"), netrayFolder)
module("Types", netray.Types, netrayFolder)

local blinkFolder = folder("Blink", bench)
module("Server", instrument(blink.Server, "Blink"), blinkFolder)
module("Client", instrument(blink.Client, "Blink"), blinkFolder)

-- The NetRay author's Entities module (50 cars, deterministic).
module("Entities", [==[
local amount = 50
local array = table.create(amount)
for index = 1, amount do
	local random = Random.new(index*index)
	table.insert(array, {
		brand = string.char(random:NextInteger(0, 255)):rep(random:NextInteger(2, 100)),
		carName = string.char(random:NextInteger(0, 255)):rep(random:NextInteger(2, 100)),
		carId = random:NextInteger(0, 65535),
		available = random:NextInteger(0, 1) == 1,
		dealers = random:NextInteger(0, 127),
		price = random:NextNumber(0, 1e12),
	})
end
return array
]==], replicated)

local control = Instance.new("RemoteEvent")
control.Name = "BenchControl"
control.Parent = replicated

local serverScript = Instance.new("Script")
serverScript.Name = "BenchServer"
serverScript.Source = fs.readFile(BASE .. "engine/BenchServer.server.luau")
serverScript.Parent = serverScripts

local playerScripts = starterPlayer:FindFirstChildOfClass("StarterPlayerScripts") or Instance.new("StarterPlayerScripts")
playerScripts.Parent = starterPlayer
local clientScript = Instance.new("LocalScript")
clientScript.Name = "BenchClient"
clientScript.Source = fs.readFile(BASE .. "engine/BenchClient.client.luau")
clientScript.Parent = playerScripts

luau.compile(serverScript.Source)
luau.compile(clientScript.Source)

fs.writeFile(OUT, roblox.serializePlace(game))
print("wrote " .. OUT)
