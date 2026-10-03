--!strict
--- Loads a generated server and client into Lune as fast as Roblox would run them.
---
--- The test suite's loader (test/Modules.luau) hands each module a custom environment, and Lune
--- documents what that costs: a chunk with a custom environment is deoptimised and never natively
--- compiled. Its builtins stop being fastcalls, so `buffer.writeu8` becomes a global lookup and a
--- call -- a benchmark of that measures the loader, not the module. Here the module keeps the real
--- global environment, and the few globals Roblox would provide arrive as locals prepended to its
--- source instead.
---
--- The mocks are as thin as the generated code allows. The test suite's run Heartbeat on a timer and
--- deliver packets through `task.spawn`; these call straight through, so nothing but the module's
--- own work lands inside a timed region.
local luau = require("@lune/luau")
local task = require("@lune/task")

local Environment = {}

export type Remote = {
	--> The last packet the client fired, and its instances.
	Sent: buffer?,
	SentInstances: { any }?,
	--> The server's handler, called directly to feed it a packet.
	ServerHandler: ((Player: any, Buffer: buffer, Instances: { any }) -> ())?,
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

local function CreateRemote(ClassName: string): any
	local Attributes: { [string]: any } = {}
	local Remote
	Remote = {
		Sent = nil,
		SentInstances = nil,
		ServerHandler = nil,
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
			Remote.Sent = Buffer
			Remote.SentInstances = Instances
		end,
		FireClient = function() end,
		FireAllClients = function() end,
		OnServerEvent = {
			Connect = function(_self, Callback)
				Remote.ServerHandler = Callback
				return {
					Disconnect = function() end,
				}
			end,
		},
		OnClientEvent = Signal(),
	}
	return Remote
end

local Players = {
	Name = "Players",
	MaxPlayers = 1,
	PlayerRemoving = Signal(),
	PlayerAdded = Signal(),
}

--- A userdata standing for a Roblox Instance, reading and writing `Fields`.
---
--- Not a table: a parameter the modules annotate `Player` or `Instance` is native code's promise that
--- a userdata arrives, and a table there sends the whole function back to the interpreter on every
--- call. In a game these are userdata, so a table would time the bench's mock rather than the module.
function Environment.Instance(Fields: { [string]: any }): any
	local Object = newproxy(true)
	local Metatable = getmetatable(Object)
	Metatable.__index = Fields
	Metatable.__newindex = Fields
	Metatable.__tostring = function()
		return tostring(Fields.Name)
	end
	return Object
end

--> One player, whose `Parent` never changes: the server asks for it on every event it decodes.
local Player = Environment.Instance({
	Name = "Player",
	Parent = Players,
	IsDescendantOf = function(_self, _Ancestor)
		return true
	end,
})

function Players.GetPlayers(_self)
	return { Player }
end

local function Game(IsServer: boolean, Remotes: { [string]: any })
	local ReplicatedStorage = {
		FindFirstChild = function(_self, Name: string)
			return Remotes[Name]
		end,
	}
	ReplicatedStorage.WaitForChild = ReplicatedStorage.FindFirstChild

	local Services = {
		Players = Players,
		ReplicatedStorage = ReplicatedStorage,
		RunService = {
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
		},
	}

	return {
		GetService = function(_self, Service: string)
			return assert(Services[Service], `No mock for service {Service}`)
		end,
	}
end

--> The globals Roblox provides and Lune does not, as locals ahead of the module's own code. They go
--> after the directives: `--!native` and `--!optimize` count only above the first line of code.
local PRELUDE = "local game, task, warn, _G, Instance = ...\n"

local function Prepare(Source: string, Native: boolean, Prelude: string?): string
	local Lines = string.split(Source, "\n")
	local Index = 1
	while Lines[Index] and string.sub(Lines[Index], 1, 2) == "--" do
		if not Native and Lines[Index] == "--!native" then
			table.remove(Lines, Index)
			continue
		end
		Index += 1
	end

	table.insert(Lines, Index, Prelude or PRELUDE)
	return table.concat(Lines, "\n")
end

--- `Source` compiled as Roblox would run it, and called with the globals the prelude names.
function Environment.Chunk(Name: string, Source: string, Native: boolean, Prelude: string?): (...any) -> any
	local Bytecode = luau.compile(Prepare(Source, Native, Prelude), {
		optimizationLevel = 2,
		debugLevel = 1,
	})

	return luau.load(Bytecode, {
		debugName = Name,
		codegenEnabled = Native,
	})
end

local function Load(Name: string, Source: string, Native: boolean, IsServer: boolean, Remotes: { [string]: any })
	local Chunk = Environment.Chunk(Name, Source, Native)
	local Instance = {
		new = function(ClassName: string)
			error(`The benchmark provides no {ClassName}`)
		end,
	}

	return Chunk(Game(IsServer, Remotes), task, function() end, {}, Instance)
end

export type Pair = {
	Server: any,
	Client: any,
	Reliable: any,
	Player: any,
}

--- Loads `ServerSource` and `ClientSource`, which must have been generated with ManualReplication
--- on, so that the benchmark decides when the client flushes.
function Environment.Load(ServerSource: string, ClientSource: string, Native: boolean): Pair
	local Reliable = CreateRemote("RemoteEvent")
	local Remotes = {
		BLINK_RELIABLE_REMOTE = Reliable,
		BLINK_UNRELIABLE_REMOTE = CreateRemote("UnreliableRemoteEvent"),
	}

	local Server = Load("Server", ServerSource, Native, true, Remotes)
	local Client = Load("Client", ClientSource, Native, false, Remotes)

	return {
		Server = Server,
		Client = Client,
		Reliable = Reliable,
		Player = Player,
	}
end

return Environment
