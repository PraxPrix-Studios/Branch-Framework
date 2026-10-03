--> Branch's workloads as QuickNet events, behind BlinkBlox's API (Fire / FireAll / On), as
--> runtime/rivals/modes/quicknet.luau wraps them. Its default rate limit is lifted, as its own
--> benchmark lifts it.
local QuickNet = require("../../../packages/quicknet")
local Data = QuickNet.Data

local IsServer = game:GetService("RunService"):IsServer()

local function Event(Name: string, Unreliable: boolean, ...: any)
	local Object = QuickNet:register(Name, ...):SetRateLimit(math.huge, 1)
	if Unreliable then
		Object = Object:Unreliable()
	end
	if IsServer then
		return {
			Fire = function(Player, ...)
				Object:FireClient(Player, ...)
			end,
			FireAll = function(...)
				Object:FireAllClients(...)
			end,
			On = function(Callback)
				Object.OnServerEvent:Connect(Callback)
			end,
		}
	end
	return {
		Fire = function(...)
			Object:FireServer(...)
		end,
		On = function(Callback)
			Object.OnClientEvent:Connect(Callback)
		end,
	}
end

--> A schema per event: QuickNet rewrites the tables it is given.
local function Entity()
	return {
		id = Data.NumberU8,
		x = Data.NumberU8,
		y = Data.NumberU8,
		z = Data.NumberU8,
		orientation = Data.NumberU8,
		animation = Data.NumberU8,
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

return {
	Booleans = Event("Booleans", false, { Data.Boolean }),
	Entities = Event("Entities", false, { Entity() }),
	Chat = Event("Chat", false, Data.String, Data.NumberU8),
	Cars = Event("Cars", false, {
		brand = Data.String,
		carName = Data.String,
		carId = Data.NumberU16,
		available = Data.Boolean,
		dealers = Data.NumberU8,
		price = Data.NumberF64,
	}),
	Moves = Event("Moves", false, Move()),
	MovesU = Event("MovesU", true, Move()),
}
