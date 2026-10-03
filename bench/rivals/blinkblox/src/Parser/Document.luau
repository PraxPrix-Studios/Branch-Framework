--!strict
--!native
--!optimize 2

--- A whole file: options, imports and the top-level declarations, and the analysis that runs
--- once every declaration is known.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Analysis = require("../Analysis")
local AttributeParser = require("../Modules/Attributes")
local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local OptionsParser = require("../Modules/Options")
local ParserClass = require("./Class")
local PathParser = require("../Modules/Path")
local Size = require("../Modules/Size")
local SourceReader = require("../Modules/Source")

type Parser = ParserClass.Parser
type Bucket = Grammar.Bucket
type Token = ParserClass.Token
type Generics = ParserClass.Generics
type Reference = ParserClass.Reference
type Attributes = ParserClass.Attributes
type Declarations = ParserClass.Declarations
type Scope = ParserClass.Scope
type Options = ParserClass.Options
type Body = ParserClass.Body
type Declaration = ParserClass.Declaration
type Enum = ParserClass.Enum
type Generic = ParserClass.Generic
type Event = ParserClass.Event
type Function = ParserClass.Function
type ScopeNode = ParserClass.ScopeNode

local BUCKETS = Grammar.BUCKETS
local KEYWORDS = Grammar.KEYWORDS

local Parser = ParserClass.Class

function Parser.Parse(self: Parser, Source: string, Scope: Scope?): Body
	--> Set state. A parse without a scope is a document's own, not an import's: an import shares the
	--> importing parser's attribute state, which has to survive into it.
	if Scope == nil then
		AttributeParser.Reset(self.Attributes)
	end
	self.Scope = Scope or { Name = { Value = "", Start = 0, End = 0 } :: any, Symbols = { Types = {}, Scopes = {} } }
	self.Source = Source
	table.clear(self.Symbols)

	--> Start the lexer
	self.Lexer:Initialize(Source, self.File)
	self.LookAhead = self.Lexer:GetNextToken()

	--> Cast because Luau will not match a metatable-backed type against a structural one, however
	--> exactly it fits. Modules/Options and Modules/Attributes want members this has; naming them in
	--> Reader types there rather than requiring Parser back is what keeps them out of a require cycle.
	local Options = OptionsParser.Parse(self :: any)
	local Declarations = self:Declarations()

	Options.SyncValidation = if Options.SyncValidation ~= nil then Options.SyncValidation else true

	Analysis.Run(self.Source, self.File, Declarations, Options)

	return {
		Type = "Body",
		Name = Scope and Scope.Name.Value or "Body",
		Value = {
			Symbols = table.clone(self.Symbols),
			Options = Options,
			Declarations = Declarations,
		},
		Tokens = {},
	}
end

function Parser.Import(self: Parser): ScopeNode
	self:Consume("Import")

	local Path = self:Consume("String")
	local ImportPath = Path.Value
	local ImportSource, ImportDirectory, Resolved = SourceReader.Read(ImportPath, self.Directory)

	if not ImportSource then
		error(
			self:Diagnostic(Error.AnalyzeUnknownImport, `Unknown require`)
				:Primary(Path, `Unknown require: "{ImportPath}"`)
				:Emit()
		)
	end

	local Name: string
	local Token = Path

	if self:TryConsume("As") then
		--> Use user provided namespace identifier
		Token = self:ConsumeText()
		Name = Token.Value
	elseif task ~= nil then
		--> ROBLOX
		local Indices = string.split(ImportPath, ".")
		Name = Indices[#Indices]
	else
		if PathParser.PathType(ImportPath) == "absolute" and string.sub(ImportPath, 1, 2) ~= "./" then
			ImportPath = `./{ImportPath}`
		end

		--> Use file name as namespace identifier
		local Filename = PathParser.Filename(ImportPath)
		assert(Filename, "Unable to parse file path for filename!")

		Name = Filename
		Token.Value = Filename
	end

	local Existing = self:Reference("Scopes", Name)
	if Existing then
		self:Diagnostic(Error.AnalyzeDuplicateDeclaration, `Duplicate declaration: "{Name}"`)
			:Secondary(Existing.Name, "Previously declared here")
			:Primary(Token, "Duplicate declared here")
			:Emit()
	end

	local Parent = self.Scope
	local Scope: Scope = {
		Name = Token,
		Symbols = {
			Types = {},
			Scopes = {},
		},
	}

	--> Two files that import each other used to recurse until the Luau stack gave out, which
	--> reports a stack overflow from somewhere deep in the lexer and names neither file. There is no
	--> memoisation here -- an import is re-parsed every time it is reached -- so the only thing that
	--> ends the recursion is noticing it.
	-->
	--> Keyed on the file, and cleared once the parse RETURNS rather than left set, because a diamond
	--> (two files importing a third) reaches the same file twice by two routes and is perfectly
	--> legal. Only a file reached while it is still being parsed is a cycle.
	local Key = PathParser.Normalise(Resolved or ImportPath)
	if self.Importing[Key] then
		error(
			self:Diagnostic(Error.AnalyzeCyclicImport, `Cyclic import`)
				:Primary(Path, `"{ImportPath}" is already being imported, so this would never finish`)
				:Emit()
		)
	end

	local Imported: Body
	--> The resolved path, not the one the import wrote: that one is relative to whichever file wrote
	--> it, so a diagnostic naming it could not be found again from anywhere else.
	local ImportParser = Parser.new(ImportDirectory, Key, self.Importing, self.Attributes)

	self.Importing[Key] = true
	local Success, ErrorText = pcall(function()
		Imported = ImportParser:Parse(ImportSource, Scope)
	end)
	self.Importing[Key] = nil

	--> Level 0: the text is already a rendered diagnostic, and re-raising it at the default level
	--> prepends this file and line every time it passes through an import. A cycle three files deep
	--> arrived with three "Parser:905:" prefixes in front of the frame the reader actually wants.
	if not Success then
		error(ErrorText, 0)
	end

	Scope.Parent = Parent
	self.Symbols[Name] = true
	Parent.Symbols.Scopes[Name] = Scope

	return {
		Type = "Scope",
		Name = Name,
		Value = {
			Scope = Scope,
			Values = Imported.Value.Declarations,
			Imported = true,
		},
		Tokens = { Path = Path },
	}
end

function Parser.Declarations(self: Parser): { Declaration }
	local Declarations = {}
	while true do
		if self:TryConsume("EndOfFile") then
			break
		end

		if self.Scope and self:TryConsume("CloseBraces") then
			break
		end

		local Previous = AttributeParser.Open(self :: any)
		local LookAhead = self:Peek()
		if LookAhead.Type == "Import" then
			AttributeParser.Close(self :: any, Previous, self:Import(), Declarations)
			continue
		end

		--> Is standalone/exported?
		local Export: Token?
		if LookAhead.Type == "Keyword" and LookAhead.Value == "export" then
			Export = self:Consume("Keyword")
		end

		local Keyword = self:Consume("Keyword")
		local Name = self:ConsumeText()
		local Declaration: Declaration

		if Keyword.Value == "option" then
			self:Diagnostic(Error.AnalyzeOptionAfterStart, "Option set after start of file")
				:Primary(Keyword, "Move to the start of the file")
				:Emit()
		end

		--> Prevent duplicates
		local KeywordSettings = KEYWORDS[Keyword.Value]
		local Type = KeywordSettings.Class

		local Bucket: Bucket = BUCKETS[Type]
		local Existing = self:Reference(Bucket, Name.Value)

		if Existing then
			self:Diagnostic(Error.AnalyzeDuplicateDeclaration, `Duplicate declaration`)
				:Secondary(Existing.Name, "Previously declared here")
				:Primary(Name, "Duplicate declared here")
				:Emit()
		end

		--> Generics
		local Generics: Generics?
		if KeywordSettings.Generics then
			Generics = self:GetGenerics()
		end

		--> Parse declaration
		-->
		--> Saved and restored rather than cleared: a namespace parses its members while its own
		--> declaration is still open, and clearing would lose the outer name on the way back out.
		local Enclosing = self.Declaring
		self.Declaring = Name.Value

		if Type == "Type" then
			local Node = self:Type(Name, Keyword)
			local Value: Attributes = Node.Value
			Value.Scope = self.Scope
			Declaration = Node
		elseif Type == "Event" then
			Declaration = self:Event(Name)
		elseif Type == "Function" then
			Declaration = self:Function(Name)
		elseif Type == "Scope" then
			Declaration = self:Namespace(Name)
		end

		self.Declaring = Enclosing

		AttributeParser.Close(self :: any, Previous, Declaration, Declarations)

		if Export then
			--> Prevent non exportable types from being exported
			if not KeywordSettings.Exportable then
				self:Diagnostic(Error.AnalyzeInvalidExport, `Declaration of type "{Keyword.Value}" is not exportable`)
					:Primary(Export, `Remove export here`)
					:Emit()
			--> Prevent types with generics from being exported
			elseif Generics then
				self:Diagnostic(Error.AnalyzeInvalidExport, `Generic types can't be exported`)
					:Primary(Export, `Remove export here`)
					:Emit()
			end

			--> An exported type gets a standalone Read/Write pair. Instances and unknowns are never
			--> encoded into the buffer -- they are appended to a table that travels as the remote's
			--> second argument -- and an export has no remote and no such table, so the value would
			--> be silently lost on write and read back as nil. Nothing checked this before.
			local Measured = Size.Sealed(Declaration :: any)
			if Measured.Refs > 0 then
				self:Diagnostic(Error.AnalyzeInvalidExport, `Types containing an Instance or unknown can't be exported`)
					:Primary(Export, "Remove export here")
					:Secondary(Name, `"{Name.Value}" carries a value that travels beside the buffer`)
					:Note("An exported Read/Write pair only has the buffer, so such a value cannot survive it.")
					:Emit()
			end

			Declaration.Value.Export = true
		end

		if Generics then
			if Declaration.Type == "Enum" then
				self:Diagnostic(Error.AnalyzeInvalidGenerics, `Unit enums don't support generics`)
					:Primary(Generics.Span, "Remove generics")
					:Emit()
			end

			self.Generics = nil
			Declaration.Value.Generics = Generics
		end

		if Type ~= "Scope" then
			self:SetReference(Bucket, Name, Declaration)
		end
	end

	return Declarations
end

return Parser
