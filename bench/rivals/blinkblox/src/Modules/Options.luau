--!strict
--- Parses the `option` block at the top of a schema.
---
--- Extracted from the parser when it was over its size limit and had no room to grow. It pairs with
--- Modules/Grammar, which already held the table of which options exist
--- and what each one's value must lex as -- the shape was there and the code that reads it was not.
---
--- It takes a structural Reader rather than the Parser type, which is what keeps this out of a
--- require cycle: Parser requires this, so this cannot require Parser back. Anything with these
--- four members satisfies it, and the parser is the only thing that has them.

---- Imports ----

local Attributes = require("./Attributes")
local Error = require("./Error")
local Grammar = require("./Grammar")
local Lexer = require("../Lexer")
local Settings = require("../Settings")

---- Types ----

type Token = Lexer.Token
type Options = Grammar.Options
--- An option as given, with the profile it was given under, if any.
type Given = { Key: Token, Profile: Token? }

--- The slice of the parser this needs: where it is reading, and enough of the source to render a
--- diagnostic against.
export type Reader = {
	Source: string,
	File: string?,
	Attributes: Attributes.State,

	Peek: (self: any) -> Token,
	Consume: (self: any, Type: Lexer.Types) -> Token,
	ConsumeAll: (self: any, ...Lexer.Types) -> ...Token,
}

---- Constants ----

local OPTIONS = Grammar.OPTIONS

--- The smallest value a numeric option takes, where it is not 1. `MaxInstancesPerPacket = 0` is a
--- real setting rather than a typo: a game whose clients send no Instance says so, and the server
--- then drops any packet that carries one. Analysis refuses it beside a client-sent Instance (E3031).
local MINIMUMS: { [string]: number } = {
	MaxInstancesPerPacket = 0,
}

--- Options measured in seconds rather than counted, so a fraction is a real setting: a test place
--- may want to give up on the server after half a second. Any value above zero is taken.
local FRACTIONAL: { [string]: true } = {
	ClientConnectTimeout = true,
}

local Utility = {}

---- Private Functions ----

--- Lists a table's keys for an "expected one of ..." line.
---
--- Built from the table being validated against rather than written out beside it, so the message
--- cannot fall out of step with the set it describes.
local function ListKeys(Of: { [string]: any }): string
	local Parts: { string } = {}
	for Key in Of do
		table.insert(Parts, `"{Key}"`)
	end

	return table.concat(Parts, " or ")
end

local function IsInteger(Number: number): boolean
	return (Number // 1) == Number
end

---- Public Functions ----

function Utility.Parse(Reader: Reader): Options
	local Options: Options = {}

	--> Read options until something that is not one. Bounding this loop by the number of KNOWN
	--> options -- as it used to be -- silently stopped parsing once that many `option` statements
	--> had been seen, duplicates included, and every option past the cut was reported as
	--> "Option set after start of file" instead of being applied.
	-->
	--> Each option with the profile it was given under, if any. See the duplicate check below.
	local Declared: { [string]: { Given } } = {}

	while true do
		--> An attribute in front of something that is not an option stays pending for the
		--> declaration it belongs to. See Modules/Attributes.
		Attributes.Read(Reader)
		if Reader:Peek().Value ~= "option" then
			break
		end

		local Profile = Reader.Attributes.Pending
		local Previous = Attributes.Open(Reader)
		local Excluded = Reader.Attributes.Excluding ~= nil
		Reader.Attributes.Excluding = Previous

		Reader:Consume("Keyword")
		local Key = Reader:ConsumeAll("Identifier", "Assign")
		local Name = Key.Value

		local Type: Lexer.Types = OPTIONS[Name]
		if not Type then
			Error.new(Error.ParserUnknownOption, Reader.Source, `Unknown option "{Name}"`, Reader.File)
				:Primary(Key, `Expected one of {ListKeys(OPTIONS)}`)
				:Emit()
		end

		--> One option may be set once per profile, and once without one. Two settings clash when
		--> some build would apply both -- either has no profile, or both have the same one -- and the
		--> clash is reported whichever profile this build uses, so a schema is valid in all or none.
		local Given: { Given } = Declared[Name] or {}
		for _, Earlier in Given do
			if Earlier.Profile == nil or Profile == nil or Earlier.Profile.Value == Profile.Value then
				Error.new(Error.AnalyzeDuplicateOption, Reader.Source, `Duplicate option "{Name}"`, Reader.File)
					:Primary(Key, "Option set twice")
					:Secondary(Earlier.Key, "Already set here")
					:Emit()
			end
		end

		table.insert(Given, { Key = Key, Profile = Profile })
		Declared[Name] = Given

		--> Parsed since 0.14 and read by nothing since: no generator has ever looked at it. Warning
		--> rather than erroring keeps existing schemas compiling while they migrate.
		if Name == "UseColon" then
			Error.new(
				Error.AnalyzeDeprecatedOption,
				Reader.Source,
				`Option "UseColon" is deprecated`,
				Reader.File,
				"Warning"
			)
				:Primary(Key, "This option has no effect")
				:Note("No generator reads it. It will be removed in 1.0 -- delete the line.")
				:Warn()
		end

		local Value = Reader:Consume(Type)
		if Type == "Number" then
			--> Number tokens carry their text; every consumer of a numeric option wants the number.
			local Numeric = tonumber(Value.Value)
			local Minimum = MINIMUMS[Name] or 1
			local Invalid = if FRACTIONAL[Name]
				then not Numeric or not (Numeric > 0) or Numeric == math.huge
				else not Numeric or Numeric < Minimum or not IsInteger(Numeric)
			if Invalid then
				local Expected = if FRACTIONAL[Name]
					then "a positive number of seconds"
					elseif Minimum == 1 then "a positive whole number"
					else `a whole number, {Minimum} or more`
				Error.new(Error.ParserUnknownOption, Reader.Source, `Invalid value for option "{Name}"`, Reader.File)
					:Primary(Value, `Expected {Expected}`)
					:Emit()
			end

			if not Excluded then
				Options[Name] = Numeric
			end
		else
			--> An unknown casing used to get all the way to the GENERATOR, which raised a plain Lua
			--> error mid-emit: no code, no source span, and a stack trace through the compiler in
			--> place of a line number. Every other bad option value is a diagnostic, and this is the
			--> last point at which the token is still around to point at.
			if Name == "Casing" and Settings.Casings[Value.Value] == nil then
				Error.new(Error.ParserUnknownOption, Reader.Source, `Invalid value for option "Casing"`, Reader.File)
					:Primary(Value, `Expected one of {ListKeys(Settings.Casings)}`)
					:Emit()
			end
			if Name == "PackedBooleanReader" and Settings.PackedBooleanReaders[Value.Value] == nil then
				Error.new(
					Error.ParserUnknownOption,
					Reader.Source,
					`Invalid value for option "PackedBooleanReader"`,
					Reader.File
				)
					:Primary(Value, `Expected one of {ListKeys(Settings.PackedBooleanReaders)}`)
					:Emit()
			end

			if not Excluded then
				Options[Name] = Value.Value
			end
		end
	end

	--> A burst below the largest packet a client may send refuses that packet every time, however
	--> long the client waits: the bucket never holds enough to pay for it.
	local Burst = Options.InboundBurst
	local Smallest = math.max(Options.MaxPacketSize or Grammar.DEFAULTS.MaxPacketSize, Grammar.DEFAULTS.InboundFloor)
	if Burst and Burst < Smallest then
		local Given = Declared.InboundBurst
		Error.new(Error.ParserUnknownOption, Reader.Source, `Invalid value for option "InboundBurst"`, Reader.File)
			:Primary(Given[#Given].Key, `Expected at least {Smallest}, the largest packet a client may send`)
			:Emit()
	end

	return Options
end

return Utility
