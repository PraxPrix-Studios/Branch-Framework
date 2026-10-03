--!strict
--!native
--!optimize 2

--- Declarations with a body of named fields -- events, functions -- and scope blocks.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local ParserClass = require("./Class")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type EventOption = ParserClass.EventOption
type Declarations = ParserClass.Declarations
type Scope = ParserClass.Scope
type EventCall = ParserClass.EventCall
type Event = ParserClass.Event
type Function = ParserClass.Function
type ScopeNode = ParserClass.ScopeNode

local EVENT = Grammar.EVENT
local FUNCTION = Grammar.FUNCTION

local Parser = ParserClass.Class

function Parser.GetOptionFromToken(self: Parser, Token: Token, Structure: { EventOption }): EventOption
	local Value = Token.Value
	for _, Option in Structure do
		local Key = Option.Key
		if Key == Value or string.lower(Key) == Value then
			return Option
		end
	end

	local OptionsString = ""
	for Index, Option in Structure do
		OptionsString ..= `{Index ~= 1 and " or " or ""}"{Option.Key}"`
	end

	error(
		self:Diagnostic(Error.ParserUnknownOption, `Unknown option "{Value}"`)
			:Primary(Token, `Expected one of {OptionsString}`)
			:Emit()
	)
end

function Parser.Structure(self: Parser, Name: Token, Structure: { EventOption }): { [string]: any }
	local Fields: { [string]: any } = {}

	local Open, Close = self:List("OpenBraces", "CloseBraces", function()
		local Value: any
		local Field = self:ConsumeText()
		local Option = self:GetOptionFromToken(Field, Structure)
		self:Consume("FieldAssign")

		--> Prevent duplicate fields
		if Fields[Option.Key] then
			self:Diagnostic(Error.AnalyzeDuplicateField, `Field "{Option.Key}" was already specified`)
				:Primary(Field, `Already specified earlier in the structure`)
				:Emit()
		end

		--> `Poll: true` is the 0.x spelling of `Call: Polling`. Both still work and compile to exactly
		--> the same thing -- Parser.Event folds one into the other -- but only `Call` appears in the
		--> documentation, so a schema written with `Poll` is using a spelling nothing tells you about
		--> and nothing warns you off. `UseColon` has warned for the same reason since it stopped
		--> doing anything; this one still works, which is why it warns rather than errors.
		if Option.Key == "Poll" then
			self:Diagnostic(Error.AnalyzeDeprecatedOption, `Field "Poll" is deprecated`, "Warning")
				:Primary(Field, "Use `Call: Polling` instead")
				:Note("The two compile to the same thing, but only `Call` is documented.")
				:Warn()
		end

		--> Parse non data/return field
		if Option.Numeric then
			local Token = self:Consume(Option.Type)
			local Numeric = tonumber(Token.Value)

			if not Numeric or Numeric <= 0 then
				self:Diagnostic(Error.ParserUnknownOption, `Invalid value for "{Option.Key}"`)
					:Primary(Token, "Expected a number greater than zero")
					:Emit()
			end

			--> An event spends one whole token, so a bucket that can never hold one refuses every
			--> event however long the client waits.
			if Option.Key == "Burst" and Numeric and Numeric < 1 then
				self:Diagnostic(Error.ParserUnknownOption, `Invalid value for "Burst"`)
					:Primary(Token, "Expected at least 1: each event spends one whole token")
					:Emit()
			end

			--> A count of calls, so a whole one: `Concurrency: 1.5` has no meaning to round towards.
			if Option.Key == "Concurrency" and Numeric and Numeric ~= math.floor(Numeric) then
				self:Diagnostic(Error.ParserUnknownOption, `Invalid value for "Concurrency"`)
					:Primary(Token, "Expected a whole number of calls")
					:Emit()
			end

			--> Stored as a number: every consumer does arithmetic with it.
			Value = Numeric
		elseif Option.Fields then
			--> A block of fields of its own, `Stream: { Rate: 10 }`, checked the same way as this one.
			Value = self:Structure(Name, Option.Fields)
		elseif Option.Key ~= "Data" and Option.Key ~= "Return" then
			local Token = self:Consume(Option.Type)
			Value = Token.Value

			if not table.find(Option.Values, Value) then
				self:Diagnostic(Error.ParserUnknownOption, `Unknown option "{Value}"`)
					:Primary(Token, `Expected one of "{table.concat(Option.Values, `" or "`)}"`)
					:Emit()
			end
		else
			Value = self:Type(Name, nil, true)
		end

		Fields[Option.Key] = Value
	end)

	--> Check if all required fields where supplied
	for _, Option in Structure do
		if Option.Optional then
			continue
		end

		if Fields[Option.Key] ~= nil then
			continue
		end

		local Span: Error.Span = {
			End = math.max(Close.End - 2, Open.Start),
			Start = Open.Start,
		}

		self:Diagnostic(Error.ParserExpectedExtraToken, `Field "{Option.Key}" is missing`)
			:Primary(Span, `Add missing field "{Option.Key}"`)
			:Emit()
	end

	return Fields
end

function Parser.Event(self: Parser, Name: Token): Event
	local Structure = self:Structure(Name, EVENT)
	local Call: EventCall = Structure.Call
	if Structure.Poll then
		Call = "Polling"
	end

	local Data, Stream, Stamp = Structure.Data, nil, nil
	if Structure.Stream then
		Data, Stream = self:StreamData(Name, Structure)
	end

	--> A stream is From: Server, so the From check there refuses a Stamp beside it.
	if Structure.Stamp ~= nil then
		Data, Stamp = self:StampData(Name, Structure)
	end

	--> What a low priority leaves out is an unreliable send the server makes; nothing else can be
	--> skipped without the receiver noticing a gap.
	if Structure.Priority ~= nil and (Structure.From ~= "Server" or Structure.Type == "Reliable") then
		self:Diagnostic(Error.AnalyzeInvalidPriority, `Event "{Name.Value}" cannot take a Priority`)
			:Primary(Name, "Priority is for an unreliable event or stream the server sends")
			:Note("A send left out for the budget is lost, which only an unreliable event may be.")
			:Emit()
	end

	return {
		Type = "Event",
		Name = Name.Value,
		Value = {
			From = Structure.From,
			Type = Structure.Type,
			Call = Call,
			Data = Data,
			Rate = Structure.Rate,
			Burst = Structure.Burst,
			Stream = Stream,
			Stamp = Stamp,
			Priority = Structure.Priority,
		},
		Tokens = {
			Identifier = Name,
		},
	}
end

function Parser.Function(self: Parser, Name: Token): Function
	local Structure = self:Structure(Name, FUNCTION)

	return {
		Type = "Function",
		Name = Name.Value,
		Value = {
			From = Structure.From or "Client",
			Yield = Structure.Yield,
			Data = Structure.Data,
			Return = Structure.Return,
			Rate = Structure.Rate,
			Burst = Structure.Burst,
			Concurrency = Structure.Concurrency,
		},
		Tokens = {
			Identifier = Name,
		},
	}
end

function Parser.Namespace(self: Parser, Name: Token): ScopeNode
	self:Consume("OpenBraces")

	--> Open scope
	local Parent = self.Scope
	local Scope: Scope = {
		Name = Name,
		Parent = Parent,
		Symbols = {
			Types = {},
			Scopes = {},
		},
	}

	self.Scope = Scope
	self.Symbols[Name.Value] = true
	Parent.Symbols.Scopes[Name.Value] = Scope

	local Declarations = self:Declarations()

	self.Scope = Parent

	return {
		Type = "Scope",
		Name = Name.Value,
		Value = {
			Scope = Scope,
			Values = Declarations,
		},
		Tokens = {},
	}
end

return Parser
