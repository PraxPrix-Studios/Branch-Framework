--!strict
--- What each tool's modules cost, measured without Roblox. Run from this directory:
---
---     luneblox run Runtime                   every bench, natively compiled and interpreted
---     luneblox run Runtime -- Entities       only the benches whose name contains "Entities"
---     luneblox run Runtime -- --frames 50    fewer frames, for a quick look
---     luneblox run Runtime -- --tools blink,zap  only these tools
---     luneblox run Runtime -- --traffic      BlinkBlox built with option TrafficStats, to price it
---
--- Studio's own benchmark (run.luau, generate.luau) reports frame rate and bandwidth, and neither
--- isolates a tool's own work: Studio caps the frame rate at 60, and Roblox compresses each packet
--- before counting its bytes. This one times the three things a tool does -- a frame's thousand
--- Fires, the flush that turns them into packets, and the server decoding those packets and calling
--- its listener -- each on its own, and counts the bytes each event cost: as the encoder wrote them,
--- and after zstd, which is what Roblox compresses a remote's packets with.
---
--- It runs every tool Studio compares -- BlinkBlox, Blink, zap, ByteNet, Packet, QuickNet, Warp -- on the same pools, so
--- the tools can be compared where Studio cannot: interpreted, as most Roblox clients run code, and
--- decoding, which Studio does not time. See runtime/Tools.luau for how each is loaded.
---
--- Each bench runs twice per tool. `native` is what a Roblox server runs: modules that declare
--- `--!native` natively compiled, and the rest interpreted -- Packet declares it nowhere, so its two
--- rows are both interpreted. `interpreted` is what most players' clients run.
local fs = require("@lune/fs")
local process = require("@lune/process")
local runtime = require("../.lune/libs/runtime")
runtime.ballast()
local serde = require("@lune/serde")

local Attributes = require("../src/Modules/Attributes")
local Generator = require("../src/Generator")
local Names = require("./Names")
local Parser = require("../src/Parser")
local Tools = require("./runtime/Tools")

local EVENTS_PER_FRAME = 1000
local WARMUP_FRAMES = 10
local BENCHES = { "Booleans", "Entities", "BooleansRandom", "EntitiesRandom", "Tiny" }
--> Benches only this file runs. The rest are Studio's, shared with it.
local LOCAL_BENCHES = { Tiny = true }

local Frames = 200
local Filter: string? = nil
local Only: { string }? = nil
local Traffic = false
local SourcesDirectory: string? = nil
--> Set in a child: the one bench, mode and tool it times; see the loop at the end.
local Cell: { Bench: string, Native: boolean, Name: string }? = nil
do
	local Index = 1
	while Index <= #process.args do
		local Argument = process.args[Index]
		if Argument == "--" then
			--> What `luneblox run Runtime -- ...` passes through ahead of the arguments.
		elseif Argument == "--frames" then
			Frames = assert(tonumber(process.args[Index + 1]), "--frames takes a number")
			Index += 1
		elseif Argument == "--sources" then
			SourcesDirectory = assert(process.args[Index + 1], "--sources takes a directory")
			Index += 1
		elseif Argument == "--traffic" then
			Traffic = true
		elseif Argument == "--cell" then
			Cell = {
				Bench = assert(process.args[Index + 1], "--cell takes a bench, a mode and a tool"),
				Native = process.args[Index + 2] == "native",
				Name = assert(process.args[Index + 3], "--cell takes a bench, a mode and a tool"),
			}
			Index += 3
		elseif Argument == "--tools" then
			Only = string.split(assert(process.args[Index + 1], "--tools takes a list"), ",")
			Index += 1
		else
			Filter = Argument
		end
		Index += 1
	end
end

--> The schema Studio's benchmark compiles, with the client flushing when told to rather than on a
--> Heartbeat that does not exist here.
local function Generate(): (string, string)
	--> Another version's modules, generated from the same schema with `option ManualReplication = true`:
	--> the only way to time two versions in one harness.
	if SourcesDirectory then
		return fs.readFile(`{SourcesDirectory}/Server.luau`), fs.readFile(`{SourcesDirectory}/Client.luau`)
	end
	local Source = fs.readFile("./definitions/Definition.blink")
	local Tree = Parser.new("./definitions/", "Definition.blink", nil, Attributes.new(nil)):Parse(Source)
	Tree.Value.Options.ManualReplication = true
	Tree.Value.Options.TrafficStats = Traffic

	return Generator.Generate("Server", Tree), Generator.Generate("Client", Tree)
end

local function LoadPool(Name: string): { any }
	--> As benches/init.luau does in Studio, so each pool is the same on every run.
	math.randomseed(0)
	local Directory = if LOCAL_BENCHES[Name] then "./runtime/benches" else "./src/shared/benches"
	return (require :: any)(`{Directory}/{Name}`)
end

local function Percentile(Sorted: { number }, Percent: number): number
	return Sorted[math.clamp(math.ceil(#Sorted * Percent), 1, #Sorted)]
end

type Summary = { Median: number, P90: number, P99: number }

local function Summarise(Samples: { number }): Summary
	table.sort(Samples)
	return {
		Median = Percentile(Samples, 0.5),
		P90 = Percentile(Samples, 0.9),
		P99 = Percentile(Samples, 0.99),
	}
end

type Result = {
	Fire: Summary,
	Flush: Summary,
	Decode: Summary,
	Bytes: number,
	Compressed: number,
}

--> Roblox compresses what a remote sends with zstd. Its level is not documented; this is Lune's.
local function Compressed(Packets: { Tools.Sent }): number
	local Total = 0
	for _, Packet in Packets do
		Total += #serde.compress("zstd", buffer.tostring(Packet.Buffer))
	end
	return Total
end

local function Run(Tool: Tools.Tool, Bench: string, Pool: { any }): Result
	local Fire = Tool.Fire
	local Flush = Tool.Flush
	local Deliver = Tool.Deliver

	local Received = 0
	local First: any = nil
	Tool.Listen(function(Value)
		Received += 1
		if First == nil then
			First = Value
		end
	end)

	local FireTimes, FlushTimes, DecodeTimes = {}, {}, {}
	local Bytes, CompressedBytes, Compressions = 0, 0, 0
	local PoolSize = #Pool
	local Sent = 0

	runtime.collect()
	for Frame = 1, WARMUP_FRAMES + Frames do
		local Start = os.clock()
		for _ = 1, EVENTS_PER_FRAME do
			Fire(Pool[Sent % PoolSize + 1])
			Sent += 1
		end
		local Fired = os.clock()
		local Packets = Flush()
		local Flushed = os.clock()
		assert(#Packets > 0, `{Bench}: the client flushed nothing`)

		local DecodeStart = os.clock()
		Deliver(Packets)
		local Decoded = os.clock()

		if Frame > WARMUP_FRAMES then
			table.insert(FireTimes, (Fired - Start) * 1000)
			table.insert(FlushTimes, (Flushed - Fired) * 1000)
			table.insert(DecodeTimes, (Decoded - DecodeStart) * 1000)
			for _, Packet in Packets do
				Bytes += buffer.len(Packet.Buffer)
			end
			--> Compressing every frame would take longer than the run; a tenth of them is plenty.
			if Frame % 10 == 0 then
				Compressions += 1
				CompressedBytes += Compressed(Packets)
			end
		end
	end

	--> A benchmark of a codec that decodes the wrong thing measures nothing.
	assert(Received == Sent, `{Bench}: the server received {Received} of {Sent} events`)
	if type(First) == "table" then
		assert(#First == #Pool[1], `{Bench}: the first event decoded to a different length`)
	else
		assert(First == Pool[1], `{Bench}: the first event decoded to a different value`)
	end

	return {
		Fire = Summarise(FireTimes),
		Flush = Summarise(FlushTimes),
		Decode = Summarise(DecodeTimes),
		Bytes = Bytes / (Frames * EVENTS_PER_FRAME),
		Compressed = CompressedBytes / (Compressions * EVENTS_PER_FRAME),
	}
end

local function Format(Value: number): string
	return string.format("%.3f", Value)
end

--- One tool's row for one bench and mode.
local function Row(Bench: string, Native: boolean, Name: string): string
	local ServerSource, ClientSource = Generate()
	local Sources = { Server = ServerSource, Client = ClientSource }
	--> A fresh load per run: listeners, buffers and the inbound budget start from nothing.
	local Result = Run(Tools.Load(Name, Native, Bench, Sources), Bench, LoadPool(Bench))
	local Cells: { string } = {
		Names.Display(Name),
		if Native then "native" else "interpreted",
		Format(Result.Fire.Median),
		Format(Result.Fire.P99),
		Format(Result.Flush.Median),
		Format(Result.Decode.Median),
		Format(Result.Decode.P99),
		string.format("%.2f", Result.Bytes),
		string.format("%.2f", Result.Compressed),
	}
	return `|{table.concat(Cells, "|")}|`
end

if Cell then
	print(Row(Cell.Bench, Cell.Native, Cell.Name))
	return
end

local Selected: { string } = {}
for _, Name in Tools.ORDER do
	if Only and not table.find(Only, Name) then
		continue
	end
	local Missing = Tools.Missing(Name)
	if Missing then
		print(`Skipping {Name}: {Missing}`)
	else
		table.insert(Selected, Name)
	end
end

runtime.notice("These timings")
local Label = if SourcesDirectory then `modules from {SourcesDirectory}` else _G.VERSION or "(unbundled)"
print(
	`BlinkBlox {Label}{if Traffic then " with TrafficStats" else ""}, {Frames} frames of {EVENTS_PER_FRAME} events, times in ms per frame, on {runtime.description}`
)

for _, Bench in BENCHES do
	if Filter and not string.find(Bench, Filter, 1, true) then
		continue
	end

	print("")
	print(`### {Bench}`)
	print("")
	print("|Tool|Code|Fire median|Fire p99|Flush median|Decode median|Decode p99|Bytes/event|zstd bytes/event|")
	print("|---|---|---|---|---|---|---|---|---|")

	--> Each row in a process of its own. In one process every tool inherited the heap and the
	--> allocator's state the ones before it left, and the first paid for growing them: BlinkBlox,
	--> always first, decoded Booleans natively in 6.5 ms, and in 2.9 when it ran last, where QuickNet
	--> took 3.6 in sixth place and 7.4 in first. Every row now starts from the same process.
	for _, Native in (if process.env.NATIVE_ONLY then { true } else { true, false }) do -- NATIVE_ONLY=1: native rows only
		for _, Name in Selected do
			if LOCAL_BENCHES[Bench] and Name ~= "blink" and Name ~= "branch" then
				--> Only BlinkBlox's definition declares the benches Studio does not run.
				continue
			end

			local Arguments = { "run", "Runtime", "--", "--cell", Bench, if Native then "native" else "interpreted" }
			table.insert(Arguments, Name)
			table.insert(Arguments, "--frames")
			table.insert(Arguments, tostring(Frames))
			if SourcesDirectory then
				table.insert(Arguments, "--sources")
				table.insert(Arguments, SourcesDirectory)
			end
			if Traffic then
				table.insert(Arguments, "--traffic")
			end
			local Child = process.exec(runtime.command, Arguments)
			local Line = string.match(Child.stdout, "(|[^\n]*|)%s*$")
			if Child.ok and Line then
				print(Line)
			else
				error(`{Name} failed on {Bench}:\n{Child.stderr}{Child.stdout}`, 0)
			end
		end
	end
end

runtime.notice("These timings")
