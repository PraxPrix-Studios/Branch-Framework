--> Scenarios.blink's events as Warp events with schemas, each behind BlinkBlox's API -- `Fire`,
--> `FireAll`, `On` -- so Rivals.luau drives them as it does BlinkBlox; see benchmark/Rivals.luau. Warp
--> queues each player's events and flushes them a cycle at a time; a schema describes one value, so
--> the Instance and the number a Touch carries go as one struct, as they do for zap and ByteNet. The
--> server registers every schema as it loads, and a client's event is built on first use, once the
--> ids it asked the server for have arrived.
local Warp = require("../../../packages/warp")

local IsServer = game:GetService("RunService"):IsServer()
local Side = if IsServer then Warp.Server() else Warp.Client()
local Schema = Side.Schema

local function Unit()
	return Schema.struct({
		id = Schema.u16,
		x = Schema.f32,
		y = Schema.f32,
		z = Schema.f32,
		health = Schema.u8,
		moving = Schema.boolean,
		crouched = Schema.boolean,
	})
end

--> Each event's schema, and whether it is reliable.
local EVENTS: { [string]: { any } } = {
	Snapshot = { Unit(), true },
	Input = {
		Schema.struct({ move = Schema.u8, turn = Schema.i16, jump = Schema.boolean, sprint = Schema.boolean }),
		false,
	},
	Touch = { Schema.struct({ part = Schema.instance, force = Schema.u8 }), true },
	WorldState = { Schema.array(Unit()), false },
	SelfState = { Unit(), false },
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
		elseif Name == "Touch" then
			function Event.Fire(Part, Force)
				Side.Fire(Name, Reliable, { part = Part, force = Force })
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
