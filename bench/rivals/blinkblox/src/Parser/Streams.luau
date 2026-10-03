--!strict
--!native
--!optimize 2

--- An event's `Stream` block: the checks that make it a stream, and the wire type it gives the event.
---
--- A stream is an event the server sends on a schedule rather than on `Fire` -- the latest state the
--- game `Set`, at the declared rate, skipped while it has not changed, repeated every `Keepalive`
--- seconds. What travels is `(Value: T?, ServerTime: u16)`: the state, nil once the game clears the
--- stream, and the server's clock in milliseconds modulo 65536. Building that as the event's `Data`
--- here, rather than special-casing it in every later stage, is what gives a stream the size
--- analysis, the schema signature, the serialisers and the TypeScript output of an ordinary event.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type TypeNode = ParserClass.TypeNode
type Tuple = ParserClass.Tuple
type Optional = ParserClass.Optional
type Primitive = ParserClass.Primitive
type StreamSettings = ParserClass.StreamSettings

local Parser = ParserClass.Class

function Parser.StreamData(self: Parser, Name: Token, Structure: { [string]: any }): (Tuple, StreamSettings)
	local Block = Structure.Stream
	local Event = Name.Value

	local function Refuse(Message: string, Label: string, Note: string): never
		return self:Diagnostic(Error.AnalyzeInvalidStream, Message):Primary(Name, Label):Note(Note):Emit()
	end

	--> The scheduler runs on the server, and a client's clock stamps nothing the server can trust.
	if Structure.From ~= "Server" then
		Refuse(`Stream "{Event}" is not sent by the server`, "Declare it From: Server", "Only the server streams.")
	end

	--> A stream is a current state: a lost packet is replaced by the next, and a late one must not
	--> overwrite a newer one. That is exactly OrderedUnreliable, and nothing else is.
	if Structure.Type ~= "OrderedUnreliable" then
		Refuse(
			`Stream "{Event}" is not OrderedUnreliable`,
			"Declare it Type: OrderedUnreliable",
			"A stream sends the latest state, so a lost packet is replaced and a late one is discarded."
		)
	end

	--> A polled stream would hand the game the raw two-byte stamp; a listener gets it unwrapped.
	if Structure.Call == "Polling" or Structure.Poll then
		Refuse(
			`Stream "{Event}" cannot be polled`,
			"Use a Sync or Async call",
			"A stream's listener receives the state with the server time it was sent at."
		)
	end

	local Data: TypeNode? = Structure.Data
	if not Data then
		return Refuse(`Stream "{Event}" has no Data`, "Add the state it streams", "A stream sends a state.")
	end

	--> nil is how a cleared stream arrives, so the state itself cannot also be nil, and a pack has no
	--> single value to compare or to clear.
	if Data.Type == "Tuple" or Data.Type == "Optional" then
		Refuse(
			`Stream "{Event}" streams {if Data.Type == "Tuple" then "a type pack" else "an optional"}`,
			"Stream one type that is not optional",
			"The listener receives nil once the stream is cleared; use a struct for several values."
		)
	end

	if Data.Type == "Primitive" and not (Data :: Primitive).Value.Primitive.AllowsOptional then
		Refuse(
			`Stream "{Event}" streams a type that cannot be optional`,
			"Stream a type that can be nil",
			"The listener receives nil once the stream is cleared, so the state is sent as optional."
		)
	end

	local Rate: number = Block.Rate
	local Fast: number? = Block.Fast
	if Fast and Fast <= Rate then
		Refuse(
			`Stream "{Event}" has a Fast rate no faster than its Rate`,
			`Fast is {Fast}, Rate is {Rate}`,
			"Fast is the rate SetFast(true) switches to, so it has to be higher."
		)
	end

	--> The stamp's node points at the event's name, where a diagnostic about the stream belongs.
	local StampToken: Token = { Type = "Primitive", Value = "u16", Start = Name.Start, End = Name.End }
	local Stamp: Primitive = {
		Type = "Primitive",
		Name = Event,
		Value = { Primitive = Settings.Primtives.u16 },
		Tokens = { Primitive = StampToken },
	}

	local State: Optional = {
		Type = "Optional",
		Name = Event,
		Value = { Of = Data },
		Tokens = {},
	}

	local Values: { TypeNode } = { State, Stamp }
	local Wire: Tuple = {
		Type = "Tuple",
		Name = Event,
		Value = { Values = Values, Names = { "Value", "ServerTime" } },
		Tokens = {},
	}

	return Wire,
		{
			Rate = Rate,
			Fast = Fast,
			Keepalive = Block.Keepalive or Grammar.STREAM_KEEPALIVE,
			Epsilon = Block.Epsilon or 0,
			Value = Data,
			PerPlayer = Block.Per == "Player",
		}
end

return Parser
