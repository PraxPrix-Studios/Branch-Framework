--!strict
--!native
--!optimize 2

--- Static size analysis: how many bytes a type can occupy on the wire, at least and at most.
---
--- It exists for one reason. Roblox drops an UnreliableRemoteEvent whose payload passes 1000 bytes,
--- and says so only in Studio's Output: in a live game the event just never arrives, and only when a
--- value happens to be large. A schema that can exceed its budget is broken in a way that no test in
--- the game will reproduce, so the compiler has to say so before the schema ships rather than after.
--- The budget is `MaxUnreliableSize`; see Grammar.DEFAULTS for why it sits below 1000.
---
--- The numbers here MUST track what `src/Generator/Prefabs/` actually emits. They are checked
--- against it rather than trusted: the suite serialises every exported type and asserts the measured
--- bounds contain the real byte length, so a prefab that changes size without a matching change here
--- fails the build.
---
--- Pure Luau on purpose. No `@lune/*` requires and no Roblox globals, so the Studio plugin can run
--- it and show the oversize diagnostic in the editor -- which is where a schema is actually written.

local Lexer = require("../Lexer")
local Settings = require("../Settings")

type Token = Lexer.Token

--- A node of the parser's AST. Deliberately structural rather than `Parser.TypeNode`: requiring the
--- parser from here would close a cycle, since the parser is what calls this.
type Node = {
	Type: string,
	Name: string,
	Value: any,
	Tokens: any,
}

export type Measurement = {
	--- Smallest number of buffer bytes a value of this type can occupy.
	Min: number,
	--- Largest. Always finite -- every length in the language is bounded by the numeral that carries
	--- it -- but "finite" routinely means 65535 elements, which is the point of `Unbounded`.
	Max: number,
	--- Whether that maximum comes from a bound the author wrote or from the default ceiling. A
	--- `string` is Unbounded; a `string(0..64)` is not, even though both have a finite maximum.
	Unbounded: boolean,
	--- Bits this type contributes to the bitfield of the scope it sits in -- booleans and optional
	--- presence flags. They are NOT bytes yet: eight of them share one, and which ones share depends
	--- on the scope, so they are carried separately until the scope closes. `Seal` converts them.
	Bits: number,
	--- Slots taken in the instance side table, which travels as the remote's second argument rather
	--- than in the buffer. Counted separately because the packet caps count them separately.
	Refs: number,
	--- The token to point a diagnostic at: the first thing that made this type unbounded.
	Culprit: Token?,
}

local PRIMITIVES = Settings.Primtives

--- Default ceiling for a length the author did not bound. Mirrors the prefabs, which fall back to
--- `2 ^ 16 - 1` for a string or buffer with no range.
local DEFAULT_LENGTH = (2 ^ 16 - 1)

--- Ceiling on the element count of a map. The generator writes it as a u16, unconditionally.
local MAP_LENGTH = (2 ^ 16 - 1)

local BITS_PER_BYTE = 8

--- How a length prefix is written, for a length within a `Span` of its minimum -- lengths travel
--- relative to it -- and whether the author wrote the bound. Whether it is a varint, and the fewest and
--- most bytes it takes. The emitter (Prefabs/Lengths.luau, Serde.Array) asks this too, so the two
--- cannot disagree.
---
--- A span a byte holds takes that byte. One that needs two takes a varint instead -- seven bits a
--- byte, so a length under 128 costs one and the rest the two they always did. A length nobody bounded
--- is one too, up to three bytes: its ceiling is the default 65535, and most such strings are short.
--- A wider span the author wrote keeps a numeral of fixed width, which is never longer than it needs.
local function LengthPrefix(Span: number, Written: boolean): (boolean, number, number)
	if Span <= 255 then
		return false, 1, 1
	elseif Span < 16384 then
		return true, 1, 2
	elseif not Written and Span <= 65535 then
		return true, 1, 3
	elseif Span <= 65535 then
		return false, 2, 2
	elseif Span <= 16777215 then
		return false, 3, 3
	end

	return false, 4, 4
end

--- Bytes a set partition costs, mirroring `Prefabs.GetTypeToUseByBits`.
local function PartitionBytes(Flags: number): number
	if Flags <= 8 then
		return 1
	elseif Flags <= 16 then
		return 2
	end

	return 4
end

--- Bits an enum's index or a tag takes: as few as tell `Count` values apart, and at least one.
--- Mirrors `Bits.Width` in the generator.
local function IndexBits(Count: number): number
	local Width = 1
	while 2 ^ Width < Count do
		Width += 1
	end
	return Width
end

local function ComponentBytes(Component: string?): number
	if not Component then
		return PRIMITIVES.f32.Bytes
	end

	local Primitive = PRIMITIVES[Component]
	return if Primitive then Primitive.Bytes else PRIMITIVES.f32.Bytes
end

local function Empty(): Measurement
	return {
		Min = 0,
		Max = 0,
		Unbounded = false,
		Bits = 0,
		Refs = 0,
		Culprit = nil,
	}
end

--- Closes a bit scope: turns however many bits accumulated into the bytes they actually occupy.
---
--- A scope here is a generated BLOCK, which is what the emitter packs bits into -- a loop body, a
--- branch, an optional's payload. A struct is NOT a scope: its fields share the enclosing block, and
--- therefore share its bitfield, which is why eight booleans in a struct cost one byte.
local function Seal(Measured: Measurement): Measurement
	local Bytes = math.ceil(Measured.Bits / BITS_PER_BYTE)

	return {
		Min = Measured.Min + Bytes,
		Max = Measured.Max + Bytes,
		Unbounded = Measured.Unbounded,
		Bits = 0,
		Refs = Measured.Refs,
		Culprit = Measured.Culprit,
	}
end

--- Folds a child's measurement into a running total, `Times` copies of it.
local function Add(Total: Measurement, Part: Measurement, Times: number?)
	local Count = Times or 1

	Total.Min += Part.Min * Count
	Total.Max += Part.Max * Count
	Total.Bits += Part.Bits * Count
	Total.Refs += Part.Refs * Count

	if Part.Unbounded and not Total.Unbounded then
		Total.Unbounded = true
		Total.Culprit = Part.Culprit
	end
end

local Measure: (Node) -> Measurement

local function MeasurePrimitive(Node: Node): Measurement
	local Value = Node.Value
	local Tokens = Node.Tokens
	local Name: string = Tokens.Primitive.Value
	local Primitive = PRIMITIVES[Name]
	local Range = Value.Range

	--> Instances and unknowns are never encoded: they are appended to the instance table and travel
	--> as the remote's second argument. Zero bytes, one slot.
	if Name == "Instance" or Name == "unknown" then
		local Result = Empty()
		Result.Refs = 1
		return Result
	end

	if Name == "string" or Name == "buffer" then
		local Result = Empty()

		--> An exact length needs no prefix at all -- the reader already knows how far to advance.
		if Range and Range.Min == Range.Max then
			Result.Min = Range.Min
			Result.Max = Range.Max
			return Result
		end

		local Upper = if Range then Range.Max else DEFAULT_LENGTH
		local Lower = if Range then Range.Min else 0
		local _, PrefixMin, PrefixMax = LengthPrefix(Upper - Lower, Range ~= nil)

		Result.Min = PrefixMin + Lower
		Result.Max = PrefixMax + Upper
		Result.Unbounded = (Range == nil)
		Result.Culprit = if Result.Unbounded then Tokens.Primitive else nil
		return Result
	end

	if Name == "vector" then
		local Components: { string }? = Value.Components
		local Component = if Components then Components[#Components] else nil
		local Bytes = ComponentBytes(Component) * 3

		local Result = Empty()
		Result.Min = Bytes
		Result.Max = Bytes
		return Result
	end

	if Name == "CFrame" then
		--> Mirrors the prefab exactly, including its asymmetry: the position is written through the
		--> vector prefab, which reads the LAST component, while the three orientation values use the
		--> first. Measuring it any other way would be measuring a different compiler.
		local Components: { string }? = Value.Components
		local Position = if Components then Components[#Components] else nil
		local Rotation = if Components then Components[1] else nil
		local Bytes = (ComponentBytes(Position) * 3) + (ComponentBytes(Rotation) * 3)

		--> `quat` may stand in either slot; the rotation is then its fixed seven bytes, and the
		--> position is whichever component remains.
		if Components and table.find(Components, "quat") then
			local Other = if Components[1] == "quat" then Components[2] else Components[1]
			Bytes = (ComponentBytes(Other) * 3) + PRIMITIVES.quat.Bytes
		end

		local Result = Empty()
		Result.Min = Bytes
		Result.Max = Bytes
		return Result
	end

	--> A boolean is one bit in the enclosing scope's bitfield rather than a byte of its own.
	if Name == "boolean" then
		local Result = Empty()
		Result.Bits = 1
		return Result
	end

	local Result = Empty()
	Result.Min = if Primitive then Primitive.Bytes else 0
	Result.Max = Result.Min
	return Result
end

--- Whether the author wrote the array's bounds. `u8[]` with none written is the case worth warning
--- about; `u8[0..16]` is not, even though both are variable length. Shared with the analysis, which
--- asks the same question of a repetition that costs nothing to decode.
local function RangeWritten(Node: Node): boolean
	local RangeToken: Token? = Node.Tokens.Range
	return if RangeToken then RangeToken.Value ~= "[]" else false
end

--- Whether an array of this element is packed eight elements to a byte rather than one per byte.
---
--- Only a plain `boolean`: an optional one carries a presence bit AND a value bit per element, and
--- a map's value shares its loop body with the key. Shared with the emitter, so the two cannot come
--- to disagree about which arrays are packed.
local function PacksBooleans(Of: Node): boolean
	return Of.Type == "Primitive" and Of.Tokens.Primitive.Value == "boolean"
end

local function MeasureArray(Node: Node): Measurement
	local Value = Node.Value
	local Range = Value.Range

	local Lower = Range.Min
	local Upper = Range.Max
	local Result = Empty()

	local _, PrefixMin, PrefixMax = LengthPrefix(Upper - Lower, RangeWritten(Node))
	if Lower == Upper then
		PrefixMin, PrefixMax = 0, 0
	end

	if PacksBooleans(Value.Of) then
		local Low = math.ceil(Lower / BITS_PER_BYTE)
		local High = math.ceil(Upper / BITS_PER_BYTE)
		Result.Min = PrefixMin + Low
		Result.Max = PrefixMax + High
		Result.Unbounded = (Lower ~= Upper) and not RangeWritten(Node)
		Result.Culprit = if Result.Unbounded then Node.Tokens.Range else nil
		return Result
	end

	--> The loop body is a block of its own, so the element's bits are packed per element rather than
	--> shared with whatever surrounds the array.
	local Of = Seal(Measure(Value.Of))

	--> A fixed-length array is unrolled and carries no length prefix.
	if Lower == Upper then
		Add(Result, Of, Upper)
		return Result
	end

	Result.Min = PrefixMin + (Of.Min * Lower)
	Result.Max = PrefixMax + (Of.Max * Upper)
	Result.Refs = Of.Refs * Upper

	Result.Unbounded = Of.Unbounded or not RangeWritten(Node)
	Result.Culprit = if Of.Unbounded then Of.Culprit else Node.Tokens.Range

	return Result
end

local function MeasureMap(Node: Node): Measurement
	local Values = Node.Value.Values

	--> Key and value are emitted into the SAME loop body, so they share one bitfield -- sealing them
	--> together rather than separately is what keeps this in step with the emitter.
	local Pair = Empty()
	Add(Pair, Measure(Values[1]))
	Add(Pair, Measure(Values[2]))
	Pair = Seal(Pair)

	--> The element count is an unconditional u16 and nothing in the language can bound it, so every
	--> map is unbounded by construction.
	local Result = Empty()
	Result.Min = 2
	Result.Max = 2 + (Pair.Max * MAP_LENGTH)
	Result.Refs = Pair.Refs * MAP_LENGTH
	Result.Unbounded = true
	--> A map node carries only its key's token (see Parser.Map); it has no `Primitive` to point at,
	--> and reading one left every map without a culprit. The key is inside the braces the author
	--> would have to change.
	Result.Culprit = Node.Tokens.Key

	return Result
end

local function MeasureSet(Node: Node): Measurement
	local Flags = #Node.Value.Values
	local Bytes = 0

	local Remaining = Flags
	while Remaining > 0 do
		local Partition = math.min(Remaining, 32)
		Bytes += PartitionBytes(Partition)
		Remaining -= Partition
	end

	local Result = Empty()
	Result.Min = Bytes
	Result.Max = Bytes
	return Result
end

--- Best token to underline for a node, for diagnostics. A range reads better than the type name --
--- `u8[]` is unbounded because of the brackets -- and the primitive is the fallback.
local function TokenOf(Node: Node): Token?
	local Tokens = Node.Tokens
	if not Tokens then
		return nil
	end

	return Tokens.Range or Tokens.Primitive
end

local function MeasureFields(Node: Node): Measurement
	local Result = Empty()
	for _, Field in Node.Value.Values do
		local Measured = Measure(Field :: Node)

		--> A child deep inside a map has no token of its own worth pointing at; the FIELD does, and
		--> that is the line the author has to change.
		if Measured.Unbounded and not Measured.Culprit then
			Measured.Culprit = TokenOf(Field :: Node)
		end

		Add(Result, Measured)
	end

	return Result
end

local function MeasureTagEnum(Node: Node): Measurement
	local Variants = Node.Value.Values

	local Smallest: number? = nil
	local Largest = 0
	local Refs = 0
	local Unbounded = false
	local Culprit: Token? = nil

	for _, Variant in Variants do
		--> Each variant is generated into its own branch, so its bits never share a byte with another
		--> variant's -- or with anything outside the tagged enum.
		local Measured = Seal(MeasureFields(Variant :: Node))

		Smallest = if Smallest then math.min(Smallest, Measured.Min) else Measured.Min
		Largest = math.max(Largest, Measured.Max)
		Refs = math.max(Refs, Measured.Refs)

		if Measured.Unbounded and not Unbounded then
			Unbounded = true
			Culprit = Measured.Culprit
		end
	end

	--> The tag is bits in the enclosing bitfield, like an enum's index.
	local Result = Empty()
	Result.Bits = IndexBits(#Variants)
	Result.Min = Smallest or 0
	Result.Max = Largest
	Result.Refs = Refs
	Result.Unbounded = Unbounded
	Result.Culprit = Culprit

	return Result
end

local function MeasureOptional(Node: Node): Measurement
	local Of = Node.Value.Of :: Node
	local IsInstance = if Of.Type == "Primitive" then Of.Tokens.Primitive.Value == "Instance" else false

	--> An optional Instance carries no flag byte: absence is read from the instance table itself.
	if IsInstance then
		return Measure(Of)
	end

	--> The presence flag is one bit in the ENCLOSING scope; the payload is generated inside a branch,
	--> which is a scope of its own. So an absent optional costs a bit and nothing else.
	local Payload = Seal(Measure(Of))
	local Result = Empty()

	Result.Bits = 1
	Result.Min = 0
	Result.Max = Payload.Max
	Result.Refs = Payload.Refs
	Result.Unbounded = Payload.Unbounded
	Result.Culprit = Payload.Culprit

	return Result
end

function Measure(Node: Node): Measurement
	local Kind = Node.Type

	if Kind == "Primitive" then
		return MeasurePrimitive(Node)
	elseif Kind == "Array" then
		return MeasureArray(Node)
	elseif Kind == "Optional" then
		return MeasureOptional(Node)
	elseif Kind == "Map" then
		return MeasureMap(Node)
	elseif Kind == "Set" then
		return MeasureSet(Node)
	elseif Kind == "Enum" then
		--> Its index is bits in the enclosing bitfield, as few as tell its values apart and at least
		--> one; mirrors `Bits.Width` in the generator.
		local Result = Empty()
		Result.Bits = IndexBits(#Node.Value.Values)
		return Result
	elseif Kind == "TagEnum" then
		return MeasureTagEnum(Node)
	elseif Kind == "Struct" or Kind == "Tuple" then
		return MeasureFields(Node)
	end

	--> "Generic" is the only remaining kind, and generics are substituted before a declaration is
	--> ever measured. Measuring one as empty is wrong but harmless; erroring here would turn a
	--> compiler bug into a crash in the editor.
	return Empty()
end

--- Measures a type as a complete, self-contained payload: bits converted into the bytes they
--- occupy. This is what every caller outside this module wants -- `Measure` alone leaves bits
--- pending, because whether they share a byte depends on what encloses them.
local function Sealed(Node: Node): Measurement
	return Seal(Measure(Node))
end

--- Bytes an ordered unreliable event spends on its sequence number, on top of its payload. Exposed
--- so the unreliable size analysis can account for it without duplicating the constant.
local ORDERING_BYTES = 2

return {
	Measure = Measure,
	Sealed = Sealed,
	PacksBooleans = PacksBooleans,
	RangeWritten = RangeWritten,
	TokenOf = TokenOf,
	LengthPrefix = LengthPrefix,
	DefaultLength = DEFAULT_LENGTH,
	MapLength = MAP_LENGTH,
	OrderingBytes = ORDERING_BYTES,
}
