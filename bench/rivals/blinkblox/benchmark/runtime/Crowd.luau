--!strict
--- A server and one client loaded as Environment.luau loads them, with a crowd of players on the
--- server and remotes that count what they carry.
---
--- Environment.luau has one player and remotes that keep only the last packet, which is all a client
--- firing at the server needs. Sending the other way needs more: a server fires at every player, so
--- each remote counts its calls and the bytes all players were sent, and keeps what one of them, the
--- observed player, received, for the one client module to decode. Roblox serialises a packet when it
--- is fired, and the modules reuse what they fired -- a stream rewrites its sequence in the same
--- buffer for each player, a flush clears its Instances -- so what a remote keeps is a copy.
local task = require("@lune/task")

local Environment = require("./Environment")

local Crowd = {}

export type Packet = { Buffer: buffer, Instances: { any } }

export type Remote = {
	--> Remote calls made and bytes delivered, summed over every player, since the last Reset.
	Calls: number,
	Bytes: number,
	--> What the client fired, in order.
	Outbox: { Packet },
	--> What the observed player received, in order.
	Inbox: { Packet },
	ServerHandler: ((Player: any, Buffer: buffer, Instances: { any }) -> ())?,
	ClientHandler: ((Buffer: buffer, Instances: { any }) -> ())?,
}

export type Pair = {
	Server: any,
	Client: any,
	Players: { any },
	Observed: any,
	Reliable: Remote,
	Unreliable: Remote,
	Reset: () -> (),
}

local function Signal()
	return {
		Connect = function(_self, _Callback)
			return {
				Disconnect = function() end,
			}
		end,
	}
end

local function Copy(Buffer: buffer): buffer
	local Copied = buffer.create(buffer.len(Buffer))
	buffer.copy(Copied, 0, Buffer)
	return Copied
end

local function CreateRemote(ClassName: string, Crowd: { any }, Observed: any): any
	local Attributes: { [string]: any } = {}
	local Remote
	Remote = {
		Calls = 0,
		Bytes = 0,
		Outbox = {},
		Inbox = {},
		ServerHandler = nil,
		ClientHandler = nil,
		SetAttribute = function(_self, Name: string, Value: any)
			Attributes[Name] = Value
		end,
		GetAttribute = function(_self, Name: string): any
			return Attributes[Name]
		end,
		IsA = function(_self, Queried: string): boolean
			return Queried == ClassName
		end,
		FireServer = function(_self, Buffer: buffer, Instances: { any })
			Remote.Calls += 1
			Remote.Bytes += buffer.len(Buffer)
			table.insert(Remote.Outbox, { Buffer = Buffer, Instances = table.clone(Instances) })
		end,
		FireClient = function(_self, Player: any, Buffer: buffer, Instances: { any })
			Remote.Calls += 1
			Remote.Bytes += buffer.len(Buffer)
			if Player == Observed then
				table.insert(Remote.Inbox, { Buffer = Copy(Buffer), Instances = table.clone(Instances) })
			end
		end,
		FireAllClients = function(_self, Buffer: buffer, Instances: { any })
			Remote.Calls += 1
			Remote.Bytes += buffer.len(Buffer) * #Crowd
			table.insert(Remote.Inbox, { Buffer = Copy(Buffer), Instances = table.clone(Instances) })
		end,
		OnServerEvent = {
			Connect = function(_self, Callback)
				Remote.ServerHandler = Callback
				return {
					Disconnect = function() end,
				}
			end,
		},
		OnClientEvent = {
			Connect = function(_self, Callback)
				Remote.ClientHandler = Callback
				return {
					Disconnect = function() end,
				}
			end,
		},
	}
	return Remote
end

local function Game(IsServer: boolean, Services: { [string]: any })
	local Own = table.clone(Services)
	Own.RunService = {
		Heartbeat = Signal(),
		IsServer = function()
			return IsServer
		end,
		IsClient = function()
			return not IsServer
		end,
		IsRunning = function()
			return true
		end,
	}

	return {
		GetService = function(_self, Service: string)
			return assert(Own[Service], `No mock for service {Service}`)
		end,
	}
end

--> An Instance, for the one scenario that sends them. Lune has none, so `typeof` is replaced in the
--> modules that scenario loads, and only there: a replaced builtin is no longer a fastcall, and every
--> other scenario would pay for it.
local Parts: { [any]: true } = setmetatable({}, { __mode = "k" }) :: any

local function MockTypeof(Value: any): string
	if Parts[Value] then
		return "Instance"
	end
	return typeof(Value)
end

function Crowd.Part(Name: string): any
	local Part = Environment.Instance({
		Name = Name,
		ClassName = "Part",
		IsA = function(_self, Class: string)
			return Class == "Part" or Class == "BasePart" or Class == "Instance"
		end,
	})
	Parts[Part] = true
	return Part
end

local PRELUDE = "local game, task, warn, _G, Instance = ...\n"
local PRELUDE_TYPEOF = "local game, task, warn, _G, Instance, typeof = ...\n"

--- A server with `Count` players and one client, the first player's. `Instances` replaces `typeof`
--- so that the mock Instances pass the modules' checks.
function Crowd.Load(
	ServerSource: string,
	ClientSource: string,
	Native: boolean,
	Count: number,
	Instances: boolean
): Pair
	local PlayersService = {
		Name = "Players",
		MaxPlayers = Count,
		PlayerRemoving = Signal(),
		PlayerAdded = Signal(),
	}

	local List: { any } = {}
	for Index = 1, Count do
		List[Index] = Environment.Instance({
			Name = `Player{Index}`,
			UserId = Index,
			Parent = PlayersService,
			IsDescendantOf = function(_self, _Ancestor)
				return true
			end,
		})
	end

	function PlayersService.GetPlayers(_self)
		--> Roblox hands out a new table on every call, and the modules pay for it.
		return table.clone(List)
	end

	local Observed = List[1]
	local Reliable = CreateRemote("RemoteEvent", List, Observed)
	local Unreliable = CreateRemote("UnreliableRemoteEvent", List, Observed)
	local Remotes = {
		BLINK_RELIABLE_REMOTE = Reliable,
		BLINK_UNRELIABLE_REMOTE = Unreliable,
	}

	local ReplicatedStorage = {
		FindFirstChild = function(_self, Name: string)
			return Remotes[Name]
		end,
	}
	ReplicatedStorage.WaitForChild = ReplicatedStorage.FindFirstChild

	local Services = {
		Players = PlayersService,
		ReplicatedStorage = ReplicatedStorage,
		Workspace = {
			GetServerTimeNow = function(_self)
				return os.clock()
			end,
		},
	}

	local Instance = {
		new = function(ClassName: string)
			error(`The benchmark provides no {ClassName}`)
		end,
	}

	local Prelude = if Instances then PRELUDE_TYPEOF else PRELUDE
	local function Load(Name: string, Source: string, IsServer: boolean)
		local Chunk = Environment.Chunk(Name, Source, Native, Prelude)
		return Chunk(Game(IsServer, Services), task, function() end, {}, Instance, MockTypeof)
	end

	local Server = Load("Server", ServerSource, true)
	local Client = Load("Client", ClientSource, false)

	return {
		Server = Server,
		Client = Client,
		Players = List,
		Observed = Observed,
		Reliable = Reliable,
		Unreliable = Unreliable,
		Reset = function()
			for _, Remote in { Reliable, Unreliable } do
				Remote.Calls = 0
				Remote.Bytes = 0
				table.clear(Remote.Outbox)
				table.clear(Remote.Inbox)
			end
		end,
	}
end

return Crowd
