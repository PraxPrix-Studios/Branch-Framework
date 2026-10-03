--!strict
--- `option TrafficStats`: counters of what the module sends and receives, read with GetTrafficStats.
---
--- Everything here emits nothing unless the option is on, so a module built without it is exactly the
--- module it always was. With it on, the counters are one preallocated array of numbers, and each
--- count is an add at an index fixed at compile time: nothing is allocated, and no string is looked
--- up, on the way an event is sent or received.
---
--- The array is laid out in blocks of four, each block `SentBytes, Sent, ReceivedBytes, Received`.
--- The reliable channel is the block at 1 and the unreliable channel the block at 5; each event
--- declaration takes the next block from 9 on, in the order the declarations are generated. A
--- channel counts packets, an event counts events. Bytes are what the buffer carries: an event's
--- index, its sequence number when it is ordered, and its payload, but not the Instances that ride
--- beside the buffer, nor what Roblox adds around a remote call.
local Blocks = require("./Blocks")
local Settings = require("../Settings")
local Size = require("../Modules/Size")
local State = require("./State")
local Util = require("./Util")

local Traffic = {}

--- The block of each channel. Events start after both.
local RELIABLE = 1
local UNRELIABLE = 5
local FIRST_EVENT = 9

--- The names of the returned table's fields, in each casing, as the generated API's members are.
local FIELDS: { [string]: { string } } = {
	Events = { "Events", "events", "events" },
	Reliable = { "Reliable", "reliable", "reliable" },
	Unreliable = { "Unreliable", "unreliable", "unreliable" },
	Sent = { "Sent", "sent", "sent" },
	SentBytes = { "SentBytes", "sentBytes", "sent_bytes" },
	Received = { "Received", "received", "received" },
	ReceivedBytes = { "ReceivedBytes", "receivedBytes", "received_bytes" },
}

--- The event names in the order their blocks were handed out, and each one's size in bytes when
--- every value of it takes the same number, or 0. Cleared at the start of each run.
local Names: { string } = {}
local Sizes: { number } = {}

--- The size of an event of that block, or nil when it varies.
local function Fixed(Base: number): number?
	local Bytes = Sizes[(Base - FIRST_EVENT) // 4 + 1]
	return if Bytes > 0 then Bytes else nil
end

local function Enabled(): boolean
	return State.Options.TrafficStats == true
end

--- The fields in the casing in force.
local function Fields(): { [string]: string }
	local Index = Settings.Casings[(State.Options.Casing :: string?) or "Pascal"] or 1
	local Spelled: { [string]: string } = {}
	for Field, Spellings in FIELDS do
		Spelled[Field] = Spellings[Index]
	end
	return Spelled
end

function Traffic.Reset()
	table.clear(Names)
	table.clear(Sizes)
end

--- Hands an event its block, and returns where the block starts; nil when the option is off, which
--- every other function here takes as "emit nothing". The name is the event's path, `Scope.Event`
--- inside a scope, which is also how the game reaches it on the module.
---
--- An event whose every value takes the same number of bytes -- the size analysis says so when its
--- least and most agree, and the suite holds the analysis to what is written -- counts events alone,
--- and GetTrafficStats multiplies. That halves what counting costs the events that cost least.
function Traffic.Register(Name: string, Data: any?, Ordered: boolean): number?
	if not Enabled() then
		return nil
	end

	local Header = 1 + (if Ordered then Size.OrderingBytes else 0)
	local Payload = if Data then Size.Sealed(Data) else nil
	local Bytes = if not Payload then Header elseif Payload.Min == Payload.Max then Header + Payload.Min else 0

	table.insert(Names, `{Util.GetScopePrefix(nil, true, State.Scope)}{Name}`)
	table.insert(Sizes, Bytes)
	return FIRST_EVENT + (#Names - 1) * 4
end

--- Counts one event sent. `Bytes` is an expression for the bytes it took in the buffer, and `Times`,
--- when given, an expression for how many recipients it went to at once. `Unreliable` counts the
--- packets too, since an unreliable event is a packet of its own; a reliable one is counted as a
--- packet by the flush that sends the batch it joined. `Prefix` indents raw lines.
function Traffic.Sent(
	Target: Blocks.Block,
	Base: number?,
	Bytes: string,
	Unreliable: boolean,
	Times: string?,
	Prefix: string?
)
	if not Base then
		return
	end

	local Indent = Prefix or ""
	local Total = if Times then `{Bytes} * {Times}` else Bytes
	local Count = Times or "1"
	if not Fixed(Base) then
		Target:Line(`{Indent}TrafficCounters[{Base}] += {Total}`)
	end
	Target:Line(`{Indent}TrafficCounters[{Base + 1}] += {Count}`)
	if Unreliable then
		Target:Line(`{Indent}TrafficCounters[{UNRELIABLE}] += {Total}`)
		Target:Line(`{Indent}TrafficCounters[{UNRELIABLE + 1}] += {Count}`)
	end
end

--- Where an event of varying size starts, emitted in its receive branch ahead of the decode. The
--- cursor is past the index and, for an ordered event, the sequence number: the branch's own reads
--- are declared at its top, so they precede this line wherever it is written.
function Traffic.Start(Target: Blocks.Block, Base: number?, Ordered: boolean)
	if Base and not Fixed(Base) then
		local Header = 1 + (if Ordered then Size.OrderingBytes else 0)
		Target:Line(`local TrafficStart = RecieveCursor - {Header}`)
	end
end

--- Counts one event received, once it has been decoded: from where Start found it began to where its
--- payload ended.
function Traffic.Received(Target: Blocks.Block, Base: number?)
	if not Base then
		return
	end

	if not Fixed(Base) then
		Target:Line(`TrafficCounters[{Base + 2}] += RecieveCursor - TrafficStart`)
	end
	Target:Line(`TrafficCounters[{Base + 3}] += 1`)
end

--- Counts a packet received on a channel, once the connection has taken its length into `Size`.
function Traffic.Packet(Target: Blocks.Block, Unreliable: boolean)
	if Enabled() then
		local Base = if Unreliable then UNRELIABLE else RELIABLE
		Target:Line(`TrafficCounters[{Base + 2}] += Size`, 1)
		Target:Line(`TrafficCounters[{Base + 3}] += 1`, 1)
	end
end

--- Counts the reliable flush in the context's template, after the line that fires it. The template
--- is fixed text, so the count goes in after an anchor, and an anchor that is missing or found twice
--- is an error here rather than a count that silently stops.
local FLUSHES = {
	Server = { "            Reliable:FireClient(Player, Buffer, Send.Instances)\n", "            " },
	Client = { "        Reliable:FireServer(Buffer, SendInstances)\n", "        " },
}

function Traffic.Template(Source: string): string
	local Flush = FLUSHES[State.Context]
	if not Enabled() or not Flush then
		return Source
	end

	local Anchor, Indent = Flush[1], Flush[2]
	local Start, Finish = string.find(Source, Anchor, 1, true)
	assert(Start and Finish, "[BlinkBlox]: The reliable flush was not found in the template.")
	assert(not string.find(Source, Anchor, Finish + 1, true), "[BlinkBlox]: The reliable flush was found twice.")

	local Count = `{Indent}TrafficCounters[{RELIABLE}] += Used\n{Indent}TrafficCounters[{RELIABLE + 1}] += 1\n`
	return string.sub(Source, 1, Finish) .. Count .. string.sub(Source, Finish + 1)
end

--- The counters, their types and the two functions that read and clear them, spliced into the module
--- ahead of the edit-mode stub, which hands out the same functions: with no remotes nothing is
--- counted, so they report zeros for every event.
function Traffic.Body(): { string }
	if not Enabled() then
		return {}
	end

	local F = Fields()
	local Quoted: { string } = {}
	for _, Name in Names do
		table.insert(Quoted, `"{Name}"`)
	end

	local Sized: { string } = {}
	for _, Bytes in Sizes do
		table.insert(Sized, tostring(Bytes))
	end

	local Counts = `\{ {F.Sent}: number, {F.SentBytes}: number, {F.Received}: number, {F.ReceivedBytes}: number \}`
	return {
		"\n",
		"--> Traffic counters (option TrafficStats), in blocks of four: bytes and count sent, bytes and\n",
		"--> count received. The reliable channel is the block at 1, the unreliable at 5, each event the\n",
		"--> next from 9 on, in the order of TRAFFIC_NAMES. A channel counts packets, an event events.\n",
		"--> An event of one size only counts events; TRAFFIC_SIZES has its size, and 0 for the rest.\n",
		`local TRAFFIC_NAMES: \{ string } = table.freeze(\{ {table.concat(Quoted, ", ")} })\n`,
		`local TRAFFIC_SIZES: \{ number } = table.freeze(\{ {table.concat(Sized, ", ")} })\n`,
		`local TrafficCounters: \{ number } = table.create({FIRST_EVENT - 1} + #TRAFFIC_NAMES * 4, 0)\n`,
		"\n",
		`type BLINK_TRAFFIC_COUNTS = {Counts}\n`,
		`type BLINK_TRAFFIC_STATS = \{ {F.Events}: \{ [string]: BLINK_TRAFFIC_COUNTS }, {F.Reliable}: BLINK_TRAFFIC_COUNTS, {F.Unreliable}: BLINK_TRAFFIC_COUNTS }\n`,
		"\n",
		"local function TrafficCounts(Base: number, Bytes: number): BLINK_TRAFFIC_COUNTS\n",
		"\treturn {\n",
		`\t\t{F.Sent} = TrafficCounters[Base + 1],\n`,
		`\t\t{F.SentBytes} = if Bytes > 0 then TrafficCounters[Base + 1] * Bytes else TrafficCounters[Base],\n`,
		`\t\t{F.Received} = TrafficCounters[Base + 3],\n`,
		`\t\t{F.ReceivedBytes} = if Bytes > 0 then TrafficCounters[Base + 3] * Bytes else TrafficCounters[Base + 2],\n`,
		"\t}\n",
		"end\n",
		"\n",
		"--> A fresh table on every call, so the game may keep one and compare it with the next.\n",
		"local function GetTrafficStats(): BLINK_TRAFFIC_STATS\n",
		"\tlocal Events: { [string]: BLINK_TRAFFIC_COUNTS } = {}\n",
		"\tfor Index, Name in TRAFFIC_NAMES do\n",
		`\t\tEvents[Name] = TrafficCounts({FIRST_EVENT - 4} + Index * 4, TRAFFIC_SIZES[Index])\n`,
		"\tend\n",
		"\n",
		"\treturn {\n",
		`\t\t{F.Events} = Events,\n`,
		`\t\t{F.Reliable} = TrafficCounts({RELIABLE}, 0),\n`,
		`\t\t{F.Unreliable} = TrafficCounts({UNRELIABLE}, 0),\n`,
		"\t}\n",
		"end\n",
		"\n",
		"local function ResetTrafficStats()\n",
		"\tfor Index = 1, #TrafficCounters do\n",
		"\t\tTrafficCounters[Index] = 0\n",
		"\tend\n",
		"end\n",
	}
end

--- The two members, on the module and on its edit-mode stub.
function Traffic.Members()
	if not Enabled() then
		return
	end

	State.Return.Push(`{State.Casing.GetTrafficStats} = GetTrafficStats,`, 1, 1)
	State.Noop.Push(`{State.Casing.GetTrafficStats} = GetTrafficStats,`, 0, 2)
	State.Return.Push(`{State.Casing.ResetTrafficStats} = ResetTrafficStats,`, 1, 1)
	State.Noop.Push(`{State.Casing.ResetTrafficStats} = ResetTrafficStats,`, 0, 2)
end

--- The TypeScript declarations of the two members, typed as the Luau module types them.
function Traffic.Typescript(Options: { [string]: any }, Casing: Settings.Cases): { string }
	if Options.TrafficStats ~= true then
		return {}
	end

	local Index = Settings.Casings[Options.Casing or "Pascal"] or 1
	local function Field(Name: string): string
		return FIELDS[Name][Index]
	end

	local Counts = `\{ {Field("Sent")}: number; {Field("SentBytes")}: number; {Field("Received")}: number; {Field(
		"ReceivedBytes"
	)}: number \}`
	local Stats =
		`\{ {Field("Events")}: Record<string, {Counts}>; {Field("Reliable")}: {Counts}; {Field("Unreliable")}: {Counts} \}`
	return {
		`export declare const {Casing.GetTrafficStats}: () => {Stats}`,
		`export declare const {Casing.ResetTrafficStats}: () => void`,
	}
end

return Traffic
