--!strict
--!native
--!optimize 2

--- Names: resolving a reference against the scopes, registering a declaration, and generics --
--- reading a template's parameter list and substituting arguments into a copy of it.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local AttributeParser = require("../Modules/Attributes")
local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local ParserClass = require("./Class")
local Table = require("../Modules/Table")
local Walk = require("../Modules/Walk")

type Parser = ParserClass.Parser
type Bucket = Grammar.Bucket
type Token = ParserClass.Token
type Generics = ParserClass.Generics
type Reference = ParserClass.Reference
type Scope = ParserClass.Scope
type TypeNode = ParserClass.TypeNode
type Declaration = ParserClass.Declaration
type Struct = ParserClass.Struct
type Generic = ParserClass.Generic

local RESERVED = Grammar.RESERVED
local GENERICS_TYPES = Grammar.GENERICS_TYPES

local Parser = ParserClass.Class

function Parser.Reference(self: Parser, Bucket: Bucket, Identifier: string): (Scope | Reference)?
	local Path = string.split(Identifier, ".")
	local Scope: Scope? = self.Scope

	local Offset = 1
	local Length = #Path
	local Result

	while Scope do
		local Index = Path[Offset]
		if not Index then
			break
		end

		local Symbols = Scope.Symbols
		local Symbol = if Offset == Length then Symbols[Bucket][Index] else Symbols.Scopes[Index]

		--> Nothing found in the current scope search upwards
		if Symbol == nil then
			Scope = Scope.Parent
			continue
		end

		--> We found a scope, start searching in it
		if Symbol and Offset < Length then
			Offset += 1
			Scope = Symbol :: any
			continue
		end

		--> Found the reference
		Result = Symbol
		break
	end

	return Result
end

function Parser.SetReference(self: Parser, Bucket: Bucket, Identifier: Token, Declaration: Declaration)
	local Name = Identifier.Value

	if RESERVED[Name] then
		self:Diagnostic(Error.AnalyzeReservedIdentifier, `Reserved identifier`)
			:Primary(Identifier, `"{Name}" is reserved and cannot be used as an identifier.`)
			:Emit()
	end

	--> Events and functions share the bucket but become table keys, not types, so only a type is held
	--> to it.
	local Kind = Declaration.Type
	if Bucket == "Types" and Kind ~= "Event" and Kind ~= "Function" and Grammar.LUAU_TYPES[Name] then
		self:Diagnostic(Error.AnalyzeReservedIdentifier, `Reserved identifier`)
			:Primary(Identifier, `"{Name}" is a Luau type, and a declared type is exported under its own name`)
			:Note("Luau refuses to redefine its built-in types. Rename the declaration.")
			:Emit()
	end

	self.Symbols[Name] = true
	self.Scope.Symbols[Bucket][Name] = {
		To = Declaration,
		Name = Identifier,
	} :: Reference
end

function Parser.GetGenerics(self: Parser): Generics?
	if self.Generics then
		return self.Generics
	end

	local OpenChevrons = self:TryConsume("OpenChevrons")
	if not OpenChevrons then
		return
	end

	--> Parse generics
	local Generics: Generics = {
		Keys = {},
		List = {},
		Span = {
			Start = OpenChevrons.Start,
			End = OpenChevrons.End + 1,
		},
	}

	while true do
		if self:TryConsume("CloseChevrons") then
			break
		end

		local Token = self:ConsumeText()

		Generics.Span.End = Token.End
		Generics.Keys[Token.Value] = {}
		table.insert(Generics.List, Token.Value)

		if self:Peek().Type ~= "CloseChevrons" then
			self:Consume("Comma")
		end
	end

	self.Generics = Generics
	return Generics
end

--> What a generic's substitution refers to rather than copies. A declared type records the scope it
--> was declared in, and that scope holds the symbol table of everything declared beside it; copying
--> it with the node copied the schema's whole symbol table for every generic argument substituted.
--> That was nine tenths of the time Test.blink took to parse. A scope is shared by every node in it,
--> never owned by one, so a copy of a node belongs to the same one.
local SHARED: { [any]: true } = { Scope = true }

function Parser.ReplaceGenerics(self: Parser, Of: TypeNode): TypeNode
	local Clone = Table.DeepClone(Of, SHARED) :: Struct
	local Generics = Clone.Value.Generics :: Generics
	local Replacements: { [string]: TypeNode } = {}

	Clone.Value.Generics = nil

	--> Parse generics input
	self:Consume("OpenChevrons")

	for Index = 1, #Generics.List do
		local Key = Generics.List[Index]
		local List = Generics.Keys[Key]

		local Token = self:Peek()
		local Declaration = self:Type(Token)
		Replacements[Key] = Declaration

		for _, Generic in List do
			local Replacement = Table.DeepClone(Declaration, SHARED)

			Generic.Type = Replacement.Type
			Generic.Value = Replacement.Value
			Generic.Tokens = Replacement.Tokens
		end

		if Index < #Generics.List then
			self:Consume("Comma")
		end
	end

	--> A trailing comma, as every other list in the language accepts. The count is still exact: one
	--> argument short fails at the comma above, one too many at the closing chevron below.
	self:TryConsume("Comma")
	self:Consume("CloseChevrons")

	--> hack to find lost references
	-->
	--> Not `Walk.Type`: that would go on into a node just substituted, and the argument may itself
	--> hold a generic of the ENCLOSING template under the same name, which must be left for that
	--> template to substitute.
	local function Traverse(Type: TypeNode)
		if Type.Type ~= "Generic" then
			for _, Nested in Walk.Children(Type) do
				Traverse(Nested)
			end

			return
		end

		local Key = Type.Value.Generic
		local Declaration = Replacements[Key]
		if Declaration == nil then
			return
		end

		local Replacement = Table.DeepClone(Declaration, SHARED)

		Type.Type = Replacement.Type
		Type.Value = Replacement.Value
		Type.Tokens = Replacement.Tokens
	end

	Traverse(Clone)

	return Clone
end

function Parser.Declaration(self: Parser, Name: Token): TypeNode
	local Token = self:ConsumeText()

	--> Generics reference resolution
	local Generics = self.Generics
	local List = (Generics and Generics.Keys[Token.Value])
	if List then
		local Generic: Generic = {
			Type = "Generic",
			Name = Name.Value,
			Value = { Generic = Token.Value },
			Tokens = {},
		}

		table.insert(List, Generic)
		return Generic
	end

	--> Normal reference resolution
	local Reference = self:Reference("Types", Token.Value) :: Reference
	if not Reference then
		--> A type that names itself reported "Unknown reference", which is true and useless: the
		--> name is missing only because a declaration is registered after it closes, and the reader
		--> is left checking their spelling of a word that is on the screen in front of them.
		-->
		--> Recursive types are not supported at all here, optional field or not. References are
		--> resolved and inlined at parse time rather than held as a link, so there is no point at
		--> which the parser could tie the knot.
		if self.Declaring ~= nil and Token.Value == self.Declaring then
			error(
				self:Diagnostic(Error.AnalyzeRecursiveType, `Recursive type`)
					:Primary(Token, `"{Token.Value}" refers to itself`)
					:Note(
						"A declaration is only in scope once it closes, and references are inlined where they appear, so a type cannot contain another of itself."
					)
					:Emit()
			)
		end

		error(
			self:Diagnostic(Error.AnalyzeUnknownReference, `Unknown reference`)
				:Primary(Token, "Unknown reference")
				:Emit()
		)
	end

	local To = Reference.To
	AttributeParser.Refer(self :: any, Token, To)

	--> Need to use the new node name.
	--> `TypeNode` is a union of node shapes, and Luau permits neither `table.clone` nor a field write
	--> on a union. The rename therefore happens on a loose clone, which is then narrowed back on the
	--> way out; the clone stays shallow either way.
	local Renamed = table.clone(To :: any)
	Renamed.Name = Name.Value
	To = Renamed :: TypeNode

	if GENERICS_TYPES[To.Type] and To.Value.Generics then
		To = self:ReplaceGenerics(To)
	end

	return To
end

return Parser
