--!strict
--!native
--!optimize 2

--- The modifiers written after a type: a numeric range, array brackets, components and the
--- optional mark.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local Lexer = require("../Lexer")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type NumberRange = ParserClass.NumberRange
type Array = ParserClass.Array
type Optional = ParserClass.Optional
type Primitive = ParserClass.Primitive

local PRIMITIVES = Settings.Primtives
local ARRAY_BOUNDS = Settings.NumberRange.new(0, (Settings.Primtives.u16.Bounds :: NumberRange).Max)
local DOUBLE_BOUNDS = Settings.Primtives.f64.Bounds :: NumberRange

local Parser = ParserClass.Class

local function IsInteger(Number: number): boolean
	return (Number // 1) == Number
end

function Parser.NumberRange(self: Parser, Token: Lexer.Token, Bounds: NumberRange, Integer: boolean?): NumberRange
	local Value = Token.Value
	Value = string.sub(Value, 2, #Value - 1)

	local function ParseRange(): NumberRange
		local Single = tonumber(string.match(Value, `^(%-?%d*%.?%d+)$`))
		if Single then
			return Settings.NumberRange.new(Single)
		end

		local LowerBounds = tonumber(string.match(Value, `^(%-?%d*%.?%d+)%.%.$`))
		if LowerBounds then
			return Settings.NumberRange.new(LowerBounds, Bounds.Max)
		end

		local UpperBounds = tonumber(string.match(Value, `^%.%.(%-?%d*%.?%d+)$`))
		if UpperBounds then
			return Settings.NumberRange.new(Bounds.Min, UpperBounds)
		end

		local Lower, Upper = string.match(Value, `^(%-?%d*%.?%d+)%.%.(%-?%d*%.?%d+)$`)
		local Minimum, Maximum = tonumber(Lower), tonumber(Upper)
		if Minimum and Maximum then
			return Settings.NumberRange.new(Minimum, Maximum)
		end

		self:Diagnostic(Error.AnalyzeInvalidRange, "Malformed range"):Primary(Token, "Unable to parse range"):Emit()

		error("never")
	end

	local Range = ParseRange()

	--> check int
	if Integer and (IsInteger(Range.Min) == false or IsInteger(Range.Max) == false) then
		self:Diagnostic(Error.AnalyzeInvalidRange, "Expected an integer"):Primary(Token, "Expected an integer"):Emit()

		error("never")
	end

	--> check bounds
	if Range.Min < Bounds.Min or Range.Max > Bounds.Max then
		self:Diagnostic(Error.AnalyzeInvalidRange, "Range outside bounds")
			:Primary(Token, `Expected a range within ({Bounds.Min}..{Bounds.Max})`)
			:Emit()

		error("never")
	end

	return Range
end

--- A scaled number's range is written in real units, `u16<0.1>(0..6553.5)`, so it is checked against
--- the scaled bounds, may be fractional, and must land on whole steps.
function Parser.Range(
	self: Parser,
	Primitive: Settings.Primitive,
	Scale: number?
): { Range: NumberRange, Token: Token }?
	local Token = self:TryConsume("Range")
	if Token == nil then
		return
	end

	local ParsedRange
	if Scale then
		ParsedRange = self:NumberRange(Token, self:ScaledBounds(Primitive, Scale), false)
		self:CheckScaledRange(ParsedRange, Token, Scale)
	else
		ParsedRange = self:NumberRange(Token, Primitive.Bounds or DOUBLE_BOUNDS, Primitive.Integer)
	end

	return {
		Range = ParsedRange,
		Token = Token,
	}
end

function Parser.Array(self: Parser): { Range: NumberRange, Token: Token }?
	local Token = self:TryConsume("Array")
	if not Token then
		return
	end

	local Value = Token.Value

	--> Empty bounds
	if Value == "[]" then
		return {
			Range = ARRAY_BOUNDS,
			Token = Token,
		}
	end

	--> Parse range
	local ParsedRange = self:NumberRange(Token, ARRAY_BOUNDS, true)

	return {
		Range = ParsedRange,
		Token = Token,
	}
end

function Parser.Components(self: Parser, Primitive: Settings.Primitive): { string }?
	local OpenChevrons = self:TryConsume("OpenChevrons")
	if not OpenChevrons then
		return
	end

	if Primitive.AllowedComponents == 0 then
		error(
			self:Diagnostic(Error.AnalyzeInvalidComponents, `Type doesn't accept components`)
				:Primary(OpenChevrons, `Remove component here`)
				:Emit()
		)
	end

	local Components = {}
	local Primitives = {}
	local Closed = false

	for _ = 1, Primitive.AllowedComponents do
		table.insert(Primitives, self:Consume("Primitive"))
		if self:TryConsume("CloseChevrons") then
			Closed = true
			break
		end

		self:Consume("Comma")

		--> A trailing comma, as every other list in the language accepts.
		if self:TryConsume("CloseChevrons") then
			Closed = true
			break
		end
	end

	if not Closed then
		local Extra = self:Peek()
		error(
			self:Diagnostic(Error.AnalyzeInvalidComponents, `Too many components`)
				:Primary(Extra, `Expected at most {Primitive.AllowedComponents} component(s)`)
				:Emit()
		)
	end

	for _, Token in Primitives do
		local Component = Token.Value
		local ComponentPrimitive = PRIMITIVES[Component]

		if not ComponentPrimitive then
			error(
				self:Diagnostic(Error.AnalyzeInvalidComponents, `Unknown primitive used as component`)
					:Primary(Token, `"{Component}" is invalid`)
					:Emit()
			)
		end

		if not ComponentPrimitive.Component then
			error(
				self:Diagnostic(Error.AnalyzeInvalidComponents, `Invalid primitive used as component`)
					:Primary(Token, `"{Component}" cannot be used as a component`)
					:Emit()
			)
		end

		table.insert(Components, Component)
	end

	return Components
end

function Parser.Optional(self: Parser): Token?
	return self:TryConsume("Optional")
end

--> Here's the logic:
--> When a generic is used it will reuse the same table under the hood
--> When replacing the generic the table's contents are changed to what it is being replaced with
--> Issues start to arise when you have another generic type that references a generic ex:
--> map GenericMap<K, V> = {[K]: V}
--> struct GenericStruct<T> { Map: GenericMap<string, T> }
--> struct MergeStruct { ..GenericStruct<u8> }
--> GenericStruct is merged just fine but GenericMap loses the reference to the table for `T` somewhere along the process (likely at the deep clone stage)

return Parser
