--!strict
--!native
--!optimize 2

--- What a number's modifiers add to its serialiser: the scale of `u16<0.1>`, and `saturate`.
---
--- Both change only the value that reaches the wire, so they wrap the primitive's own read and write
--- rather than replacing them. The sender converts into a local, `Fixed`, never into the caller's
--- table: a scaled value is rounded to whole steps, a saturated integer to a whole number, and a
--- saturated value is then clamped into its range. The receiver reads the integer as always, checks
--- it against the range in whole steps -- exact, where a check in real units would compare rounded
--- doubles -- and only then scales it back.
--- Required by Common.luau, so it reaches for Blocks and the parser directly rather than back
--- through Common.
local Blocks = require("../Blocks")
local FixedPoint = require("../../Modules/FixedPoint")
local Parser = require("../../Parser")

type Block = Blocks.Block
type NumberRange = Parser.NumberRange

local Fixed = {}

--> The local the sender converts into. Declared through the block, so one per scope is shared.
local VARIABLE = "Fixed"

--- The bounds a value is held to on the wire: the declared range in whole steps when the type is
--- scaled, otherwise the declared range or, without one, the type's own.
function Fixed.WireBounds(Declaration: Parser.Primitive): NumberRange
	local Value = Declaration.Value
	local Scale = Value.Scale
	local Range = Value.Range
	local Bounds = Range or Value.Primitive.Bounds :: NumberRange

	if Scale and Range then
		local Offset = Value.Offset or 0
		return {
			Min = FixedPoint.Encode(Range.Min, Scale) - Offset,
			Max = FixedPoint.Encode(Range.Max, Scale) - Offset,
		}
	end

	return { Min = Bounds.Min, Max = Bounds.Max }
end

--- Emits the clamp of a saturated value. NaN goes to the value in range nearest zero; see
--- `FixedPoint.NaNTarget`. An open float side is left out, as the range checks leave it out.
---
--- `Offset` is a quantized float's minimum in steps: NaN goes to the value nearest zero in the schema's
--- own units, which on the wire is that many steps lower.
local function Clamp(Block: Block, Min: number, Max: number, Offset: number)
	local Target = FixedPoint.NaNTarget(Min + Offset, Max + Offset) - Offset
	local Line: string
	if Target == Min and Min ~= -math.huge then
		Line = `if not ({VARIABLE} >= {Min}) then {VARIABLE} = {Min}`
	else
		Line = `if {VARIABLE} ~= {VARIABLE} then {VARIABLE} = {Target}`
		if Min ~= -math.huge then
			Line ..= ` elseif {VARIABLE} < {Min} then {VARIABLE} = {Min}`
		end
	end

	if Max ~= math.huge then
		Line ..= ` elseif {VARIABLE} > {Max} then {VARIABLE} = {Max}`
	end

	Block:Line(`{Line} end`)
end

--- Emits the WriteValidations check of a scaled value that is not saturated: the steps it rounds
--- to must fit the range, and the message speaks in the schema's own units.
local function Check(Block: Block, Target: string, Declaration: Parser.Primitive, Bounds: NumberRange)
	local Scale = Declaration.Value.Scale :: number
	local Offset = Declaration.Value.Offset or 0
	local Min, Max = FixedPoint.Decode(Bounds.Min + Offset, Scale), FixedPoint.Decode(Bounds.Max + Offset, Scale)
	local Units = `in steps of {Scale}`

	if Bounds.Min == Bounds.Max then
		Block:Line(
			`if {VARIABLE} ~= {Bounds.Max} then error(\`Expected "{Target}" to be equal to {Max} {Units}, got \{{Target}} instead.\`) end`
		)
		return
	end

	--> Written `not (x >= Min)`, so that NaN -- whose steps are NaN -- is refused as well.
	Block:Line(
		`if not ({VARIABLE} >= {Bounds.Min}) then error(\`Expected "{Target}" to be larger than or equal to {Min} {Units}, got \{{Target}} instead.\`) end`
	)
	Block:Line(
		`if not ({VARIABLE} <= {Bounds.Max}) then error(\`Expected "{Target}" to be smaller than or equal to {Max} {Units}, got \{{Target}} instead.\`) end`
	)
end

--- Emits the send of a number with modifiers: type check, conversion, clamp or check, then the
--- primitive's own write of the converted value.
function Fixed.Write(
	Declaration: Parser.Primitive,
	Target: string,
	Block: Block,
	WriteValidations: boolean?,
	Write: (Value: string) -> ()
)
	local Value = Declaration.Value
	local Scale = Value.Scale
	local Integer = Value.Primitive.Integer == true

	if WriteValidations then
		Block:Compare(`typeof({Target})`, `"number"`, "Not")
			:Line(`error(\`Expected {Target} to be of type number, got \{type({Target})} instead.\`)`)
			:End()
	end

	local Offset = Value.Offset or 0
	local Expression = if Scale
		then FixedPoint.EncodeExpression(Target, Scale)
		elseif Integer then `math.round({Target})`
		else Target
	if Offset > 0 then
		Expression ..= ` - {Offset}`
	elseif Offset < 0 then
		Expression ..= ` + {-Offset}`
	end
	Block:Line(`{Block:Declare(VARIABLE)} = {Expression}`)

	local Bounds = Fixed.WireBounds(Declaration)
	if Value.Saturate then
		Clamp(Block, Bounds.Min, Bounds.Max, Offset)
	elseif WriteValidations and Scale then
		Check(Block, Target, Declaration, Bounds)
	end

	Write(VARIABLE)
end

--- Emits the scaling of a value just read, after its range has been checked in whole steps.
function Fixed.Read(Declaration: Parser.Primitive, Target: string, Block: Block)
	local Scale = Declaration.Value.Scale
	local Offset = Declaration.Value.Offset or 0
	local Steps = if Offset > 0 then `({Target} + {Offset})` elseif Offset < 0 then `({Target} - {-Offset})` else Target
	local Expression = Scale and (FixedPoint.DecodeExpression(Steps, Scale) or (if Steps ~= Target then Steps else nil))
	if Expression then
		Block:Line(`{Target} = {Expression}`)
	end
end

return Fixed
