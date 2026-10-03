--> Definition.blink's benches as Warp events with schemas, each behind `Fire` and `On` as BlinkBlox's
--> are. Warp names an event by string on every call, and its client learns the ids from the server:
--> the server registers every schema as it loads, and a client's event is built on first use, once
--> the ids have arrived.
local Warp = require("../../../packages/warp")

local IsServer = game:GetService("RunService"):IsServer()
local Side = if IsServer then Warp.Server() else Warp.Client()
local Schema = Side.Schema
--> The client waits for the server's ids here, where a require may yield, rather than inside the
--> first event lookup (a metamethod, which cannot yield in Roblox).
if not IsServer and game:GetService("RunService"):IsStudio() then -- (the Lune world settles ids after loading)
	Side.awaitReady()
end

local function Entities()
	return Schema.array(Schema.struct({
		id = Schema.u8,
		x = Schema.u8,
		y = Schema.u8,
		z = Schema.u8,
		orientation = Schema.u8,
		animation = Schema.u8,
	}))
end

local SCHEMAS = {
	Booleans = Schema.array(Schema.boolean),
	Entities = Entities(),
	BooleansRandom = Schema.array(Schema.boolean),
	EntitiesRandom = Entities(),
	Cars = Schema.struct({
		brand = Schema.string,
		carName = Schema.string,
		carId = Schema.u16,
		available = Schema.boolean,
		dealers = Schema.u8,
		price = Schema.f64,
	}),
}

--> Server to client (the down benches), with whether each is reliable.
local function Move()
	return Schema.struct({
		pos = Schema.vector3,
		vel = Schema.vector3,
		yaw = Schema.f32,
		grounded = Schema.boolean,
		crouch = Schema.boolean,
		sprint = Schema.boolean,
		anim = Schema.u8,
	})
end
local DOWN = { Moves = { Move(), true }, MovesU = { Move(), false } }

if IsServer then
	for Name, Definition in SCHEMAS do
		Side.useSchema(Name, Definition)
	end
	for Name, Definition in DOWN do
		Side.useSchema(Name, Definition[1])
	end
end

return setmetatable({}, {
	__index = function(Self, Name: string)
		local Down = DOWN[Name]
		if Down then
			if not IsServer then
				Side.awaitReady()
				Side.useSchema(Name, Down[1])
			end
			local Event = {
				Fire = function(Player, Value)
					Side.Fire(Name, Down[2], Player, Value)
				end,
				FireAll = function(Value)
					Side.Fires(Name, Down[2], Value)
				end,
				On = function(Callback)
					Side.Connect(Name, Callback)
				end,
			}
			rawset(Self, Name, Event)
			return Event
		end
		local Definition = SCHEMAS[Name]
		if not Definition then
			return nil
		end
		if not IsServer then
			Side.awaitReady()
			Side.useSchema(Name, Definition)
		end

		local Event = {
			Fire = function(Value)
				Side.Fire(Name, true, Value)
			end,
			On = function(Callback)
				Side.Connect(Name, Callback)
			end,
		}
		rawset(Self, Name, Event)
		return Event
	end,
})
