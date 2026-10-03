--!strict
--!native
--!optimize 2

--- A number's modifiers, written in angle brackets where a vector or a CFrame takes its components:
--- a scale, `u16<0.1>`, and `saturate`, in either order and at most once each -- `u16<0.1, saturate>`.
---
--- `saturate` is an identifier here rather than a keyword, so a field, type or event may still be
--- called that; it means something only inside a number's brackets.
---
--- Part of the parser: every file in src/Parser/ adds methods to the one class in Class.luau,
--- so a method here calls any other through `self` as if they shared a file.

local Error = require("../Modules/Error")
local FixedPoint = require("../Modules/FixedPoint")
local ParserClass = require("./Class")
local Settings = require("../Settings")

type Parser = ParserClass.Parser
type Token = ParserClass.Token
type NumberRange = ParserClass.NumberRange
type Primitive = ParserClass.Primitive

export type Modifiers = { Scale: number?, Saturate: boolean?, Token: Token }

local SATURATE = "saturate"
local DOUBLE_BOUNDS = Settings.Primtives.f64.Bounds :: NumberRange

local Parser = ParserClass.Class

--- Whether `Primitive` is one of the number types -- the integers and the floats -- which are the
--- ones that take these modifiers rather than components.
function Parser.IsNumber(_self: Parser, Primitive: Settings.Primitive): boolean
	return Primitive.Component and Primitive.Bounds ~= nil
end

function Parser.NumberModifiers(self: Parser, _Primitive: Settings.Primitive, Type: Token): Modifiers?
	local Open = self:TryConsume("OpenChevrons")
	if not Open then
		return nil
	end

	local Scale: number?
	local Saturate: boolean?

	while true do
		local Token = self:Peek()
		if Token.Type == "Number" then
			self:Consume("Number")

			if Scale then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "Repeated scale")
					:Primary(Token, "A number has one scale")
					:Emit()
			end

			local Value = tonumber(Token.Value)
			if not Value or Value <= 0 or Value == math.huge then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "A scale must be greater than zero")
					:Primary(Token, `"{Token.Value}" is not a positive step`)
					:Note("The scale is the step between the values the type carries: `u16<0.1>` counts tenths.")
					:Emit()
			end

			Scale = Value :: number
		elseif Token.Type == "Identifier" and Token.Value == SATURATE then
			self:Consume("Identifier")

			if Saturate then
				self:Diagnostic(Error.AnalyzeInvalidModifier, "Repeated saturate")
					:Primary(Token, "Remove this one")
					:Emit()
			end

			Saturate = true
		else
			self:Diagnostic(Error.AnalyzeInvalidModifier, "Unknown number modifier")
				:Primary(Token, `Expected a scale such as 0.1, or "saturate"`)
				:Secondary(Type, `"{Type.Value}" is a number, which takes no components`)
				:Emit()
		end

		local Close = self:TryConsume("CloseChevrons")
		if Close then
			return { Scale = Scale, Saturate = Saturate, Token = Open }
		end

		self:Consume("Comma")

		--> A trailing comma, as every other list in the language accepts.
		Close = self:TryConsume("CloseChevrons")
		if Close then
			return { Scale = Scale, Saturate = Saturate, Token = Open }
		end
	end
end

--- The range `Primitive` covers once scaled: its integer bounds as whole numbers of steps.
function Parser.ScaledBounds(_self: Parser, Primitive: Settings.Primitive, Scale: number): NumberRange
	local Bounds = Primitive.Bounds or DOUBLE_BOUNDS
	return Settings.NumberRange.new(FixedPoint.Decode(Bounds.Min, Scale), FixedPoint.Decode(Bounds.Max, Scale))
end

--- Quantizes a float with a scale: `f32<0.01>(-1..1)` is sent as its offset from the range's minimum,
--- in whole steps, in the narrowest unsigned integer that holds the span -- 200 steps, one byte, where
--- the float took four. The node becomes that integer, scaled, with `Offset` the minimum's steps, so
--- the size analysis, the signature and the serialisers see a scaled integer; only the offset is new
--- to them. It needs both bounds, since the span is what sizes it.
function Parser.Quantize(self: Parser, Node: Primitive, Range: NumberRange?)
	local Value = Node.Value
	local Scale = Value.Scale :: number
	local Token = Node.Tokens.Primitive

	if not Range or Range.Min == -math.huge or Range.Max == math.huge then
		self:Diagnostic(Error.AnalyzeInvalidModifier, "A scaled float needs a closed range")
			:Primary(Token, `Give it both bounds: \`{Token.Value}<{Scale}>(0..100)\``)
			:Note("A scaled float is sent as whole steps from its minimum, in as few bytes as its range needs.")
			:Emit()
		return
	end

	local Low = FixedPoint.Encode(Range.Min, Scale)
	local Span = FixedPoint.Encode(Range.Max, Scale) - Low
	local Name = if Span <= 255
		then "u8"
		elseif Span <= 65535 then "u16"
		elseif Span <= 16777215 then "u24"
		elseif Span <= 4294967295 then "u32"
		else nil
	if not Name then
		self:Diagnostic(Error.AnalyzeInvalidModifier, "A scaled float's range holds too many steps")
			:Primary(Token, `{Span} steps of {Scale} do not fit four bytes`)
			:Note("Use a larger step, a narrower range, or the float itself.")
			:Emit()
		return
	end

	local Integer = table.clone(Token)
	Integer.Value = Name
	Value.Primitive = Settings.Primtives[Name]
	Value.Offset = Low
	Node.Tokens.Primitive = Integer
end

--- Refuses a bound of a scaled range that falls between two steps. `u16<0.1>(0..0.05)` would put
--- the receiver's check between the values the type can carry.
function Parser.CheckScaledRange(self: Parser, Range: NumberRange, Token: Token, Scale: number)
	for _, Bound in { Range.Min, Range.Max } do
		if not FixedPoint.IsMultiple(Bound, Scale) then
			self:Diagnostic(Error.AnalyzeInvalidRange, "Bound is not a whole number of steps")
				:Primary(Token, `{Bound} is not a multiple of the scale {Scale}`)
				:Note("A scaled number carries whole steps only, so each bound of its range has to be one.")
				:Emit()
		end
	end
end

return Parser
