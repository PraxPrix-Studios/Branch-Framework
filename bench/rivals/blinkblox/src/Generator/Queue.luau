--!strict
--- Where an event goes when it arrives before anything is listening for it.
---
--- Reliable events and invocations that reach a side with no listener bound are queued, and the
--- queue is replayed the moment `.On` connects, so a listener attached a frame late still sees what
--- was sent before it. Games depend on that, and it stays.
---
--- On the SERVER that queue is filled by clients. Uncapped, a client firing an event the game never
--- listens to grew server memory for as long as it cared to keep sending, each row pinning its
--- Player, and past 256 rows it printed a warning per event -- the output flood the decode loop
--- already refuses to cause. So the server stops at the cap and says nothing. The CLIENT's queue is
--- filled by the server, which it trusts, and there the warning is the useful signal of a listener
--- somebody forgot. Upstream reported the same unbounded queue against `rewrite` as #93.
local Blocks = require("./Blocks")

type Block = Blocks.Block

local CAPACITY = 256

--- Answers an invocation the server will not run: the same three-byte failure reply the error path
--- writes, so the caller rejects promptly. A dropped call is not an option -- the caller is parked
--- until its timeout, holding one of its 32 slots the whole time.
---
--- `return`: this is emitted in the channel's decoder, which the decode loop calls once an event, and
--- returning from it goes on with the packet's next event.
local function Refuse(Target: Block, Index: number, Indent: number): Block
	for _, Line in
		{
			"LoadPlayer(Player)",
			"local Position = Allocate(3)",
			`buffer.writeu8(SendBuffer, Position, {Index})`,
			"buffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)",
			"buffer.writeu8(SendBuffer, Position + 2, 0)",
			"SavePlayerBuffer(Player)",
			"return",
		}
	do
		Target:Line(Line, Indent)
	end

	return Target
end

--- Emits the enqueue into `Target`, the branch taken when no listener is bound, and returns it.
--- `Invocation` is the event index of a function, whose caller is answered rather than dropped when
--- the server's queue is full. `Release` is emitted on that refusal first: a call a `Concurrency`
--- limit has already counted as running is given back when it is answered this way instead.
--- Each row is `table.pack`ed and replayed with its own `n`. A row built as `{A, B, ...}` lost every
--- value after a `nil` it ended on: `#{1, nil, nil, 4, nil}` is 1, so a tuple with optional elements
--- that arrived before its listener was replayed with some of its values gone.
local function Enqueue(
	Target: Block,
	Context: string,
	Queue: string,
	Row: string,
	Name: string,
	Invocation: number?,
	Release: string?
): Block
	local Insert = `table.insert({Queue}, table.pack({Row}))`

	if Context ~= "Server" then
		return Target:Compare(`#{Queue}`, CAPACITY, "Greater")
			:Line(
				`warn("[BlinkBlox]: Event queue of \\"{Name}\\" exceeded {CAPACITY}, did you forget to implement a listener?")`
			)
			:End()
			:Line(Insert)
	end

	if Invocation then
		local Full = Target:Compare(`#{Queue}`, CAPACITY, "GreaterOrEquals")
		if Release then
			Full:Line(Release)
		end

		return Refuse(Full, Invocation, Full.Indent):End():Line(Insert)
	end

	return Target:Compare(`#{Queue}`, CAPACITY, "Less"):Line(Insert):End()
end

return {
	CAPACITY = CAPACITY,
	Refuse = Refuse,
	Enqueue = Enqueue,
}
