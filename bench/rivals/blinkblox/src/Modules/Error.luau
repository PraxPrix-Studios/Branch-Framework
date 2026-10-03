--!strict
--!native
--!optimize 2

--> Dual-target probe: this module runs on Lune for the CLI and inside Roblox for the Studio
--> plugin. Roblox type defs declare `game` as a non-nullable DataModel, so the comparison only
--> type-checks through `any` — at runtime on Lune the global is genuinely absent.
local IS_ROBLOX = ((game :: any) ~= nil)

local stdio
local process
if not IS_ROBLOX then
	stdio = require("@lune/stdio")
	process = require("@lune/process")
end

type Slice = {
	Line: number,
	Text: string,
	Spaces: number,
	Underlines: number,
}

export type Label = {
	Span: Span,
	Text: string,
}

type Color = "red" | "green" | "blue" | "black" | "white" | "cyan" | "purple" | "yellow" | "reset"

export type Span = {
	Start: number,
	End: number,
}

--- Errors abort the compile; warnings are rendered and then execution continues. Anything that is
--- merely suspicious -- a type whose maximum serialised size cannot be bounded, a deprecated option
--- -- has to be a warning, because refusing to compile a schema that might be fine is worse than
--- letting it through with a note.
export type Severity = "Error" | "Warning"

local SpecialSymbols = {
	CLI = {
		Line = "─",
		Down = "│",
		DownDash = "┆",
		Cross = "┬",
		RightUp = "╭",
		LeftDown = "╯",
		RightDown = "╰",
	},
	ROBLOX = {
		Line = "-",
		Down = "|",
		DownDash = " ",
		Cross = "-",
		RightUp = "╭",
		LeftDown = "╯",
		RightDown = "╰",
	},
}

local Colors = {
	black = "rgb(0, 0, 0)",
	blue = "rgb(0, 0, 255)",
	cyan = "rgb(0, 255, 255)",
	green = "rgb(0, 255, 0)",
	purple = "rgb(163, 44, 196)",
	red = "rgb(255, 0, 0)",
	white = "rgb(255, 255, 255)",
	yellow = "rgb(255, 255, 0)",
}

local Compact = false

--- Diagnostic codes, banded by the stage that raises them: 1xxx lexing, 2xxx parsing, 3xxx
--- analysis. Assigned by hand and never renumbered -- the Invalid fixtures match on them and the
--- Studio plugin looks them up by number -- so the gaps below are deletions, not mistakes. A code
--- nothing raises is worse than no code: it reads as a condition the compiler checks for.
local Error = {

	LexerUnexpectedToken = 1001,

	ParserUnexpectedEndOfFile = 2001,
	ParserUnexpectedToken = 2002,
	ParserUnknownOption = 2003,
	ParserExpectedExtraToken = 2005,

	AnalyzeReferenceInvalidType = 3001,
	AnalyzeInvalidOptionalType = 3002,
	AnalyzeDuplicateField = 3004,
	AnalyzeReservedIdentifier = 3005,
	AnalyzeUnknownReference = 3007,
	AnalyzeInvalidRangeType = 3008,
	AnalyzeInvalidRange = 3009,
	AnalyzeDuplicateDeclaration = 3010,
	AnalyzeInvalidGenerics = 3012,
	AnalyzeInvalidExport = 3013,
	AnalyzeUnknownImport = 3014,
	AnalyzeCyclicImport = 3015,
	AnalyzeOptionAfterStart = 3016,
	AnalyzeDeprecatedOption = 3017,
	AnalyzeOversizeUnreliable = 3018,
	AnalyzePotentiallyOversizeUnreliable = 3019,
	AnalyzeMissingRateLimit = 3020,
	AnalyzeCostlessRepetition = 3021,
	AnalyzeRecursiveType = 3022,
	AnalyzeInvalidComponents = 3023,
	AnalyzeDuplicateOption = 3024,
	AnalyzeUnknownAttribute = 3025,
	AnalyzeUnknownProfile = 3026,
	AnalyzeExcludedReference = 3027,
	AnalyzeMisplacedAttribute = 3028,
	AnalyzeEnumSize = 3029,
	AnalyzeChannelSize = 3030,
	AnalyzeInstanceWithoutSlots = 3031,
	AnalyzeInvalidModifier = 3032,
	AnalyzeInvalidStream = 3033,
	AnalyzeInvalidStamp = 3034,
	AnalyzeInvalidPriority = 3035,
}

Error.__index = Error

export type Class = typeof(setmetatable(
	{} :: {
		Labels: { Label },
		Source: { string },
		Message: string,

		Code: number,
		File: string,
		RawMessage: string,
		PrimarySpan: Span?,
		Severity: Severity,
		Notes: { string },
	},
	Error
))

--- Hook the Studio plugin installs to receive diagnostics instead of having them printed or thrown
--- (see the editor's `OnErrorEmitted`). Declared here rather than in the table literal above because
--- it refers to `Class`, and a field initialised to `nil` in the literal types as exactly `nil` —
--- which made every assignment to it a type error.
--- Returning true from it for a warning says the handler has shown it, so it is not also printed.
export type EmitHandler = (Error: Class) -> boolean?
Error.OnEmit = nil :: EmitHandler?

local Symbols = IS_ROBLOX and SpecialSymbols.ROBLOX or SpecialSymbols.CLI

local function Color(Text: string, ColorName: Color): string
	if IS_ROBLOX then
		return `<font color="{Colors[ColorName]}">{Text}</font>`
	end

	return `{stdio.color(ColorName)}{Text}{stdio.color("reset")}`
end

local function Style(Text: string, StyleName: "bold" | "dim"): string
	if IS_ROBLOX then
		return Text
	end

	return `{stdio.style(StyleName)}{Text}{stdio.style("reset")}`
end

function Error.SetCompact(Value: boolean)
	Compact = Value
end

function Error.GetNameFromCode(From: number): string
	for Name, Code in Error do
		if Code == From then
			return Name :: string
		end
	end

	error(`Unknown error code: {From}`)
end

function Error.new(Code: number, Source: string, Message: string, File: string?, Severity: Severity?): Class
	local Level: Severity = Severity or "Error"
	local Prefix = (Level == "Warning") and "W" or "E"
	local TextColor: Color = if Level == "Warning" then "yellow" else "red"

	local Lines = string.split(Source, "\n")
	local Content = `{Color(`[{Prefix}{string.format("%04i", Code)}] {Level}`, TextColor)}: {Message}`
	Content ..= `\n    {Symbols.RightUp}{Symbols.Line}[{File or "input.blink"}:1:{#Lines}]`
	Content ..= `\n    {Symbols.Down}`

	return setmetatable({
		Labels = {},
		Source = Lines,
		Message = Content,

		Code = Code,
		File = File or "input.blink",
		RawMessage = Message,
		Severity = Level,
		Notes = {},
	}, Error)
end

function Error.Slice(self: Class, Span: Span): { Slice }
	local Slices = {}
	local Cursor = 1

	for Line, Text in self.Source do
		local Start = Cursor
		local Length = #Text

		--> Advance cursor
		--> Cursor + #Length = \n => \n + 1 = Next line
		Cursor += (Length + 1)

		--> Span end is past cursor
		if Span.Start > Cursor then
			continue
		end

		local Spaces = (Span.Start - Start)

		--> `math.clamp` throws when max < min, and an EMPTY line has a length of zero -- so a span
		--> that reaches a blank line crashed the renderer instead of printing the diagnostic it was
		--> called to print. One underline is the floor: there is always something to point at.
		local Underlines = math.clamp(Span.End - Span.Start, 1, math.max(Length, 1))

		table.insert(Slices, {
			Line = Line,
			Text = Text,
			Spaces = Spaces,
			Underlines = Underlines,
		})

		if Span.End <= Cursor then
			break
		end
	end

	return Slices
end

function Error.Label(self: Class, Span: Span, Text: string, TextColor: Color): Class
	local Slices = self:Slice(Span)

	--> Analyze hook
	table.insert(self.Labels, {
		Span = Span,
		Text = Text,
	})

	--> Construct message
	for Index, Slice in Slices do
		self.Message ..= `\n{Style(string.format("%03i", Slice.Line), "dim")} {Symbols.Down} {Slice.Text}`
		if Index == #Slices then
			local Length = (Slice.Underlines // 2)
			local Indent = `    {Symbols.DownDash} {string.rep(" ", Slice.Spaces)}`
			local Underlines = Color(string.rep(Symbols.Line, Length), TextColor)
			local ExtraIndent = string.rep(" ", Length)

			self.Message ..= `\n{Indent}{Underlines}{Color(Symbols.Cross, TextColor)}{Underlines}`
			self.Message ..= `\n{Indent}{ExtraIndent}{Color(Symbols.Down, TextColor)}`
			self.Message ..= `\n{Indent}{ExtraIndent}{Color(
				`{Symbols.RightDown}{Symbols.Line}{Symbols.Line}`,
				TextColor
			)} {Color(Text, TextColor)}`
		end
	end

	return self
end

function Error.Primary(self: Class, Span: Span, Text: string): Class
	self.PrimarySpan = Span
	--> A warning's primary label follows its header colour; a red underline under a yellow header
	--> reads as an error the reader then has to un-read.
	local LabelColor: Color = if self.Severity == "Warning" then "yellow" else "red"
	return self:Label(Span, Text, LabelColor)
end

function Error.Secondary(self: Class, Span: Span, Text: string): Class
	return self:Label(Span, Text, "blue")
end

--- A trailing line that says what to do about the diagnostic, rendered under the labels. A label
--- points at what is wrong; a note points at the fix, and the two read badly when merged.
function Error.Note(self: Class, Text: string): Class
	table.insert(self.Notes, Text)
	return self
end

--- Closes the gutter. Shared by Emit and Warn so the two render identically -- only what happens
--- afterwards differs.
local function Finalize(self: Class)
	for _, Note in self.Notes do
		self.Message ..= `\n    {Symbols.Down} {Style("= note:", "dim")} {Note}`
	end

	self.Message ..= `\n    {Symbols.Down}`
	self.Message ..= `\n{string.rep(Symbols.Line, 4)}{Symbols.LeftDown}\n`
end

--- Renders the diagnostic and RETURNS. The compile continues, so this is the only reporting path a
--- caller may use for something that does not invalidate the output.
function Error.Warn(self: Class)
	Finalize(self)

	local OnEmit: EmitHandler? = Error.OnEmit
	if OnEmit and OnEmit(self) == true then
		return
	end

	if IS_ROBLOX then
		warn(self.Message)
		return
	end

	if not stdio then
		return
	end

	if Compact then
		local LineStart = 0
		local LineFinish = 0

		if self.PrimarySpan then
			local Slices = self:Slice(self.PrimarySpan)
			LineStart = Slices[1].Line
			LineFinish = Slices[#Slices].Line
		end

		stdio.ewrite(
			string.format(
				"[W%04i] [L%03i:L%03i] [%s] Warning: %s\n",
				self.Code,
				LineStart,
				LineFinish,
				self.File,
				self.RawMessage
			)
		)
	else
		stdio.ewrite(self.Message)
	end
end

function Error.Emit(self: Class): never
	Finalize(self)

	--> A handler takes the error in every build, the released CLI included -- `--json` collects its
	--> diagnostics through one. Only with none installed does a release print and exit.
	local OnEmit: EmitHandler? = Error.OnEmit
	if IS_ROBLOX or _G.RELEASE == nil or OnEmit then
		if OnEmit then
			OnEmit(self)
		end

		error(self.Message, 2)
	elseif stdio and process then
		if Compact then
			local LineStart = 0
			local LineFinish = 0

			if self.PrimarySpan then
				local Slices = self:Slice(self.PrimarySpan)
				LineStart = Slices[1].Line
				LineFinish = Slices[#Slices].Line
			end

			stdio.ewrite(
				string.format(
					"[E%04i] [L%03i:L%03i] [%s] Error: %s",
					self.Code,
					LineStart,
					LineFinish,
					self.File,
					self.RawMessage
				)
			)
		else
			stdio.ewrite(self.Message)
		end

		if _G.WATCH_THREAD then
			error(self.RawMessage)
		else
			process.exit(1)
		end
	end

	error("never")
end

return Error
