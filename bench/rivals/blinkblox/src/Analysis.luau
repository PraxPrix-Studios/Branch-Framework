--!strict
--- Semantic checks that run once the whole file is parsed, when every declaration is available and
--- every generic has been substituted.
---
--- They live apart from the parser because they are not parsing: nothing here consumes a token or
--- advances the lexer. They take the finished declarations and say what is wrong with them.
---
--- ONLY THIS FILE'S DECLARATIONS ARE WALKED. An imported scope holds nodes whose spans index the
--- imported source, so that file's own parse raises its diagnostics -- underlining those offsets
--- against this source would point at whatever text happens to sit there.

local Error = require("./Modules/Error")
local Grammar = require("./Modules/Grammar")
local InstanceSlots = require("./Modules/InstanceSlots")
local Lexer = require("./Lexer")
local ModuleNames = require("./Modules/ModuleNames")
local Priorities = require("./Modules/Priorities")
local Size = require("./Modules/Size")
local Walk = require("./Modules/Walk")

type Token = Lexer.Token

--- The checks take the source text and file name directly rather than the parser itself: requiring
--- the parser from here would close a cycle, since the parser is what calls them.
--- Structural stand-ins for the parser's AST nodes, for the same reason.
type Declaration = any
type Options = any
type Event = any

--- The largest payload an unreliable event may send, unless the schema says otherwise: its buffer
--- plus INSTANCE_BYTES per Instance. Roblox drops an UnreliableRemoteEvent whose encoded payload
--- passes 1000 bytes, see Grammar.DEFAULTS for what was measured. A live game drops it without a
--- word, which is why the compiler refuses a schema that cannot fit instead of leaving it to be
--- discovered in production.
local DEFAULT_MAX_UNRELIABLE_SIZE = Grammar.DEFAULTS.MaxUnreliableSize
local INSTANCE_BYTES = Grammar.DEFAULTS.UnreliableInstanceBytes

--- Checks the rate limiting fields. Same file-scoping rule as AnalyzeUnreliableSizes: imported
--- declarations are diagnosed by the parse of the file they came from.
local function RateLimits(Source: string, File: string?, Declarations: { Declaration }, Options: Options)
	Walk.Declarations(Declarations, function(Declaration: Declaration)
		if Declaration.Type ~= "Event" and Declaration.Type ~= "Function" then
			return
		end

		local Value = Declaration.Value
		local Identifier: Token = Declaration.Tokens.Identifier

		--> Inbound means "sent to the server". Nothing limits the server itself: it is the party being
		--> protected, and throttling its own traffic would drop what the game meant to send.
		-->
		--> This used to read `if IsEvent then ... else true`, because a function could only ever go
		--> client to server. Now that one can go the other way, treating every function as inbound
		--> would say nothing about a pointless Rate and -- worse -- demand one under RequireRates for
		--> traffic the server itself sends.
		local Inbound = Value.From == "Client"

		if not Inbound then
			if Value.Rate or Value.Burst or Value.Concurrency then
				Error.new(
					Error.AnalyzeMissingRateLimit,
					Source,
					`Rate limiting a Server {string.lower(Declaration.Type)} has no effect`,
					File,
					"Warning"
				)
					:Primary(Identifier, `This {string.lower(Declaration.Type)} is sent BY the server, not to it`)
					:Note("Rate and concurrency limits apply to inbound traffic only. Remove the field.")
					:Warn()
			end

			return
		end

		local Effective = Value.Rate or Options.DefaultRate

		--> A burst without a sustained rate has nothing to refill it: the bucket would empty once and
		--> stay empty, which is never what anyone means.
		if Value.Burst and not Effective then
			Error.new(Error.AnalyzeMissingRateLimit, Source, `"Burst" was set without a "Rate"`, File)
				:Primary(Identifier, "Add a Rate, or remove the Burst")
				:Note("Burst is the bucket's capacity; Rate is what refills it.")
				:Emit()
		end

		if Options.RequireRates and not Effective then
			Error.new(Error.AnalyzeMissingRateLimit, Source, `Inbound "{Declaration.Name}" has no rate limit`, File)
				:Primary(Identifier, "Add a Rate, in events per second")
				:Note("option RequireRates is set, so every inbound event and function must declare one.")
				:Emit()
		end
	end)
end

--- Refuses unreliable events that cannot fit in a single unreliable packet, and warns about the ones
--- that merely might not.
---
--- Only declarations from THIS file are walked. An imported scope holds nodes whose spans index the
--- imported source, so the parse of that file raises its own diagnostics -- underlining those offsets
--- here would point at unrelated text.
local function UnreliableSizes(Source: string, File: string?, Declarations: { Declaration }, Options: Options)
	local Limit = Options.MaxUnreliableSize or DEFAULT_MAX_UNRELIABLE_SIZE

	Walk.Declarations(Declarations, function(Declaration: Declaration)
		if Declaration.Type ~= "Event" then
			return
		end

		local Event = Declaration :: Event
		local Reliability = Event.Value.Type
		if Reliability ~= "Unreliable" and Reliability ~= "OrderedUnreliable" then
			return
		end

		local Data = Event.Value.Data
		local Measured = if Data then Size.Sealed(Data :: any) else nil

		--> The event index is one byte, written ahead of the payload, and an ordered event adds its
		--> sequence number on top of that -- all but a stream, which is ordered by its server time.
		local Sequenced = Reliability == "OrderedUnreliable" and Event.Value.Stream == nil
		local Header = 1 + (if Sequenced then Size.OrderingBytes else 0)
		--> Instances cost the payload bytes of their own, beside the buffer. `Refs` counts the most an
		--> event can carry, not the fewest, so it raises the maximum only: the minimum is what makes
		--> E3018 an error, and an optional Instance must not make an event that can fit refuse to build.
		local Minimum = Header + (if Measured then Measured.Min else 0)

		--> A stream's state travels as optional, since nil is how a clear arrives, and an absent optional
		--> costs nothing: measured as written, a state that can never fit would pass as one that might
		--> not. Every packet but the clear carries it, so it counts in full.
		local Stream = Event.Value.Stream
		if Stream then
			Minimum += Size.Sealed(Stream.Value).Min
		end
		local Maximum = Header + (if Measured then Measured.Max + Measured.Refs * INSTANCE_BYTES else 0)
		local Identifier = Event.Tokens.Identifier

		if Minimum > Limit then
			Error.new(
				Error.AnalyzeOversizeUnreliable,
				Source,
				`Unreliable event "{Event.Name}" cannot fit in one packet`,
				File
			)
				:Primary(Identifier, `Always at least {Minimum} bytes, the limit is {Limit}`)
				:Note(
					if Stream
						then "Roblox drops unreliable payloads past this size. Stream a smaller state, or split it."
						else "Roblox drops unreliable payloads past this size. Send it as a Reliable event instead."
				)
				:Emit()
		end

		if Maximum <= Limit then
			return
		end

		--> An unbounded type reports a real but absurd maximum -- a map of structs measures in the
		--> gigabytes -- and quoting that number reads as a compiler bug rather than as advice.
		local Bound = if (Measured and Measured.Unbounded)
			then `Unbounded, and the limit is {Limit} bytes`
			else `Up to {Maximum} bytes, the limit is {Limit}`

		local Diagnostic = Error.new(
			Error.AnalyzePotentiallyOversizeUnreliable,
			Source,
			`Unreliable event "{Event.Name}" may exceed the packet limit`,
			File,
			"Warning"
		):Primary(Identifier, Bound)

		local Culprit = if Measured then Measured.Culprit else nil
		if Culprit then
			Diagnostic:Secondary(Culprit, "This has no upper bound")
		end

		Diagnostic:Note("Bound the variable-length fields -- `string(0..64)`, `u8[..16]` -- or send it reliably.")
			:Warn()
	end)
end

--- Whether one element of a repetition costs nothing to decode -- no buffer bytes, no bits, and no
--- slot in the instance table.
---
--- A packed boolean is NOT costless, though it takes an eighth of a byte: sealed on its own it is a
--- bit rounded up to a byte, and the loop over a packed run still ends when the packet does.
local function Costless(Node: Declaration): boolean
	local Measured = Size.Sealed(Node :: any)
	return Measured.Max == 0 and Measured.Refs == 0
end

--- Refuses a repetition whose element count is read off the wire but whose elements cost nothing to
--- decode.
---
--- A decode loop is bounded by what its body consumes. An element that reads buffer bytes can only
--- repeat until the packet runs out, and MaxPacketSize caps that. An element that takes a slot in
--- the instance table runs out of instances, which the reader checks. An element that does NEITHER
--- gives the loop nothing to exhaust: `struct {}[]` turns a two-byte count into 65535 iterations and
--- 65535 table allocations, and 64 such events fit in a couple of hundred bytes.
---
--- A bound the author writes settles it: twenty costless elements are twenty iterations, and the
--- ceiling is visible in the schema. What is refused is the ceiling nobody chose -- a bare `[]`,
--- which inherits what its u16 prefix holds, and a map, which takes no range in the language at all.
---
--- Same file-scoping rule as the checks above: imported declarations are diagnosed by the parse of
--- the file they came from.
local function CostlessRepetitions(Source: string, File: string?, Declarations: { Declaration })
	local function Report(Node: Declaration, What: string)
		local Diagnostic =
			Error.new(Error.AnalyzeCostlessRepetition, Source, `{What} of a type that costs nothing to decode`, File)

		local Culprit = Size.TokenOf(Node)
		if Culprit then
			Diagnostic:Primary(Culprit, "The element count is read from the packet")
		end

		Diagnostic:Note(
			"Each element reads no bytes and takes no instance slot, so nothing stops the decode "
				.. "loop: a two-byte count is worth 65535 iterations to a hostile client."
		)
			:Note("Bound it -- `[..16]` -- or give the element a field that is actually sent.")
			:Emit()
	end

	Walk.Types(Declarations, function(Node: Declaration)
		local Value = Node.Value

		if Node.Type == "Array" then
			--> A fixed-length array is unrolled against a count the schema wrote, and a bounded one
			--> states its own ceiling -- twenty costless elements are twenty iterations. A bare `[]`
			--> inherits whatever its u16 prefix can hold, which nobody chose.
			local Range = Value.Range
			if Range and Range.Min ~= Range.Max and not Size.RangeWritten(Node) and Costless(Value.Of) then
				Report(Node, "Array")
			end
		elseif Node.Type == "Map" then
			if Costless(Value.Values[1]) and Costless(Value.Values[2]) then
				Report(Node, "Map")
			end
		end
	end)
end

--- Which decoded types can serve as a map key, and which produce a value the receiver can never
--- look anything up by.
---
--- A key has to survive the round trip AS A KEY. A string, a number, a boolean and a plain `enum`
--- all decode to the same value the sender had, so they do. Everything else decodes to a FRESH
--- TABLE per entry, and in Luau a table is its own identity: the receiver ends up with
--- `[Table(0x...)] = value`, which nothing it constructs will ever match. The map is not corrupt --
--- every byte round-trips -- it is simply unusable, which is worse, because it looks like it worked.
local UNUSABLE_KEYS: { [string]: string } = {
	Struct = "a struct",
	TagEnum = "a tagged enum",
	Map = "a map",
	Set = "a set",
	Array = "an array",
	Tuple = "a type pack",
}

--- Refuses map keys of a type that cannot be looked up.
---
--- Runs here rather than in the parser because generics are already substituted by the time this
--- walks: `GenericMap<u8[], f64>` is an ordinary map with an array key at this point, and checking
--- where the map is written would not see it.
local function MapKeys(Source: string, File: string?, Declarations: { Declaration })
	Walk.Types(Declarations, function(Node: Declaration)
		if Node.Type ~= "Map" then
			return
		end

		local Key = Node.Value.Values[1]
		local Unusable = Key and UNUSABLE_KEYS[Key.Type]
		if not Unusable then
			return
		end

		local Diagnostic =
			Error.new(Error.AnalyzeReferenceInvalidType, Source, `A map cannot be keyed by {Unusable}`, File)

		local Culprit = (Node.Tokens and Node.Tokens.Key) or Size.TokenOf(Key) or Size.TokenOf(Node)
		if Culprit then
			Diagnostic:Primary(Culprit, "This key decodes to a new table for every entry")
		end

		Diagnostic:Note(
			"Each decoded key is a table with its own identity, so nothing the receiving side "
				.. "builds will ever index the map -- every entry is reachable only by iterating it."
		)
			:Note("Key it by a string, a number, a boolean or an enum, and move the rest into the value.")
			:Emit()
	end)
end

--- Refuses `quat` anywhere but a CFrame's rotation.
---
--- `quat` is a component like `f16`, which is what lets `CFrame<quat>` parse without the parser
--- knowing about it -- and also what lets it be written where it means nothing. The parser checks
--- that a component is a component, not which type it is a component of, so that is checked here.
local function Rotations(Source: string, File: string?, Declarations: { Declaration })
	Walk.Types(Declarations, function(Node: Declaration)
		if Node.Type ~= "Primitive" then
			return
		end

		local Token = Node.Tokens.Primitive
		local Components: { string } = Node.Value.Components or {}
		local Quaternions = 0
		for _, Component in Components do
			if Component == "quat" then
				Quaternions += 1
			end
		end

		local Message, Label
		if Token.Value == "quat" then
			Message, Label = "`quat` is not a type on its own", "Write CFrame<quat> for a quaternion rotation"
		elseif Quaternions > 0 and Token.Value ~= "CFrame" then
			Message, Label = "Only a CFrame's rotation can be a quaternion", "`quat` is a component of CFrame alone"
		elseif Quaternions > 1 then
			Message, Label = "A CFrame has one rotation", "Name the position's type in the other component"
		else
			return
		end

		Error.new(Error.AnalyzeInvalidComponents, Source, Message, File):Primary(Token, Label):Emit()
	end)
end

--- How many declarations one channel can number: the index travels as a single byte.
local CHANNEL_CAPACITY = 256

--- Refuses a channel with more declarations than its one-byte index can number.
---
--- Reliable events and functions share one channel, Unreliable and OrderedUnreliable events the
--- other, and each numbers its declarations 0 to 255 in the order the generator meets them. Nothing
--- stopped a 257th: it went out with the first one's index, and the receiver decoded it as that
--- event -- the same silent misreading the schema signature exists to prevent, with nothing for the
--- signature to catch, since both sides agree on it.
---
--- The count is the generator's own walk (see `Collect` in Modules/Signature.luau), so unlike the
--- checks above it DOES descend into imported scopes: an import takes indices like anything written
--- here. An overflow inside one is reported at its `import`, the only span this file has for it. A
--- file that overflows on its own is refused by its own parse first.
local function Channels(Source: string, File: string?, Declarations: { Declaration })
	local Counts = { Reliable = 0, Unreliable = 0 }

	local function Visit(List: { Declaration }, Import: Token?)
		for _, Declaration in List do
			local Value = Declaration.Value

			if Declaration.Type == "Scope" then
				Visit(Value.Values, Import or (if Value.Imported then Declaration.Tokens.Path else nil))
				continue
			elseif Declaration.Type ~= "Event" and Declaration.Type ~= "Function" then
				continue
			end

			local Unreliable = Declaration.Type == "Event"
				and (Value.Type == "Unreliable" or Value.Type == "OrderedUnreliable")
			local Channel = if Unreliable then "Unreliable" else "Reliable"
			Counts[Channel] += 1

			if Counts[Channel] <= CHANNEL_CAPACITY then
				continue
			end

			local Noun = if Unreliable then "unreliable events" else "reliable events and functions"

			local Diagnostic = Error.new(Error.AnalyzeChannelSize, Source, `Too many {Noun}`, File)

			if Import then
				Diagnostic:Primary(Import, `This import brings the channel past {CHANNEL_CAPACITY}`)
			else
				Diagnostic:Primary(Declaration.Tokens.Identifier, `This is number {Counts[Channel]} on its channel`)
			end

			Diagnostic:Note(
				`Each channel numbers its declarations with one byte, so it holds at most {CHANNEL_CAPACITY}: `
					.. "the next would be sent with the first one's index."
			)
				:Note(
					"Reliable events and functions share a channel; Unreliable and OrderedUnreliable events share the other."
				)
				:Emit()
		end
	end

	Visit(Declarations, nil)
end

--- The Roblox types every generated module names in its own signatures and serialisers.
local ROBLOX_TYPES = {
	Player = true,
	Instance = true,
	RemoteEvent = true,
	UnreliableRemoteEvent = true,
	CFrame = true,
	Vector3 = true,
	Color3 = true,
	DateTime = true,
	BrickColor = true,
}

--- Refuses a top-level type named after a Roblox type the generated module uses.
---
--- A declared type is exported under its own name, and a Luau type alias shadows the global one for
--- the whole module: `type Player = Instance(Player)` emitted `export type Player = Player`, a type
--- that refers to itself, and every `Player: Player` parameter in the module then named the alias.
--- The module still ran -- types are erased -- but its strict type check failed.
---
--- A type inside a scope is exported with the scope's name in front, so only the top level can
--- collide. The classes named by `Instance(Class)` anywhere in the module, imports included, are
--- names it uses too.
local function RobloxNames(Source: string, File: string?, Declarations: { Declaration })
	local Used: { [string]: boolean } = table.clone(ROBLOX_TYPES)

	local function Collect(List: { Declaration })
		for _, Declaration in List do
			if Declaration.Type == "Scope" then
				Collect(Declaration.Value.Values)
				continue
			end

			for _, Root in Walk.Roots(Declaration) do
				Walk.Type(Root, function(Node: Declaration)
					if Node.Type == "Primitive" and Node.Value.Class then
						Used[Node.Value.Class] = true
					end
				end)
			end
		end
	end

	Collect(Declarations)

	for _, Declaration in Declarations do
		local Kind = Declaration.Type
		if Kind == "Scope" or Kind == "Event" or Kind == "Function" or not Used[Declaration.Name] then
			continue
		end

		--> A type node carries no token for its own name; the scope's symbol table holds it.
		local Scope = Declaration.Value.Scope
		local Symbol = Scope and Scope.Symbols.Types[Declaration.Name]
		local Identifier: Token? = Symbol and Symbol.Name
		local Diagnostic = Error.new(Error.AnalyzeReservedIdentifier, Source, `Reserved identifier`, File)
		if Identifier then
			Diagnostic:Primary(Identifier, `"{Declaration.Name}" is a Roblox type the generated module uses`)
		end

		Diagnostic:Note("A declared type is exported under its own name and would shadow it. Rename the declaration.")
			:Emit()
	end
end

--- Every check, in the order the parser has always run them.
local function Run(Source: string, File: string?, Declarations: { Declaration }, Options: Options)
	Channels(Source, File, Declarations)
	RobloxNames(Source, File, Declarations)
	ModuleNames.Check(Source, File, Declarations, Options)
	UnreliableSizes(Source, File, Declarations, Options)
	RateLimits(Source, File, Declarations, Options)
	CostlessRepetitions(Source, File, Declarations)
	MapKeys(Source, File, Declarations)
	Rotations(Source, File, Declarations)
	InstanceSlots.Check(Source, File, Declarations, Options)
	Priorities.Check(Source, File, Declarations, Options)
end

return {
	Channels = Channels,
	RobloxNames = RobloxNames,
	RateLimits = RateLimits,
	UnreliableSizes = UnreliableSizes,
	CostlessRepetitions = CostlessRepetitions,
	MapKeys = MapKeys,
	Rotations = Rotations,
	Run = Run,
}
