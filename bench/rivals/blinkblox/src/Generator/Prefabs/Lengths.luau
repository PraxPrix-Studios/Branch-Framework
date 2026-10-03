--!strict
--!native
--!optimize 2

--- The two variable-length primitives, `string` and `buffer`: a length prefix sized from the span the
--- schema allows, then the bytes.
local AssertsModule = require("./Asserts")
local Common = require("./Common")
local Size = require("../../Modules/Size")

type Block = Common.Block
type NumberRange = Common.NumberRange
type TypePrefab = Common.TypePrefab
type AssertGenerator = Common.AssertGenerator

local Types = Common.Types
local Primitives = Common.Primitives
local GetTypeToUse = Common.GetTypeToUse
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab
local SEND_BUFFER = Common.SEND_BUFFER
local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local SEND_POSITION = Common.SEND_POSITION
local Asserts = AssertsModule.Asserts
local EmitLengthGuard = AssertsModule.EmitLengthGuard
local EmitReceivedLength = AssertsModule.EmitReceivedLength
local GenerateSpaceGuard = AssertsModule.GenerateSpaceGuard

--- The bounds a length lies within, and the numeral that carries it: a fixed-width one, or nil for a
--- varint (ReadVarLength and WriteVarLength in the base template). An unbounded value takes the
--- default ceiling the size analysis assumes too, and the choice is Size.LengthPrefix's.
---
--- The length is encoded RELATIVE to the declared minimum: `string(300..400)` spends one byte on a
--- hundred possible lengths rather than the two that 400 alone would need.
local function Span(Range: NumberRange?): (number, number, TypePrefab?)
	local Upper = if Range then Range.Max else Size.DefaultLength
	local Lower = if Range then Range.Min else 0
	local Varint = Size.LengthPrefix(Upper - Lower, Range ~= nil)
	return Lower, Upper, if Varint then nil else GetTypeToUse(Upper - Lower)
end

--- Reads a length prefix into `Name`, fixed-width or varint.
local function ReadPrefix(Name: string, Block: Block, LengthType: TypePrefab?)
	if LengthType then
		LengthType.Read(Name, Block)
	else
		Block:Line(`local {Name} = ReadVarLength()`)
	end
end

--- Writes `Value` as a length prefix, fixed-width or varint.
local function WritePrefix(Value: string, Block: Block, LengthType: TypePrefab?)
	if LengthType then
		LengthType.Write(Value, Block)
	else
		Block:Line(`WriteVarLength({Value})`)
	end
end

--- Reads a length prefix into a local `Length`, and checks it before anything is read or allocated
--- for it.
local function ReadLength(Variable: string, Block: Block, Range: NumberRange?, Assert: AssertGenerator)
	local Lower, Upper, LengthType = Span(Range)

	if Lower > 0 then
		ReadPrefix("LengthOffset", Block, LengthType)
		Block:Line(`local Length = LengthOffset + {Lower}`)
	else
		ReadPrefix("Length", Block, LengthType)
	end

	--> Checked before the read, and against the reconstructed length rather than the raw numeral:
	--> the prefix is sized from the span, so `string(300..400)` fits a u8 whose 255 decodes to 555.
	--> The bound named here is the one the schema author actually wrote.
	if Range then
		EmitReceivedLength(Block, Assert(Variable, Lower, Upper, "Length"), Lower, Upper, true)
	end

	Block:Line(GenerateSpaceGuard("Length", Variable))
end

--- Writes `Measure` as a length prefix, through a local `Length`, once it is known to fit.
local function WriteLength(Block: Block, Range: NumberRange?, Measure: string)
	local Lower, Upper, LengthType = Span(Range)

	Block:Line(`local Length = {Measure}`)
	EmitLengthGuard(Block, Lower, Upper)

	if Lower > 0 then
		Block:Line(`local LengthOffset = Length - {Lower}`)
		WritePrefix("LengthOffset", Block, LengthType)
	else
		WritePrefix("Length", Block, LengthType)
	end
end

--> String
do
	Types.string = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			--> Fixed size string
			if Range and Range.Min == Range.Max then
				Block:Line(
					`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, {Block:Read(Range.Min)}, {Range.Min})`
				)
				return
			end

			ReadLength(Variable, Block, Range, Asserts.string)
			Block:Line(`{Block:Declare(Variable)} = buffer.readstring({RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.writestring({SEND_BUFFER}, {Block:Allocate(Range.Min)}, {Value}, {Range.Min})`)
				return
			end

			WriteLength(Block, Range, `#{Value}`)
			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.writestring({SEND_BUFFER}, {SEND_POSITION}, {Value}, Length)`)
		end,

		ValidatesOnRead = true,
	}

	Primitives.string = {
		Type = "string",
		Generate = GeneratePrimitivePrefab("string", Types.string, Asserts.string),
	}
end

--> Buffer
do
	Types.buffer = {
		Read = function(Variable: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				local Length = Range.Max
				Block:Line(`{Block:Declare(Variable)} = buffer.create({Length})`)
				Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, {Block:Read(Length)}, {Length})`)
				return
			end

			ReadLength(Variable, Block, Range, Asserts.buffer)
			Block:Line(`{Block:Declare(Variable)} = buffer.create(Length)`)
			Block:Line(`buffer.copy({Variable}, 0, {RECIEVE_BUFFER}, Read(Length), Length)`)
		end,
		Write = function(Value: string, Block: Block, Range: NumberRange?)
			if Range and Range.Min == Range.Max then
				Block:Line(`buffer.copy({SEND_BUFFER}, {Block:Allocate(Range.Max)}, {Value}, 0, {Range.Max})`)
				return
			end

			WriteLength(Block, Range, `buffer.len({Value})`)
			Block:Line(`Allocate(Length)`)
			Block:Line(`buffer.copy({SEND_BUFFER}, {SEND_POSITION}, {Value}, 0, Length)`)
		end,

		ValidatesOnRead = true,
	}

	Primitives.buffer = {
		Type = "buffer",
		Generate = GeneratePrimitivePrefab("buffer", Types.buffer, Asserts.buffer),
	}
end

return {
	ReadPrefix = ReadPrefix,
	WritePrefix = WritePrefix,
}
