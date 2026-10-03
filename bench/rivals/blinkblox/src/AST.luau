--!strict
--- The shape of a parsed schema: every node the parser builds and every later stage reads.
---
--- It lives apart from the parser so the stages that only READ the tree -- size analysis, the
--- analysis passes, the signature, the generator -- can name these types without requiring the
--- parser itself, which would close a cycle through Analysis and Size. Parser re-exports each one,
--- so `Parser.TypeNode` and friends keep working for code that already requires it.
local Error = require("./Modules/Error")
local Grammar = require("./Modules/Grammar")
local Lexer = require("./Lexer")
local Settings = require("./Settings")

--> Shared with Settings and the generator so all three mean the same table, not Roblox's userdata.
export type NumberRange = Settings.NumberRange

export type Token = Lexer.Token

export type Type = "Type" | "Event" | "Scope"
export type Node<Type, Body, Tokens> = {
	Type: Type,
	Name: string,
	Value: Body,
	Tokens: Tokens,
}

export type Generics = {
	Span: Error.Span,
	List: { string },
	Keys: { [string]: { Generic } },
}

export type Reference = {
	Name: Token,
	To: TypeNode,
}

export type Scope = {
	Name: Token,
	Parent: Scope?,
	Symbols: {
		Types: { [string]: Reference },
		Scopes: { [string]: Scope },
	},
}

export type EventOption = Grammar.EventOption

export type Attributes = {
	Scope: Scope?,
	Range: NumberRange?,
	Export: boolean?,
	Generics: Generics?,
	Components: { string }?,
	--> A number's modifiers, written in angle brackets: `u16<0.1>` sends round(v / 0.1) in a u16, and
	--> `saturate` clamps a value into its range on send. See Modules/FixedPoint and Parser/Scales.
	Scale: number?,
	Saturate: boolean?,
	--> A quantized float's minimum in steps: `f32<0.01>(-1..1)` is sent as a u8 of steps above -100.
	--> Set with the node rewritten to that integer; see Parser/Scales.
	Offset: number?,
}

export type AttributesTokens = {
	Range: Token?,
	Modifiers: Token?,
}

export type Options = Grammar.Options

export type Body = Node<"Body", {
	Options: Options,
	Symbols: { [string]: true },
	Declarations: { Declaration },
}, {}>

export type Declarations = Grammar.Declarations
export type TypeNode = | Map | Set | Enum | TagEnum | Tuple | Struct | Primitive | Generic | Array | Optional

export type Declaration = Node<Declarations, {
	[any]: any,
}, {
	[any]: any,
}>

export type Array = Node<"Array", {
	Of: TypeNode,
} & Attributes, AttributesTokens>

export type Optional = Node<"Optional", {
	Of: TypeNode,
} & Attributes, AttributesTokens>

export type Set = Node<"Set", {
	Values: { string },
} & Attributes, AttributesTokens>

export type Map = Node<"Map", {
	Values: { TypeNode },
} & Attributes, AttributesTokens>

export type Enum = Node<"Enum", {
	Values: { string },
} & Attributes, AttributesTokens>

export type TagEnum = Node<"TagEnum", {
	Tag: string,
	Values: { Struct },
} & Attributes, AttributesTokens>

export type Struct = Node<"Struct", {
	Values: { TypeNode },
} & Attributes, AttributesTokens>

export type Primitive = Node<"Primitive", {
	Class: string?,
	Primitive: Settings.Primitive,
} & Attributes, {
	Primitive: Token,
} & AttributesTokens>

export type Generic = Node<"Generic", {
	Generic: string,
} & Attributes, AttributesTokens>

--- `Names` is sparse and indexed alongside `Values`: an element may be named, as in
--- `(chefId: f64, dish: string)`, and one that is not has no entry. Naming is for the reader and for
--- the generated signature only -- a type pack is serialised positionally with no field tags, so it
--- never reaches the wire.
export type Tuple = Node<"Tuple", {
	Values: { TypeNode },
	Names: { [number]: string },
} & Attributes, AttributesTokens>

--- The listening API generated for an event. Named so `Parser.Event` can annotate its local without
--- restating the union (it used to reach for it through `index<index<Event, "Value">, "Call">`, which
--- this Luau version does not parse).
export type EventCall = "SingleSync" | "SingleAsync" | "ManySync" | "ManyAsync" | "Polling"

--- An event's `Stream` block, with its defaults filled in. `Value` is the type the game streams; the
--- event's `Data` is what goes on the wire, `(Value: Value?, ServerTime: u16)` -- nil once the stream
--- is cleared, and the server's clock in milliseconds modulo 65536. See Parser/Streams.luau.
export type StreamSettings = {
	Rate: number,
	Fast: number?,
	Keepalive: number,
	Epsilon: number,
	Value: TypeNode,
	--> `Per: Player`: the server holds a state for each player rather than one for all of them.
	PerPlayer: boolean,
}

--- An event's `Stamp`. `Window` is in seconds; `Value` is the Data the game declared, while the
--- event's `Data` is what goes on the wire, the same with a `SentAt: u16` appended -- the client's
--- estimate of the server's clock in milliseconds modulo 65536. See Parser/Stamps.luau.
export type StampSettings = {
	Window: number,
	Value: (TypeNode | Tuple)?,
}

export type Event = Node<
	"Event",
	{
		From: "Client" | "Server",
		--> OrderedUnreliable is Unreliable plus a sequence number: delivery is still not guaranteed,
		--> but a packet arriving after a newer one is discarded rather than applied out of order.
		Type: "Reliable" | "Unreliable" | "OrderedUnreliable",
		Call: EventCall,
		Data: (TypeNode | Tuple)?,
		--> Sustained events per second accepted from one player, and the bucket capacity that lets a
		--> burst through. Absent means unlimited -- see the generator's rate limiting.
		Rate: number?,
		Burst: number?,
		--> Set on a stream: the server sends the latest state on a schedule rather than on Fire.
		Stream: StreamSettings?,
		--> Set on a stamped event: the listener also receives when the client sent it.
		Stamp: StampSettings?,
		--> Set to "Low" on a server's unreliable event or stream that may be left out of a send to a
		--> player whose outbound budget is spent.
		Priority: ("Low" | "Normal")?,
	},
	{
		Identifier: Token,
	}
>

export type Function = Node<
	"Function",
	{
		--> Which side INVOKES. The other side listens, exactly as with an event's From -- except that a
		--> function's default is Client, since that was the only direction the language used to have.
		From: "Client" | "Server",
		Yield: "Future" | "Promise" | "Coroutine",
		Data: (TypeNode | Tuple)?,
		Return: (TypeNode | Tuple)?,
		Rate: number?,
		Burst: number?,
		--> Calls from one player the server runs at once; see Grammar.FUNCTION.
		Concurrency: number?,
	},
	{
		Identifier: Token,
	}
>

export type ScopeNode = Node<
	"Scope",
	{
		Scope: Scope,
		Values: { Declaration },
		--- Set when the scope came from an `import` rather than a `scope` block in this file. Its
		--- declarations carry spans into the IMPORTED source, so any diagnostic about them has to be
		--- raised by the parse of that file -- pointing at those offsets in this one underlines
		--- whatever text happens to sit there.
		Imported: boolean?,
	},
	{
		--- The path string of the `import` statement, for a diagnostic about everything the import
		--- brought in. Absent on a `scope` block, whose declarations are this file's own.
		Path: Token?,
	}
>

return {}
