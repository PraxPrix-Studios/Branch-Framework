--> Definition.blink's benches as QuickNet events, each behind `Fire` and `On` as BlinkBlox's are.
--> QuickNet lets a player send an event 60 times a second by default, and the bench sends it 60,000
--> times; its own benchmark raises the limit on each event the same way.
local QuickNet = require("../../../packages/quicknet")
local Data = QuickNet.Data

local function Event(Name: string, Schema: any)
	local Object = QuickNet:register(Name, Schema):SetRateLimit(math.huge, 1)
	return {
		Fire = function(Value)
			Object:FireServer(Value)
		end,
		On = function(Callback)
			Object.OnServerEvent:Connect(Callback)
		end,
	}
end

--> Server to client (the down benches): Fire to one player, FireAll, On on the client.
local function Down(Name: string, Unreliable: boolean, Schema: any)
	local Object = QuickNet:register(Name, Schema):SetRateLimit(math.huge, 1)
	if Unreliable then
		Object = Object:Unreliable()
	end
	return {
		Fire = function(Player, Value)
			Object:FireClient(Player, Value)
		end,
		FireAll = function(Value)
			Object:FireAllClients(Value)
		end,
		On = function(Callback)
			Object.OnClientEvent:Connect(Callback)
		end,
	}
end

local function Move()
	return {
		pos = Data.Vector3F32,
		vel = Data.Vector3F32,
		yaw = Data.NumberF32,
		grounded = Data.Boolean,
		crouch = Data.Boolean,
		sprint = Data.Boolean,
		anim = Data.NumberU8,
	}
end

--> A schema per event: QuickNet rewrites the tables it is given.
local function Booleans()
	return { Data.Boolean }
end

local function Entities()
	return {
		{
			id = Data.NumberU8,
			x = Data.NumberU8,
			y = Data.NumberU8,
			z = Data.NumberU8,
			orientation = Data.NumberU8,
			animation = Data.NumberU8,
		},
	}
end

return {
	Booleans = Event("Booleans", Booleans()),
	Entities = Event("Entities", Entities()),
	BooleansRandom = Event("BooleansRandom", Booleans()),
	EntitiesRandom = Event("EntitiesRandom", Entities()),
	Moves = Down("Moves", false, Move()),
	MovesU = Down("MovesU", true, Move()),
	Cars = Event("Cars", {
		brand = Data.String,
		carName = Data.String,
		carId = Data.NumberU16,
		available = Data.Boolean,
		dealers = Data.NumberU8,
		price = Data.NumberF64,
	}),
}
