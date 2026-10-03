--!strict
--!native
--!optimize 2

--- The composite types: sets, maps, enums, tagged enums, type packs and structs.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local ParserClass = require("./Class")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type TypeNode = ParserClass.TypeNode
type Declaration = ParserClass.Declaration
type Optional = ParserClass.Optional
type Set = ParserClass.Set
type Map = ParserClass.Map
type Enum = ParserClass.Enum
type TagEnum = ParserClass.TagEnum
type Struct = ParserClass.Struct
type Tuple = ParserClass.Tuple

local LUAU_KEYWORDS = Grammar.LUAU_KEYWORDS

local Parser = ParserClass.Class

--- An enum's value, and a tagged enum's variant, travel as a one-byte index. A 257th was written as
--- index 0 -- `writeu8` keeps the low byte -- and decoded as the first, with a tagged enum then
--- reading the first variant's fields out of the 257th's bytes. And an enum with nothing in it gave
--- the generator nothing to index, and it failed with an internal error. `Count` is how many there are
--- once `Token` is added; `Token` is the opening brace when checking a list that turned out empty.
local function EnsureIndexable(self: Parser, Token: Token, Count: number, Noun: string)
	if Count > 256 then
		error(
			self:Diagnostic(Error.AnalyzeEnumSize, `Too many {Noun}s`)
				:Primary(Token, `The 257th {Noun}`)
				:Note(`Each {Noun} is sent as a one-byte index, so an enum holds at most 256.`)
				:Emit()
		)
	elseif Count == 0 then
		error(
			self:Diagnostic(Error.AnalyzeEnumSize, "Empty enum")
				:Primary(Token, `An enum needs at least one {Noun}`)
				:Emit()
		)
	end
end

--- Reads a set's flags or an enum's values: a braced list of names, each allowed once. A repeat was
--- accepted, and meant a flag taking two bits that always travel together, or an enum index the
--- writer never sends because the first of the two always matches.
local function ReadNames(self: Parser, Noun: string, Indexed: boolean?): { string }
	local Values: { string } = {}
	local Seen: { [string]: true } = {}

	local Opening = self:List("OpenBraces", "CloseBraces", function()
		local Token = self:ConsumeText(true, true)
		if Seen[Token.Value] then
			error(
				self:Diagnostic(Error.AnalyzeDuplicateField, `Duplicate {Noun} "{Token.Value}"`)
					:Primary(Token, `Duplicate {Noun}`)
					:Emit()
			)
		end

		if Indexed then
			EnsureIndexable(self, Token, #Values + 1, Noun)
		end

		Seen[Token.Value] = true
		table.insert(Values, Token.Value)
	end)

	if Indexed and #Values == 0 then
		EnsureIndexable(self, Opening, 0, Noun)
	end

	return Values
end

function Parser.Set(self: Parser, Name: Token): Set
	local Values = ReadNames(self, "flag")

	return {
		Type = "Set",
		Name = Name.Value,
		Value = {
			Values = Values,
		},
		Tokens = {},
	} :: Set
end

function Parser.Map(self: Parser, Name: Token): Map
	self:ConsumeAll("OpenBraces", "OpenBrackets")

	--> Errors
	local function ParseElement(): (TypeNode, Token)
		local Token = self:Peek()
		local Declaration = self:Type(Name)
		if Declaration.Type == "Optional" then
			self:Diagnostic(Error.AnalyzeInvalidOptionalType, "Invalid optional type")
				:Primary(Token, `Maps cannot have optionals as keys or values`)
				:Emit()
		end

		return Declaration, Token
	end

	--> Parse key and value
	local Key, KeyToken = ParseElement()
	self:Consume("CloseBrackets")
	self:Consume("FieldAssign")

	local Value = ParseElement()
	self:Consume("CloseBraces")

	return {
		Type = "Map",
		Name = Name.Value,
		Value = {
			Values = { Key, Value },
		},
		--> Kept so a diagnostic about the key can underline the key rather than the declaration. A
		--> composite key is a node with no token of its own, and Analysis runs after generics are
		--> substituted, by which point there is nothing left to point at without this.
		Tokens = { Key = KeyToken },
	}
end

function Parser.Enum(self: Parser, Name: Token): Enum | TagEnum
	--> Is it a tagged enum?
	local Tag = self:TryConsume("String")
	if Tag then
		return self:TagEnum(Tag, Name)
	end

	local Values = ReadNames(self, "value", true)

	return {
		Type = "Enum",
		Name = Name.Value,
		Value = { Values = Values } :: any,
		Tokens = {},
	}
end

function Parser.TagEnum(self: Parser, Tag: Token, Name: Token): TagEnum
	local Values: { Struct } = {}
	local Seen: { [string]: true } = {}

	local Opening = self:List("OpenBraces", "CloseBraces", function()
		local Token: Token

		if self:Peek().Type == "OpenBrackets" then
			self:Consume("OpenBrackets")
			Token = self:Consume("String")
			self:Consume("CloseBrackets")
		else
			Token = self:ConsumeText(true)
		end

		--> The writer dispatches on the variant's name, so a second variant of the same name could
		--> never be sent: the first always matches.
		if Seen[Token.Value] then
			error(
				self:Diagnostic(Error.AnalyzeDuplicateField, `Duplicate variant "{Token.Value}"`)
					:Primary(Token, `Duplicate variant`)
					:Emit()
			)
		end

		EnsureIndexable(self, Token, #Values + 1, "variant")
		Seen[Token.Value] = true

		local Struct = self:Struct(Token)
		local Fields = Struct.Value.Values

		--> Don't allow tag field to be set
		for _, Field: TypeNode in Fields do
			if Field.Name == Tag.Value then
				self:Diagnostic(Error.AnalyzeReservedIdentifier, `Enum tag used as field in variant`)
					:Secondary(Token, `Used in variant`)
					:Primary(Tag, `Enum tag`)
					:Emit()
			end
		end

		table.insert(Values, Struct)
	end)

	if #Values == 0 then
		EnsureIndexable(self, Opening, 0, "variant")
	end

	return {
		Type = "TagEnum",
		Name = Name.Value,
		Value = {
			Tag = Tag.Value,
			Values = Values,
		},
		Tokens = {},
	}
end

function Parser.Tuple(self: Parser, Name: Token): Tuple
	local Names: { [number]: string } = {}
	local Taken: { [string]: true } = {}
	local Values: { TypeNode } = {}

	--> An element may carry a name: `(chefId: f64, dish: string)`. Deciding that needs one token of
	--> lookahead past the candidate -- `(u8)` and `(x: u8)` are indistinguishable where the element
	--> starts, since a bare type is itself a perfectly good element. `self.LookAhead` is the element's
	--> first token and the lexer sits just past it, so a non-advancing GetNextToken is the token after.
	local function TryConsumeName(): Token?
		if self.Lexer:GetNextToken(true).Type ~= "FieldAssign" then
			return nil
		end

		local Text = self:ConsumeText(true)
		self:Consume("FieldAssign")
		return Text
	end

	self:List("OpenParentheses", "CloseParentheses", function()
		local Text = TryConsumeName()
		if Text then
			--> Unlike a struct field, which becomes a table key and is quoted on the way out, this name
			--> becomes a local variable in the generated module. A Luau keyword, or anything that is not
			--> an identifier, would emit code that does not compile -- so it is refused here, where the
			--> author can see which name did it, rather than by luau-analyze over generated output.
			if LUAU_KEYWORDS[Text.Value] or not string.match(Text.Value, "^[%a_][%w_]*$") then
				error(
					self:Diagnostic(Error.AnalyzeReservedIdentifier, `"{Text.Value}" cannot name a type pack element`)
						:Primary(Text, "Not usable as a variable name")
						:Note(
							"A named element becomes a parameter in the generated code, so it has to be a Luau identifier."
						)
						:Emit()
				)
			end

			if Grammar.WRAPPER_NAMES[Text.Value] then
				error(
					self:Diagnostic(Error.AnalyzeReservedIdentifier, `"{Text.Value}" cannot name a type pack element`)
						:Primary(Text, "Used by the generated code")
						:Note(
							"A named element becomes a parameter of the generated Fire and Invoke, whose bodies already use this name."
						)
						:Emit()
				)
			end

			if Taken[Text.Value] then
				error(
					self:Diagnostic(Error.AnalyzeDuplicateField, `Duplicate element "{Text.Value}"`)
						:Primary(Text, `Duplicate element`)
						:Note("Each named element of a type pack becomes a parameter, so the names must differ.")
						:Emit()
				)
			end
		end

		--> The pack's own token goes through even for a named element. The name is recorded beside the
		--> value instead of replacing the node's, so a named and an unnamed element are described
		--> identically -- a diagnostic inside either still points at the declaration, and the
		--> generated comment still reads `chefId: NamedTuple` rather than `chefId: chefId`.
		local Value = self:Type(Name)
		table.insert(Values, Value)

		if Text then
			Taken[Text.Value] = true
			Names[#Values] = Text.Value
		end
	end)

	return {
		Type = "Tuple",
		Name = Name.Value,
		Value = {
			Values = Values,
			Names = Names,
		},
		Tokens = {},
	}
end

function Parser.Struct(self: Parser, Name: Token): Struct
	local Fields: { [string]: true } = {}
	local Values: { TypeNode } = {}

	self:List("OpenBraces", "CloseBraces", function()
		--> struct merging
		if self:TryConsume("Merge") then
			local Text = self:Peek()
			local Declaration = self:Declaration(Name)
			if Declaration.Type ~= "Struct" then
				error(
					self:Diagnostic(
						Error.AnalyzeReferenceInvalidType,
						`Expected a struct to merge, got "{Declaration.Type}" instead`
					)
						:Primary(Text, `Expected a "Struct", got "{Declaration.Type}" instead`)
						:Emit()
				)
			end

			local Struct: Struct = Declaration :: Struct
			local StructValues = Struct.Value.Values
			for _, Field in StructValues do
				local FieldIdentifier = Field.Name
				if Fields[FieldIdentifier] then
					error(
						self:Diagnostic(Error.AnalyzeDuplicateField, `Merged struct contains a duplicate field`)
							:Primary(Text, `Field "{FieldIdentifier}" already exists in struct`)
							:Emit()
					)
				end

				table.insert(Values, Field)
				Fields[FieldIdentifier] = true
			end
		else --> fields
			local Text: Token

			if self:Peek().Type == "OpenBrackets" then
				self:Consume("OpenBrackets")
				Text = self:Consume("String")
				self:Consume("CloseBrackets")
			else
				Text = self:ConsumeText(true)
			end

			if Fields[Text.Value] then
				error(
					self:Diagnostic(Error.AnalyzeDuplicateField, `Duplicate field "{Text.Value}"`)
						:Primary(Text, `Duplicate field`)
						:Emit()
				)
			end

			self:Consume("FieldAssign")

			Fields[Text.Value] = true
			table.insert(Values, self:Type(Text))
		end
	end)

	return {
		Type = "Struct",
		Name = Name.Value,
		Value = {
			Values = Values,
		},
		Tokens = {},
	}
end

return Parser
