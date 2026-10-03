--!strict
--!native
--!optimize 2

--- Integers, floats, half floats and booleans.
local AssertsModule = require("./Asserts")
local Common = require("./Common")

type Block = Common.Block
type Generate = Common.Generate
type TypePrefab = Common.TypePrefab

local Types = Common.Types
local Primitives = Common.Primitives
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab
local SEND_BUFFER = Common.SEND_BUFFER
local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local BYTE = Common.BYTE
local SHORT = Common.SHORT
local TRIPLE = Common.TRIPLE
local INTEGER = Common.INTEGER
local HALF_FLOAT = Common.HALF_FLOAT
local FLOAT = Common.FLOAT
local DOUBLE = Common.DOUBLE
local Asserts = AssertsModule.Asserts

local function GenerateNumberGenerator(Type: string, Bytes: number): (TypePrefab, { Type: string, Generate: Generate })
	local Prefab = {
		Read = function(Variable: string, Block: Block)
			Block:Line(`{Block:Declare(Variable)} = buffer.read{Type}({RECIEVE_BUFFER}, {Block:Read(Bytes)})`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`buffer.write{Type}({SEND_BUFFER}, {Block:Allocate(Bytes)}, {Value})`)
		end,
	}

	local Primitive = {
		Type = "number",
		Generate = GeneratePrimitivePrefab("number", Prefab, Asserts.number),
	}

	return Prefab, Primitive
end

--> Numbers
Types.u8, Primitives.u8 = GenerateNumberGenerator("u8", BYTE)
Types.u16, Primitives.u16 = GenerateNumberGenerator("u16", SHORT)
Types.u32, Primitives.u32 = GenerateNumberGenerator("u32", INTEGER)

Types.i8, Primitives.i8 = GenerateNumberGenerator("i8", BYTE)
Types.i16, Primitives.i16 = GenerateNumberGenerator("i16", SHORT)
Types.i32, Primitives.i32 = GenerateNumberGenerator("i32", INTEGER)

Types.f32, Primitives.f32 = GenerateNumberGenerator("f32", FLOAT)
Types.f64, Primitives.f64 = GenerateNumberGenerator("f64", DOUBLE)

--- Three bytes the buffer library has no call for: the low u16, then the high byte. `bit32.rshift`
--- truncates and wraps exactly as `buffer.writebits(_, _, 24, Value)` would -- checked over the edges
--- and random doubles -- at a tenth of its cost, so a value out of range wraps as it does in a u16.
local function WriteParts(Offset: string, Low: string, High: string, Block: Block)
	Block:Line(`buffer.writeu16({SEND_BUFFER}, {Offset}, {Low})`)
	Block:Line(`buffer.writeu8({SEND_BUFFER}, {Offset} + 2, {High})`)
end

local function WriteTriple(Offset: string, Value: string, Block: Block)
	WriteParts(Offset, Value, `bit32.rshift({Value}, 16)`, Block)
end

local function GenerateTripleGenerator(High: string): (TypePrefab, { Type: string, Generate: Generate })
	local Prefab = {
		Read = function(Variable: string, Block: Block)
			local Offset = Block:Read(TRIPLE)
			Block:Line(
				`{Block:Declare(Variable)} = buffer.readu16({RECIEVE_BUFFER}, {Offset}) + buffer.read{High}({RECIEVE_BUFFER}, {Offset} + 2) * 0x10000`
			)
		end,
		Write = function(Value: string, Block: Block)
			WriteTriple(Block:Allocate(TRIPLE), Value, Block)
		end,
	}

	local Primitive = {
		Type = "number",
		Generate = GeneratePrimitivePrefab("number", Prefab, Asserts.number),
	}

	return Prefab, Primitive
end

--> The sign lives in the high byte, so a signed read differs from an unsigned one only there.
Types.u24, Primitives.u24 = GenerateTripleGenerator("u8")
Types.i24, Primitives.i24 = GenerateTripleGenerator("i8")

Types.f16 = {
	Read = function(Variable: string, Block: Block)
		Types.u16.Read("Encoded", Block)
		Block:Declare(Variable, true)
		--> Declared through the block, as `Encoded` is, so every half float read in one scope shares one
		--> local. A `local` line per read ran a struct of about seventy `vector<f16>` fields past Luau's
		--> 200 locals a function, and the generated module failed to load.
		Block:Line(`{Block:Declare("MantissaExponent")} = Encoded % 0x8000`)
		Block
			:Compare("MantissaExponent", "0b0_11111_0000000000 ", "Equals")
			:Compare("Encoded // 0x8000", "1", "Equals")
			:Line(`{Variable} = -math.huge`)
			:Branch("Default")
			:Line(`{Variable} = math.huge`)
			:End()
			--> Exponent all ones with any mantissa is NaN. This compared against the SIGNED pattern,
			--> which a value with the sign stripped can never equal, so a NaN fell through to the
			--> arithmetic below and came out as -65600.
			:Branch(
				"Conditional",
				"MantissaExponent",
				"0b0_11111_0000000000",
				"Greater"
			)
			:Line(`{Variable} = 0 / 0`)
			--> Zero keeps its sign, as it does in f32 and f64: 0x8000 is -0.
			:Branch(
				"Conditional",
				"MantissaExponent",
				"0b0_00000_0000000000  ",
				"Equals"
			)
			:Line(`{Variable} = if Encoded == 0 then 0 else -0`)
			:Branch("Default")
			:Lines({
				"local Mantissa = MantissaExponent % 0x400\n",
				"local Exponent = MantissaExponent // 0x400\n",
				"local Fraction;\n",
				"if Exponent == 0 then\n",
				"	Fraction = Mantissa / 0x400\n",
				"else\n",
				"	Fraction = Mantissa / 0x800 + 0.5\n",
				"end\n",
				"local Result = math.ldexp(Fraction, Exponent - 14)\n",
			}, Block.Indent + 1)
			:Line(`{Variable} = if Encoded // 0x8000 == 1 then -Result else Result`)
			:End()
	end,
	Write = function(Value: string, Block: Block)
		local Allocation = Block:Allocate(HALF_FLOAT)
		Block
			:Compare(Value, "65504", "Greater")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b0_11111_0000000000)`)
			:Branch("Conditional", Value, "-65504", "Less")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000000)`)
			:Branch("Conditional", Value, Value, "Not")
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, 0b1_11111_0000000001)`)
			--> `-0 == 0`, so the sign of a zero is read off its reciprocal. Written as 0 it came back as
			--> +0; an older reader decodes 0x8000 as 0, so builds either side still agree on everything
			--> but the sign.
			:Branch(
				"Conditional",
				Value,
				"0",
				"Equals"
			)
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, if 1 / {Value} < 0 then 0x8000 else 0)`)
			:Branch("Default")
			:Line(`local float = {Value}`)
			:Lines({
				"local Abosulte = math.abs(float)\n",
				"local Interval = math.ldexp(1, math.floor(math.log(Abosulte, 2)) - 10)\n",
				"local RoundedValue = (Abosulte // Interval) * Interval\n",
				"local Fraction, Exponent = math.frexp(RoundedValue)\n",
				"Exponent += 14\n",
				--> Rounding can carry a mantissa into the exponent -- a subnormal just below the smallest
				--> normal rounds up to it. Adding the mantissa to the exponent field, rather than taking
				--> it modulo 0x400 first, lets the carry land; the modulo dropped it, and 6.102e-5 went
				--> out as zero.
				"local Scaled = math.round(if Exponent <= 0\n",
				"	then Fraction * 0x400 / math.ldexp(1, math.abs(Exponent))\n",
				"	else Fraction * 0x800)\n",
				"local Result = (if Exponent <= 0 then Scaled else Scaled - 0x400 + Exponent * 0x400)\n",
				"	+ if float < 0 then 0x8000 else 0\n",
			}, Block.Indent + 1)
			:Line(`buffer.writeu16({SEND_BUFFER}, {Allocation}, Result)`)
			:End()
	end,
}

Primitives.f16 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f16, Asserts.number),
}

--- A sign, six bits of exponent biased by 31, and seventeen of mantissa, laid out as f16 is: the sign
--- in the top bit, all-ones exponent for the infinities and NaN, zero exponent for the subnormals.
---
--- Unlike f16 it rounds to nearest rather than truncating, which halves the error at the same size.
--- Rounding is where a 24-bit float usually goes wrong: a mantissa that rounds up to 2^17 must carry
--- into the exponent, and one taken modulo the field instead arrives at half its value -- 1023.9999999
--- as 512. Adding the scaled mantissa to the exponent field lets the carry land, into infinity at the
--- top. `Narrow.f24` runs the same arithmetic at compile time.
Types.f24 = {
	Read = function(Variable: string, Block: Block)
		Types.u24.Read("Encoded", Block)
		Block:Declare(Variable, true)
		--> One local per scope, shared, for the reason given in f16's reader.
		Block:Line(`{Block:Declare("MantissaExponent")} = Encoded % 0x800000`)
		Block:Compare("MantissaExponent", "0x7E0000", "Equals")
			:Line(`{Variable} = if Encoded >= 0x800000 then -math.huge else math.huge`)
			:Branch("Conditional", "MantissaExponent", "0x7E0000", "Greater")
			:Line(`{Variable} = 0 / 0`)
			:Branch("Conditional", "MantissaExponent", "0", "Equals")
			:Line(`{Variable} = if Encoded == 0 then 0 else -0`)
			:Branch("Default")
			:Lines({
				"local Mantissa = MantissaExponent % 0x20000\n",
				"local Exponent = MantissaExponent // 0x20000\n",
				"local Fraction = if Exponent == 0 then Mantissa / 0x20000 else Mantissa / 0x40000 + 0.5\n",
				"local Result = math.ldexp(Fraction, Exponent - 30)\n",
			}, Block.Indent + 1)
			:Line(`{Variable} = if Encoded >= 0x800000 then -Result else Result`)
			:End()
	end,
	Write = function(Value: string, Block: Block)
		local Allocation = Block:Allocate(TRIPLE)
		local Branch = Block:Compare(Value, Value, "Not")
		WriteParts(Allocation, "0x0001", "0xFE", Branch)
		--> `-0 == 0`, so the sign of a zero is read off its reciprocal.
		Branch = Branch:Branch("Conditional", Value, "0", "Equals")
		WriteParts(Allocation, "0", `if 1 / {Value} < 0 then 0x80 else 0`, Branch)
		Branch = Branch:Branch("Default")
		Branch:Line(`local float = {Value}`):Lines({
			"local Fraction, Exponent = math.frexp(math.abs(float))\n",
			"Exponent += 30\n",
			"local Scaled = math.round(if Exponent <= 0\n",
			"	then Fraction * 0x20000 / math.ldexp(1, -Exponent)\n",
			"	else Fraction * 0x40000)\n",
			--> Infinity, and anything that rounds past the largest finite value, meets the cap.
			"local Result = math.min(if Exponent <= 0 then Scaled else Scaled - 0x20000 + Exponent * 0x20000, 0x7E0000)\n",
			"	+ if float < 0 then 0x800000 else 0\n",
		}, Block.Indent + 1)
		WriteTriple(Allocation, "Result", Branch)
		Branch:End()
	end,
}

Primitives.f24 = {
	Type = "number",
	Generate = GeneratePrimitivePrefab("number", Types.f24, Asserts.number),
}

--> Boolean
do
	--> One BIT, not one byte. Eight booleans in the same block share a byte; see `Block.Bit`.
	Types.boolean = {
		Read = function(Variable: string, Block: Block)
			local Accumulator, Mask = Block:Bit("Read")
			Block:Line(`{Block:Declare(Variable)} = bit32.btest({Accumulator}, {Mask})`)
		end,
		Write = function(Value: string, Block: Block)
			local Accumulator, Mask = Block:Bit("Allocate")
			Block:Line(`if {Value} then {Accumulator} += {Mask} end`)
		end,
	}

	Primitives.boolean = {
		Type = "boolean",
		Generate = GeneratePrimitivePrefab("boolean", Types.boolean),
	}
end

return {}
