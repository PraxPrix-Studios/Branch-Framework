--!strict
--- How an event's listeners are called: on receipt, once per listener, from the decode loop or
--- Predict, and when `.On` connects, once per queued row. Both paths go through `Call`, so a listener
--- is guarded the same way whichever of them reaches it.
---
--- On the server every one of those calls reports a listener's error through `ListenerFailed` or
--- `RunListener` (Templates/Limits.luau), which hand it to the game's `SetListenerErrorHandler` or,
--- with none installed, leave it to surface as it always did. The client has no such handler: what
--- its listeners run was sent by the trusted server, so their errors stay in the output.
local Blocks = require("./Blocks")

type Block = Blocks.Block

--- What emitting a call needs to know about the event. `Connection` is the expression holding its
--- listener, or its list of listeners for a Many event.
export type Event = {
	Name: string,
	Context: string,
	Connection: string,
	IsSync: boolean,
	Validating: boolean,
}

--- One call of `Path` with `Arguments`, emitted at indent 1 for the caller to place. `Sender` is the
--- expression naming the player on the server: `Player` on receipt, the row's first value on replay.
--- `Receiving` sets the event's name for SyncValidation's report first.
---
--- A Sync listener runs inside the decode loop's pcall, so an error in game code used to be reported
--- as a packet that could not be decoded -- blamed on the sender, silently on the server unless the
--- game had installed a handler, and taking the rest of the packet and any later listeners with it.
--- It is caught here instead, where the cursor already sits past the event: reported to the game's
--- handler, or raised on a thread of its own, which is where an Async listener's error has always
--- surfaced. The two locals are typed because a listener declared to return nothing gives `pcall` one
--- result under `--!strict`.
---
--- `Direct`, for the one listener of a Single Sync event received in the decode loop, calls it without
--- a pcall of its own: `Decoding` is set to `-2 - Index` first, so when the loop's pcall catches an
--- error with it there, the listener threw, and it is reported the same way and the decode goes on
--- with the next event (Generator/init.luau, CloseDecode). The next event's index overwrites it. A
--- pcall an event cost more than the decode of a small one, and naming the event with a string a
--- call cost two writes the collector watches. Predict, replay and a Many event's listeners, which
--- the next listener of the same event must survive, keep their pcall.
local function Call(
	Event: Event,
	Path: string,
	Arguments: string,
	Sender: string,
	Receiving: boolean,
	Direct: boolean?
): Block
	local Target = Blocks.Block()
	local OnServer = Event.Context == "Server"

	if not Event.IsSync then
		if OnServer then
			return Target:Line(`Spawn(RunListener, "{Event.Name}", {Path}, {Arguments})`)
		end

		return Target:Line(`Spawn({Path}, {Arguments})`)
	end

	if Receiving and Event.Validating then
		Target:Line(`SerdesEvent = "{Event.Name}"`)
	end

	if Direct then
		return Target:Line("Decoding = -2 - Index"):Line(`{Path}({Arguments})`)
	end

	local Raise = "task.spawn(error, ListenerFailure, 0)"
	local Failed = if OnServer
		then `if not ListenerRan and not ListenerFailed({Sender}, "{Event.Name}", ListenerFailure) then {Raise} end`
		else `if not ListenerRan then {Raise} end`

	return Target:Line(`local ListenerRan: boolean, ListenerFailure: any = pcall({Path}, {Arguments})`):Line(Failed)
end

--- Calls every listener of a Many event, and returns `Target`.
---
--- The list is replaced on connect and disconnect, never edited in place, so the loop walks the one it
--- started with: a listener that disconnects itself -- a "once" -- cannot shift the next one past it.
--- Walking a stale list also reached a listener that an EARLIER one had just disconnected, which
--- RBXScriptSignal skips and every Luau signal written after it does too. So once anything has
--- disconnected since the loop began, a listener no longer in the list is passed over. Until then the
--- check is one upvalue compared with a local: comparing the list itself with the one the loop took
--- cost a fifth to a half of each call in measurement; this one stayed inside the noise.
local function Each(Target: Block, Event: Event, Arguments: string): Block
	local Connection = Event.Connection
	Target:Line("local Epoch = ListenerEpoch")

	local Loop = Target:Iterator("_", "Listener", Connection)
	Loop:Line(`if ListenerEpoch ~= Epoch and table.find({Connection}, Listener) == nil then continue end`)
	Loop:Lines(Call(Event, "Listener", Arguments, "Player", true).Content, Loop.Indent - 1)

	return Loop:End()
end

--- Replays the queue `.On` finds to the listener it is connecting, and returns `Target`.
---
--- The replay called a Sync listener bare, where receipt guards it. A listener that threw on a queued
--- event threw out of `.On` -- after it had been bound, before the queue was cleared -- so the caller
--- never got its disconnect, the rows after the failing one were never delivered, and the next `.On`
--- was handed the same queue again. The queue is taken before the first row is replayed, so a listener
--- that connects again from inside the replay is not handed it a second time either. On the server a
--- row begins with its sender, which is who a failure is reported against.
local function Replay(Target: Block, Event: Event, Queue: string): Block
	Target:Line(`local Pending = {Queue}`)
	Target:Line(`{Queue} = \{}`)

	local Row = "table.unpack(Arguments, 1, Arguments.n)"
	local Loop = Target:Iterator("_", "Arguments", "Pending")
	Loop:Lines(Call(Event, "Listener", Row, "Arguments[1]", false).Content, Loop.Indent - 1)

	return Loop:End()
end

return {
	Call = Call,
	Each = Each,
	Replay = Replay,
}
