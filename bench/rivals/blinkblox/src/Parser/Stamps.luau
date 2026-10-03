--!strict
--!native
--!optimize 2

--- An event's `Stamp`: the checks that allow it, and the wire type it gives the event.
---
--- A stamped event carries the moment the client sent it, as the client's estimate of the server's
--- clock (`GetServerTimeNow`) in milliseconds modulo 65536. The server unwraps it against its own
--- clock and hands the listener `SentAt` in seconds, no later than the moment it arrived and no
--- earlier than `Stamp` milliseconds before that -- a client can lie about when it acted, but only
--- inside the window the schema allows. That is what lag compensation needs: the game rewinds to
--- `SentAt` to judge a hit where the player saw it.
---
--- What travels is the declared Data with `SentAt: u16` appended. Building that as the event's `Data`
--- here, as streams do, gives the stamp the size analysis, the schema signature, the serialisers and
--- the listener's types of an ordinary element.
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
type Primitive = ParserClass.Primitive
type StampSettings = ParserClass.StampSettings

local Parser = ParserClass.Class

function Parser.StampData(self: Parser, Name: Token, Structure: { [string]: any }): (Tuple, StampSettings)
	local Event = Name.Value

	local function Refuse(Message: string, Label: string, Note: string): never
		return self:Diagnostic(Error.AnalyzeInvalidStamp, Message):Primary(Name, Label):Note(Note):Emit()
	end

	--> The server's clock is the one being estimated, so only a client's send has anything to stamp.
	if Structure.From ~= "Client" then
		Refuse(
			`Event "{Event}" is stamped but not sent by a client`,
			"Declare it From: Client, or remove Stamp",
			"A stamp tells the server when a client sent an event; the server knows when it sends its own."
		)
	end

	--> A polled event hands the game its values raw, so the listener would get the two-byte stamp
	--> rather than the unwrapped, clamped time.
	if Structure.Call == "Polling" or Structure.Poll then
		Refuse(
			`Stamped event "{Event}" cannot be polled`,
			"Use a Sync or Async call",
			"The listener receives the time the client sent the event, which a poll does not unwrap."
		)
	end

	local Window: number = Structure.Stamp
	if not (Window >= 1 and Window <= Grammar.STAMP_MAX) then
		Refuse(
			`Stamp window of "{Event}" is out of range`,
			`Stamp is {Window}`,
			`A stamp is milliseconds from 1 to {Grammar.STAMP_MAX}, under half the u16 it wraps at.`
		)
	end

	--> The stamp's node points at the event's name, where a diagnostic about the stamp belongs.
	local StampToken: Token = { Type = "Primitive", Value = "u16", Start = Name.Start, End = Name.End }
	local Stamp: Primitive = {
		Type = "Primitive",
		Name = Event,
		Value = { Primitive = Settings.Primtives.u16 },
		Tokens = { Primitive = StampToken },
	}

	local Data: TypeNode? = Structure.Data
	local Values: { TypeNode } = {}
	local Names: { [number]: string } = {}

	if Data and Data.Type == "Tuple" then
		local Pack = (Data :: Tuple).Value
		for Index, Element in Pack.Values do
			Values[Index] = Element
			Names[Index] = Pack.Names[Index]
		end
	elseif Data then
		--> A single value is the listener's `Value`, as it was before the stamp joined it.
		Values[1] = Data
		Names[1] = "Value"
	end

	--> Names is sparse -- an unnamed element has no entry -- so it is walked, not searched.
	for _, Taken in Names do
		if Taken ~= "SentAt" then
			continue
		end
		Refuse(
			`Stamped event "{Event}" already has an element named SentAt`,
			"Rename the element",
			"The stamp reaches the listener as SentAt, after the declared values."
		)
	end

	table.insert(Values, Stamp)
	Names[#Values] = "SentAt"

	local Wire: Tuple = {
		Type = "Tuple",
		Name = Event,
		Value = { Values = Values, Names = Names },
		Tokens = {},
	}

	return Wire, { Window = Window / 1000, Value = Data }
end

return Parser
