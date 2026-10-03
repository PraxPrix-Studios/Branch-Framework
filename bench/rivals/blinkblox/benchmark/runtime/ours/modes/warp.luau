--> Branch's workloads as Warp events with schemas, behind BlinkBlox's API (Fire / FireAll / On), as
--> runtime/rivals/modes/warp.luau wraps them. A Warp schema is one value, so Chat's two arguments
--> go as one struct. Warp's only vector type is f16 (6 bytes where the others send 12).
local Warp = require("../../../packages/warp")

local IsServer = game:GetService("RunService"):IsServer()
local Side = if IsServer then Warp.Server() else Warp.Client()
local Schema = Side.Schema

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

--> Each event's schema, and whether it is reliable.
local EVENTS: { [string]: { any } } = {
	Booleans = { Schema.array(Schema.boolean), true },
	Entities = { Entities(), true },
	Chat = { Schema.struct({ text = Schema.string, n = Schema.u8 }), true },
	Cars = {
		Schema.struct({
			brand = Schema.string,
			carName = Schema.string,
			carId = Schema.u16,
			available = Schema.boolean,
			dealers = Schema.u8,
			price = Schema.f64,
		}),
		true,
	},
	Moves = { Move(), true },
	MovesU = { Move(), false },
}

if IsServer then
	for Name, Event in EVENTS do
		Side.useSchema(Name, Event[1])
	end
end

return setmetatable({}, {
	__index = function(Self, Name: string)
		local Definition = EVENTS[Name]
		if not Definition then
			return nil
		end
		local Reliable = Definition[2]
		if not IsServer then
			Side.awaitReady()
			Side.useSchema(Name, Definition[1])
		end

		local Event = {
			On = function(Callback)
				Side.Connect(Name, Callback)
			end,
		}
		if IsServer then
			function Event.Fire(Player, Value)
				Side.Fire(Name, Reliable, Player, Value)
			end
			function Event.FireAll(Value)
				Side.Fires(Name, Reliable, Value)
			end
		elseif Name == "Chat" then
			function Event.Fire(Text, N)
				Side.Fire(Name, Reliable, { text = Text, n = N })
			end
		else
			function Event.Fire(Value)
				Side.Fire(Name, Reliable, Value)
			end
		end
		rawset(Self, Name, Event)
		return Event
	end,
})
