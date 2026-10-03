--!strict
--- The tables that describe the shape of the language rather than how it is parsed: which options a
--- file accepts, which fields an `event` or a `function` declares, which keywords open a
--- declaration. They were extracted from the parser when it was over its size limit and had no room
--- to grow.
---
--- Data only, so this module requires nothing but the lexer's token types. Everything that reads a
--- token or raises a diagnostic stays in src/Parser/ -- put behaviour here and the cycle comes back.

local Lexer = require("../Lexer")

--- Every kind of node the parser can produce. AST.luau aliases this rather than restating it.
export type Declarations =
	"Map"
	| "Set"
	| "Enum"
	| "TagEnum"
	| "Tuple"
	| "Struct"
	| "Primitive"
	| "Generic"
	| "Array"
	| "Event"
	| "Function"
	| "Scope"
	| "Optional"

export type EventOption = {
	Key: string,
	Type: Lexer.Types,
	Values: { any },
	Optional: true?,
	--- Field whose value is a NUMBER the author chooses rather than one of a fixed set of keywords.
	--- `Values` cannot express that: it is checked with `table.find`, so a rate of 5 would have to be
	--- listed alongside every other rate anyone might want.
	Numeric: true?,
	--- Field whose value is a braced block of fields of its own, parsed against this list: an
	--- event's `Stream: { Rate: 10 }`.
	Fields: { EventOption }?,
}

export type Bucket = "Types" | "Scopes"

export type Keyword = {
	Class: string,
	Type: Declarations,
	Generics: boolean,
	Exportable: boolean,
}

local Grammar = {}

Grammar.OPTIONS = {
	Casing = "Identifier",
	UseColon = "Boolean",
	UsePolling = "Boolean",
	Typescript = "Boolean",
	TypesOutput = "String",
	ClientOutput = "String",
	ServerOutput = "String",
	FutureLibrary = "String",
	PromiseLibrary = "String",
	SyncValidation = "Boolean",
	WriteValidations = "Boolean",
	PackedBooleanReader = "String",
	ManualReplication = "Boolean",
	BatchUnreliable = "Boolean",
	RemoteScope = "String",
	MaxPacketSize = "Number",
	MaxEventsPerPacket = "Number",
	MaxInstancesPerPacket = "Number",
	MaxUnreliableSize = "Number",
	InboundBytesPerSecond = "Number",
	InboundBurst = "Number",
	OutboundBytesPerSecond = "Number",
	OutboundBurst = "Number",
	ClientFlushRate = "Number",
	DefaultRate = "Number",
	RequireRates = "Boolean",
	Predict = "Boolean",
	InvocationTimeout = "Number",
	ClientConnectTimeout = "Number",
	AutoStart = "Boolean",
	TrafficStats = "Boolean",
	ExportLimits = "Boolean",
} :: { [string]: Lexer.Types }

--> Defaults the option checks and the generator both need. Here because this module is data only,
--> and the generator's Fragments cannot be required from the option parser.
-->
--> The inbound budget charges every packet at least `InboundFloor` bytes, so a flood of tiny packets
--> is not free, and refills at `InboundRatePackets` full-size packets a second.
-->
--> The unreliable budget was measured in Studio by benchmark/Probe.luau, the same in both directions:
--> a call carrying only a buffer arrives up to 994 bytes of it, and every Instance beside it costs
--> exactly 6 bytes more (988 with one, 970 with four, 898 with sixteen). `MaxUnreliableSize` is
--> checked against the buffer plus `UnreliableInstanceBytes` per Instance, and its default keeps 14
--> bytes of that 994 in reserve against the encoding shifting between Roblox versions.
Grammar.DEFAULTS = {
	MaxPacketSize = 8192,
	InboundFloor = 128,
	InboundRatePackets = 8,
	MaxUnreliableSize = 980,
	UnreliableInstanceBytes = 6,
	ClientFlushRate = 60,
}

--- The fields of an event's `Stream` block (docs/src/content/docs/language/streams.mdx): the rate
--- the server sends at, the faster rate `SetFast(true)` switches to, how long a state that has not
--- changed waits before it is sent again, and how far a number may move before it counts as changed.
--- Nested in the event rather than a declaration of its own, so a stream keeps everything an event
--- already has -- its channel index, its sequence number, `Call`, the size analysis, the signature.
Grammar.STREAM = {
	{ Key = "Rate", Type = "Number", Values = {}, Numeric = true },
	{ Key = "Fast", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Keepalive", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Epsilon", Type = "Number", Values = {}, Optional = true, Numeric = true },
	--- `Per: Player` holds a state for each player instead of one for everyone.
	{ Key = "Per", Type = "Identifier", Values = { "Player" }, Optional = true },
} :: { EventOption }

--- Seconds a stream waits before it sends an unchanged state again, when its block does not say.
Grammar.STREAM_KEEPALIVE = 1

Grammar.EVENT = {
	{ Key = "From", Type = "Identifier", Values = { "Client", "Server" } },
	{ Key = "Type", Type = "Identifier", Values = { "Reliable", "Unreliable", "OrderedUnreliable" } },
	{ Key = "Call", Type = "Identifier", Values = { "SingleSync", "SingleAsync", "ManySync", "ManyAsync", "Polling" } },
	{ Key = "Poll", Type = "Boolean", Values = { true, false }, Optional = true },
	{ Key = "Rate", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Burst", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Stream", Type = "OpenBraces", Values = {}, Optional = true, Fields = Grammar.STREAM },
	--- Milliseconds a client's send time may reach back: the server hands the listener the time the
	--- client sent the event, no earlier than this before the server received it.
	{ Key = "Stamp", Type = "Number", Values = {}, Optional = true, Numeric = true },
	--- `Low` leaves a server's unreliable send to a player out while that player's outbound budget is
	--- spent; see option OutboundBytesPerSecond.
	{ Key = "Priority", Type = "Identifier", Values = { "Low", "Normal" }, Optional = true },
	{ Key = "Data", Type = "Identifier", Values = {}, Optional = true },
} :: { EventOption }

--- The widest `Stamp` window, in milliseconds: under half the u16 the stamp wraps at, so a stamp
--- inside it always unwraps to the right side of the server's clock.
Grammar.STAMP_MAX = 30000

Grammar.FUNCTION = {
	--- Optional, and defaulting to Client, because every schema written before this existed means
	--- "the client asks the server" -- which was the only direction Blink had.
	{ Key = "From", Type = "Identifier", Values = { "Client", "Server" }, Optional = true },
	{ Key = "Yield", Type = "Identifier", Values = { "Future", "Promise", "Coroutine" } },
	{ Key = "Rate", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Burst", Type = "Number", Values = {}, Optional = true, Numeric = true },
	--- How many of one player's calls the server runs at once. Rate bounds how many START; this bounds
	--- how many are still running, which is what a listener that waits -- a DataStore request, an
	--- invocation back to the same client -- turns a flood of calls into.
	{ Key = "Concurrency", Type = "Number", Values = {}, Optional = true, Numeric = true },
	{ Key = "Data", Type = "Identifier", Values = {}, Optional = true },
	{ Key = "Return", Type = "Identifier", Values = {}, Optional = true },
} :: { EventOption }

Grammar.BUCKETS = {
	Type = "Types",
	Event = "Scopes",
	Function = "Scopes",
	Scope = "Scopes",
} :: { [string]: Bucket }

Grammar.KEYWORDS = {
	map = {
		Type = "Map",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	set = {
		Type = "Set",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	enum = {
		Type = "Enum",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	type = {
		Type = "Primitive",
		Class = "Type",
		Generics = false,
		Exportable = true,
	},
	struct = {
		Type = "Struct",
		Class = "Type",
		Generics = true,
		Exportable = true,
	},
	event = {
		Type = "Event",
		Class = "Event",
		Generics = false,
		Exportable = false,
	},
	["function"] = {
		Type = "Function",
		Class = "Function",
		Generics = false,
		Exportable = false,
	},
	scope = {
		Type = "Scope",
		Class = "Scope",
		Generics = false,
		Exportable = false,
	},
} :: { [string]: Keyword }

--- The three composite types whose bodies may be written in terms of a generic parameter.
Grammar.GENERICS_TYPES = {
	Map = true,
	Struct = true,
	TagEnum = true,
}

--- Names the generated module already uses at the top level, so a declaration may not take them.
Grammar.RESERVED = {
	StepReplication = true,
	SetRateLimitHandler = true,
	SetDecodeErrorHandler = true,
	SetPacketDropHandler = true,
	SetListenerErrorHandler = true,
	--> Emitted only under `option TrafficStats`, reserved always: turning the option on must not
	--> start refusing a schema that compiled without it.
	GetTrafficStats = true,
	ResetTrafficStats = true,
}

--- Luau's built-in type names. A declared type becomes an exported Luau type of the same name, and
--- Luau refuses to redefine these: `type number = u8` emitted `export type number = number`, a type
--- error in the strict module. (`nil` and `typeof` are words the lexer never passes as a name.)
Grammar.LUAU_TYPES = {
	any = true,
	boolean = true,
	buffer = true,
	never = true,
	number = true,
	string = true,
	thread = true,
	unknown = true,
}

--- Luau's reserved words. A named type-pack element becomes a LOCAL VARIABLE in the generated
--- module -- unlike a struct field, which becomes a table key and is quoted by FormatKey -- so one
--- of these as a name would emit code that does not compile.
Grammar.LUAU_KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

--- Names the public functions of a generated module use in their own bodies. A named type-pack
--- element becomes a PARAMETER of those functions -- `Fire(chefId, dish)` -- so an element named after
--- one of these shadows it there: `Player` would be the payload rather than the recipient, `Load`
--- a number rather than the function every send begins with. Everywhere else in the module the
--- elements travel under positional names, so this is the whole list.
Grammar.WRAPPER_NAMES = {
	Player = true,
	Players = true,
	PlayersMap = true,
	Load = true,
	Save = true,
	Mark = true,
	Rollback = true,
	Cursor = true,
	Instances = true,
	Sent = true,
	Failure = true,
	Previous = true,
	SerdesFunctions = true,
	SavePlayerBuffer = true,
	CheckUnreliableSize = true,
	Buffer = true,
	Size = true,
	SendBuffer = true,
	SendCursor = true,
	SendInstances = true,
	Allocate = true,
	Position = true,
	Unreliable = true,
	Reliable = true,
	NextOrder = true,
	List = true,
	Except = true,
	InvocationIdentifier = true,
	InvokePlayer = true,
	ClaimInvocation = true,
	Invocations = true,
	PlayerInvocations = true,
	ReleaseInvocation = true,
	ParkInvocation = true,
	TimeoutInvocation = true,
	TimeoutPlayerInvocation = true,
	Success = true,
	Future = true,
	Promise = true,
	Resolve = true,
	Reject = true,
	OnCancel = true,
	Events = true,
	Queue = true,
	Listener = true,
	ListenerRan = true,
	ListenerFailure = true,
	ListenerFailed = true,
	RunListener = true,
	SerdesEvent = true,
	Spawn = true,
	pcall = true,
	error = true,
	buffer = true,
	table = true,
	task = true,
	coroutine = true,
	typeof = true,
}

--- The option block's shape. Moved here from Parser.luau so that the code which PARSES it can
--- live outside the parser without requiring it back.
export type Options = {
	Casing: string?,
	UseColon: boolean?,
	UsePolling: boolean?,
	Typescript: boolean?,
	TypesOutput: string?,
	ClientOutput: string?,
	ServerOutput: string?,
	FutureLibrary: string?,
	PromiseLibrary: string?,
	SyncValidation: boolean?,
	WriteValidations: boolean?,
	--- How a packed `boolean[]` is read: "Auto" (measured as the module loads), "Bits" or "Rows".
	PackedBooleanReader: string?,
	ManualReplication: boolean?,
	BatchUnreliable: boolean?,
	RemoteScope: string?,

	--> Inbound limits. These bound what a hostile client can make the server do inside a single
	--> packet; see the generator's INBOUND_GUARD.
	MaxPacketSize: number?,
	MaxEventsPerPacket: number?,
	MaxInstancesPerPacket: number?,

	--> The per-player inbound budget: bytes a client's packets may cost the server each second, and
	--> the most it may bank. Checked before a packet is decoded, unlike the limits per packet.
	InboundBytesPerSecond: number?,
	InboundBurst: number?,

	--> The per-player outbound budget: bytes the server may send one player each second, and the most
	--> it may bank. Only a `Priority: Low` send is ever left out for it.
	OutboundBytesPerSecond: number?,
	OutboundBurst: number?,

	--> The most times a second a client's Heartbeat sends what it has gathered; see Fragments.Heartbeat.
	ClientFlushRate: number?,

	--> Largest payload an unreliable event may send: its buffer, plus `UnreliableInstanceBytes` for
	--> each Instance beside it. Roblox drops an UnreliableRemoteEvent whose payload passes 1000
	--> bytes, and the payload is every argument of the call as Roblox encodes it: the buffer, the
	--> instances table, and the bytes that describe each. Roblox does not document what the rest
	--> costs, so it was measured; see DEFAULTS. Configurable because a platform's ceiling can move.
	MaxUnreliableSize: number?,

	--> Rate limiting. `DefaultRate` applies to every inbound event and function that does not set its
	--> own `Rate`; `RequireRates` turns a missing rate into a compile error, which is how a project
	--> stops one from being forgotten.
	DefaultRate: number?,
	RequireRates: boolean?,

	--> Generates a Predict entry point on each event, which dispatches to local listeners without
	--> touching remotes. See the generator.
	Predict: boolean?,

	--> Seconds before an unanswered invocation fails its caller and gives its slot back.
	InvocationTimeout: number?,

	--> Seconds the client waits for the server's remotes before it returns a module that is not
	--> connected. Absent, it waits for as long as it takes. See Generator/Lifecycle.
	ClientConnectTimeout: number?,

	--> False leaves the server's remotes uncreated until the game calls `Start`. See
	--> Generator/Lifecycle.
	AutoStart: boolean?,

	--> Counts the bytes and events each declaration sends and receives, and the packets on each
	--> channel, behind GetTrafficStats. Off by default, and when off nothing of it is emitted.
	TrafficStats: boolean?,

	--> Adds a frozen `Limits` table of the schema's bounds to every generated module. See
	--> Generator/Limits.
	ExportLimits: boolean?,
}

return Grammar
