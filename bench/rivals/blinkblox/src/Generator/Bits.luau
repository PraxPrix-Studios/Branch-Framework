--!strict
--!native
--!optimize 2

--- A field of several bits in a block's bitfield: an enum's index, a tagged enum's tag. Claimed a bit
--- at a time through `Block.Bit`, so it shares bytes with the booleans and presence flags around it
--- exactly as they share with each other, and the size analysis counts it as that many bits. The bits
--- are grouped by the byte they landed in, so reading one costs a `bit32.extract` a byte rather than a
--- test a bit.
---
--- Apart from Blocks.luau, which it works through, because that file is at its size cap.
local Blocks = require("./Blocks")

type Block = Blocks.Block

--- Where part of a field landed: `Width` of its bits, from bit `From` of the value, at bit `Shift` of
--- the byte held in `Accumulator`.
type Segment = { Accumulator: string, Shift: number, Width: number, From: number }

--> `Block.Bit` names a bit by its mask; this is the bit's place in the byte.
local SHIFTS: { [string]: number } = {
	["0x01"] = 0,
	["0x02"] = 1,
	["0x04"] = 2,
	["0x08"] = 3,
	["0x10"] = 4,
	["0x20"] = 5,
	["0x40"] = 6,
	["0x80"] = 7,
}

local Bits = {}

--- The bits it takes to tell `Count` values apart, and never fewer than one: a field of none would
--- cost nothing, and an array of nothing is refused as a repetition that costs nothing to decode.
function Bits.Width(Count: number): number
	local Width = 1
	while 2 ^ Width < Count do
		Width += 1
	end
	return Width
end

--- Claims `Width` bits of `Target`'s bitfield, reading or writing.
function Bits.Claim(Target: Block, Method: "Read" | "Allocate", Width: number): { Segment }
	local Segments: { Segment } = {}
	for Index = 0, Width - 1 do
		local Accumulator, Mask = Target:Bit(Method)
		local Last = Segments[#Segments]
		if Last and Last.Accumulator == Accumulator then
			Last.Width += 1
		else
			table.insert(Segments, { Accumulator = Accumulator, Shift = SHIFTS[Mask], Width = 1, From = Index })
		end
	end
	return Segments
end

--- Reads a field of `Width` bits into a new local `Name`.
function Bits.Read(Target: Block, Name: string, Width: number)
	local Parts: { string } = {}
	for _, Segment in Bits.Claim(Target, "Read", Width) do
		local Part = `bit32.extract({Segment.Accumulator}, {Segment.Shift}, {Segment.Width})`
		if Segment.From > 0 then
			Part = `bit32.lshift({Part}, {Segment.From})`
		end
		table.insert(Parts, Part)
	end
	Target:Line(`local {Name} = {table.concat(Parts, " + ")}`)
end

--- Writes the constant `Value` into claimed bits: one addition a byte, worked out here, and none at
--- all for a byte whose bits are all zero.
function Bits.WriteConstant(Target: Block, Segments: { Segment }, Value: number)
	for _, Segment in Segments do
		local Part = bit32.lshift(bit32.extract(Value, Segment.From, Segment.Width), Segment.Shift)
		if Part ~= 0 then
			Target:Line(`{Segment.Accumulator} += {Part}`)
		end
	end
end

return Bits
