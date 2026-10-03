--!strict
--- The server's per-player outbound budget, `option OutboundBytesPerSecond`, and the sends a
--- `Priority: Low` leaves out for it.
---
--- Every byte the server sends a player is charged to that player's bucket, wherever the remote call is
--- made: the reliable flush, the unreliable batches, an unbatched unreliable send. A send to everyone is
--- one addition to a shared total, which each bucket pays its share of when it is next read, rather than
--- one charge per player. Nothing is ever refused for the budget but a low-priority send: an event's to
--- a player whose bucket is spent is dropped, and a low stream held per player waits for that player
--- until it refills, then sends the state it holds by then.
---
--- The runtime and every charge are spliced in only when the option is set. A module without it is
--- exactly what it was, and the budget costs its sends nothing.
local State = require("./State")
local Template = require("../Templates/Outbound")

local Outbound = {}

--- Whether this module keeps an outbound budget: a server's, with the option set.
function Outbound.Enabled(): boolean
	return State.Context == "Server" and State.Options.OutboundBytesPerSecond ~= nil
end

--- Whether a declaration of this priority is left out for the budget in this module.
function Outbound.Low(Priority: string?): boolean
	return Priority == "Low" and Outbound.Enabled()
end

--- Replaces the one occurrence of `Old` in `Source`. The templates are fixed text, so a splice that no
--- longer finds its line, or finds it twice, is an error here rather than a charge that silently stops.
local function Replace(Source: string, Old: string, New: string): string
	local Start, Finish = string.find(Source, Old, 1, true)
	assert(Start and Finish, `[BlinkBlox]: The outbound budget did not find its line in the template: {Old}`)
	assert(
		not string.find(Source, Old, Finish + 1, true),
		`[BlinkBlox]: The outbound budget found its line twice: {Old}`
	)
	return string.sub(Source, 1, Start - 1) .. New .. string.sub(Source, Finish + 1)
end

--- Adds the charge `Charge` after each remote call in `Calls`, a list of `{ Call, Charge }`.
local function Charge(Source: string, Calls: { { string } }): string
	if not Outbound.Enabled() then
		return Source
	end

	for _, Pair in Calls do
		Source = Replace(Source, Pair[1], Pair[1] .. Pair[2])
	end

	return Source
end

--> The reliable flush in Templates/Server.luau: a player's own batch, then the broadcast batch, to
--> everyone at once or to each player who did not take it in their own.
local FLUSH = {
	{
		"            Reliable:FireClient(Player, Buffer, Send.Instances)\n",
		"            OutboundCharge(Player, Used)\n",
	},
	{ "            Reliable:FireAllClients(Buffer, SharedInstances)\n", "            OutboundShared += Shared\n" },
	{
		"                    Reliable:FireClient(Player, Buffer, SharedInstances)\n",
		"                    OutboundCharge(Player, Shared)\n",
	},
}

--> The unreliable batches in Generator/Batches.luau: a batch sent whole, and the part of one sent ahead
--> of an event that did not fit beside it.
local BATCHES = {
	{ "        Unreliable:FireClient(Player, Packet, Batch.Instances)\n", "        OutboundCharge(Player, Used)\n" },
	{ "        Unreliable:FireAllClients(Packet, Batch.Instances)\n", "        OutboundShared += Used\n" },
	{ "            Unreliable:FireClient(Player, Packet, Before)\n", "            OutboundCharge(Player, Start)\n" },
	{ "            Unreliable:FireAllClients(Packet, Before)\n", "            OutboundShared += Start\n" },
}

--> The step over streams held per player in Templates/Stream.luau. A low family skips a player whose
--> budget is spent, so the stream's state for them is neither sent nor counted as sent.
local STEP = "        for _, Stream in Family.Players do\n            StepStream(Stream, Delta)\n"
local STEP_LOW = table.concat({
	"        local Low = OutboundLow[Family] == true\n",
	"        for Player, Stream in Family.Players do\n",
	"            if Low and OutboundSpent(Player) then\n",
	"                continue\n",
	"            end\n",
	"            StepStream(Stream, Delta)\n",
})

--- The server template with the reliable flush charged.
function Outbound.Flush(Source: string): string
	return Charge(Source, FLUSH)
end

--- The server's unreliable batches with every send charged.
function Outbound.Batches(Source: string): string
	return Charge(Source, BATCHES)
end

--- The server's stream runtime, stepping a low family only for players with budget left.
function Outbound.Streams(Source: string): string
	if not Outbound.Enabled() then
		return Source
	end

	return Replace(Source, STEP, STEP_LOW)
end

--- The budget's runtime, or nothing. The burst is a second of the rate unless the schema says.
function Outbound.Body(): { string }
	if not Outbound.Enabled() then
		return {}
	end

	local Rate = State.Options.OutboundBytesPerSecond :: number
	local Burst = State.Options.OutboundBurst or Rate
	return {
		`\nlocal OUTBOUND_RATE = {Rate}\n`,
		`local OUTBOUND_BURST = {Burst}\n`,
		Template,
	}
end

return Outbound
