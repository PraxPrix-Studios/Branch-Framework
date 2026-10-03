--> Scenarios.blink's events as QuickNet events, each behind BlinkBlox's API -- `Fire`, `FireAll`, `On`
--> -- so Rivals.luau drives them as it does BlinkBlox; see benchmark/Rivals.luau. QuickNet batches
--> each player's events a frame, one remote call per channel, and serialises a send to many players
--> once. Its default rate limit, 60 an event a second, is lifted as its own benchmark lifts it.
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
local function Unit()
	return {
		id = Data.NumberU16,
		x = Data.NumberF32,
		y = Data.NumberF32,
		z = Data.NumberF32,
		health = Data.NumberU8,
		moving = Data.Boolean,
		crouched = Data.Boolean,
	}
end

return {
	Snapshot = Event("Snapshot", false, Unit()),
	Input = Event(
		"Input",
		true,
		{ move = Data.NumberU8, turn = Data.NumberI16, jump = Data.Boolean, sprint = Data.Boolean }
	),
	Touch = Event("Touch", false, Data.Instance, Data.NumberU8),
	WorldState = Event("WorldState", true, { Unit() }),
	SelfState = Event("SelfState", true, Unit()),
}
