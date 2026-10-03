--!strict
--!native
--!optimize 2

--- The runtime pieces a module carries only when its schema needs them: sequence numbers for ordered
--- events, the unreliable size check, the rate buckets' template, and the packet limits a client cuts
--- its batch to fit. Each is a list of lines, empty when not needed.
---
--- Moved out of init.luau when that file reached its size cap.
local Fragments = require("./Fragments")
local State = require("./State")

local DEFAULT_MAX_EVENTS_PER_PACKET = Fragments.DEFAULT_MAX_EVENTS_PER_PACKET
local DEFAULT_MAX_UNRELIABLE_SIZE = Fragments.DEFAULT_MAX_UNRELIABLE_SIZE
local UNRELIABLE_INSTANCE_BYTES = Fragments.UNRELIABLE_INSTANCE_BYTES

local Bodies = {}

--> Sequence bookkeeping for OrderedUnreliable, emitted only where the schema uses it.
-->
--> Incoming is the last sequence seen per event, per SOURCE -- which on the server means per
--> player, since each client runs its own. Outgoing is per event on a client, which has one
--> recipient, and per event PER PLAYER on the server: one counter shared by every player told a
--> player left out of 32768 sends that each later packet was older than the last one it had seen,
--> until the counter came round again. The server's serialiser writes a placeholder and each send
--> stamps the recipient's own number over it.
-->
--> A sequence is newer when it is less than half the counter's range AHEAD of the last one, the
--> usual serial-number comparison, which is what makes the wrap at 65536 harmless. The earlier
--> check refused only what was below the last sequence, so a packet from just before the wrap
--> arriving just after it was taken as newer and delivered out of order.
function Bodies.Ordering(): { string }
	local OrderingBody = {}
	if State.UsesOrdering then
		local Newer = {
			"\tlocal Last = State[Slot]\n",
			"\tif Last ~= nil then\n",
			"\t\tlocal Ahead = (Identifier - Last) % 65536\n",
			"\t\tif Ahead == 0 or Ahead >= 32768 then\n",
			"\t\t\treturn false\n",
			"\t\tend\n",
			"\tend\n",
			"\n",
			"\tState[Slot] = Identifier\n",
			"\treturn true\n",
			"end\n",
		}

		if State.Context == "Server" then
			OrderingBody = {
				"\n",
				"--> Sequence numbers for ordered unreliable events, per player and per event, both ways.\n",
				"local OrderOut: { [Player]: { number } } = {}\n",
				"local OrderIn: { [Player]: { number } } = {}\n",
				"\n",
				"Players.PlayerRemoving:Connect(function(Player)\n",
				"\tOrderOut[Player] = nil\n",
				"\tOrderIn[Player] = nil\n",
				"end)\n",
				"\n",
				"--> The next sequence number this player is sent for this event. A player who has already left\n",
				"--> gets a number and keeps no state, which PlayerRemoving would have nothing left to clear.\n",
				"local function NextOrder(Player: Player, Slot: number): number\n",
				"\tlocal State = OrderOut[Player]\n",
				"\tif not State then\n",
				"\t\tif Player.Parent == nil then\n",
				"\t\t\treturn 0\n",
				"\t\tend\n",
				"\t\tState = {}\n",
				"\t\tOrderOut[Player] = State\n",
				"\tend\n",
				"\n",
				"\tlocal Identifier = ((State[Slot] or 0) + 1) % 65536\n",
				"\tState[Slot] = Identifier\n",
				"\treturn Identifier\n",
				"end\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one this player sent for this event.\n",
				"local function OrderAccept(Player: Player, Slot: number, Identifier: number): boolean\n",
				"\tif Player.Parent == nil then\n",
				"\t\tOrderIn[Player] = nil\n",
				"\t\treturn false\n",
				"\tend\n",
				"\n",
				"\tlocal State = OrderIn[Player]\n",
				"\tif not State then\n",
				"\t\tState = {}\n",
				"\t\tOrderIn[Player] = State\n",
				"\tend\n",
				"\n",
			}
		else
			OrderingBody = {
				"\n",
				"--> Sequence numbers for ordered unreliable events, one counter per event each way.\n",
				"local OrderOut: { number } = {}\n",
				"local OrderIn: { number } = {}\n",
				"\n",
				"--> Accepts a packet only if it is newer than the last one seen for this event.\n",
				"local function OrderAccept(Slot: number, Identifier: number): boolean\n",
				"\tlocal State = OrderIn\n",
			}
		end

		table.move(Newer, 1, #Newer, #OrderingBody + 1, OrderingBody)
	end

	return OrderingBody
end

--> Emitted only when the schema actually has unreliable events -- most do not, and a helper
--> nothing calls is noise in a file people read when debugging their own traffic.
function Bodies.UnreliableGuard(): { string }
	local UnreliableGuardBody = {}
	if State.Channels.Unreliable.Count > 0 then
		local MaxUnreliableSize = State.Options.MaxUnreliableSize or DEFAULT_MAX_UNRELIABLE_SIZE
		UnreliableGuardBody = {
			"\n",
			"--> Roblox drops an unreliable payload past this size and tells nobody. The compiler\n",
			"--> refuses schemas that can never fit; this catches the ones that merely overflow at\n",
			"--> runtime, and says which event did it. Each Instance sent beside the buffer costs the\n",
			"--> payload bytes of its own, measured in Studio, so it counts against the same limit.\n",
			`local MAX_UNRELIABLE_SIZE = {MaxUnreliableSize}\n`,
			`local UNRELIABLE_INSTANCE_BYTES = {UNRELIABLE_INSTANCE_BYTES}\n`,
			"local function CheckUnreliableSize(Name: string): boolean\n",
			"\tlocal Size = SendCursor + #SendInstances * UNRELIABLE_INSTANCE_BYTES\n",
			"\tif Size <= MAX_UNRELIABLE_SIZE then\n",
			"\t\treturn true\n",
			"\tend\n",
			"\n",
			'\twarn(`[BlinkBlox]: Dropped unreliable event "{Name}", {Size} bytes exceeds the {MAX_UNRELIABLE_SIZE} byte limit.`)\n',
			"\treturn false\n",
			"end\n",
		}
	end

	return UnreliableGuardBody
end

--> Initial contents of a player's rate bucket: tokens, refill clock, report clock, refusals since
--> that report, per limited declaration. Cloned per player on first use, so one allocation per player per session rather
--> than a table per event.
function Bodies.RateTemplate(): { string }
	local RateTemplateBody = {}
	if State.Context == "Server" then
		local Entries = {}
		for _, Slot in State.RateSlots do
			table.insert(Entries, `{Slot.Burst}, 0, 0, 0`)
		end

		RateTemplateBody = { `local RATE_TEMPLATE = table.freeze(\{{table.concat(Entries, ", ")}\})\n` }
	end

	return RateTemplateBody
end

--> The server's packet limits, which the client cuts its batch to fit; see Close in the client
--> template.
function Bodies.PacketLimits(): { string }
	local PacketLimitsBody = {}
	if State.Context == "Client" then
		PacketLimitsBody = {
			`local MAX_PACKET_SIZE = {State.Options.MaxPacketSize or Fragments.DEFAULT_MAX_PACKET_SIZE}\n`,
			`local MAX_EVENTS_PER_PACKET = {State.Options.MaxEventsPerPacket or DEFAULT_MAX_EVENTS_PER_PACKET}\n`,
			`local MAX_INSTANCES_PER_PACKET = {State.Options.MaxInstancesPerPacket or Fragments.DEFAULT_MAX_INSTANCES_PER_PACKET}\n`,
		}
	end

	return PacketLimitsBody
end

return Bodies
