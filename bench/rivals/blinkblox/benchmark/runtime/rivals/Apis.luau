--!strict
--- What Rivals.luau asks of each tool in each scenario, and the scenarios themselves: the events
--- Scenarios.blink declares, fired and heard through each tool's own API.
local World = require("../World")

local Apis = {}

--> How many players a scenario with a crowd has.
Apis.CROWD = 50

type Unit = {
	id: number,
	x: number,
	y: number,
	z: number,
	health: number,
	moving: boolean,
	crouched: boolean,
}

local function MakeUnit(Id: number, Frame: number): Unit
	return {
		id = Id,
		x = Id * 3.5 + Frame * 0.25,
		y = 12.75,
		z = Id * -1.5 - Frame * 0.125,
		health = (Id * 7 + Frame) % 101,
		moving = (Id + Frame) % 2 == 0,
		crouched = (Id + Frame) % 3 == 0,
	}
end

local function MakeInput(Index: number, Frame: number)
	return { move = (Frame + Index) % 256, turn = Index * 100 - 400, jump = Index == 1, sprint = Frame % 2 == 0 }
end

--- What a scenario asks of a tool: one call each, with the tool's own modules. `Listen` binds the
--- receiving side's listener, which calls `Received` once per event.
export type Api = {
	Listen: (Server: any, Client: any, Received: () -> ()) -> (),
	Fire: (Server: any, Client: any, Universe: World.Universe, Frame: number) -> (),
}

export type Scenario = {
	Name: string,
	Players: number,
	Instances: boolean?,
	--> Which side sends, so the flush and the delivery go the right way.
	FromServer: boolean,
	Expected: number,
	Tools: { [string]: Api },
}

local BROADCASTS = 100
local INPUTS = 8
local TOUCHES = 100
local WORLD_UNITS = 16

local function Units(Frame: number): { Unit }
	local List = table.create(WORLD_UNITS)
	for Index = 1, WORLD_UNITS do
		List[Index] = MakeUnit(Index, Frame)
	end
	return List
end

--> BlinkBlox and upstream share an API, and the modes of QuickNet and Warp wrap theirs in it.
local function BlinkStyle(): { [string]: Api }
	return {
		Broadcast = {
			Listen = function(_Server, Client, Received)
				Client.Snapshot.On(Received)
			end,
			Fire = function(Server, _Client, _Universe, Frame)
				for Index = 1, BROADCASTS do
					Server.Snapshot.FireAll(MakeUnit(Index, Frame))
				end
			end,
		},
		UnreliableInput = {
			Listen = function(Server, _Client, Received)
				Server.Input.On(Received)
			end,
			Fire = function(_Server, Client, _Universe, Frame)
				for Index = 1, INPUTS do
					Client.Input.Fire(MakeInput(Index, Frame))
				end
			end,
		},
		Instances = {
			Listen = function(Server, _Client, Received)
				Server.Touch.On(Received)
			end,
			Fire = function(_Server, Client, Universe, Frame)
				local Parts = (Universe :: any).Parts
				for Index = 1, TOUCHES do
					Client.Touch.Fire(Parts[(Index + Frame) % #Parts + 1], Index)
				end
			end,
		},
		WorldState = {
			Listen = function(_Server, Client, Received)
				Client.WorldState.On(Received)
			end,
			Fire = function(Server, _Client, _Universe, Frame)
				Server.WorldState.FireAll(Units(Frame))
			end,
		},
		SelfState = {
			Listen = function(_Server, Client, Received)
				Client.SelfState.On(Received)
			end,
			Fire = function(Server, _Client, Universe, Frame)
				for Index, Player in Universe.Crowd do
					Server.SelfState.Fire(Player, MakeUnit(Index, Frame))
				end
			end,
		},
	}
end

local ZAP: { [string]: Api } = {
	Broadcast = {
		Listen = function(_Server, Client, Received)
			Client.Snapshot.SetCallback(Received)
		end,
		Fire = function(Server, _Client, _Universe, Frame)
			for Index = 1, BROADCASTS do
				Server.Snapshot.FireAll(MakeUnit(Index, Frame))
			end
		end,
	},
	UnreliableInput = {
		Listen = function(Server, _Client, Received)
			Server.Input.SetCallback(Received)
		end,
		Fire = function(_Server, Client, _Universe, Frame)
			for Index = 1, INPUTS do
				Client.Input.Fire(MakeInput(Index, Frame))
			end
		end,
	},
	Instances = {
		Listen = function(Server, _Client, Received)
			Server.Touch.SetCallback(Received)
		end,
		Fire = function(_Server, Client, Universe, Frame)
			local Parts = (Universe :: any).Parts
			for Index = 1, TOUCHES do
				Client.Touch.Fire({ part = Parts[(Index + Frame) % #Parts + 1], force = Index })
			end
		end,
	},
	WorldState = {
		Listen = function(_Server, Client, Received)
			Client.WorldState.SetCallback(Received)
		end,
		Fire = function(Server, _Client, _Universe, Frame)
			Server.WorldState.FireAll(Units(Frame))
		end,
	},
	SelfState = {
		Listen = function(_Server, Client, Received)
			Client.SelfState.SetCallback(Received)
		end,
		Fire = function(Server, _Client, Universe, Frame)
			for Index, Player in Universe.Crowd do
				Server.SelfState.Fire(Player, MakeUnit(Index, Frame))
			end
		end,
	},
}

local BYTENET: { [string]: Api } = {
	Broadcast = {
		Listen = function(_Server, Client, Received)
			Client.Snapshot.listen(Received)
		end,
		Fire = function(Server, _Client, _Universe, Frame)
			for Index = 1, BROADCASTS do
				Server.Snapshot.sendToAll(MakeUnit(Index, Frame))
			end
		end,
	},
	UnreliableInput = {
		Listen = function(Server, _Client, Received)
			Server.Input.listen(Received)
		end,
		Fire = function(_Server, Client, _Universe, Frame)
			for Index = 1, INPUTS do
				Client.Input.send(MakeInput(Index, Frame))
			end
		end,
	},
	Instances = {
		Listen = function(Server, _Client, Received)
			Server.Touch.listen(Received)
		end,
		Fire = function(_Server, Client, Universe, Frame)
			local Parts = (Universe :: any).Parts
			for Index = 1, TOUCHES do
				Client.Touch.send({ part = Parts[(Index + Frame) % #Parts + 1], force = Index })
			end
		end,
	},
	WorldState = {
		Listen = function(_Server, Client, Received)
			Client.WorldState.listen(Received)
		end,
		Fire = function(Server, _Client, _Universe, Frame)
			Server.WorldState.sendToAll(Units(Frame))
		end,
	},
	SelfState = {
		Listen = function(_Server, Client, Received)
			Client.SelfState.listen(Received)
		end,
		Fire = function(Server, _Client, Universe, Frame)
			for Index, Player in Universe.Crowd do
				Server.SelfState.sendTo(MakeUnit(Index, Frame), Player)
			end
		end,
	},
}

local PACKET: { [string]: Api } = {
	Broadcast = {
		Listen = function(_Server, Client, Received)
			Client.Snapshot.OnClientEvent:Connect(Received)
		end,
		Fire = function(Server, _Client, _Universe, Frame)
			for Index = 1, BROADCASTS do
				Server.Snapshot:Fire(MakeUnit(Index, Frame))
			end
		end,
	},
	Instances = {
		Listen = function(Server, _Client, Received)
			Server.Touch.OnServerEvent:Connect(Received)
		end,
		Fire = function(_Server, Client, Universe, Frame)
			local Parts = (Universe :: any).Parts
			for Index = 1, TOUCHES do
				Client.Touch:Fire(Parts[(Index + Frame) % #Parts + 1], Index)
			end
		end,
	},
}

Apis.APIS = {
	blink = BlinkStyle(),
	upstream = BlinkStyle(),
	zap = ZAP,
	bytenet = BYTENET,
	packet = PACKET,
	--> Their modes wrap each event in BlinkBlox's API.
	quicknet = BlinkStyle(),
	warp = BlinkStyle(),
	branch = BlinkStyle(),
}

Apis.SCENARIOS = {
	{ Name = "Broadcast", Players = Apis.CROWD, FromServer = true, Expected = BROADCASTS },
	{ Name = "UnreliableInput", Players = 1, FromServer = false, Expected = INPUTS },
	{ Name = "Instances", Players = 1, Instances = true, FromServer = false, Expected = TOUCHES },
	{ Name = "WorldState", Players = Apis.CROWD, FromServer = true, Expected = 1 },
	{ Name = "SelfState", Players = Apis.CROWD, FromServer = true, Expected = 1 },
}

return Apis
