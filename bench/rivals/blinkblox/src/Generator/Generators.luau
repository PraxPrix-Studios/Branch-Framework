--!strict
--!native
--!optimize 2

--- Luau types and serialisers for type declarations, the per-event read and write functions, and the
--- walk over a schema's declarations that dispatches each one to its generator.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Fragments = require("./Fragments")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Serde = require("./Serde")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode

local IGNORED_TYPES_IN_SHARED = Fragments.IGNORED_TYPES_IN_SHARED
local Types = Prefabs.Types
local Primitives = Prefabs.Primitives
local Declarations = Serde

local Generators = {}

--- Dispatches a node to the serde function for its kind. Serde.Emit points back here so that a
--- struct, an array or a map can emit whatever it contains without either file requiring the other.
function Generators.UserType(Declaration: Type, Read: Blocks.Block, Write: Blocks.Block, Variable: string?)
	local Name = Declaration.Name
	local Target = Variable or "Value"

	if not _G.RELEASE then
		Read:Comment(`{Target}: {Name}`)
		Write:Comment(`{Target}: {Name}`)
	end

	if Declaration.Type == "Primitive" then
		local Kind = (Declaration :: Parser.Primitive).Tokens.Primitive.Value
		if Kind == "Instance" then
			Read:Line("RecieveInstanceCursor += 1")
		end

		Declarations.Primitive(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Set" then
		Declarations.Set(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Map" then
		Declarations.Map(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Enum" then
		Declarations.Enum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Struct" then
		Declarations.Struct(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Tuple" then
		Declarations.Tuple(Declaration, Read, Write)
	elseif Declaration.Type == "TagEnum" then
		Declarations.TagEnum(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Array" then
		Declarations.Array(Declaration, Read, Write, Target)
	elseif Declaration.Type == "Optional" then
		Declarations.Optional(Declaration, Read, Write, Target)
	end
end

--- `Positional` names a pack's elements `Value1`, `Value2`... whatever the schema called them. The
--- names a schema gives belong in what the game sees -- a Fire's parameters, a listener's type -- and
--- nowhere else: inside a serialiser, a decode branch or a listener's reply they shared a scope with
--- the generated code's own locals, and `(s: string, Length: u16)` wrote `#s` as the u16.
--> See the reader in Generators.Event.
local READ_LOCAL = "local RecieveBuffer = RecieveBuffer"

function Generators.LuauType(
	Declaration: Type,
	UseTypeAsValue: boolean?,
	Prefix: string?,
	Positional: boolean?
): (string, string, string, string)
	Prefix = Prefix or ""

	local Type = "nil"
	local Values = "Value: nil"
	local Export = Util.GetExportName(Declaration.Name, State.Scope)
	local Returns = `{Prefix}Value`

	if Declaration.Type == "Primitive" then
		local Tokens = (Declaration :: Parser.Primitive).Tokens
		local Primitive = Primitives[Tokens.Primitive.Value]
		if type(Primitive.Type) == "function" then
			Type = Primitive.Type(Declaration :: Parser.Primitive)
		else
			Type = Primitive.Type
		end
	elseif Declaration.Type == "Set" then
		Type = Util.SetType((Declaration :: Parser.Set).Value.Values)
	elseif Declaration.Type == "Enum" then
		local Value = (Declaration :: Parser.Enum).Value
		Type = `({Util.GenerateEnumLiterals(Value.Values)})`
	elseif Declaration.Type == "TagEnum" then
		local Value = (Declaration :: Parser.TagEnum).Value
		Type = Util.TagEnumType(Value.Tag, Value.Values, function(Variant)
			return (Generators.LuauType(Variant))
		end)
	elseif Declaration.Type == "Map" then
		local MapValue = (Declaration :: Parser.Map).Value
		local Key = Generators.LuauType(MapValue.Values[1])
		local Value = Generators.LuauType(MapValue.Values[2])
		Type = `\{[{Key}]: {Value}\}`
	elseif Declaration.Type == "Struct" then
		Type = Util.StructType(Declaration.Value.Values, function(Field)
			return (Generators.LuauType(Field))
		end, false)
	elseif Declaration.Type == "Generic" then
		Type = `{Declaration.Value.Generic}`
	elseif Declaration.Type == "Tuple" then
		local Value = (Declaration :: Parser.Tuple).Value

		local TupleTypes = { "nil" }
		local Variables = { "Value" }
		local AnnotatedVariables = { "Value: nil" }

		--> The prefix applies to a named element too: a function's Data and Return packs share a scope
		--> in the generated body, so it is what keeps `(id: u8)` and `(id: string)` from colliding.
		for Index, TupleValue in Value.Values do
			local Name = if Positional then nil else Value.Names[Index]
			local Variable = `{Prefix}{Name or `Value{Index}`}`
			local ValueType = Generators.LuauType(TupleValue)

			TupleTypes[Index] = ValueType
			Variables[Index] = Variable
			AnnotatedVariables[Index] = `{Variable}: {ValueType}`
		end

		Type = table.concat(TupleTypes, ", ")
		Values = table.concat(AnnotatedVariables, ", ")
		Returns = table.concat(Variables, ", ")
	elseif Declaration.Type == "Array" then
		local Value = Declaration.Value
		Type = `\{ {Generators.LuauType(Value.Of)} }`
	elseif Declaration.Type == "Optional" then
		local Value = Declaration.Value
		Type = `{Generators.LuauType(Value.Of)}?`
	end

	--> Generalized type generation, works for everything except tuples
	if Declaration.Type ~= "Tuple" then
		Values = `{Prefix}Value: {UseTypeAsValue and Type or Export}`
	end

	return Type, Values, Export, Returns
end

function Generators.Type(Declaration: Type)
	local Value = Declaration.Value
	local Type, _, Export = Generators.LuauType(Declaration)

	local Generics = Util.GenericsHeader(Value.Generics)

	--> Write luau export
	State.LuauTypes.PushMultiline(`export type {Export}{Generics} = {Type}`, 1, 0)
end

function Generators.Export(Declaration: Type)
	local Name = Declaration.Name
	local _, Values, Export, Returns = Generators.LuauType(Declaration)

	local Read = Blocks.Function(State.Casing.Read, "Buffer: buffer", `({Export})`, true)
	local Write = Blocks.Function(State.Casing.Write, `{Values}`, `(buffer)`, true)

	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> The serialiser runs against the module's own cursors, swapped out for the call and swapped back
	--> after. Protected, because a value that fails validation throws part way through: before, the
	--> swap back was skipped, so a failed Write left its scratch buffer installed as the outgoing one
	--> -- the batch already queued was gone, and the next flush sent the half-written value instead --
	--> and a failed Read left the receive cursors pointing into the caller's buffer, under a decode
	--> loop that would carry on reading from it.
	local Reader = Blocks.Function("", "", `({Export})`)
	Reader:Line(READ_LOCAL)
	local Writer = Blocks.Function("", "", "(buffer)")

	Generators.UserType(Declaration, Reader, Writer)

	--> The payload is complete, so any half-filled bitfield has to reach the buffer BEFORE the trim
	--> and the return below. Left to `End`, it would be emitted after the return.
	Reader:FlushBits()
	Writer:FlushBits()

	Writer:Line("local Result = buffer.create(SendCursor)")
	Writer:Line("buffer.copy(Result, 0, SendBuffer, 0, SendCursor)")

	Reader:Return(Returns)
	Writer:Return("Result")

	Read:Lines({
		"local PreviousCursor = RecieveCursor\n",
		"local PreviousBuffer = RecieveBuffer\n",
		"local PreviousInstanceCursor = RecieveInstanceCursor\n",
		"RecieveCursor = 0\n",
		"RecieveBuffer = Buffer\n",
	}, 1)
	Read:Lines(Reader:End():Wrap("local Success, Result = pcall(", ")").Content, 1)
	Read:Lines({
		"RecieveCursor = PreviousCursor\n",
		"RecieveBuffer = PreviousBuffer\n",
		"RecieveInstanceCursor = PreviousInstanceCursor\n",
	}, 1)

	Write:Lines({
		"local Previous = Save()\n",
		"Load()\n",
	}, 1)
	Write:Lines(Writer:End():Wrap("local Success, Result = pcall(", ")").Content, 1)
	Write:Line("Load(Previous)")

	Read:Compare("Success", "true", "Not"):Line("error(Result, 0)"):End()
	Write:Compare("Success", "true", "Not"):Line("error(Result, 0)"):End()
	--> A cast, because pcall widens what it passes through: an enum read returns its literal, and
	--> strict mode sees the result as `string` rather than the enum's union of literals.
	Read:Return(`Result :: {Export}`)
	Write:Return("Result")

	Read:End():Wrap("", ",")
	Write:End()

	Body.PushLines(Read.Content, 0, Indent + 1)
	Body.PushLines(Write.Content, 0, Indent + 1)
	Body.Push(`\},`, 0, Indent)

	local BodyLines = Body.DumpLines()

	State.Noop.PushLines(table.clone(BodyLines), 0, 0)
	State.Return.PushLines(BodyLines, 0, 0)
end

function Generators.Event(
	Data: Type?,
	Index: number,
	Identifier: string,
	Function: ("Data" | "Return")?,
	Ordered: boolean?
): ({ string }, { string })
	local Type, Values, _, Returns = "nil", "Value: nil", nil, "nil"
	if Data then
		Type, Values, _, Returns = Generators.LuauType(Data, true, nil, true)

		--> An empty pack, `Data: ()`, names the placeholder `Value` for its parameter lists, where it
		--> is declared. The reader has no such parameter, so returning it read an undeclared global:
		--> nil at runtime, and a type error in the `--!strict` module a game's editor checks.
		if Data.Type == "Tuple" and #(Data :: Parser.Tuple).Value.Values == 0 then
			Returns = "nil"
		end
	end

	local Arguments = `{Values}{Function and ", InvocationIdentifier: number" or ""}`
	local Read = Blocks.Function(Util.GetPath(Identifier, false, State.Scope), "", `({Type})`)
	local Write = Blocks.Function(Util.GetPath(Identifier, true, State.Scope), Arguments, "()")

	--> The packet being read is an upvalue, and every read in the function fetched it again; a local
	--> of the same name is read from a register. Nothing replaces the packet while a reader runs. The
	--> writers get no such local: Allocate replaces SendBuffer whenever it grows it.
	Read:Line(READ_LOCAL)

	if not _G.RELEASE then
		Write:Comment(`{Identifier} ({Index})`)
	end

	--> The event index is a literal in the generated code; the writers take the text form.
	Types.u8.Write(tostring(Index), Write)

	--> An ordered event carries a per-event sequence number after its index. It wraps at 65536, and
	--> the receiver's comparison is written to tolerate that.
	--> On the server the sequence is per recipient, so the writer leaves a placeholder that each send
	--> stamps with its own recipient's number; see the ordering body in Generator/init.luau.
	if Ordered then
		if State.Context == "Server" then
			Types.u16.Write("0", Write)
		else
			Write:Line(`local OrderIdentifier = ((OrderOut[{Index}] or 0) + 1) % 65536`)
			Write:Line(`OrderOut[{Index}] = OrderIdentifier`)
			Types.u16.Write("OrderIdentifier", Write)
		end
	end
	--> A reply carries a flag after its id: 1 when the payload follows, 0 when the call failed and
	--> nothing does. The flag is read by the reply branch, not here -- a failure reply is three bytes
	--> long, and a reader that took the flag inside the payload's block had already skipped past the
	--> payload's size before it learnt there was none, landing in the middle of the next event.
	if Function then
		Types.u8.Write("InvocationIdentifier", Write)
		if Function == "Return" then
			Types.u8.Write("1", Write)
		end
	end

	if Data then
		Generators.UserType(Data, Read, Write)
	end

	Read:FlushBits()
	Write:FlushBits()

	return Read:Return(Returns):End().Content, Write:End().Content
end

function Generators.Scope(Declaration: Parser.ScopeNode)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local Parent = State.Scope
	local NewScope = Value.Scope

	local Path = Util.GetScopePrefix(NewScope, true, State.Scope)
	local Indent = (#string.split(Path, ".") - 1)
	Path = string.sub(Path, 1, #Path - 1)

	State.Scope = NewScope
	State.Noop.Push(`{Name} = \{`, 0, Indent)
	State.Return.Push(`{Name} = \{`, 0, Indent)

	Generators.AbstractSyntaxTree(Value.Values)

	State.Noop.Push(`},`, 0, Indent)
	State.Return.Push(`},`, 0, Indent)
	State.Scope = Parent
end

function Generators.AbstractSyntaxTree(Tree: { Parser.Declaration })
	for _, Declaration in Tree do
		if State.Context == "Shared" and IGNORED_TYPES_IN_SHARED[Declaration.Type] then
			continue
		end

		if Declaration.Type == "Scope" then
			Generators.Scope(Declaration :: Parser.ScopeNode)
		elseif Declaration.Type == "Event" then
			Declarations.Event(Declaration :: Parser.Event)
		elseif Declaration.Type == "Function" then
			Declarations.Function(Declaration :: Parser.Function)
		else
			if Declaration.Value.Export then
				Generators.Export(Declaration :: Type)
			end

			Generators.Type(Declaration :: Type)
		end
	end
end

return Generators
