--!strict
--- Scenarios.luau's paths, run on every tool the benchmark compares. Run from this directory, after
--- `luneblox run build --download` has fetched the tools and packages:
---
---     luneblox run Rivals                      every scenario and tool, natively compiled and interpreted
---     luneblox run Rivals -- Broadcast         only the scenarios whose name contains "Broadcast"
---     luneblox run Rivals -- --frames 50       fewer frames
---     luneblox run Rivals -- --tools blink,zap only these tools
---     luneblox run Rivals -- --batch           BlinkBlox with option BatchUnreliable
---
--- Every tool loads through World.luau here, BlinkBlox included, so each pays for the same mocks: a
--- remote call costs the same whoever makes it. Each flushes on its own Heartbeat, as it would in a
--- game. The events are definitions/Scenarios.blink's, declared for each tool in
--- definitions/Scenarios.zap, definitions/Scenarios.upstream.blink and runtime/rivals/modes.
--- BlinkBlox sends state here as plain unreliable events, as the others must: its streams have no
--- counterpart to compare with, and Scenarios.luau times them.
---
--- Packet has no unreliable channel, so it runs only the reliable scenarios, and a scenario a tool
--- cannot run is left out of its rows rather than run another way.
local fs = require("@lune/fs")
local process = require("@lune/process")
local runtime = require("../.lune/libs/runtime")
runtime.ballast()

local Apis = require("./runtime/rivals/Apis")
local Attributes = require("../src/Modules/Attributes")
local Generator = require("../src/Generator")
local Names = require("./Names")
local Parser = require("../src/Parser")
local Tools = require("./runtime/Tools")
local World = require("./runtime/World")

local WARMUP_FRAMES = 10
--> What each Heartbeat tells the tools a frame took; see the same constant in runtime/Tools.luau.
local FRAME = 1 / 30

local ORDER = { "blink", "branch", "upstream", "zap", "bytenet", "packet", "quicknet", "warp" }
local REQUIRES: { [string]: { string } } = {
	upstream = { "runtime/rivals/upstream/Server.luau" },
	zap = { "runtime/rivals/zap/Server.luau" },
	bytenet = { "packages/bytenet/init.luau" },
	packet = { "packages/packet/init.luau" },
	quicknet = { "packages/quicknet/init.luau" },
	warp = { "packages/warp/init.luau" },
	branch = { "packages/branch/Scenarios/Server.luau" },
}

local Frames = 200
--> `--batch`: BlinkBlox built with option BatchUnreliable, which gathers a frame's unreliable events.
local Batch = false
local Filter: string? = nil
local Only: { string }? = nil
do
	local Index = 1
	while Index <= #process.args do
		local Argument = process.args[Index]
		if Argument == "--" then
			--> What `luneblox run Rivals -- ...` passes through ahead of the arguments.
		elseif Argument == "--batch" then
			Batch = true
		elseif Argument == "--frames" then
			Frames = assert(tonumber(process.args[Index + 1]), "--frames takes a number")
			Index += 1
		elseif Argument == "--tools" then
			Only = string.split(assert(process.args[Index + 1], "--tools takes a list"), ",")
			Index += 1
		else
			Filter = Argument
		end
		Index += 1
	end
end

--> BlinkBlox's modules, compiled from this tree into the directory its mode requires.
do
	local Source = fs.readFile("./definitions/Scenarios.blink")
	local Tree = Parser.new("./definitions/", "Scenarios.blink", nil, Attributes.new(nil)):Parse(Source)
	Tree.Value.Options.BatchUnreliable = Batch
	fs.writeDir("./runtime/rivals/blink")
	fs.writeFile("./runtime/rivals/blink/Server.luau", Generator.Generate("Server", Tree))
	fs.writeFile("./runtime/rivals/blink/Client.luau", Generator.Generate("Client", Tree))
end

local function Missing(Name: string): string?
	for _, Path in REQUIRES[Name] or {} do
		if not fs.isFile(Path) then
			return `{Path} is missing; run \`luneblox run build --download\` first`
		end
	end
	return nil
end

local function Median(Samples: { number }): number
	table.sort(Samples)
	return Samples[math.clamp(math.ceil(#Samples * 0.5), 1, #Samples)]
end

type Result = { Fire: number, Flush: number, Decode: number, Calls: number, Bytes: number }

local function Run(Tool: string, Scenario: any, Api: Apis.Api, Native: boolean): Result
	local Universe = World.Universe(Native, Tools.Mounts(), Scenario.Players, Scenario.Instances == true)
	local Parts = {}
	for Index = 1, 16 do
		Parts[Index] = World.Part(`Part{Index}`)
	end
	(Universe :: any).Parts = Parts

	local Mode = `runtime/rivals/modes/{Tool}.luau`
	local ServerWorld = World.new(Universe, true)
	local Server = ServerWorld.Require(Mode)
	local ClientWorld = World.new(Universe, false)
	local Client = ClientWorld.Require(Mode)
	World.Settle(Universe)

	local Received = 0
	Api.Listen(Server, Client, function()
		Received += 1
	end)

	local FireTimes, FlushTimes, DecodeTimes = {}, {}, {}
	local Calls, Bytes = 0, 0
	local Sender = if Scenario.FromServer then ServerWorld else ClientWorld

	runtime.collect()
	for Frame = 1, WARMUP_FRAMES + Frames do
		table.clear(Universe.Outbox)
		table.clear(Universe.Inbox)
		Universe.Calls = 0
		Universe.Bytes = 0
		Received = 0

		local Start = os.clock()
		Api.Fire(Server, Client, Universe, Frame)
		local Fired = os.clock()
		Sender.Heartbeat:Fire(FRAME)
		World.Drain(Universe)
		local Flushed = os.clock()

		if Scenario.FromServer then
			for _, Packet in Universe.Inbox do
				(Packet :: any).Remote.OnClientEvent:Fire(Packet.Buffer, Packet.Instances)
			end
		else
			for _, Packet in Universe.Outbox do
				(Packet :: any).Remote.OnServerEvent:Fire(Universe.Player, Packet.Buffer, Packet.Instances)
			end
		end
		World.Drain(Universe)
		local Decoded = os.clock()

		assert(
			Received == Scenario.Expected,
			`{Tool} {Scenario.Name}: frame {Frame} decoded {Received} events, expected {Scenario.Expected}`
		)

		if Frame > WARMUP_FRAMES then
			table.insert(FireTimes, (Fired - Start) * 1000)
			table.insert(FlushTimes, (Flushed - Fired) * 1000)
			table.insert(DecodeTimes, (Decoded - Flushed) * 1000)
			Calls += Universe.Calls
			Bytes += Universe.Bytes
		end
	end

	return {
		Fire = Median(FireTimes),
		Flush = Median(FlushTimes),
		Decode = Median(DecodeTimes),
		Calls = Calls / Frames,
		Bytes = Bytes / Frames,
	}
end

local Selected: { string } = {}
for _, Name in ORDER do
	if Only and not table.find(Only, Name) then
		continue
	end
	local Reason = Missing(Name)
	if Reason then
		print(`Skipping {Name}: {Reason}`)
	else
		table.insert(Selected, Name)
	end
end

runtime.notice("These timings")
print(
	`BlinkBlox {_G.VERSION or "(unbundled)"}, {Frames} frames, times in ms per frame, {Apis.CROWD} players where a crowd, on {runtime.description}`
)

for _, Scenario in Apis.SCENARIOS do
	if Filter and not string.find(Scenario.Name, Filter, 1, true) then
		continue
	end

	print("")
	print(`### {Scenario.Name}`)
	print("")
	print("|Tool|Code|Fire median|Flush median|Decode median|Remote calls/frame|Bytes/frame|")
	print("|---|---|---|---|---|---|---|")

	for _, Native in (if process.env.NATIVE_ONLY then { true } else { true, false }) do -- NATIVE_ONLY=1: native rows only
		for _, Tool in Selected do
			local Api = Apis.APIS[Tool][Scenario.Name]
			if not Api then
				continue
			end

			local Result = Run(Tool, Scenario, Api, Native)
			local Cells: { string } = {
				Names.Display(Tool),
				if Native then "native" else "interpreted",
				string.format("%.3f", Result.Fire),
				string.format("%.3f", Result.Flush),
				string.format("%.3f", Result.Decode),
				string.format("%.1f", Result.Calls),
				string.format("%.1f", Result.Bytes),
			}
			print(`|{table.concat(Cells, "|")}|`)
		end
	end
end

runtime.notice("These timings")
