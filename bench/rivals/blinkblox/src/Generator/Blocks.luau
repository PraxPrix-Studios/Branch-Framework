--!strict
type BranchType = "Conditional" | "Default"
type EqualityOperator = "Not" | "Equals" | "Greater" | "Less" | "GreaterOrEquals" | "LessOrEquals"

type Method = "Read" | "Allocate" | "None"

--- A fragment that is interpolated into the code being generated. It is `string | number` because
--- callers legitimately pass both: an identifier from the schema ("Length", "Value1") or a literal
--- count computed by the generator (an event index, a fixed array size). Both interpolate to the
--- same text, and declaring only `string` is what forced numeric call sites to type-error.
export type Emittable = string | number

type Operation = {
	Method: Method,
	Bytes: number,
	Counts: number,
	Variable: Emittable?,
}

local DEFAULT_UNIQUE = "BLOCK_START"
local ARRAY_UNIQUE = "ARRAY_START"

--> Names of the runtime buffers, spliced in from src/Templates/Base.luau. Hardcoded here for the
--> same reason `Declarations.Enum` hardcodes them: this DSL only ever emits into generated
--> modules, where both names are in scope by construction.
local SEND_BUFFER = "SendBuffer"
local RECIEVE_BUFFER = "RecieveBuffer"

--> One mask per bit position. Hex because that is how the emitted code reads best beside
--> `bit32.btest`, and it is what the set packing already uses.
local BIT_MASKS = { "0x01", "0x02", "0x04", "0x08", "0x10", "0x20", "0x40", "0x80" }
local BITS_PER_BYTE = 8

local Operators = {
	Not = "~=",
	Equals = "==",
	Greater = ">",
	Less = "<",
	GreaterOrEquals = ">=",
	LessOrEquals = "<=",
}

local Block = {}

--> Indentation by depth, built once per depth: every emitted line is prefixed by one, and building it
--> with string.rep on each of the tens of thousands of lines a module has was a measurable share of
--> generation.
local INDENTS: { [number]: string } = setmetatable({}, {
	__index = function(Cache: { [number]: string }, Depth: number): string
		local Indentation = string.rep("\t", Depth)
		Cache[Depth] = Indentation
		return Indentation
	end,
}) :: any

Block.__index = Block

export type Block = typeof(setmetatable(
	{} :: {
		Unique: string,
		Parent: Block?,
		Indent: number,
		Cursor: number,
		Unsafe: boolean,
		Content: { string },
		Operation: Operation,
		Variables: { [string]: boolean },
		OperationOffset: number,
		--> Lines `_lineFront` has put at the top of the block, which Scope.luau has to count past.
		FrontInserted: number,

		--> Bit packing state. A boolean, or an optional's presence flag, costs one BIT rather than a
		--> whole byte: the block reserves a byte on the first bit and keeps filling it until either
		--> it holds eight or the block ends.
		BitCursor: number,
		BitCount: number,
		BitMethod: Method,
		BitOffset: string?,
		BitAccumulator: string?,
	},
	Block
))

function Block.new<Parent>(Parent: Block?, Unique: string?): Block
	local Indent = (Parent and Parent.Indent + 1 or 1)
	return setmetatable(
		{
			Unique = Unique or DEFAULT_UNIQUE,
			Parent = Parent,
			Indent = Indent,
			Cursor = 1,
			Unsafe = false,
			Content = table.create(64),
			Operation = {
				Method = "None",
				Bytes = 0,
				Counts = 0,
			},
			Variables = {},
			OperationOffset = 0,
			FrontInserted = 0,

			BitCursor = 0,
			BitCount = 0,
			BitMethod = "None",
			BitOffset = nil,
			BitAccumulator = nil,
		} :: any,
		Block
	)
end

function Block.DisableOperationOptimisations(self: Block): Block
	self.Unsafe = true
	return self
end

function Block._operation(self: Block, Method: Method, Bytes: number): string
	local Operation = self.Operation
	if Operation.Method ~= "None" and Operation.Method ~= Method then
		error(`Block can't both Allocate and Read`)
	end

	if self.Unsafe then
		local Counts = Operation.Counts
		local Variable = `OFFSET_{Counts}`

		Operation.Counts += 1
		self:Line(`local {Variable} = {Method}({Bytes})`)

		return Variable
	end

	local Offset = Operation.Bytes
	Operation.Bytes += Bytes
	Operation.Method = Method

	if self.Unique ~= DEFAULT_UNIQUE then
		self:Comment(`{Method} {Bytes}`)
		local OperationOffset = `OPERATION_OFFSET_{self.OperationOffset}`
		self.OperationOffset += 1
		self:Line(`local {OperationOffset} = {self.Unique}`)
		self:Line(`{self.Unique} += {Bytes}`)
		return OperationOffset
	end

	return `{self.Unique} + {Offset}`
end

function Block.Read(self: Block, Bytes: number): string
	return self:_operation("Read", Bytes)
end

function Block.Allocate(self: Block, Bytes: number): string
	return self:_operation("Allocate", Bytes)
end

function Block._lineFront(self: Block, Text: string, Indent: number?): Block
	table.insert(self.Content, self.Cursor, `{INDENTS[Indent or self.Indent]}{Text}\n`)
	self.FrontInserted += 1
	return self
end

--- Declares `Name` at the top of the block rather than where it is first assigned, so it outlives any
--- scope Scope.luau opens around the field that assigns it. A loop block's top is above its `for` line, as its allocation
--- header is.
function Block._declareFront(self: Block, Name: string)
	self:_lineFront(`local {Name}`, if self.Unique ~= DEFAULT_UNIQUE then self.Indent - 1 else self.Indent)
end

--- Writes out the byte a write-side bitfield has been filling, and closes the current bit scope.
---
--- Only the WRITE side needs this. A reader has the byte in hand the moment it reserves it, so it
--- reads bits straight out of a local; a writer accumulates into that local and has to put it back
--- into the buffer at the offset it reserved earlier.
---
--- Reserving early and writing late is safe even if the buffer grew in between: `Allocate` copies
--- the existing contents forward and offsets stay valid.
function Block._flushBits(self: Block): Block
	local Accumulator = self.BitAccumulator
	if Accumulator and self.BitMethod == "Allocate" then
		self:Line(`buffer.writeu8({SEND_BUFFER}, {self.BitOffset}, {Accumulator})`)
	end

	self.BitCursor = 0
	self.BitOffset = nil
	self.BitAccumulator = nil
	self.BitMethod = "None"

	return self
end

--- Closes the current bit scope explicitly.
---
--- Needed where a block keeps receiving lines after the serialisation is finished -- an exported
--- Write appends its buffer trim and `return Result` afterwards, and a bitfield flushed at
--- `End` would land after that return, where it is both unreachable and a syntax error.
function Block.FlushBits(self: Block): Block
	return self:_flushBits()
end

--- Claims one bit and returns the accumulator holding it together with its mask.
---
--- Callers emit their own test or set: `bit32.btest(BITFIELD_0, 0x04)` on read,
--- `if Value then BITFIELD_0 += 0x04 end` on write.
---
--- THE POINT OF DOING IT THIS WAY: the total number of bits does not have to be known in advance.
--- The ninth bit simply reserves another byte, which coalesces into the same block allocation at
--- whatever offset it lands. Read and write walk the identical AST in the identical order, so both
--- sides reserve the same number of bytes at the same relative offsets without either side counting
--- anything ahead of time. That is what removes the need for an IR here: zap needs a bit budget
--- because its IR flushes explicitly, while the tree walk gives determinism for free.
function Block.Bit(self: Block, Method: Method): (string, string)
	if self.BitAccumulator == nil or self.BitCursor >= BITS_PER_BYTE then
		self:_flushBits()

		local Offset = self:_operation(Method, 1)
		--> Named for the block's depth as well: a tagged enum's branch declares bitfields of its own and
		--> writes the tag into its parent's, which a name the two shared would shadow.
		local Accumulator = `BITFIELD_{self.Indent}_{self.BitCount}`

		--> Declared at the top of the block: the fields that share this byte may each sit in a scope of
		--> their own (see Scope.luau), and the byte is written out after the last of them.
		self:_declareFront(Accumulator)
		if Method == "Read" then
			self:Line(`{Accumulator} = buffer.readu8({RECIEVE_BUFFER}, {Offset})`)
		else
			self:Line(`{Accumulator} = 0`)

			--> In a loop or an unsafe block the offset is a local declared where it was reserved, which
			--> may be inside such a scope too; the flush needs it after that scope ends.
			if string.match(Offset, "^[%a_][%w_]*$") then
				local Held = `{Accumulator}_OFFSET`
				self:_declareFront(Held)
				self:Line(`{Held} = {Offset}`)
				Offset = Held
			end
		end

		self.BitCount += 1
		self.BitMethod = Method
		self.BitOffset = Offset
		self.BitAccumulator = Accumulator
		self.BitCursor = 0
	end

	local Mask = BIT_MASKS[self.BitCursor + 1]
	self.BitCursor += 1

	return self.BitAccumulator :: string, Mask
end

function Block._appendOperations(self: Block): Block
	--> Before the allocation header, and before the block's content goes anywhere: a half-filled
	--> bitfield still has to reach the buffer. This runs from both End and Branch, which are
	--> exactly the points where a bit scope ends.
	self:_flushBits()

	local Operation = self.Operation
	local Variable = Operation.Variable
	if Operation.Method == "None" then
		return self
	end

	local Append = `local {self.Unique} = {Operation.Method}({Operation.Bytes}{Variable and ` * {Variable}` or ""})`

	self:_lineFront(Append, self.Unique ~= DEFAULT_UNIQUE and self.Indent - 1 or self.Indent)
	self:_lineFront(`-- {Operation.Method} BLOCK: {Operation.Bytes} bytes`)

	return self
end

function Block.Declare(self: Block, Variable: string, Initialize: boolean?): string
	local Current = self
	local Declared = false
	local IsFieldAccess = (string.find(Variable, "[%.%[]", 1) ~= nil)

	--> Ignore field acceses
	if IsFieldAccess then
		return Variable
	end

	--> Search for variable declaration in block hierarchy
	while Current do
		if Current.Variables[Variable] then
			Declared = true
			break
		end

		Current = Current.Parent :: Block
	end

	if Declared then
		return Variable
	end

	--> Declare variable within current block
	self.Variables[Variable] = true

	if Initialize then
		self:Line(`local {Variable}`)
	end

	return `local {Variable}`
end

function Block.Advance(self: Block, Offset: number): Block
	self.Cursor += Offset
	return self
end

function Block.Line(self: Block, Text: string, Indent: number?): Block
	table.insert(self.Content, `{INDENTS[Indent or self.Indent]}{Text}\n`)
	return self
end

function Block.Character(self: Block, Character: string): Block
	table.insert(self.Content, Character)
	return self
end

function Block.Comment(self: Block, Content: string): Block
	self:Line(`-- {Content}`)
	return self
end

function Block.Lines(self: Block, Lines: { string }, Indent: number?): Block
	local IndentLevel = Indent or 0

	--> FAST PATH
	if IndentLevel == 0 then
		table.move(Lines, 1, #Lines, #self.Content + 1, self.Content)
		return self
	end

	local Indentation = INDENTS[IndentLevel]

	for _, Line in Lines do
		table.insert(self.Content, `{Indentation}{Line}`)
	end

	return self
end

function Block.Multiline(self: Block, Content: string, Indent: number?): Block
	local Lines = string.split(Content, "\n")
	for _, Line in Lines do
		table.insert(self.Content, `{INDENTS[Indent or 0]}{Line}\n`)
	end

	return self
end

function Block.Loop(self: Block, Counter: Emittable, Length: Emittable): Block
	local Loop = Block.new(self, `{ARRAY_UNIQUE}_{self.Indent}`)
	Loop:Line(`for {Counter}, {Length} do`, Loop.Indent - 1)
	Loop.Operation.Variable = Length
	return Loop
end

function Block.While(self: Block, Condition: string): Block
	self:Line(`while ({Condition}) do`)
	return Block.new(self)
end

--- A scope of its own under `Header`, such as a local function: closed by `End` like any other.
function Block.Scope(self: Block, Header: string): Block
	self:Line(Header)
	return Block.new(self)
end

function Block.Iterator(self: Block, Key: string, Value: string, Iterator: string): Block
	self:Line(`for {Key}, {Value} in {Iterator} do`)
	return Block.new(self)
end

function Block.Compare(self: Block, Left: Emittable, Right: Emittable, Operator: EqualityOperator): Block
	self:Line(`if {Left} {Operators[Operator]} {Right} then`)
	return Block.new(self)
end

function Block.Branch(
	self: Block,
	Branch: BranchType,
	Left: Emittable?,
	Right: Emittable?,
	Operator: EqualityOperator?
): Block
	local Parent = self.Parent
	assert(Parent, "Cannot branch the top level block.")

	--> Push previous branch content
	self:_appendOperations()
	Parent:Lines(self.Content)

	--> Create new branch
	if Branch == "Conditional" then
		Parent:Line(`elseif {Left} {Operators[Operator]} {Right} then`)
	else
		Parent:Line(`else`)
	end

	return Block.new(Parent)
end

function Block.Return(self: Block, Return: string): Block
	self:Line(`return {Return}`)
	return self
end

function Block.End(self: Block): Block
	self:_appendOperations()

	local Parent = self.Parent
	if Parent then
		Parent:Lines(self.Content)
		Parent:Line("end")
		return Parent
	end

	self:Line("end", 0)
	return self
end

function Block.Wrap(self: Block, Front: string, Back: string): Block
	local First = self.Content[1]
	self.Content[1] = `{Front}{First}`

	local Last = self.Content[#self.Content]
	self.Content[#self.Content] = `{string.gsub(Last, "\n", "")}{Back}\n`

	return self
end

function Block.Unwrap(self: Block)
	return table.concat(self.Content)
end

local Function = {}
Function.__index = Function
setmetatable(Function, Block)

function Function.new(Name: string, Arguments: string, Return: string?, IsInlined: boolean?, Localised: boolean?): Block
	local NewBlock = Block.new(nil)
	setmetatable(NewBlock :: any, Function)

	local Suffix = Return and `: {Return}` or ""
	NewBlock:Advance(1)

	if IsInlined then
		NewBlock:Line(`{Name} = function({Arguments}){Suffix}`, 0)
	elseif Localised then
		NewBlock:Line(`local function {Name}({Arguments}){Suffix}`, 0)
	else
		NewBlock:Line(`function {Name}({Arguments}){Suffix}`, 0)
	end

	return NewBlock
end

local Connection = {}
Connection.__index = Connection
setmetatable(Connection, Block)

function Connection.new(Signal: string, Arguments: string): Block
	local NewBlock = Block.new()
	setmetatable(NewBlock :: any, Connection)
	NewBlock:Advance(1)
	NewBlock:Line(`{Signal}:Connect(function({Arguments})`, 0)
	return NewBlock
end

function Connection.End(self: Block): Block
	self:Line("end)", 0)
	return self
end

return {
	Block = Block.new,
	Function = Function.new,
	Connection = Connection.new,
}
