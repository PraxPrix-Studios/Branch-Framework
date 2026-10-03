--!strict
--- Everything one generation run builds up, in one table.
---
--- These were module-level locals of Generator/init.luau, and several of them are REASSIGNED while
--- a run is under way -- the decode functions are swapped in once the connections are open. A local is
--- an upvalue of the file that declares it, so no other file could take part in generating. Held as
--- fields of one shared table, the event, function and type generators can live in files of their
--- own and still read and write the same values.
---
--- A run starts with `State.Reset`, then sets `Context`, `Options` and `Casing` from the schema.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Settings = require("../Settings")

export type Context = "Client" | "Server" | "Shared"

--- One declaration's branch of a channel's decode loop, by the index it is sent under.
export type Branch = { Index: number, Block: Blocks.Block }

export type State = {
	--- The scope whose declarations are being generated; swapped on the way into a nested scope.
	Scope: Parser.Scope,
	Context: Context,
	Casing: Settings.Cases,
	Options: Parser.Options,

	--- The edit-mode stub table, the events table, the serdes of named types, their Luau types,
	--- and the public API table.
	Noop: Builder.Builder,
	Events: Builder.Builder,
	UserTypes: Builder.Builder,
	LuauTypes: Builder.Builder,
	Return: Builder.Builder,
	--- Each stream's scheduler entry and the send it calls, emitted after the stream runtime.
	Streams: Builder.Builder,

	--- Each channel's decode function, which its branches are nested in; see Decode.Close.
	Reliables: Blocks.Block,
	Unreliables: Blocks.Block,

	--- Set when the schema declares at least one OrderedUnreliable event, so the sequence
	--- bookkeeping is emitted only where something uses it.
	UsesOrdering: boolean,

	--- Set when the schema declares a stream, so the stream runtime (Templates/Stream.luau) is
	--- emitted only where something uses it.
	UsesStreams: boolean,
	--- Whether this side batches any unreliable event it sends; see Batches.luau.
	UsesBatches: boolean,

	--- Set when this side sends or receives a stamped event, so the stamp runtime
	--- (Templates/Stamp.luau) is emitted only where something uses it.
	UsesStamps: boolean,

	--- Set when this side's module invokes a function whose Yield is Future or Promise -- only the
	--- invoking side does -- so the library is required only by a module that calls into it. A
	--- require nothing used was a lint warning in every listening module.
	UsesFuture: boolean,
	UsesPromise: boolean,

	--- One entry per rate-limited event or function, in the order they were generated. Each takes
	--- four consecutive numbers in the per-player bucket, so the entry at index N starts at slot
	--- (N - 1) * 4 + 1.
	RateSlots: { { Rate: number, Burst: number } },

	--- How many events each channel carries, and the decode branch of each declaration this side
	--- listens for on it: none means this side receives nothing there.
	Channels: { [string]: { Count: number, Branches: { Branch } } },

	Reset: () -> (),
}

local State: State = {
	Scope = nil :: any,
	Context = "Shared",
	Casing = nil :: any,
	Options = nil :: any,

	Noop = Builder.new(),
	Events = Builder.new(),
	UserTypes = Builder.new(),
	LuauTypes = Builder.new(),
	Return = Builder.new(),
	Streams = Builder.new(),

	Reliables = nil :: any,
	Unreliables = nil :: any,

	UsesOrdering = false,
	UsesStreams = false,
	UsesBatches = false,
	UsesStamps = false,
	UsesFuture = false,
	UsesPromise = false,
	RateSlots = {},
	Channels = {
		Reliable = { Count = 0, Branches = {} },
		Unreliable = { Count = 0, Branches = {} },
	},

	Reset = nil :: any,
}

function State.Reset()
	State.Noop = Builder.new()
	State.Events = Builder.new()
	State.UserTypes = Builder.new()
	State.LuauTypes = Builder.new()
	State.Return = Builder.new()
	State.Streams = Builder.new()

	table.clear(State.RateSlots)
	table.clear(Prefabs.Required)
	State.UsesOrdering = false
	State.UsesStreams = false
	State.UsesBatches = false
	State.UsesStamps = false
	State.UsesFuture = false
	State.UsesPromise = false

	for _, Channel in State.Channels do
		Channel.Count = 0
		table.clear(Channel.Branches)
	end
end

return State
