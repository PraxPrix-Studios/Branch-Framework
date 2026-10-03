--!strict
--- How each kind of type is read from and written to a buffer. One function per node the parser can
--- produce, each emitting into a Read block and a Write block.
---
--- Split out of Generator/init.luau when that file was over its size limit.
--- These were the obvious piece to move: of everything in that file they reach for the least of its
--- state. Two things they do need are injected rather than required, because the dependency runs
--- both ways -- the generator dispatches into these, and a struct or an array has to dispatch back
--- out to whatever its fields are. The options the run is under are read from State.luau.
local Parser = require("../Parser")
local Size = require("../Modules/Size")

local Bits = require("./Bits")
local Blocks = require("./Blocks")
local PackedBooleans = require("./PackedBooleans")
local Prefabs = require("./Prefabs")
local Scope = require("./Scope")
local State = require("./State")
local Util = require("./Util")

local Types = Prefabs.Types
local Primitives = Prefabs.Primitives

local FormatIndex = Util.FormatIndex
local BitIndexToHex = Util.BitIndexToHex

type Type = Parser.TypeNode
--> One definition shared with Settings, Parser and Prefabs, not Roblox NumberRange userdata.
type NumberRange = Parser.NumberRange

local Serde = {}

--- The recursive entry point, set once by the generator to Generators.UserType. Requiring it here
--- instead would be a cycle: that function's whole job is to dispatch into this table.
Serde.Emit = (nil :: any) :: (Declaration: Type, Read: Blocks.Block, Write: Blocks.Block, Variable: string?) -> ()

--- The two the generator defines on this table rather than here. An event or a function is not a
--- type on the wire -- emitting one needs scopes, builders, casing and the channel counters, all of
--- which are that file's state. Declared so the table is not sealed against them.
Serde.Event = (nil :: any) :: (Declaration: Parser.Event) -> ()
Serde.Function = (nil :: any) :: (Declaration: Parser.Function) -> ()

function Serde.Primitive(Declaration: Parser.Primitive, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Tokens = Declaration.Tokens
	local Primitive = Tokens.Primitive.Value
	local Generator = Primitives[Primitive]
	Generator.Generate(Declaration, Variable, Read, Write, State.Options.WriteValidations)
end

function Serde.Set(Declaration: Parser.Set, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Flags = Value.Values

	do
		--> Read Flags

		Read:Line(`{Read:Declare(Variable)} = \{\}`)

		local Remaining = #Flags
		local FlagIndex = 1

		while Remaining > 0 do
			local Partition = math.min(Remaining, 32)
			Prefabs.GetTypeToUseByBits(Partition).Read("SET_BITS", Read)

			for Index = 1, Partition do
				local Flag = Flags[FlagIndex]

				--> A flag is a table field, never a local, so nothing is declared for it. It used to be
				--> recorded as a declared variable, and a reader after it that declares a local of the
				--> same name -- a string's `Length`, an enum's `Index` -- then assigned a global instead.
				Read:Line(`{Variable}{FormatIndex(Flag)} = bit32.btest(SET_BITS, {BitIndexToHex(Index - 1)});`)

				FlagIndex += 1
			end

			Remaining -= Partition
		end
	end

	do
		--> Write body

		local Remaining = #Flags
		local FlagIndex = 1

		while Remaining > 0 do
			local Partition = math.min(Remaining, 32)
			Write:Line(`{Write:Declare("SET_BITS")} = 0`)

			for Index = 1, Partition do
				local Flag = Flags[FlagIndex]
				Write:Line(`if {Variable}{FormatIndex(Flag)} == true then SET_BITS += {BitIndexToHex(Index - 1)} end`)
				FlagIndex += 1
			end

			Prefabs.GetTypeToUseByBits(Partition).Write("SET_BITS", Write)

			Remaining -= Partition
		end
	end
end

function Serde.Enum(Declaration: Parser.Enum, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Enums = Value.Values
	local Literal = Util.GenerateEnumLiterals(Enums)
	Literal = string.gsub(Literal, "|", "or")

	--> The index takes the bits that tell the values apart, in the block's bitfield beside its
	--> booleans and presence flags, where it took a byte of its own.
	local Width = Bits.Width(#Enums)

	--> Read body
	Read:Line(`{Read:Declare(Variable)} = true :: any`)
	Bits.Read(Read, "Index", Width)
	Read = Read:Compare("Index", "0", "Equals")
	for Index, EnumItem in Enums do
		if Index > 1 then
			Read = Read:Branch("Conditional", "Index", `{Index - 1}`, "Equals")
		end

		Read:Line(`{Variable} = "{EnumItem}"`)
	end
	Read:Branch("Default"):Line(`error(\`Unexpected enum: \{Index\}\`)`):End()

	--> Write body. Each branch adds its own index, worked out now, to the bytes it lands in.
	local Segments = Bits.Claim(Write, "Allocate", Width)
	for Index, EnumItem in Enums do
		if Index == 1 then
			Write = Write:Compare(Variable, `"{EnumItem}"`, "Equals")
		else
			Write = Write:Branch("Conditional", Variable, `"{EnumItem}"`, "Equals")
		end

		Bits.WriteConstant(Write, Segments, Index - 1)
	end
	Write:Branch("Default"):Line(`error(\`Unexpected enum: \{{Variable}\}, expected one of {Literal}.\`)`):End()
end

function Serde.Map(Declaration: Parser.Map, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local MapValue = Declaration.Value
	local Key = MapValue.Values[1]
	local Value = MapValue.Values[2]

	local KeyVariable = `Key_{Read.Indent}`
	local ElementVariable = `Element_{Write.Indent}`
	local ElementsVariable = `Elements_{Write.Indent}`
	local ElementsAllocation = Write:Allocate(2)

	Read:Line(`{Read:Declare(Variable)} = \{\}`)
	Write:Line(`local {ElementsVariable} = 0`)
	Types.u16.Read(ElementsVariable, Read)

	local ReadLoop = Read:Loop("_ = 1", ElementsVariable)
	local WriteLoop = Write:Iterator(KeyVariable, ElementVariable, Variable)

	--> Maps are unsafe
	ReadLoop:DisableOperationOptimisations()
	WriteLoop:DisableOperationOptimisations()

	--ReadLoop:Line(`local Key: {KeyType}, Element: {ValueType};`)
	WriteLoop:Line(`{ElementsVariable} += 1`)
	Serde.Emit(Key :: Type, ReadLoop, WriteLoop, KeyVariable)
	Serde.Emit(Value :: Type, ReadLoop, WriteLoop, ElementVariable)
	ReadLoop:Line(`{Variable}[{KeyVariable}] = {ElementVariable}`)

	WriteLoop:End()
	ReadLoop:End()

	--> The count is a u16 and nothing bounds a map in the schema, so one past 65535 entries would go
	--> out as its low sixteen bits in front of every entry. See Prefabs.EmitLengthGuard.
	Prefabs.EmitLengthGuard(Write, 0, Size.MapLength, ElementsVariable)
	Write:Line(`buffer.writeu16(SendBuffer, {ElementsAllocation}, {ElementsVariable})`)
end

--- A decoded struct is created with a slot for every field its reader always assigns, rather than
--- empty: a table built as `{}` and then given six fields rehashed four times on the way, 0 to 1 to
--- 2 to 4 to 8, and that measured five times the cost of one made at its size -- the most expensive
--- line of the server's decode loop for an array of structs. The placeholders are written over at
--- once. An optional field gets none, because its reader assigns nothing when the value is absent
--- and a placeholder would then be decoded as a value.
function Serde.Struct(Declaration: Parser.Struct, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value

	local Slots = {}
	for _, Field in Value.Values do
		if Field.Type ~= "Optional" then
			local Name = Field.Name
			table.insert(Slots, if Util.IsValidIdentifier(Name) then `{Name} = false` else `["{Name}"] = false`)
		end
	end

	Read:Line(`{Read:Declare(Variable)} = \{{table.concat(Slots, ", ")}\} :: any`)

	--> Each field in a scope of its own, so that its locals end with it; see Scope.luau.
	for _, Field in Value.Values do
		local Name = Field.Name
		local FieldVariable = `{Variable}{FormatIndex(Name)}`
		Scope(Read, function()
			Scope(Write, function()
				Serde.Emit(Field :: Type, Read, Write, FieldVariable)
			end)
		end)
	end
end

--- A pack's elements are serialised under positional names, never the ones the schema gave them; see
--- `Generators.LuauType`.
function Serde.Tuple(Declaration: Parser.Tuple, Read: Blocks.Block, Write: Blocks.Block)
	for Index, Value in Declaration.Value.Values do
		Serde.Emit(Value :: Type, Read, Write, `Value{Index}`)
	end
end

function Serde.TagEnum(Declaration: Parser.TagEnum, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Values = Value.Values

	--> Body
	local Tag = Value.Tag
	local Header = `"{Values[1].Name}"`
	local TagIndex = `{Variable}{FormatIndex(Tag)}`

	--> The tag takes the bits that tell the variants apart, in the enclosing block's bitfield. Each
	--> variant's own fields are generated into its branch, a block of its own.
	local Width = Bits.Width(#Values)
	Bits.Read(Read, "Tag", Width)
	Read:Line(`{Read:Declare(Variable)} = true :: any`)

	local Segments = Bits.Claim(Write, "Allocate", Width)

	Read = Read:Compare("Tag", "0", "Equals")
	Write = Write:Compare(TagIndex, Header, "Equals")

	for Index, Variant in Values do
		local Name = `"{Variant.Name}"`
		if Index > 1 then
			Read = Read:Branch("Conditional", "Tag", tostring(Index - 1), "Equals")
			Write = Write:Branch("Conditional", TagIndex, Name, "Equals")
		end

		Bits.WriteConstant(Write, Segments, Index - 1)

		Serde.Emit(Variant, Read, Write, Variable)
		Read:Line(`{TagIndex} = {Name}`)
	end

	Read:Branch("Default"):Line(`error(\`Unexpected variant: \{Tag\}\`)`):End()

	Write:Branch("Default"):Line(`error(\`Unexpected variant: \{{TagIndex}\}\`)`):End()
end
function Serde.Array(Declaration: Parser.Array, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	local Value = Declaration.Value
	local Of = Value.Of
	local Range = Value.Range :: NumberRange

	Read:Comment("START ARRAY")
	Write:Comment("START ARRAY")

	local Lower = Range.Min
	local Upper = Range.Max

	local Iterator = `Item_{Read.Indent}`
	local IsVariableSize = (Lower ~= Upper)

	--> Length
	if IsVariableSize then
		--> Encoded RELATIVE to the declared minimum, in the smallest numeral that can hold the span.
		--> `u8[300..400]` needs one byte for a hundred possible lengths, not the two that 400 would
		--> otherwise demand -- and a length below the minimum can no longer be written at all.
		local Span = (Upper - Lower)
		local Varint = Size.LengthPrefix(Span, Size.RangeWritten(Declaration :: any))
		local LengthType = if Varint then nil else Prefabs.GetTypeToUse(Span)
		local Assert = Prefabs.Asserts.number("Length", Lower, Upper)

		if Lower > 0 then
			Prefabs.ReadPrefix("LengthOffset", Read, LengthType)
			Read:Line(`local Length = LengthOffset + {Lower}`)
		else
			Prefabs.ReadPrefix("Length", Read, LengthType)
		end

		Prefabs.EmitReceivedLength(Read, Assert, Lower, Upper, Size.RangeWritten(Declaration :: any))

		--> Checked on the SEND side too, and unconditionally; see Prefabs.EmitLengthGuard.
		Prefabs.EmitLengthGuard(Write, Lower, Upper, `#{Variable}`)

		if Lower > 0 then
			Write:Line(`local LengthOffset = #{Variable} - {Lower}`)
			Prefabs.WritePrefix("LengthOffset", Write, LengthType)
		else
			Prefabs.WritePrefix(`#{Variable}`, Write, LengthType)
		end
	else
		Read:Line(`local Length = {Upper}`)

		--> A fixed length sends no prefix, so a longer array cannot corrupt the packet -- it is cut
		--> to its first elements, silently. Under WriteValidations that is refused instead. `#` is
		--> meaningless across an optional's holes, so there every index is checked.
		if State.Options.WriteValidations then
			if Of.Type == "Optional" then
				Write:Line(
					`for Key in {Variable} do if type(Key) == "number" and Key > {Upper} then error(\`Expected "{Variable}" to hold at most {Upper} elements, got one at index \{Key} instead.\`) end end`
				)
			else
				Write:Line(Prefabs.Asserts.string(Variable, Upper, Upper).Exact :: string)
			end
		end
	end

	--> Array
	if IsVariableSize then
		Prefabs.EmitCapacityGuard(Read, "Length", Variable, Of)
	end
	Read:Line(`{Read:Declare(Variable)} = table.create(Length)`)

	if Size.PacksBooleans(Of :: any) then
		PackedBooleans.Emit(Read, Write, Variable, if IsVariableSize then nil else Upper)
		Read:Comment("END ARRAY")
		Write:Comment("END ARRAY")
		return
	end

	--> Body
	--> The reader's counter is named for its depth: an element's own reader may declare an `Index` of
	--> its own -- an enum does -- which would shadow a counter of that name before it is used below.
	local Slot = `Slot_{Read.Indent}`
	Read = Read:Loop(`{Slot} = 1`, "Length")
	Write = Write:Loop("Index = 1", IsVariableSize and `#{Variable}` or Upper)

	Write:Line(`local {Iterator} = {Variable}[Index]`)
	Serde.Emit(Of, Read, Write, Iterator)

	--> By index, not `table.insert`: an absent optional element is nil, and inserting nil does nothing,
	--> so every element after a hole used to arrive one place early.
	Read:Line(`{Variable}[{Slot}] = {Iterator}`)

	--> End
	Read = Read:End()
	Write = Write:End()

	Read:Comment("END ARRAY")
	Write:Comment("END ARRAY")
end

function Serde.Optional(Declaration: Parser.Optional, Read: Blocks.Block, Write: Blocks.Block, Variable: string)
	Read:Declare(Variable, true)

	local Of = Declaration.Value.Of
	local IsInstance = if Of.Type == "Primitive" then Of.Tokens.Primitive.Value == "Instance" else false

	if IsInstance then
		Read:Line("RecieveInstanceCursor += 1")
		Read = Read:Compare("typeof(RecieveInstances[RecieveInstanceCursor])", '"Instance"', "Equals")
		Read:Line("RecieveInstanceCursor -= 1")
	else
		--> The presence flag is one BIT, sharing a byte with any other flags and booleans in the same
		--> block. It is claimed on both sides before the payload branch, so read and write reserve the
		--> same byte at the same offset.
		local WriteAccumulator, WriteMask = Write:Bit("Allocate")
		Write:Line(`if {Variable} ~= nil then {WriteAccumulator} += {WriteMask} end`)

		local ReadAccumulator, ReadMask = Read:Bit("Read")
		Read = Read:Scope(`if bit32.btest({ReadAccumulator}, {ReadMask}) then`)
		Write = Write:Compare(Variable, "nil", "Not")
	end

	Serde.Emit(Declaration.Value.Of, Read, Write, Variable)
	Read:End()

	if not IsInstance then
		Write:End()
	end
end

return Serde
