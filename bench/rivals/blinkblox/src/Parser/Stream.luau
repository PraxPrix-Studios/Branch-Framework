--!strict
--!native
--!optimize 2

--- The token stream: looking at the next token and consuming it, with the diagnostics for
--- a token that is not the one the grammar expects.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Lexer = require("../Lexer")
local ParserClass = require("./Class")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type Primitive = ParserClass.Primitive

local Parser = ParserClass.Class

--- A diagnostic about this parser's source. Every one the parser raises points into the file it is
--- parsing -- an import's own errors come from the parser that reads it -- so the source and the
--- file name are filled in here rather than passed at forty call sites.
function Parser.Diagnostic(self: Parser, Code: number, Message: string, Severity: Error.Severity?): Error.Class
	return Error.new(Code, self.Source, Message, self.File, Severity)
end

--- Reads `Open item, item, ... Close`, calling `Item` to read each one, and returns both brackets.
---
--- An empty list and a trailing comma are accepted; two items with no comma between them are not.
--- Every delimited list in a declaration -- fields, variants, flags, values, pack elements, an
--- event's or a function's options -- is read through here, so they all agree on that.
function Parser.List(self: Parser, Open: Lexer.Types, Close: Lexer.Types, Item: () -> ()): (Token, Token)
	local Opening = self:Consume(Open)
	while true do
		local Closing = self:TryConsume(Close)
		if Closing then
			return Opening, Closing
		end

		Item()

		Closing = self:TryConsume(Close)
		if Closing then
			return Opening, Closing
		end

		self:Consume("Comma")
	end
end

function Parser.Peek(self: Parser): Token
	local Token = self.LookAhead
	if not Token then
		error(
			self:Diagnostic(Error.ParserUnexpectedEndOfFile, "Unexpected end of file")
				:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
				:Emit()
		)
	end

	return Token
end

function Parser.Consume(self: Parser, Type: Lexer.Types): Token
	local Token = self.LookAhead
	if not Token then
		self:Diagnostic(Error.ParserUnexpectedEndOfFile, "Unexpected end of file")
			:Primary({ Start = #self.Source, End = #self.Source }, "File ends here")
			:Emit()

		--> Above already errors
		error("Unexpected end of file")
	end

	if Token.Type ~= Type then
		self:Diagnostic(Error.ParserUnexpectedToken, `Unexpected token`)
			:Primary(Token, `Expected "{Type}", found "{Token.Type}"`)
			:Emit()
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

function Parser.TryConsume(self: Parser, Type: Lexer.Types): Token?
	local Token = self.LookAhead
	if not Token then
		return
	end

	if Token.Type ~= Type then
		return
	end

	self.LookAhead = self.Lexer:GetNextToken()

	return Token
end

--- Consumes the next token if it is any of `...`. Compared in place rather than through TryConsume
--- per type: the parser's identifiers go through here, over eight hundred times a parse of
--- Test.blink, and a table of the types and a call per type were most of what that cost.
function Parser.ConsumeAny(self: Parser, ...: Lexer.Types): Token
	local Next = self.LookAhead
	if Next then
		local Kind = Next.Type
		for Index = 1, select("#", ...) do
			if (select(Index, ...)) == Kind then
				self.LookAhead = self.Lexer:GetNextToken()
				return Next
			end
		end
	end

	local Types = { ... }
	local Token = self:Peek()
	error(
		self:Diagnostic(Error.ParserUnexpectedToken, `Unexpected token`)
			:Primary(Token, `Expected one of "{table.concat(Types, `", "`)}", found "{Token.Type}"`)
			:Emit()
	)
end

function Parser.ConsumeAll(self: Parser, ...: Lexer.Types): ...Token
	local Tokens = {}
	for _, Type: Lexer.Types in { ... } do
		table.insert(Tokens, self:Consume(Type))
	end

	return table.unpack(Tokens)
end

--> Used to consume identifiers without getting "Expected Identifier, got Keyword" errors
--> Boolean flag here is code smell but this codebase is already EOL and will soonish be replaced by the rewrite

function Parser.ConsumeText(self: Parser, ConsumePrimitives: boolean?, ConsumeStrings: boolean?): Token
	--> Get text token
	local Token: Token

	if ConsumeStrings and self:Peek().Type == "String" then
		Token = self:Consume("String")
	else
		if ConsumePrimitives then
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier", "Primitive")
		else
			Token = self:ConsumeAny("As", "Import", "Boolean", "Keyword", "Identifier")
		end
	end

	--> Convert token to identifier token
	return {
		End = Token.End,
		Start = Token.Start,
		Type = "Identifier",
		Value = Token.Value,
	}
end

return Parser
