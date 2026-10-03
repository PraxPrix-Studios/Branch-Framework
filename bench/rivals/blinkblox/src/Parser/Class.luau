--!strict
--- The parser's class: its per-parse state, the signature of every method, and the constructor.
---
--- The methods themselves live in the other files of src/Parser/, each adding its own to this one
--- table as it loads. They call each other through `self` -- a struct calls back into `Type` for its
--- fields -- so the full set is declared here, where each file can see it; a method written in a
--- file of its own would otherwise be invisible to the type checker everywhere else.
local AST = require("../AST")
local AttributeParser = require("../Modules/Attributes")
local Error = require("../Modules/Error")
local Grammar = require("../Modules/Grammar")
local Lexer = require("../Lexer")
local Settings = require("../Settings")

--> Defined in AST.luau, which the read-only stages can require without a cycle.
export type Token = AST.Token
export type Generics = AST.Generics
export type Reference = AST.Reference
export type EventOption = AST.EventOption
export type Attributes = AST.Attributes
export type AttributesTokens = AST.AttributesTokens
export type Declarations = AST.Declarations
export type NumberRange = AST.NumberRange
export type Scope = AST.Scope
export type Options = AST.Options
export type Body = AST.Body
export type TypeNode = AST.TypeNode
export type Declaration = AST.Declaration
export type Array = AST.Array
export type Optional = AST.Optional
export type Set = AST.Set
export type Map = AST.Map
export type Enum = AST.Enum
export type TagEnum = AST.TagEnum
export type Struct = AST.Struct
export type Primitive = AST.Primitive
export type Generic = AST.Generic
export type Tuple = AST.Tuple
export type EventCall = AST.EventCall
export type Event = AST.Event
export type StreamSettings = AST.StreamSettings
export type StampSettings = AST.StampSettings
export type Function = AST.Function
export type ScopeNode = AST.ScopeNode

type Bucket = Grammar.Bucket

export type State = {
	Source: string,

	File: string?,
	Directory: string,

	Lexer: Lexer.Lexer,
	LookAhead: Token?,

	Scope: Scope,
	Symbols: { [string]: true },
	Generics: Generics?,

	--> Files whose parse has STARTED and not yet finished, shared by every parser in one
	--> compilation. See Parser.Import.
	Importing: { [string]: true },

	--> The name being declared right now, so a reference to it from inside its own body can be
	--> told apart from a reference to something that does not exist. See Parser.Declaration.
	Declaring: string?,
	Attributes: AttributeParser.State, --> The profile, and what it excludes. See Modules/Attributes.
}

export type Methods = {
	--> Stream.luau
	Diagnostic: (self: Parser, Code: number, Message: string, Severity: Error.Severity?) -> Error.Class,
	List: (self: Parser, Open: Lexer.Types, Close: Lexer.Types, Item: () -> ()) -> (Token, Token),
	Peek: (self: Parser) -> Token,
	Consume: (self: Parser, Type: Lexer.Types) -> Token,
	TryConsume: (self: Parser, Type: Lexer.Types) -> Token?,
	ConsumeAny: (self: Parser, ...Lexer.Types) -> Token,
	ConsumeAll: (self: Parser, ...Lexer.Types) -> ...Token,
	ConsumeText: (self: Parser, ConsumePrimitives: boolean?, ConsumeStrings: boolean?) -> Token,

	--> Symbols.luau
	Reference: (self: Parser, Bucket: Bucket, Identifier: string) -> (Scope | Reference)?,
	SetReference: (self: Parser, Bucket: Bucket, Identifier: Token, Declaration: Declaration) -> (),
	GetGenerics: (self: Parser) -> Generics?,
	ReplaceGenerics: (self: Parser, Of: TypeNode) -> TypeNode,
	Declaration: (self: Parser, Name: Token) -> TypeNode,

	--> Ranges.luau
	NumberRange: (self: Parser, Token: Lexer.Token, Bounds: NumberRange, Integer: boolean?) -> NumberRange,
	Range: (self: Parser, Primitive: Settings.Primitive, Scale: number?) -> { Range: NumberRange, Token: Token }?,
	Array: (self: Parser) -> { Range: NumberRange, Token: Token }?,
	Components: (self: Parser, Primitive: Settings.Primitive) -> { string }?,
	Optional: (self: Parser) -> Token?,

	--> Scales.luau
	IsNumber: (self: Parser, Primitive: Settings.Primitive) -> boolean,
	NumberModifiers: (
		self: Parser,
		Primitive: Settings.Primitive,
		Type: Token
	) -> { Scale: number?, Saturate: boolean?, Token: Token }?,
	ScaledBounds: (self: Parser, Primitive: Settings.Primitive, Scale: number) -> NumberRange,
	CheckScaledRange: (self: Parser, Range: NumberRange, Token: Token, Scale: number) -> (),
	Quantize: (self: Parser, Node: Primitive, Range: NumberRange?) -> (),

	--> Document.luau
	Parse: (self: Parser, Source: string, Scope: Scope?) -> Body,
	Import: (self: Parser) -> ScopeNode,
	Declarations: (self: Parser) -> { Declaration },

	--> Structures.luau
	GetOptionFromToken: (self: Parser, Token: Token, Structure: { EventOption }) -> EventOption,
	Structure: (self: Parser, Name: Token, Structure: { EventOption }) -> { [string]: any },
	Event: (self: Parser, Name: Token) -> Event,
	Function: (self: Parser, Name: Token) -> Function,
	Namespace: (self: Parser, Name: Token) -> ScopeNode,

	--> Streams.luau
	StreamData: (self: Parser, Name: Token, Structure: { [string]: any }) -> (Tuple, StreamSettings),
	StampData: (self: Parser, Name: Token, Structure: { [string]: any }) -> (Tuple, StampSettings),

	--> Types.luau
	Type: (self: Parser, Name: Token, Keyword: Token?, IsDataField: boolean?) -> TypeNode,
	Primitive: (self: Parser, Name: Token) -> Primitive,

	--> Collections.luau
	Set: (self: Parser, Name: Token) -> Set,
	Map: (self: Parser, Name: Token) -> Map,
	Enum: (self: Parser, Name: Token) -> Enum | TagEnum,
	TagEnum: (self: Parser, Tag: Token, Name: Token) -> TagEnum,
	Tuple: (self: Parser, Name: Token) -> Tuple,
	Struct: (self: Parser, Name: Token) -> Struct,
}

export type Parser = State & Methods

export type Class = Methods & {
	__index: Class,
	new: (
		Directory: string?,
		File: string?,
		Importing: { [string]: true }?,
		Attributes: AttributeParser.State?
	) -> Parser,
}

local Class: Class = {} :: any
Class.__index = Class

function Class.new(
	Directory: string?,
	File: string?,
	Importing: { [string]: true }?,
	Attributes: AttributeParser.State?
): Parser
	local State: State = {
		Source = "",
		File = File,
		Directory = Directory or "./",

		Lexer = Lexer.new("Parsing"),
		Symbols = {},
		Scope = nil :: any,

		--> Inherited when one parser spawns another for an import, fresh for a top-level parse.
		Importing = Importing or {},
		Attributes = Attributes or AttributeParser.new(),
	}

	return setmetatable(State, Class) :: any
end

return {
	Class = Class,
}
