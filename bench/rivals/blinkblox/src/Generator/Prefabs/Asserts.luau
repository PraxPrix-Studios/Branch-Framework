--!strict
--!native
--!optimize 2

--- The runtime checks the prefabs emit: bounds on a value, and guards that a decoded length is backed
--- by what the packet still holds before anything is allocated for it.
local Common = require("./Common")
local Parser = require("../../Parser")
local Size = require("../../Modules/Size")

type Block = Common.Block
type AssertPrefab = Common.AssertPrefab

local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local RECIEVE_CURSOR = Common.RECIEVE_CURSOR

--- The bound checks on one measured quantity: a number itself, a string's length, a buffer's size or
--- a vector's magnitude. `Noun` names what is measured in the message, and `Measure` is the expression
--- compared.
---
--- `NaNSafe` writes the comparisons as `not (x >= Min)` rather than `x < Min`. NaN compares false
--- against everything, so `x < Min` and `x > Max` both let it through, and a client could hand a
--- ranged float listener a NaN that every check downstream had been told was impossible. A length is
--- an integer, so the plain form is kept there.
local function Bounds(
	Variable: string,
	Min: number,
	Max: number,
	Noun: string,
	Measure: string,
	NaNSafe: boolean
): AssertPrefab
	local Subject = `{Noun}"{Variable}"`
	local Below = if NaNSafe then `not ({Measure} >= {Min})` else `{Measure} < {Min}`
	local Above = if NaNSafe then `not ({Measure} <= {Max})` else `{Measure} > {Max}`

	return {
		Lower = `if {Below} then error(\`Expected {Subject} to be larger than or equal to {Min}, got \{{Measure}} instead.\`) end`,
		Upper = `if {Above} then error(\`Expected {Subject} to be smaller than or equal to {Max}, got \{{Measure}} instead.\`) end`,
		Exact = `if {Measure} ~= {Max} then error(\`Expected {Subject} to be equal to {Max}, got \{{Measure}} instead.\`) end`,
	}
end

local Asserts = {
	--> `Measure` names a local the value was read into, when it is checked there and stored after.
	number = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		return Bounds(Variable, Min, Max, "", Measure or Variable, true)
	end,

	--> `Measure` names the expression to compare. The read path passes the decoded length so the
	--> bound is checked before the string is read; the write path omits it and measures the value.
	string = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		return Bounds(Variable, Min, Max, "length of ", Measure or `#{Variable}`, false)
	end,

	vector = function(Variable: string, Min: number, Max: number): AssertPrefab
		return Bounds(Variable, Min, Max, "magnitude of ", `{Variable}.Magnitude`, true)
	end,

	buffer = function(Variable: string, Min: number, Max: number, Measure: string?): AssertPrefab
		return Bounds(Variable, Min, Max, "size of ", Measure or `buffer.len({Variable})`, false)
	end,

	Instance = function(Variable: string, Class: string): AssertPrefab
		local TypeAssertion =
			`if typeof({Variable}) ~= "Instance" then error(\`Expected an Instance, got \{typeof({Variable})} instead.\`) end`
		return {
			Lower = `error("Something has gone wrong")`,
			Upper = `error("Something has gone wrong")`,
			Exact = if Class == "Instance"
				then TypeAssertion
				else `{TypeAssertion}\nif not {Variable}:IsA("{Class}") then error(\`Expected an Instance of type "{Class}", got "\{{Variable}.ClassName}" instead.\`) end`,
		}
	end,
}

--> A length read out of a hostile packet may name more bytes than the packet still holds. Reading
--> that far throws inside `buffer.read*` and the decode loop's pcall turns it into a dropped packet,
--> but `buffer` would have allocated the whole span first. Checking the remaining space keeps a
--> length prefix from buying an allocation, and it is exact rather than conservative: block reads
--> reserve their fixed bytes up front, so at this point the cursor sits where the payload begins.
local function GenerateSpaceGuard(Length: string, Variable: string): string
	return `if {Length} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
end

--- Emits a guard on a decoded element count, before the array behind it is allocated.
---
--- `table.create(Length)` reserves every slot up front, so a count the packet cannot possibly back
--- still buys that allocation even though the loop fails on its first iteration: two bytes reserve
--- 65535 slots, and `u8[]` is enough to ask for them. Comparing the count against what is left of
--- whatever its elements read closes that.
---
--- The comparison uses the MINIMUM an element costs, which is the most that can be assumed about
--- it, so the guard errs towards letting a packet through rather than refusing an honest one. An
--- element that costs nothing either way is refused at compile time instead -- there is no resource
--- left to measure it against.
local function EmitCapacityGuard(Block: Block, Length: string, Variable: string, Of: Parser.TypeNode)
	--> A packed boolean costs an eighth of a byte, which the per-element minimum below would round up
	--> to one -- and then refuse an honest 800-element array for not fitting in its 100 bytes.
	if Size.PacksBooleans(Of :: any) then
		Block:Line(
			`if ({Length} + 7) // 8 > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	local Element = Size.Sealed(Of :: any)

	if Element.Min > 0 then
		local Needed = if Element.Min == 1 then Length else `{Length} * {Element.Min}`
		Block:Line(
			`if {Needed} > buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR} then error(\`Expected "{Variable}" to fit in the \{buffer.len({RECIEVE_BUFFER}) - {RECIEVE_CURSOR}} bytes left in the packet, got a length of \{{Length}} instead.\`) end`
		)
		return
	end

	if Element.Refs > 0 then
		local Needed = if Element.Refs == 1 then Length else `{Length} * {Element.Refs}`
		Block:Line(
			`if {Needed} > #RecieveInstances - RecieveInstanceCursor then error(\`Expected "{Variable}" to fit in the \{#RecieveInstances - RecieveInstanceCursor} values left beside the packet, got a length of \{{Length}} instead.\`) end`
		)
	end
end

--- Emits the send-side check on a variable length, before the length is written. Unconditional,
--- whatever WriteValidations says, because the alternative is not a missed check but a corrupt
--- packet: the prefix is the smallest numeral that holds the span, so a value outside the bounds
--- does not fit it. One shorter than a nonzero minimum encodes as a negative offset; one longer than
--- the maximum overflows the numeral -- `writeu8` keeps the low byte, so 300 goes out as 44 with all
--- 300 bytes behind it, and the receiver reads a shorter value and then the rest of the packet from
--- the wrong offset. A minimum of zero cannot be undercut, so only the maximum is checked there.
local function EmitLengthGuard(Block: Block, Lower: number, Upper: number, Length: string?)
	local Assert = Asserts.number(Length or "Length", Lower, Upper)
	if Lower > 0 then
		Block:Line(Assert.Lower)
	end

	Block:Line(Assert.Upper)
end

--- Emits the checks a received length still needs once its prefix is read. The prefix carries the
--- length's offset from `Lower` as an unsigned numeral, so the length cannot fall below `Lower`, and it
--- cannot pass `Lower` plus the most that numeral holds -- 65535 for a varint, which ReadVarLength
--- refuses past, or a fixed numeral's ceiling. A bound the prefix already meets is a comparison that
--- never fails, run once per string and once per array on every packet, so only an `Upper` short of
--- that ceiling is checked.
local function EmitReceivedLength(Block: Block, Assert: AssertPrefab, Lower: number, Upper: number, Written: boolean)
	local Varint, _, Bytes = Size.LengthPrefix(Upper - Lower, Written)
	local Ceiling = if Varint then 65535 else 256 ^ Bytes - 1
	if Lower + Ceiling > Upper then
		Block:Line(Assert.Upper)
	end
end

return {
	Asserts = Asserts,
	EmitReceivedLength = EmitReceivedLength,
	EmitLengthGuard = EmitLengthGuard,
	GenerateSpaceGuard = GenerateSpaceGuard,
	EmitCapacityGuard = EmitCapacityGuard,
}
