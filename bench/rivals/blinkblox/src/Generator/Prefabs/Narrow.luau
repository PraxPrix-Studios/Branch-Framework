--!strict
--- What a float becomes on the wire, worked out at compile time.
---
--- A range is checked on the RECEIVER against the value it decoded, and a decoded f32, f24 or f16 is
--- the declared number narrowed to that precision -- `f32(0..0.3)` receives 0.3 as
--- 0.30000001192092896, above its own bound, and `f16(0.1..1)` receives 0.1 as 0.0999755859375, below
--- it. So the receiver checks against the bounds narrowed the same way. The encodings are monotonic, so
--- a value inside the declared range always decodes inside the narrowed one, and a value outside it
--- never does.
---
--- An integer is never narrowed, but its read has limits of its own: `readu8` yields nothing outside
--- 0..255, so a bound at or past them is met by the read and needs no comparison.

local Narrow = {}

local INTEGERS: { [string]: { number } } = {
	u8 = { 0, 255 },
	u16 = { 0, 65535 },
	u24 = { 0, 16777215 },
	u32 = { 0, 4294967295 },
	i8 = { -128, 127 },
	i16 = { -32768, 32767 },
	i24 = { -8388608, 8388607 },
	i32 = { -2147483648, 2147483647 },
}

function Narrow.f32(Value: number): number
	if Value ~= Value or Value == math.huge or Value == -math.huge then
		return Value
	end

	local Scratch = buffer.create(4)
	buffer.writef32(Scratch, 0, Value)
	return buffer.readf32(Scratch, 0)
end

--- The f16 writer and reader in Prefabs/Numbers.luau, run on one number.
function Narrow.f16(Value: number): number
	if Value > 65504 then
		return math.huge
	elseif Value < -65504 then
		return -math.huge
	elseif Value ~= Value or Value == 0 then
		return Value
	end

	local Absolute = math.abs(Value)
	local Interval = math.ldexp(1, math.floor(math.log(Absolute, 2)) - 10)
	local Rounded = (Absolute // Interval) * Interval
	local Fraction, Exponent = math.frexp(Rounded)
	Exponent += 14

	local Scaled =
		math.round(if Exponent <= 0 then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent)) else Fraction * 0x800)
	local Encoded = if Exponent <= 0 then Scaled else Scaled - 0x400 + Exponent * 0x400

	local Field = Encoded // 0x400
	local Mantissa = Encoded % 0x400
	local Result = if Field >= 31
		then math.huge
		else math.ldexp(if Field == 0 then Mantissa / 0x400 else Mantissa / 0x800 + 0.5, Field - 14)

	return if Value < 0 then -Result else Result
end

--- The f24 writer and reader in Prefabs/Numbers.luau, run on one number.
function Narrow.f24(Value: number): number
	if Value ~= Value or Value == 0 then
		return Value
	end

	local Fraction, Exponent = math.frexp(math.abs(Value))
	Exponent += 30
	local Scaled =
		math.round(if Exponent <= 0 then Fraction * 0x20000 / math.ldexp(1, -Exponent) else Fraction * 0x40000)
	local Encoded = math.min(if Exponent <= 0 then Scaled else Scaled - 0x20000 + Exponent * 0x20000, 0x7E0000)

	local Field = Encoded // 0x20000
	local Mantissa = Encoded % 0x20000
	local Result = if Field >= 63
		then math.huge
		else math.ldexp(if Field == 0 then Mantissa / 0x20000 else Mantissa / 0x40000 + 0.5, Field - 30)

	return if Value < 0 then -Result else Result
end

--- The bounds a receiver checks for a range declared on `Primitive`: narrowed for the float types,
--- unchanged for everything else.
function Narrow.Bounds(Primitive: string, Min: number, Max: number): (number, number)
	if Primitive == "f32" then
		return Narrow.f32(Min), Narrow.f32(Max)
	elseif Primitive == "f16" then
		return Narrow.f16(Min), Narrow.f16(Max)
	elseif Primitive == "f24" then
		return Narrow.f24(Min), Narrow.f24(Max)
	end

	return Min, Max
end

--- The least and most a read of `Primitive` can yield: an integer type's limits, and unbounded for
--- everything else -- a float read can yield NaN, which only a comparison refuses.
function Narrow.Readable(Primitive: string): (number, number)
	local Limits = INTEGERS[Primitive]
	if Limits then
		return Limits[1], Limits[2]
	end

	return -math.huge, math.huge
end

return Narrow
