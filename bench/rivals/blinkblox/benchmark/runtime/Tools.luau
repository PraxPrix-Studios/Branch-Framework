--!strict
--- Each tool the Studio benchmark compares, behind one shape the timing loop drives: fire an event,
--- flush a frame's events into packets, deliver packets to the server, listen for what it decodes.
---
--- BlinkBlox loads through Environment.luau, as it always has. The others load through World.luau,
--- upstream Blink among them, compiled by its own compiler from definitions/Definition.upstream.blink
--- -- from the same files Studio runs: `src/shared/modes/<tool>.luau` declares each tool's events, and
--- requires the generated modules or the downloaded packages. `lune run build --download` fetches
--- those; a tool whose files are missing is skipped, and says so.
local fs = require("@lune/fs")

local Environment = require("./Environment")
local World = require("./World")

local Tools = {}

export type Sent = World.Sent

export type Tool = {
	Fire: (Value: any) -> (),
	--> The packets one frame's fires turned into, in the order they went out.
	Flush: () -> { Sent },
	Deliver: (Packets: { Sent }) -> (),
	--> `Callback` gets the decoded value, whatever the tool passes beside it.
	Listen: (Callback: (Value: any) -> ()) -> (),
}

--> What each tool needs on disk, relative to the benchmark, beyond its mode file.
local REQUIRES: { [string]: { string } } = {
	upstream = { "src/shared/upstream/Server.luau", "src/shared/upstream/Client.luau" },
	zap = { "src/shared/zap/Server.luau", "src/shared/zap/Client.luau" },
	bytenet = { "packages/bytenet/init.luau" },
	packet = { "packages/packet/init.luau" },
	quicknet = { "packages/quicknet/init.luau" },
	warp = { "packages/warp/init.luau" },
	branch = { "packages/branch/Definition/Server.luau" },
}

Tools.ORDER = { "blink", "branch", "upstream", "zap", "bytenet", "packet", "quicknet", "warp" }

--> The packages a World mounts, those downloaded.
function Tools.Mounts(): { string }
	local Mounts = {}
	for _, Name in { "bytenet", "packet", "quicknet", "warp", "branch" } do
		local Path = `packages/{Name}`
		if fs.isDir(Path) then
			table.insert(Mounts, Path)
		end
	end
	return Mounts
end

--- Why `Name` cannot run here, or nil when it can.
function Tools.Missing(Name: string): string?
	local Paths: { string } = REQUIRES[Name] or {}
	for _, Path in Paths do
		if not fs.isFile(Path) then
			return `{Path} is missing; run \`lune run build --download\` first`
		end
	end
	return nil
end

local function Blink(Pair: Environment.Pair, Bench: string): Tool
	local Reliable = Pair.Reliable
	local StepReplication = Pair.Client.StepReplication

	return {
		Fire = Pair.Client[Bench].Fire,
		Flush = function()
			StepReplication()
			local Buffer = Reliable.Sent
			Reliable.Sent = nil
			return if Buffer then { { Buffer = Buffer, Instances = Reliable.SentInstances } } else {}
		end,
		Deliver = function(Packets)
			local Handler = assert(Reliable.ServerHandler, "The server never connected")
			for _, Packet in Packets do
				Handler(Pair.Player, Packet.Buffer, Packet.Instances or {})
			end
		end,
		Listen = function(Callback)
			Pair.Server[Bench].On(function(_Player, Value)
				Callback(Value)
			end)
		end,
	}
end

--> Packet's client sends once a 60th of a second has passed, counting each Heartbeat's delta, so a
--> delta of exactly 1/60 sends every other frame. Every tool here is asked to flush every frame.
local FRAME = 1 / 30

--- `Name` loaded fresh, natively compiled or not. `Sources` is BlinkBlox's generated server and
--- client, used only for it.
function Tools.Load(Name: string, Native: boolean, Bench: string, Sources: { Server: string, Client: string }): Tool
	if Name == "blink" then
		return Blink(Environment.Load(Sources.Server, Sources.Client, Native), Bench)
	end

	local Universe = World.Universe(Native, Tools.Mounts())
	--> The server first: it creates the remotes and assigns the ids the client then reads.
	local Server = World.new(Universe, true)
	local ServerEvents = Server.Require(`src/shared/modes/{Name}.luau`)
	local Client = World.new(Universe, false)
	local ClientEvents = Client.Require(`src/shared/modes/{Name}.luau`)
	World.Settle(Universe)

	local ClientEvent = ClientEvents[Bench]
	local ServerEvent = ServerEvents[Bench]

	local Fire: (Value: any) -> ()
	local Listen: (Callback: (Value: any) -> ()) -> ()
	--> QuickNet's and Warp's modes wrap each event in BlinkBlox's shape.
	if Name == "upstream" or Name == "quicknet" or Name == "warp" or Name == "branch" then
		Fire = ClientEvent.Fire
		Listen = function(Callback)
			ServerEvent.On(function(_Player, Value)
				Callback(Value)
			end)
		end
	elseif Name == "zap" then
		Fire = ClientEvent.Fire
		Listen = function(Callback)
			ServerEvent.SetCallback(function(_Player, Value)
				Callback(Value)
			end)
		end
	elseif Name == "bytenet" then
		Fire = ClientEvent.send
		Listen = function(Callback)
			ServerEvent.listen(function(Value, _Player)
				Callback(Value)
			end)
		end
	elseif Name == "packet" then
		Fire = function(Value)
			ClientEvent:Fire(Value)
		end
		Listen = function(Callback)
			ServerEvent.OnServerEvent:Connect(function(_Player, Value)
				Callback(Value)
			end)
		end
	else
		error(`No tool called {Name}`)
	end

	return {
		Fire = Fire,
		Flush = function()
			Client.Heartbeat:Fire(FRAME)
			World.Drain(Universe)
			local Packets = table.clone(Universe.Outbox)
			table.clear(Universe.Outbox)
			return Packets
		end,
		Deliver = function(Packets)
			for _, Packet in Packets do
				(Packet :: any).Remote.OnServerEvent:Fire(Universe.Player, Packet.Buffer, Packet.Instances)
			end
			--> Packet defers every listener, and the benchmark counts calling them as decoding.
			World.Drain(Universe)
		end,
		Listen = Listen,
	}
end

return Tools
