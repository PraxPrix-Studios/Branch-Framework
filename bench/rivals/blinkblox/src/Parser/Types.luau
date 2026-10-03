--!strict
--!native
--!optimize 2

--- The type grammar: the keyword dispatch in `Type`, and primitives.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local Lexer = require("../Lexer")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type Attributes = ParserClass.Attributes
type AttributesTokens = ParserClass.AttributesTokens
type Declarations = ParserClass.Declarations
type TypeNode = ParserClass.TypeNode
type Declaration = ParserClass.Declaration
type Array = ParserClass.Array
type Optional = ParserClass.Optional
type Set = ParserClass.Set
type Map = ParserClass.Map
type Enum = ParserClass.Enum
type TagEnum = ParserClass.TagEnum
type Struct = ParserClass.Struct
type Primitive = ParserClass.Primitive
type Tuple = ParserClass.Tuple

local KEYWORDS = Grammar.KEYWORDS
local PRIMITIVES = Settings.Primtives

local Parser = ParserClass.Class

local function IsDeclarationTypeSimiliar(A: Declarations, B: Declarations): boolean
	if A == B then
		return true
	end

	if A == "Enum" or B == "Enum" then
		return (A == "TagEnum" and B == "Enum") or (A == "Enum" and B == "TagEnum")
	end

	return false
end

function Parser.Type(self: Parser, Name: Token, Keyword: Token?, IsDataField: boolean?): TypeNode
	local Declaration: TypeNode

	--> Fast path: We know the exact type
	if Keyword then
		local Value = Keyword.Value
		if Value ~= "struct" then
			self:Consume("Assign")

			--> Handle reference declarations
			local Type = KEYWORDS[Value].Type
			local Token = self:Peek()

			if Token.Type == "Identifier" then
				Declaration = self:Declaration(Name)
				if not IsDeclarationTypeSimiliar(Declaration.Type, Type :: Declarations) then
					self:Diagnostic(Error.AnalyzeReferenceInvalidType, `Cannot cast "{Declaration.Type}" to "{Type}"`)
						:Primary(Token, `Expected a reference to "{Type}", got "{Declaration.Type}" instead`)
						:Emit()
				end
			end
		end

		--> Wasn't a reference declaration
		if not Declaration then
			if Value == "map" then
				Declaration = self:Map(Name)
			elseif Value == "set" then
				Declaration = self:Set(Name)
			elseif Value == "enum" then
				Declaration = self:Enum(Name)
			elseif Value == "type" then
				Declaration = self:Primitive(Name)
			elseif Value == "struct" then
				Declaration = self:Struct(Name)
			end
		end
	end

	--> Slow path: We have to figure out what we're declaring :)
	if not Keyword then
		local Peek = self:Peek()
		local Type: Lexer.Types = Peek.Type :: Lexer.Types

		if Type == "Keyword" then
			local Value = Peek.Value
			self:Consume("Keyword")

			if Value == "map" then
				Declaration = self:Map(Name)
			elseif Value == "set" then
				Declaration = self:Set(Name)
			elseif Value == "enum" then
				Declaration = self:Enum(Name)
			elseif Value == "struct" then
				Declaration = self:Struct(Name)
			end
		elseif Type == "Primitive" then
			Declaration = self:Primitive(Name)
		elseif Type == "Identifier" then
			Declaration = self:Declaration(Name)
		elseif Type == "OpenParentheses" and IsDataField then
			Declaration = self:Tuple(Name)
		end

		if not Declaration then
			self:Diagnostic(Error.ParserUnexpectedToken, `Unexpected token`)
				:Primary(Peek, `Expected one of "Identifier" or "Primitive" or "Keyword", got "{Type}" instead`)
				:Emit()
		end
	end

	--> Set type attributes
	local Primitive: Settings.Primitive?
	if Declaration.Type == "Primitive" then
		Primitive = (Declaration :: Primitive).Value.Primitive
	end

	local Value = Declaration.Value :: Attributes
	local Tokens = Declaration.Tokens :: AttributesTokens

	-- ex: vector<u8> and u8(0..00)
	if Primitive then
		if self:IsNumber(Primitive) then
			local Modifiers = self:NumberModifiers(Primitive, (Declaration :: Primitive).Tokens.Primitive)
			if Modifiers then
				Value.Scale = Modifiers.Scale
				Value.Saturate = Modifiers.Saturate
				Tokens.Modifiers = Modifiers.Token
			end
		else
			local Components = self:Components(Primitive)
			if Components then
				Value.Components = Components
			end
		end

		local Range = self:Range(Primitive, Value.Scale)
		if Range then
			if not Primitive.AllowsRange then
				local PrimitiveToken = (Declaration :: Primitive).Tokens.Primitive
				self:Diagnostic(Error.AnalyzeInvalidRangeType, `Type doesn't accept a range`)
					:Primary(Range.Token, "Remove this range")
					:Secondary(PrimitiveToken, `"{PrimitiveToken.Value}" has no bounds to constrain`)
					:Emit()
			end

			Value.Range = Range.Range
			Tokens.Range = Range.Token
		end

		if Value.Scale and not Primitive.Integer then
			self:Quantize(Declaration :: Primitive, Value.Range)
		end
	end

	local function WrapInOptional()
		-- ex: u8?
		local Optional = self:Optional()
		if Optional then
			if Declaration.Type == "Primitive" then
				local Node = Declaration :: Primitive
				if not Node.Value.Primitive.AllowsOptional then
					self:Diagnostic(Error.AnalyzeInvalidOptionalType, `Type cannot be optional`)
						:Primary(Optional, "Remove this optional")
						:Secondary(
							Node.Tokens.Primitive,
							`"{Node.Tokens.Primitive.Value}" has no way to encode absence`
						)
						:Emit()
				end
			end

			Declaration = {
				Type = "Optional",
				Name = Name.Value,
				Value = { Of = Declaration },
				Tokens = {},
			} :: Optional
		end
	end

	WrapInOptional()

	-- ex: u8[][][]
	while true do
		local Array = self:Array()
		if Array then
			Declaration = {
				Type = "Array",
				Name = Name.Value,
				Value = {
					Of = Declaration,
					Range = Array.Range,
				},
				Tokens = {
					Range = Array.Token,
				},
			} :: Array
		end

		WrapInOptional()

		if Array == nil then
			break
		end
	end

	return Declaration
end

function Parser.Primitive(self: Parser, Name: Token): Primitive
	local Token = self:Consume("Primitive")

	local Class: string?
	local Value = Token.Value
	local Primitive = PRIMITIVES[Value]

	if Value == "Instance" then
		local ClassToken = self:TryConsume("Class")
		Class = if ClassToken then string.sub(ClassToken.Value, 2, #ClassToken.Value - 1) else "Instance"
	end

	return {
		Type = "Primitive",
		Name = Name.Value,
		Value = {
			Class = Class,
			Primitive = Primitive,
		},
		Tokens = {
			Primitive = Token,
		},
	}
end

return Parser
