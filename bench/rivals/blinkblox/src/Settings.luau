--!strict
--- The compiler's own range type. Deliberately NOT Roblox's `NumberRange` userdata: the CLI runs on
--- Lune where that global does not exist, and every range in the AST is a plain table.
export type NumberRange = { Min: number, Max: number }
local NumberRange = {
	new = function(Min: number, Max: number?): NumberRange
		return {
			Min = Min,
			Max = Max or Min,
		}
	end,
}

export type Case = "Camel" | "Snake" | "Pascal"
export type Cases = {
	Fire: string,
	FireAll: string,
	FireList: string,
	FireExcept: string,
	On: string,
	Invoke: string,
	Predict: string,
	StepReplication: string,
	SetRateLimitHandler: string,
	SetDecodeErrorHandler: string,
	SetPacketDropHandler: string,
	SetListenerErrorHandler: string,
	Remotes: string,
	Start: string,
	Connected: string,
	GetTrafficStats: string,
	ResetTrafficStats: string,
	Next: string,
	Iter: string,
	Read: string,
	Write: string,
	Set: string,
	Clear: string,
	Urgent: string,
	SetFast: string,
}

export type Primitive = {
	Bounds: NumberRange?,
	Integer: boolean?,
	Component: boolean,
	AllowsRange: boolean,
	AllowsOptional: boolean,
	AllowedComponents: number,

	--- Bytes this primitive occupies on the wire when its size is FIXED. Zero means the size is not
	--- a property of the primitive alone: `string` and `buffer` depend on their range, `vector` and
	--- `CFrame` on their component types, and `Instance`/`unknown` occupy no buffer bytes at all --
	--- they ride the remote's second argument. `src/Modules/Size.luau` handles those cases and reads
	--- this field for everything else.
	---
	--- It lives here rather than next to the prefabs that emit the writes because the Studio plugin
	--- cannot reach `src/Generator/Prefabs/` -- it never loads `Blocks` -- and the size analysis
	--- has to run in the editor for the oversize-unreliable diagnostic to appear there.
	Bytes: number,
}

local Indexes = {
	Pascal = 1,
	Camel = 2,
	Snake = 3,
}

local Cases: { [string]: { string } } = {
	On = { "On", "on", "on" },
	Invoke = { "Invoke", "invoke", "invoke" },
	Predict = { "Predict", "predict", "predict" },
	Fire = { "Fire", "fire", "fire" },
	FireAll = { "FireAll", "fireAll", "fire_all" },
	FireList = { "FireList", "fireList", "fire_list" },
	FireExcept = { "FireExcept", "fireExcept", "fire_except" },
	StepReplication = { "StepReplication", "stepReplication", "step_replication" },
	SetRateLimitHandler = { "SetRateLimitHandler", "setRateLimitHandler", "set_rate_limit_handler" },
	SetDecodeErrorHandler = { "SetDecodeErrorHandler", "setDecodeErrorHandler", "set_decode_error_handler" },
	SetPacketDropHandler = { "SetPacketDropHandler", "setPacketDropHandler", "set_packet_drop_handler" },
	SetListenerErrorHandler = {
		"SetListenerErrorHandler",
		"setListenerErrorHandler",
		"set_listener_error_handler",
	},
	Remotes = { "Remotes", "remotes", "remotes" },
	Start = { "Start", "start", "start" },
	Connected = { "Connected", "connected", "connected" },
	GetTrafficStats = { "GetTrafficStats", "getTrafficStats", "get_traffic_stats" },
	ResetTrafficStats = { "ResetTrafficStats", "resetTrafficStats", "reset_traffic_stats" },
	Next = { "Next", "next", "next" },
	Iter = { "Iter", "iter", "iter" },
	Read = { "Read", "read", "read" },
	Write = { "Write", "write", "write" },
	Set = { "Set", "set", "set" },
	Clear = { "Clear", "clear", "clear" },
	Urgent = { "Urgent", "urgent", "urgent" },
	SetFast = { "SetFast", "setFast", "set_fast" },
}

local Primitives: { [string]: Primitive } = {
	u8 = {
		Bounds = NumberRange.new(0, 255),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 1,
	},
	u16 = {
		Bounds = NumberRange.new(0, 65535),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	u24 = {
		Bounds = NumberRange.new(0, 16777215),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 3,
	},
	u32 = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	i8 = {
		Bounds = NumberRange.new(-128, 127),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 1,
	},
	i16 = {
		Bounds = NumberRange.new(-32768, 32767),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	i24 = {
		Bounds = NumberRange.new(-8388608, 8388607),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 3,
	},
	i32 = {
		Bounds = NumberRange.new(-2147483648, 2147483647),
		Integer = true,
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	f16 = {
		Bounds = NumberRange.new(-65504, 65504),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	--> Three bytes: a sign, six bits of exponent and seventeen of mantissa. The largest finite value is
	--> (2 - 2^-17) * 2^31, and anything that rounds past it is infinity, as in f16.
	f24 = {
		Bounds = NumberRange.new(-4294950912, 4294950912),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 3,
	},
	--> Floats are bounded by infinity, not by the range of exact integers: an open side of `f32(0..)`
	--> used to be filled with 2^24, which emitted a check refusing every value above it at runtime.
	f32 = {
		Bounds = NumberRange.new(-math.huge, math.huge),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 4,
	},
	f64 = {
		Bounds = NumberRange.new(-math.huge, math.huge),
		Component = true,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
	--> A rotation encoding, not a number: valid only as a CFrame component, where `CFrame<quat>`
	--> writes the rotation as a unit quaternion's three smallest components -- a u8 naming the one
	--> left out, then three i16. `src/Analysis.luau` refuses it anywhere else.
	quat = {
		Component = true,
		AllowsRange = false,
		AllowsOptional = false,
		AllowedComponents = 0,
		Bytes = 7,
	},
	boolean = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		--> Zero because a boolean is not measured in bytes at all: it takes one bit of the enclosing
		--> block's bitfield, and `src/Modules/Size.luau` counts it there.
		Bytes = 0,
	},
	string = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	vector = {
		--> A vector's range bounds its magnitude, which is never negative.
		Bounds = NumberRange.new(0, math.huge),
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 1,
		Bytes = 0,
	},
	buffer = {
		Bounds = NumberRange.new(0, 4294967295),
		Integer = true,
		Component = false,
		AllowsRange = true,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	Color3 = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 3,
	},
	CFrame = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 2,
		Bytes = 0,
	},
	Instance = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 0,
	},
	BrickColor = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 2,
	},
	unknown = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = false,
		AllowedComponents = 0,
		Bytes = 0,
	},
	DateTime = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
	DateTimeMillis = {
		Component = false,
		AllowsRange = false,
		AllowsOptional = true,
		AllowedComponents = 0,
		Bytes = 8,
	},
}

return {
	--> The parser builds its ranges through this too, so there is one constructor for the one type.
	NumberRange = NumberRange,

	Keywords = {
		map = true,
		set = true,
		type = true,
		enum = true,
		struct = true,

		event = true,
		["function"] = true,

		scope = true,
		option = true,

		export = true,
	},

	Primtives = Primitives,

	--> Exported so the parser can reject a bad `option Casing` against the same table this reads,
	--> rather than keeping a second list that drifts from it.
	Casings = Indexes,

	--> `option PackedBooleanReader`: see Generator/PackedBooleans.luau.
	PackedBooleanReaders = { Auto = true, Bits = true, Rows = true },

	GetCasing = function(Case: Case): Cases
		local Index = Indexes[Case]
		if not Index then
			--> Unreachable from a schema: Parser.Options rejects an unknown casing where the token
			--> still exists, so it can point at the word. This stays as a guard for a caller inside
			--> the compiler, which is why it is a plain error and not a diagnostic -- there is no
			--> source span to render by the time the generator asks.
			error(`Unknown casing "{Case}", expected one of "Pascal", "Camel" or "Snake"`)
		end

		local Casing: any = {}
		for Key, Options in Cases do
			Casing[Key] = Options[Index]
		end
		return Casing
	end,
}
