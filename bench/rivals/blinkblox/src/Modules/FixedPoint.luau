--!strict
--- The arithmetic of a scaled integer, `u16<0.1>`: a real number sent as the nearest whole number of
--- steps, `round(v / 0.1)`, in the integer type, and read back as that count times the step.
---
--- It is written two ways, chosen once per scale. A step whose reciprocal is a whole number -- 0.1,
--- 0.25, 0.001, 1 -- is encoded as `round(v * 10)` and decoded as `n / 10`. Division by a whole
--- number is correctly rounded, so 123 comes back as exactly the double the literal `12.3` parses to,
--- where `123 * 0.1` is 12.300000000000001. Any other step -- 2.5, 0.3 -- multiplies and divides by
--- the step itself.
---
--- The parser, the generator, the size of a scaled type's bounds and the exported limits all come
--- through here, so the compile-time and the emitted arithmetic cannot drift apart. Pure Luau: the
--- Studio plugin parses schemas too.

local FixedPoint = {}

--- The reciprocal of `Scale` when it is a whole number, else nil. The tolerance absorbs the rounding
--- of the literal itself: 0.001 is not exactly a thousandth, and its reciprocal is not exactly 1000.
function FixedPoint.Reciprocal(Scale: number): number?
	local Inverse = 1 / Scale
	local Whole = math.round(Inverse)
	if Whole >= 1 and math.abs(Inverse - Whole) <= Whole * 1e-12 then
		return Whole
	end

	return nil
end

--- The whole number of steps nearest `Value`, ties away from zero, as the sender computes it.
function FixedPoint.Encode(Value: number, Scale: number): number
	local Reciprocal = FixedPoint.Reciprocal(Scale)
	return if Reciprocal then math.round(Value * Reciprocal) else math.round(Value / Scale)
end

--- The real number `Steps` stands for, as the receiver computes it.
function FixedPoint.Decode(Steps: number, Scale: number): number
	local Reciprocal = FixedPoint.Reciprocal(Scale)
	return if Reciprocal then Steps / Reciprocal else Steps * Scale
end

--- Whether `Value` is a whole number of steps: what it decodes to after encoding is itself, to within
--- a rounding of the step. A range on a scaled type has to be, or its bound would not be a value the
--- type can carry.
function FixedPoint.IsMultiple(Value: number, Scale: number): boolean
	local Back = FixedPoint.Decode(FixedPoint.Encode(Value, Scale), Scale)
	return math.abs(Back - Value) <= math.max(math.abs(Value), Scale) * 1e-12
end

--- The Luau expression the sender writes for `Value`: its steps, rounded to nearest.
function FixedPoint.EncodeExpression(Value: string, Scale: number): string
	local Reciprocal = FixedPoint.Reciprocal(Scale)
	if Reciprocal == 1 then
		return `math.round({Value})`
	elseif Reciprocal then
		return `math.round({Value} * {Reciprocal})`
	end

	return `math.round({Value} / {Scale})`
end

--- The Luau expression the receiver reads `Steps` back through, or nil for a step of 1.
function FixedPoint.DecodeExpression(Steps: string, Scale: number): string?
	local Reciprocal = FixedPoint.Reciprocal(Scale)
	if Reciprocal == 1 then
		return nil
	elseif Reciprocal then
		return `{Steps} / {Reciprocal}`
	end

	return `{Steps} * {Scale}`
end

--- The value a saturated write sends for NaN: the one in its range nearest zero -- zero itself when
--- the range holds it, as Rust's saturating casts send it -- so that a NaN never reaches the wire and a
--- ranged receiver never refuses the packet over it.
function FixedPoint.NaNTarget(Min: number, Max: number): number
	if Min > 0 then
		return Min
	elseif Max < 0 then
		return Max
	end

	return 0
end

return FixedPoint
