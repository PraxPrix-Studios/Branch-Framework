--!strict
--- The schema's bounds as constants the game can read, behind `option ExportLimits = true`.
---
--- A game that sends `CrawlHead[..16]` otherwise repeats the 16 by hand, and the two drift the first
--- time either changes. With the option on, every module the compiler writes -- server, client, and
--- the types module -- carries a frozen `Limits` table: `Net.Limits.CrawlPacket.Heads.Length.Max`.
---
--- Its shape mirrors the schema. A declaration is keyed by its name, a scope nests its own, a struct
--- keys its fields, a tagged enum its variants, a type pack its named elements (or their positions),
--- a function its `Data` and `Return`, and a stream the type it streams rather than its wire pack.
--- What sits at the bottom is a range, `{ Min, Max }`:
---
---   a number with a range, a scale or `saturate`   its bounds in the schema's units, plus `Step`
---                                                   for a scaled one
---   a ranged string or buffer                       its length in bytes
---   a ranged vector                                 its magnitude
---   an array                                        `{ Length, Element }`, whichever are bounded
---   a map                                           `{ Key, Value }`, whichever are bounded
---
--- Anything the schema bounds nowhere inside is left out, so a key exists only where there is a
--- number to read. The structural words -- Min, Max, Step, Length, Element, Key, Value -- follow
--- `option Casing`; names from the schema, `Data` and `Return` included, are kept as written.
local FixedPoint = require("../Modules/FixedPoint")
local Parser = require("../Parser")
local Settings = require("../Settings")
local Size = require("../Modules/Size")
local Util = require("./Util")

type Node = any

export type Limit = {
	--> A range: set on the leaves.
	Min: number?,
	Max: number?,
	Step: number?,
	--> A table of further limits, in schema order: set on everything else.
	Entries: { { Key: string | number, Limit: Limit } }?,
}

--> The structural keys, per casing.
local WORDS: { [string]: { string } } = {
	Limits = { "Limits", "limits", "limits" },
	Min = { "Min", "min", "min" },
	Max = { "Max", "max", "max" },
	Step = { "Step", "step", "step" },
	Length = { "Length", "length", "length" },
	Element = { "Element", "element", "element" },
	Key = { "Key", "key", "key" },
	Value = { "Value", "value", "value" },
}

local Limits = {}

local function Range(Min: number, Max: number, Step: number?): Limit
	return { Min = Min, Max = Max, Step = Step }
end

local function Table(Entries: { { Key: string | number, Limit: Limit } }): Limit?
	return if #Entries > 0 then { Entries = Entries } else nil
end

--- The limits inside one type node, or nil when it bounds nothing.
function Limits.Of(Node: Node, Word: (string) -> string): Limit?
	local Value = Node.Value
	local Kind = Node.Type

	if Kind == "Primitive" then
		local Primitive: Settings.Primitive = Value.Primitive
		local IsNumber = Primitive.Component and Primitive.Bounds ~= nil
		if IsNumber and (Value.Range or Value.Scale or Value.Saturate) then
			local Scale: number? = Value.Scale
			local Bounds = Primitive.Bounds :: Settings.NumberRange
			local Declared = Value.Range
				or if Scale
					then { Min = FixedPoint.Decode(Bounds.Min, Scale), Max = FixedPoint.Decode(Bounds.Max, Scale) }
					else Bounds
			return Range(Declared.Min, Declared.Max, Scale)
		elseif not IsNumber and Value.Range then
			return Range(Value.Range.Min, Value.Range.Max)
		end

		return nil
	elseif Kind == "Optional" then
		return Limits.Of(Value.Of, Word)
	elseif Kind == "Array" then
		local Entries = {}
		if Size.RangeWritten(Node) then
			table.insert(Entries, { Key = Word("Length"), Limit = Range(Value.Range.Min, Value.Range.Max) })
		end

		local Element = Limits.Of(Value.Of, Word)
		if Element then
			table.insert(Entries, { Key = Word("Element"), Limit = Element })
		end

		return Table(Entries)
	elseif Kind == "Map" then
		local Entries = {}
		for Index, Part in { "Key", "Value" } do
			local Inner = Limits.Of(Value.Values[Index], Word)
			if Inner then
				table.insert(Entries, { Key = Word(Part), Limit = Inner })
			end
		end

		return Table(Entries)
	elseif Kind == "Struct" or Kind == "TagEnum" or Kind == "Tuple" then
		local Entries = {}
		for Index, Field in Value.Values do
			local Inner = Limits.Of(Field, Word)
			if Inner then
				local Key: string | number = if Kind == "Tuple" then (Value.Names[Index] or Index) else Field.Name
				table.insert(Entries, { Key = Key, Limit = Inner })
			end
		end

		return Table(Entries)
	end

	return nil
end

--- The limits of a list of declarations: a schema's, or a scope's.
function Limits.Declarations(Declarations: { Parser.Declaration }, Word: (string) -> string): Limit
	local Entries = {}
	local Seen: { [string]: true } = {}

	local function Add(Name: string, Limit: Limit?)
		if Limit and not Seen[Name] then
			Seen[Name] = true
			table.insert(Entries, { Key = Name, Limit = Limit })
		end
	end

	for _, Declaration in Declarations do
		local Kind = Declaration.Type
		local Value = Declaration.Value
		if Kind == "Scope" then
			local Inner = Limits.Declarations(Value.Values, Word)
			Add(Declaration.Name, if Inner.Entries and #Inner.Entries > 0 then Inner else nil)
		elseif Kind == "Event" then
			--> A stream's `Data` is its wire pack, `(Value: T?, ServerTime: u16)`; the schema declared `T`,
			--> and the table mirrors the schema.
			local Data = if Value.Stream then Value.Stream.Value else Value.Data
			Add(Declaration.Name, if Data then Limits.Of(Data, Word) else nil)
		elseif Kind == "Function" then
			local Parts = {}
			for _, Part in { "Data", "Return" } do
				local Inner = if Value[Part] then Limits.Of(Value[Part], Word) else nil
				if Inner then
					table.insert(Parts, { Key = Part, Limit = Inner })
				end
			end
			Add(Declaration.Name, Table(Parts))
		elseif not Value.Generics then
			Add(Declaration.Name, Limits.Of(Declaration, Word))
		end
	end

	return { Entries = Entries }
end

--- The local every module declares the table under, and then returns as its `Limits` member.
Limits.LOCAL = "BLINK_LIMITS"

--- The lines declaring the table for a schema, or none when the option is off.
function Limits.Body(Tree: Parser.Body): { string }
	local Options = Tree.Value.Options :: any
	if not Options.ExportLimits then
		return {}
	end

	local Word = Limits.Words(Options.Casing)
	local Limit = Limits.Declarations(Tree.Value.Declarations, Word)
	return {
		"\n",
		"--> The schema's bounds, for the game to read instead of repeating them (option ExportLimits).\n",
		`local {Limits.LOCAL} = {Limits.Luau(Limit, Word)}\n`,
	}
end

--- The word for a structural key under a casing.
function Limits.Words(Casing: Settings.Case?): (string) -> string
	local Index = (Settings.Casings :: { [string]: number })[Casing or "Pascal"] or 1
	return function(Word: string): string
		return WORDS[Word][Index]
	end
end

local function Number(Value: number): string
	if Value == math.huge then
		return "math.huge"
	elseif Value == -math.huge then
		return "-math.huge"
	end

	return tostring(Value)
end

--- The Luau constructor for `Limit`, frozen at every level, indented from `Depth`.
function Limits.Luau(Limit: Limit, Word: (string) -> string, Depth: number?): string
	local Indent = string.rep("\t", (Depth or 0) + 1)
	local Lines = {}

	if Limit.Entries then
		for _, Entry in Limit.Entries do
			local Key = if type(Entry.Key) == "number" then `[{Entry.Key}]` else Util.FormatKey(Entry.Key :: string)
			table.insert(Lines, `{Indent}{Key} = {Limits.Luau(Entry.Limit, Word, (Depth or 0) + 1)},`)
		end
	else
		table.insert(Lines, `{Indent}{Word("Min")} = {Number(Limit.Min :: number)},`)
		table.insert(Lines, `{Indent}{Word("Max")} = {Number(Limit.Max :: number)},`)
		if Limit.Step then
			table.insert(Lines, `{Indent}{Word("Step")} = {Number(Limit.Step)},`)
		end
	end

	if #Lines == 0 then
		return "table.freeze({})"
	end

	return `table.freeze(\{\n{table.concat(Lines, "\n")}\n{string.rep("\t", Depth or 0)}\})`
end

--- The TypeScript type of `Limit`, every member readonly.
function Limits.Typescript(Limit: Limit, Word: (string) -> string, Depth: number?): string
	local Indent = string.rep("\t", (Depth or 0) + 1)
	local Lines = {}

	local function Member(Key: string | number, Type: string)
		local Name = if type(Key) == "number" or string.match(Key, "^[%a_][%w_]*$") then tostring(Key) else `"{Key}"`
		table.insert(Lines, `{Indent}readonly {Name}: {Type};`)
	end

	if Limit.Entries then
		for _, Entry in Limit.Entries do
			Member(Entry.Key, Limits.Typescript(Entry.Limit, Word, (Depth or 0) + 1))
		end
	else
		Member(Word("Min"), "number")
		Member(Word("Max"), "number")
		if Limit.Step then
			Member(Word("Step"), "number")
		end
	end

	if #Lines == 0 then
		return "{}"
	end

	return `\{\n{table.concat(Lines, "\n")}\n{string.rep("\t", Depth or 0)}\}`
end

return Limits
