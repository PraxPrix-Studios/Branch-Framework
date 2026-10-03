--!strict
--- The machine-readable side of the CLI: what `--json` prints instead of rendered diagnostics.
---
--- An editor task, a CI step or an assistant that wants to know what went wrong used to have two
--- choices, both bad: parse the rendered diagnostic, box-drawing and colour codes included, or parse
--- `--compact`, which carries a line range and nothing else -- no column, no labels, no notes. This
--- collects the same diagnostics through `Error.OnEmit` and prints them as one JSON document.
---
--- The encoder is written out here rather than taken from `@lune/serde`, which encodes an empty
--- table as `{}` -- so a clean compile would report `"diagnostics": {}` -- and orders keys as the
--- hash table happens to, so two runs over one schema need not print the same text.

---- Imports ----

local Error = require("../../Modules/Error")
local Verify = require("./Verify")

---- Settings ----

--- Bumped when a field is removed or changes meaning. Adding a field does not bump it.
local FORMAT_VERSION = 1

--- JSON's null, a sentinel because a nil in a Luau table is no entry at all.
local Null = newproxy(false)

--- A value the encoder can write. An object is a list of key-value pairs, so it keeps its order.
export type Value = string | number | boolean | Object | Array | typeof(Null)
export type Object = { Keys: { string }, Values: { [string]: Value } }
export type Array = { Items: { Value } }

type Position = { Line: number, Column: number, Offset: number }

export type Collector = {
	Diagnostics: { Value },
	Failed: boolean,
}

---- Constants ----

local Utility = {}

---- Private Functions ----

local function Object(Pairs: { { any } }): Object
	local Result: Object = { Keys = {}, Values = {} }
	for _, Pair in Pairs do
		local Key = Pair[1] :: string
		table.insert(Result.Keys, Key)
		Result.Values[Key] = Pair[2] :: Value
	end

	return Result
end

local function Quote(Text: string): string
	local Escaped = string.gsub(Text, '[%c"\\]', function(Character: string): string
		if Character == '"' then
			return '\\"'
		elseif Character == "\\" then
			return "\\\\"
		elseif Character == "\n" then
			return "\\n"
		elseif Character == "\t" then
			return "\\t"
		elseif Character == "\r" then
			return "\\r"
		end

		return string.format("\\u%04x", string.byte(Character))
	end)

	return `"{Escaped}"`
end

local function Encode(Item: Value): string
	if Item == Null then
		return "null"
	elseif type(Item) == "string" then
		return Quote(Item)
	elseif type(Item) == "number" or type(Item) == "boolean" then
		return tostring(Item)
	end

	local Table = Item :: any
	local Parts: { string } = {}
	if Table.Items then
		for _, Element in (Table :: Array).Items do
			table.insert(Parts, Encode(Element))
		end

		return `[{table.concat(Parts, ",")}]`
	end

	for _, Key in (Table :: Object).Keys do
		table.insert(Parts, `{Quote(Key)}:{Encode((Table :: Object).Values[Key])}`)
	end

	return `\{{table.concat(Parts, ",")}}`
end

--- Where a span's byte index falls. Lines and columns count from 1, as the rendered diagnostic's
--- line numbers do; the offset counts from 0, as a byte offset into a file does everywhere else. A
--- column counts bytes, so a tab or a multi-byte character is as wide as it is in the file -- which
--- is what a tool holding the file's bytes needs to find the spot again.
local function Locate(Lines: { string }, Index: number): Position
	local LineStart = 1
	for Line, Text in Lines do
		local LineEnd = LineStart + #Text
		if Index <= LineEnd or Line == #Lines then
			return { Line = Line, Column = math.max(Index - LineStart + 1, 1), Offset = math.max(Index - 1, 0) }
		end

		LineStart = LineEnd + 1
	end

	return { Line = 1, Column = 1, Offset = 0 }
end

local function EncodePosition(Where: Position): Object
	return Object({ { "line", Where.Line }, { "column", Where.Column }, { "offset", Where.Offset } })
end

--- A span's `Start` is its first byte and `End` the byte after its last, so the range reads the same
--- way: `start` inclusive, `end` exclusive. An empty span points between two bytes.
local function EncodeRange(Lines: { string }, Span: Error.Span): Object
	return Object({
		{ "start", EncodePosition(Locate(Lines, Span.Start)) },
		{ "end", EncodePosition(Locate(Lines, math.max(Span.End, Span.Start))) },
	})
end

local function Describe(Diagnostic: Error.Class): Object
	local Labels: { Value } = {}
	for _, Label in Diagnostic.Labels do
		table.insert(
			Labels,
			Object({
				{ "primary", Label.Span == Diagnostic.PrimarySpan },
				{ "message", Label.Text },
				{ "range", EncodeRange(Diagnostic.Source, Label.Span) },
			})
		)
	end

	local Notes: { Value } = {}
	for _, Note in Diagnostic.Notes do
		table.insert(Notes, Note)
	end

	local Prefix = if Diagnostic.Severity == "Warning" then "W" else "E"
	return Object({
		{ "severity", string.lower(Diagnostic.Severity) },
		{ "code", `{Prefix}{string.format("%04i", Diagnostic.Code)}` },
		{ "name", Error.GetNameFromCode(Diagnostic.Code) },
		{ "message", Diagnostic.RawMessage },
		{ "file", Diagnostic.File },
		{
			"range",
			if Diagnostic.PrimarySpan then EncodeRange(Diagnostic.Source, Diagnostic.PrimarySpan) else Null,
		},
		{ "labels", { Items = Labels } :: Array },
		{ "notes", { Items = Notes } :: Array },
	})
end

---- Public Functions ----

--- Installs a handler that takes every diagnostic the compile raises, warnings included, so none of
--- them is printed. An error still aborts the compile -- `Error.Emit` throws once the handler has it.
function Utility.Collect(): Collector
	local Collector: Collector = { Diagnostics = {}, Failed = false }
	Error.OnEmit = function(Diagnostic: Error.Class): boolean?
		if Diagnostic.Severity == "Error" then
			Collector.Failed = true
		end

		table.insert(Collector.Diagnostics, Describe(Diagnostic))
		return true
	end

	return Collector
end

--- A failure that is not a diagnostic: a missing schema, a schema without an output path, a file
--- that could not be written. It still has to come out as JSON, or a caller reading standard output
--- gets nothing to parse on exactly the runs it most needs to understand.
function Utility.Fail(Collector: Collector, File: string, Message: string)
	--> Lune appends the stack trace to a runtime error's text. It locates the compiler, not the fault.
	Message = string.gsub(Message, "\n?stack traceback:.*$", "")
	Collector.Failed = true
	table.insert(
		Collector.Diagnostics,
		Object({
			{ "severity", "error" },
			{ "code", Null },
			{ "name", Null },
			{ "message", Message },
			{ "file", File },
			{ "range", Null },
			{ "labels", { Items = {} } :: Array },
			{ "notes", { Items = {} } :: Array },
		})
	)
end

--- `Verified` is given under `--verify` alone, and only then does the document carry a `verify`
--- field: its absence tells a reader that nothing was compared, where an empty list could not.
function Utility.Encode(Collector: Collector, Outputs: { string }, Verified: { Verify.Entry }?): string
	local Written: { Value } = {}
	for _, Path in Outputs do
		table.insert(Written, Path)
	end

	local Fields: { { any } } = {
		{ "version", FORMAT_VERSION },
		{ "success", not Collector.Failed },
		{ "diagnostics", { Items = Collector.Diagnostics } :: Array },
		{ "outputs", { Items = Written } :: Array },
	}

	if Verified then
		local Compared: { Value } = {}
		for _, Entry in Verified do
			table.insert(
				Compared,
				Object({
					{ "file", Entry.Path },
					{ "status", Entry.Status },
					{ "line", if Entry.Line then Entry.Line else Null },
				})
			)
		end

		local Field: { any } = { "verify", { Items = Compared } :: Array }
		table.insert(Fields, Field)
	end

	return Encode(Object(Fields))
end

return Utility
