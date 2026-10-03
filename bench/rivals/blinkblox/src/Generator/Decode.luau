--!strict
--!native
--!optimize 2

--- The receiving side's decode loop, per declaration: the branch that receives it, and the checks made
--- once it has been read -- whether its rate limit lets it through, and whether an ordered packet is
--- newer than the last one seen.
local Blocks = require("./Blocks")
local State = require("./State")

local Decode = {}

--- Claims a bucket slot for an inbound declaration that declares a rate, and returns the call that
--- spends a token from it. Returns nil when nothing limits this declaration, in which case no guard
--- is emitted at all -- an unlimited schema produces exactly the code it always did.
---
--- Server-only: the client trusts the server, and the bucket state lives in Templates/Limits.luau.
function Decode.RateGuardExpression(Value: { Rate: number?, Burst: number? }, Name: string): string?
	if State.Context ~= "Server" then
		return nil
	end

	local Rate = Value.Rate or State.Options.DefaultRate
	if not Rate then
		return nil
	end

	--> A burst of one would refuse the very first event of a frame whenever the previous frame used
	--> its budget, so the floor is one whole token.
	local Burst = Value.Burst or math.max(math.ceil(Rate), 1)

	table.insert(State.RateSlots, { Rate = Rate, Burst = Burst })
	local Slot = ((#State.RateSlots - 1) * 4) + 1

	return `RateAccept(Player, {Slot}, {Rate}, {Burst}, "{Name}")`
end

--- The call that decides whether an ordered packet is newer than the last one seen. Nil when the
--- event is not ordered, in which case no check is emitted at all.
---
--- The server keys by player: sixty clients each run their own sequence, and one client's counter
--- says nothing about another's.
function Decode.OrderGuardExpression(IsOrdered: boolean, Index: number): string?
	if not IsOrdered then
		return nil
	end

	if State.Context == "Server" then
		return `OrderAccept(Player, {Index}, OrderIdentifier)`
	end

	return `OrderAccept({Index}, OrderIdentifier)`
end

--- The call that decides whether a stream's state is newer than the last one taken, by the server
--- time `Stamp` it carries, already unwrapped. Streams go from the server to the clients only.
function Decode.StreamGuardExpression(Index: number, Stamp: string): string
	return `StreamAccept({Index}, {Stamp})`
end

--- Opens the branch of a channel's decode loop that receives declaration `Index`. The branch is a
--- block of its own, kept until `Close` arranges the channel's branches into the dispatch.
function Decode.Open(Unreliable: boolean, Index: number): Blocks.Block
	local Channel = if Unreliable then State.Channels.Unreliable else State.Channels.Reliable
	local Decoder = if Unreliable then State.Unreliables else State.Reliables

	local Block = Blocks.Block(Decoder)
	table.insert(Channel.Branches, { Index = Index, Block = Block })
	return Block
end

--> A run of at most this many branches is tested one index after another; a longer one is split in
--> two by a comparison. Eight keeps a channel of up to eight declarations emitting the chain it always
--> did: split, the first of five paid a comparison it had not, and a hundred sends over 128 events
--> decoded no faster with runs of four (0.053 ms a frame either way).
local LEAF = 8

--- Appends a branch's lines to `Decoder`, `Depth` tabs deeper than the branch was built at.
local function Nest(Decoder: Blocks.Block, Lines: { string }, Depth: number)
	if Depth == 0 then
		Decoder:Lines(Lines)
		return
	end

	local Indentation = string.rep("\t", Depth)
	for _, Line in Lines do
		local Nested = string.gsub(Line, "\n(.)", `\n{Indentation}%1`)
		table.insert(Decoder.Content, `{Indentation}{Nested}`)
	end
end

--- Emits a channel's dispatch into `Decoder`: which branch the index just read selects, and
--- `Unknown` for an index no branch claims.
---
--- It was one `if Index == 0 ... elseif` chain, and an interpreted client walked it one comparison
--- at a time -- a hundred to reach the hundredth event, on every event it received. The branches
--- are now halved by `Index < Middle` until a run of `LEAF` is left, so reaching any of 256 takes
--- at most thirteen comparisons rather than 256. Each run ends in `Unknown`, and every index outside the declared ones
--- lands in some run, so an unclaimed index is refused exactly as before.
function Decode.Close(Decoder: Blocks.Block, Branches: { State.Branch }, Unknown: string): Blocks.Block
	table.sort(Branches, function(Left: State.Branch, Right: State.Branch): boolean
		return Left.Index < Right.Index
	end)

	local Base = Decoder.Indent
	local function Emit(From: number, To: number, Depth: number)
		local Indent = Base + Depth
		if To - From < LEAF then
			for Position = From, To do
				local Branch = Branches[Position]
				local Keyword = if Position == From then "if" else "elseif"
				Decoder:Line(`{Keyword} Index == {Branch.Index} then`, Indent)
				Branch.Block:_appendOperations()
				Nest(Decoder, Branch.Block.Content, Depth)
			end

			Decoder:Line("else", Indent)
			Decoder:Line(Unknown, Indent + 1)
			Decoder:Line("end", Indent)
			return
		end

		local Middle = (From + To + 1) // 2
		Decoder:Line(`if Index < {Branches[Middle].Index} then`, Indent)
		Emit(From, Middle - 1, Depth + 1)
		Decoder:Line("else", Indent)
		Emit(Middle, To, Depth + 1)
		Decoder:Line("end", Indent)
	end

	Emit(1, #Branches, 0)
	return Decoder
end

return Decode
