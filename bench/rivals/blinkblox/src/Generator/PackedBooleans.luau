--!strict
--- Packed `boolean[]` serialisation, split out of Serde.luau when that file reached its size limit.
local Blocks = require("./Blocks")
local Prefabs = require("./Prefabs")
local State = require("./State")

local PackedBooleans = {}

local EmitWriter: (Write: Blocks.Block, Variable: string, Fixed: number?, WriteOffset: string) -> ()
--- An array of plain booleans, eight to a byte, least significant bit first like `Block.Bit`.
---
--- A loop body is a block of its own, so the generic path gave every element a bitfield of its own:
--- one byte per boolean. Here the whole array is one run of bytes. A variable length reserves its
--- run at runtime, after the block's fixed bytes, the way a string does; a fixed one reserves it in
--- the block. Each side runs in a `do` scope, so two such arrays in one struct do not redeclare.
---
--- Both sides go a byte at a time, eight elements unrolled against constant masks, and finish the
--- last partial byte with a short loop. The loop they replace went an element at a time and paid a
--- modulo, a shift and a branch for every boolean -- a million of them a frame at the benchmark's
--- load -- and the reader appended each one with `table.insert`.
---
--- The writer loads a byte's eight elements into locals before it branches on any of them, and
--- under WriteValidations checks their types in the same pass rather than in a loop of its own.
--- Branching straight on `Value[i]` cost 13.5 ms a frame on random data against 3.8 on constant,
--- natively; through locals it is 7.8, and the validated writer went from 17.4 to 9.7. Truly
--- branchless forms (`v and k or 0`, a `{ [true] = 1 }` lookup) measured no better or worse.
function PackedBooleans.Emit(Read: Blocks.Block, Write: Blocks.Block, Variable: string, Fixed: number?)
	local Bytes = if Fixed then math.ceil(Fixed / 8) else nil
	if Bytes == 0 then
		return
	end

	--> Taken before the scopes open: in a loop body `_operation` emits the offset's declaration.
	local ReadOffset = if Bytes then Read:Read(Bytes) else "Read((Length + 7) // 8)"
	local WriteOffset = if Bytes then Write:Allocate(Bytes) else "Allocate((PACKED_LENGTH + 7) // 8)"

	--> Two readers, because the faster one depends on how the module runs (see `PACKED_ROWS` in
	--> Fragments.luau): testing each bit inlines natively and nothing beat it there, and copying a byte's
	--> row interprets 30% faster. "Auto" emits both and branches once per array on what the module
	--> measured as it loaded; "Bits" and "Rows" emit one, for a game that wants the choice fixed.
	local Reader = State.Options.PackedBooleanReader or "Auto"
	Read:Line("do")
	Read:Line(`\tlocal PACKED_OFFSET = {ReadOffset}`)
	local Indent = "\t"
	if Reader ~= "Bits" then
		Prefabs.Required.PackedRows = true
		local Call = `PackedRows(RecieveBuffer, PACKED_OFFSET, Length, {Variable})`
		if Reader == "Rows" then
			Read:Line(`\t{Call}`)
			Read:Line("end")
			return EmitWriter(Write, Variable, Fixed, WriteOffset)
		end
		Prefabs.Required.PackedCalibration = true
		Read:Line("\tif PACKED_BY_ROWS then")
		Read:Line(`\t\t{Call}`)
		Read:Line("\telse")
		Indent = "\t\t"
	end
	Read:Line(`{Indent}local PACKED_WHOLE = Length // 8`)
	Read:Line(`{Indent}for PACKED_BYTE = 0, PACKED_WHOLE - 1 do`)
	Read:Line(`{Indent}\tlocal PACKED_BITS = buffer.readu8(RecieveBuffer, PACKED_OFFSET + PACKED_BYTE)`)
	Read:Line(`{Indent}\tlocal PACKED_BASE = PACKED_BYTE * 8`)
	for Bit = 0, 7 do
		Read:Line(`{Indent}\t{Variable}[PACKED_BASE + {Bit + 1}] = bit32.btest(PACKED_BITS, {bit32.lshift(1, Bit)})`)
	end
	Read:Line(`{Indent}end`)
	Read:Line(`{Indent}if Length % 8 ~= 0 then`)
	Read:Line(`{Indent}\tlocal PACKED_BITS = buffer.readu8(RecieveBuffer, PACKED_OFFSET + PACKED_WHOLE)`)
	Read:Line(`{Indent}\tlocal PACKED_BASE = PACKED_WHOLE * 8`)
	Read:Line(`{Indent}\tfor PACKED_BIT = 0, Length % 8 - 1 do`)
	Read:Line(
		`{Indent}\t\t{Variable}[PACKED_BASE + PACKED_BIT + 1] = bit32.btest(PACKED_BITS, bit32.lshift(1, PACKED_BIT))`
	)
	Read:Line(`{Indent}\tend`)
	Read:Line(`{Indent}end`)
	if Reader ~= "Bits" then
		Read:Line("\tend")
	end
	Read:Line("end")

	EmitWriter(Write, Variable, Fixed, WriteOffset)
end

--- The writer, the same whichever reader the schema uses.
EmitWriter = function(Write: Blocks.Block, Variable: string, Fixed: number?, WriteOffset: string)
	local Validate = State.Options.WriteValidations
	local function Refuse(Indent: string, Index: string)
		Write:Line(
			`{Indent}if typeof(PACKED_ITEM) ~= "boolean" then error(\`Expected {Variable}[\{{Index}}] to be of type boolean, got \{type(PACKED_ITEM)} instead.\`) end`
		)
	end

	Write:Line("do")
	Write:Line(`\tlocal PACKED_LENGTH = {Fixed or `#{Variable}`}`)
	Write:Line(`\tlocal PACKED_OFFSET = {WriteOffset}`)
	Write:Line("\tlocal PACKED_WHOLE = PACKED_LENGTH // 8")
	Write:Line("\tfor PACKED_BYTE = 0, PACKED_WHOLE - 1 do")
	Write:Line("\t\tlocal PACKED_BASE = PACKED_BYTE * 8")
	local Items = {}
	for Bit = 1, 8 do
		Items[Bit] = `PACKED_{Bit}`
	end
	for Half = 0, 4, 4 do
		local Names = table.concat(Items, ", ", Half + 1, Half + 4)
		local Reads = {}
		for Bit = Half + 1, Half + 4 do
			table.insert(Reads, `{Variable}[PACKED_BASE + {Bit}]`)
		end
		Write:Line(`\t\tlocal {Names} = {table.concat(Reads, ", ")}`)
	end
	if Validate then
		--> One test for the byte on the hot path; which element failed is worked out only once one has.
		local Tests = {}
		for _, Item in Items do
			table.insert(Tests, `typeof({Item}) ~= "boolean"`)
		end
		Write:Line(`\t\tif {table.concat(Tests, " or ")} then`)
		Write:Line("\t\t\tfor PACKED_INDEX = PACKED_BASE + 1, PACKED_BASE + 8 do")
		Write:Line(`\t\t\t\tlocal PACKED_ITEM = {Variable}[PACKED_INDEX]`)
		Refuse("\t\t\t\t", "PACKED_INDEX")
		Write:Line("\t\t\tend")
		Write:Line("\t\tend")
	end
	Write:Line("\t\tlocal PACKED_BITS = 0")
	for Bit, Item in Items do
		Write:Line(`\t\tif {Item} then PACKED_BITS += {bit32.lshift(1, Bit - 1)} end`)
	end
	Write:Line("\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + PACKED_BYTE, PACKED_BITS)")
	Write:Line("\tend")
	Write:Line("\tif PACKED_LENGTH % 8 ~= 0 then")
	Write:Line("\t\tlocal PACKED_BASE = PACKED_WHOLE * 8")
	Write:Line("\t\tlocal PACKED_BITS = 0")
	Write:Line("\t\tfor PACKED_BIT = 0, PACKED_LENGTH % 8 - 1 do")
	Write:Line(`\t\t\tlocal PACKED_ITEM = {Variable}[PACKED_BASE + PACKED_BIT + 1]`)
	if Validate then
		Refuse("\t\t\t", "PACKED_BASE + PACKED_BIT + 1")
	end
	Write:Line("\t\t\tif PACKED_ITEM then PACKED_BITS += bit32.lshift(1, PACKED_BIT) end")
	Write:Line("\t\tend")
	Write:Line("\t\tbuffer.writeu8(SendBuffer, PACKED_OFFSET + PACKED_WHOLE, PACKED_BITS)")
	Write:Line("\tend")
	Write:Line("end")
end

return PackedBooleans
