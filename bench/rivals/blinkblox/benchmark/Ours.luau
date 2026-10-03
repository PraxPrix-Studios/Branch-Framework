--!strict
--- Branch's own benchmark workloads (Branch-Studio/tests/bench/core.luau) run on this harness's
--- World, so every tool pays for the same mocks, in a process of its own per row, natively compiled
--- and interpreted. Run from this directory:
---
---     lune run Ours                          every workload and tool
---     lune run Ours -- Cars                  only workloads whose name contains "Cars"
---     lune run Ours -- --frames 50           fewer frames
---     lune run Ours -- --tools branch,blink  only these tools
---
--- Vectors are Luau's native vectors (what Roblox's Vector3 is), handed to every tool as Vector3.
local fs = require("@lune/fs")
local process = require("@lune/process")
local runtime = require("../.lune/libs/runtime")
runtime.ballast()

local Attributes = require("../src/Modules/Attributes")
local Generator = require("../src/Generator")
local Names = require("./Names")
local Parser = require("../src/Parser")
local Tools = require("./runtime/Tools")
local World = require("./runtime/World")

local WARMUP_FRAMES = 10
local FRAME = 1 / 30
local ORDER = { "branch", "blink", "upstream", "quicknet", "warp" }

local Frames = 200
local Filter: string? = nil
local Only: { string }? = nil
local Cell: { Workload: string, Native: boolean, Name: string }? = nil
do
	local Index = 1
	while Index <= #process.args do
		local Argument = process.args[Index]
		if Argument == "--" then
			-- passed through by `lune run Ours -- ...`
		elseif Argument == "--frames" then
			Frames = assert(tonumber(process.args[Index + 1]), "--frames takes a number")
			Index += 1
		elseif Argument == "--tools" then
			Only = string.split(assert(process.args[Index + 1], "--tools takes a list"), ",")
			Index += 1
		elseif Argument == "--cell" then
			Cell = {
				Workload = process.args[Index + 1],
				Native = process.args[Index + 2] == "native",
				Name = process.args[Index + 3],
			}
			Index += 3
		else
			Filter = Argument
		end
		Index += 1
	end
end

local VECTOR = { new = vector.create, zero = vector.create(0, 0, 0), one = vector.create(1, 1, 1) }

-- The data, deterministic: the same on every run and host (core.luau's generator).
local seed = 1
local function random(low: number, high: number): number
	seed = (seed * 1103515245 + 12345) % 2147483648
	return low + math.floor(seed / 2147483648 * (high - low + 1))
end
local entities = {}
for _ = 1, 100 do
	table.insert(entities, {
		id = random(1, 255),
		x = random(1, 255),
		y = random(1, 255),
		z = random(1, 255),
		orientation = random(1, 255),
		animation = random(1, 255),
	})
end
local booleans = table.create(1000, true)
local move = {
	pos = vector.create(120.5, 3, -44.25),
	vel = vector.create(0, -9.8, 16),
	yaw = 1.25,
	grounded = true,
	crouch = false,
	sprint = true,
	anim = 7,
}
local cars = table.create(50)
for _ = 1, 50 do
	table.insert(cars, {
		brand = string.rep(string.char(random(0, 255)), random(2, 100)),
		carName = string.rep(string.char(random(0, 255)), random(2, 100)),
		carId = random(0, 65535),
		available = random(0, 1) == 1,
		dealers = random(0, 127),
		price = random(0, 1e9) * 1000,
	})
end

type Workload = {
	Name: string,
	Players: number,
	FromServer: boolean,
	Expected: number, -- events the loaded client (or the server) decodes a frame
	Event: string,
	Fire: (Server: any, Client: any, Universe: any) -> (),
}

local WORKLOADS: { Workload } = {
	{
		Name = "Cars (50 structs a frame, client to server)",
		Players = 1,
		FromServer = false,
		Expected = 50,
		Event = "Cars",
		Fire = function(_Server, Client)
			local Cars = Client.Cars
			for Index = 1, 50 do
				Cars.Fire(cars[Index])
			end
		end,
	},
	{
		Name = "Booleans (1000 booleans x10 a frame)",
		Players = 1,
		FromServer = false,
		Expected = 10,
		Event = "Booleans",
		Fire = function(_Server, Client)
			for _ = 1, 10 do
				Client.Booleans.Fire(booleans)
			end
		end,
	},
	{
		Name = "Entities (100 structs x10 a frame)",
		Players = 1,
		FromServer = false,
		Expected = 10,
		Event = "Entities",
		Fire = function(_Server, Client)
			for _ = 1, 10 do
				Client.Entities.Fire(entities)
			end
		end,
	},
	{
		Name = "Chat ((string, u8) x500 a frame)",
		Players = 1,
		FromServer = false,
		Expected = 500,
		Event = "Chat",
		Fire = function(_Server, Client)
			local Chat = Client.Chat
			for Index = 1, 500 do
				Chat.Fire("hello there", Index % 256)
			end
		end,
	},
	{
		Name = "Moves (server to 1 player x500 a frame)",
		Players = 1,
		FromServer = true,
		Expected = 500,
		Event = "Moves",
		Fire = function(Server, _Client, Universe)
			local Player = Universe.Player
			local Moves = Server.Moves
			for _ = 1, 500 do
				Moves.Fire(Player, move)
			end
		end,
	},
	{
		Name = "FireAll (Moves to 20 players x50 a frame)",
		Players = 20,
		FromServer = true,
		Expected = 50,
		Event = "Moves",
		Fire = function(Server)
			local Moves = Server.Moves
			for _ = 1, 50 do
				Moves.FireAll(move)
			end
		end,
	},
	{
		Name = "Unreliable moves (server to 1 player x200 a frame)",
		Players = 1,
		FromServer = true,
		Expected = 200,
		Event = "MovesU",
		Fire = function(Server, _Client, Universe)
			local Player = Universe.Player
			local Moves = Server.MovesU
			for _ = 1, 200 do
				Moves.Fire(Player, move)
			end
		end,
	},
}

local function Median(Samples: { number }): number
	table.sort(Samples)
	return Samples[math.clamp(math.ceil(#Samples * 0.5), 1, #Samples)]
end

local function Run(Tool: string, Workload: Workload, Native: boolean)
	local Universe: any = World.Universe(Native, Tools.Mounts(), Workload.Players, false)
	Universe.Vector3 = VECTOR
	local Mode = `runtime/ours/modes/{Tool}.luau`
	local ServerWorld = World.new(Universe, true)
	local Server = ServerWorld.Require(Mode)
	local ClientWorld = World.new(Universe, false)
	local Client = ClientWorld.Require(Mode)
	World.Settle(Universe)

	local Received = 0
	local Receiver = if Workload.FromServer then Client else Server
	Receiver[Workload.Event].On(function()
		Received += 1
	end)

	local EncodeTimes, DecodeTimes = {}, {}
	local Calls, Bytes, Largest = 0, 0, 0
	local Sender = if Workload.FromServer then ServerWorld else ClientWorld

	runtime.collect()
	for Frame = 1, WARMUP_FRAMES + Frames do
		table.clear(Universe.Outbox)
		table.clear(Universe.Inbox)
		Universe.Calls = 0
		Universe.Bytes = 0
		Received = 0

		local Start = os.clock()
		Workload.Fire(Server, Client, Universe)
		Sender.Heartbeat:Fire(FRAME)
		World.Drain(Universe)
		local Encoded = os.clock()

		local Packets = if Workload.FromServer then Universe.Inbox else Universe.Outbox
		for _, Packet in Packets do
			Largest = math.max(Largest, if Packet.Buffer then buffer.len(Packet.Buffer) else 0)
		end
		if Workload.FromServer then
			for _, Packet in Packets do
				Packet.Remote.OnClientEvent:Fire(Packet.Buffer, Packet.Instances)
			end
		else
			for _, Packet in Packets do
				Packet.Remote.OnServerEvent:Fire(Universe.Player, Packet.Buffer, Packet.Instances)
			end
		end
		World.Drain(Universe)
		local Decoded = os.clock()

		assert(
			Received == Workload.Expected,
			`{Tool} {Workload.Name}: frame {Frame} decoded {Received} events, expected {Workload.Expected}`
		)
		if Frame > WARMUP_FRAMES then
			table.insert(EncodeTimes, (Encoded - Start) * 1000)
			table.insert(DecodeTimes, (Decoded - Encoded) * 1000)
			Calls += Universe.Calls
			Bytes += Universe.Bytes
		end
	end

	return {
		Encode = Median(EncodeTimes),
		Decode = Median(DecodeTimes),
		Calls = Calls / Frames,
		Bytes = Bytes / Frames,
		Largest = Largest,
	}
end

local function Row(Workload: Workload, Native: boolean, Tool: string): string
	local Result = Run(Tool, Workload, Native)
	return `|{Names.Display(Tool)}|{if Native then "native" else "interpreted"}|{string.format(
		"%.3f|%.3f|%.3f",
		Result.Encode,
		Result.Decode,
		Result.Encode + Result.Decode
	)}|{string.format("%.0f", Result.Bytes)}|{string.format("%.1f", Result.Calls)}|{Result.Largest}|`
end

if Cell then
	for _, Workload in WORKLOADS do
		if Workload.Name == Cell.Workload then
			print(Row(Workload, Cell.Native, Cell.Name))
			return
		end
	end
	error(`no workload {Cell.Workload}`)
end

-- BlinkBlox's modules, compiled from this checkout (as Rivals.luau does)
do
	local Source = fs.readFile("./definitions/Ours.blink")
	local Tree = Parser.new("./definitions/", "Ours.blink", nil, Attributes.new(nil)):Parse(Source)
	fs.writeDir("./runtime/ours/blink")
	fs.writeFile("./runtime/ours/blink/Server.luau", Generator.Generate("Server", Tree))
	fs.writeFile("./runtime/ours/blink/Client.luau", Generator.Generate("Client", Tree))
end

runtime.notice("These timings")
print(`Branch's workloads, {Frames} frames, times in ms per frame (median), on {runtime.description}`)
for _, Workload in WORKLOADS do
	if Filter and not string.find(Workload.Name, Filter, 1, true) then
		continue
	end
	print("")
	print(`### {Workload.Name}`)
	print("")
	print("|Tool|Code|Encode (fire + flush)|Decode|Total|Bytes/frame|Remote calls/frame|Largest packet|")
	print("|---|---|---|---|---|---|---|---|")
	for _, Native in (if process.env.NATIVE_ONLY then { true } else { true, false }) do -- NATIVE_ONLY=1: native rows only
		for _, Tool in ORDER do
			if Only and not table.find(Only, Tool) then
				continue
			end
			local Child = process.exec(runtime.command, {
				"run",
				"Ours",
				"--",
				"--cell",
				Workload.Name,
				if Native then "native" else "interpreted",
				Tool,
				"--frames",
				tostring(Frames),
			})
			local Line = string.match(Child.stdout, "(|[^\n]*|)%s*$")
			if Child.ok and Line then
				print(Line)
			else
				print(`|{Names.Display(Tool)}|{if Native then "native" else "interpreted"}|failed: {string.sub(
					string.gsub(Child.stderr .. Child.stdout, "\n", " "),
					1,
					160
				)}|||||`)
			end
		end
	end
end
runtime.notice("These timings")
