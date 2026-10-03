--!strict
--- Just enough of Roblox, on Lune, to load the other tools the Studio benchmark compares against:
--- zap's generated modules, ByteNet, Packet, QuickNet and Warp.
---
--- Environment.luau loads BlinkBlox's own modules, whose few needs are known. The other tools reach
--- for more: an instance tree they `require(script.Parent.X)` through, `Instance.new` for their
--- remotes, attributes, `HttpService`, `Enum`, and a `task` library they dispatch listeners through.
--- A `Universe` is what Roblox replicates -- the instance tree, the remotes, the one player -- and a
--- `World` is one side of it, server or client, with its own module cache, `_G`, `shared` and
--- RunService.
---
--- Modules keep the real global environment, as in Environment.luau: a chunk with a custom one is
--- never natively compiled. Roblox's globals arrive as upvalues of each module's code; see Source.luau.
---
--- `task` runs a spawned thread at once and queues a deferred one, and the benchmark drains that
--- queue inside the timed region it belongs to. Packet hands every listener to `task.defer`, so a
--- decode that did not drain it would be timed without calling anyone.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")

local Mocks = require("./Mocks")
local Source = require("./Source")
local Signal = Mocks.Signal

local World = {}

--> An instance: its properties and children behind a metatable, so `script.Signal` finds a child and
--> assigning `Parent` moves it.
local Methods = {}
local Hidden: { [any]: any } = setmetatable({}, { __mode = "k" }) :: any

local function Create(ClassName: string, Name: string?): any
	local State = {
		ClassName = ClassName,
		Properties = { Name = Name or ClassName, ClassName = ClassName } :: { [string]: any },
		Children = {} :: { any },
		Attributes = {} :: { [string]: any },
		AttributeChanged = Signal(),
		Changed = Signal(),
	}

	--> A userdata, as in Environment.Instance: a table would send every function that annotates a
	--> parameter `Player` or `Instance` back to the interpreter.
	local Object = newproxy(true)
	local Metatable = getmetatable(Object)
	for Key, Value in
		{
			__index = function(Self, Key)
				local Method = Methods[Key]
				if Method then
					return Method
				end
				if Key == "AttributeChanged" or Key == "Changed" then
					return State[Key]
				end
				local Value = State.Properties[Key]
				if Value ~= nil then
					return Value
				end
				for _, Child in State.Children do
					if Child.Name == Key then
						return Child
					end
				end
				return nil
			end,
			__newindex = function(Self, Key, Value)
				if Key == "Parent" then
					local Previous = State.Properties.Parent
					if Previous then
						local Siblings = Hidden[Previous].Children
						table.remove(Siblings, table.find(Siblings, Self))
					end
					if Value then
						table.insert(Hidden[Value].Children, Self)
					end
				end
				State.Properties[Key] = Value
				if Key == "Value" then
					State.Changed:Fire(Value)
				end
			end,
			__tostring = function()
				return State.Properties.Name
			end,
		} :: { [string]: any }
	do
		Metatable[Key] = Value
	end

	Hidden[Object] = State
	return Object
end

function Methods.IsA(Self, Queried: string): boolean
	return Hidden[Self].ClassName == Queried
end

function Methods.FindFirstChild(Self, Name: string)
	for _, Child in Hidden[Self].Children do
		if Child.Name == Name then
			return Child
		end
	end
	return nil
end

function Methods.WaitForChild(Self, Name: string)
	return assert(Methods.FindFirstChild(Self, Name), `{Self.Name} has no {Name}, and the benchmark cannot wait`)
end

function Methods.GetChildren(Self)
	return table.clone(Hidden[Self].Children)
end

function Methods.SetAttribute(Self, Name: string, Value: any)
	local State = Hidden[Self]
	State.Attributes[Name] = Value
	State.AttributeChanged:Fire(Name)
end

function Methods.GetAttribute(Self, Name: string)
	return Hidden[Self].Attributes[Name]
end

function Methods.Destroy(Self)
	Self.Parent = nil
end

function Methods.IsDescendantOf(_Self, _Ancestor)
	return true
end

export type Sent = { Buffer: buffer, Instances: { any }? }

export type Universe = {
	Native: boolean,
	Root: any,
	ReplicatedStorage: any,
	Players: any,
	Player: any,
	--> Every player on the server. The first is `Player`, the one whose client is loaded.
	Crowd: { any },
	--> Every packet a client fired since the benchmark last took them.
	Outbox: { Sent },
	--> Every packet the server sent the loaded client since the benchmark last took them.
	Inbox: { Sent },
	--> Remote calls made either way, and the bytes they delivered summed over every recipient.
	Calls: number,
	Bytes: number,
	--> Whether modules see `typeof` answer "Instance" for the mock instances. Off unless a scenario
	--> sends Instances: a replaced builtin is no longer a fastcall.
	Instances: boolean,
	--> What a module's path is as an instance, for `require(script.X)` and for `script` itself.
	Modules: { [string]: any },
	Deferred: { { any } },
}

local function Remote(Universe: Universe, ClassName: string)
	local Object = Create(ClassName)
	local State = Hidden[Object]
	State.Properties.OnServerEvent = Signal()
	State.Properties.OnClientEvent = Signal()
	--> A remote serialises its arguments when it is fired, and the tools reuse what they fired, so what
	--> is kept of a packet with Instances is a copy. Buffers are copied where the server sends: some
	--> tools rewrite one buffer for each player.
	local function Keep(Instances: { any }?): { any }?
		return if Instances and #Instances > 0 then table.clone(Instances) else Instances
	end

	--> Warp's client asks for the server's event ids with a call that carries nothing. The client's buffer is
	--> kept as it is, not copied as Roblox does: the harness decodes it in the same frame, before the tool
	--> flushes again, so a tool that reuses its buffer is still read right, and the flush it is timed on
	--> carries no copy that is the harness's rather than the tool's.
	State.Properties.FireServer = function(_self, Buffer: buffer?, Instances: { any }?)
		Universe.Calls += 1
		Universe.Bytes += if Buffer then buffer.len(Buffer) else 0
		table.insert(Universe.Outbox, { Buffer = Buffer, Instances = Keep(Instances), Remote = Object } :: any)
	end
	State.Properties.FireClient = function(_self, Player: any, Buffer: buffer, Instances: { any }?)
		Universe.Calls += 1
		Universe.Bytes += buffer.len(Buffer)
		if Player == Universe.Player then
			local Copy = buffer.create(buffer.len(Buffer))
			buffer.copy(Copy, 0, Buffer)
			table.insert(Universe.Inbox, { Buffer = Copy, Instances = Keep(Instances), Remote = Object } :: any)
		end
	end
	State.Properties.FireAllClients = function(_self, Buffer: buffer, Instances: { any }?)
		Universe.Calls += 1
		Universe.Bytes += buffer.len(Buffer) * #Universe.Crowd
		local Copy = buffer.create(buffer.len(Buffer))
		buffer.copy(Copy, 0, Buffer)
		table.insert(Universe.Inbox, { Buffer = Copy, Instances = Keep(Instances), Remote = Object } :: any)
	end
	return Object
end

--> Mirrors a directory as ModuleScripts and Folders: a directory with an `init.luau` is that module,
--> and the rest of its entries are its children, as Rojo builds it.
local function Mount(Universe: Universe, Path: string, Parent: any): any
	local Name = string.match(Path, "([^/]+)$") :: string
	local Object
	if fs.isDir(Path) then
		local Init = `{Path}/init.luau`
		Object = Create(if fs.isFile(Init) then "ModuleScript" else "Folder", Name)
		if fs.isFile(Init) then
			Universe.Modules[Init] = Object
		end
		for _, Entry in fs.readDir(Path) do
			local Child = `{Path}/{Entry}`
			if Entry ~= "init.luau" and (fs.isDir(Child) or string.sub(Entry, -5) == ".luau") then
				Mount(Universe, Child, Object)
			end
		end
	else
		Object = Create("ModuleScript", string.sub(Name, 1, -6))
		Universe.Modules[Path] = Object
	end
	Hidden[Object].Path = Path
	Object.Parent = Parent
	return Object
end

--- A fresh universe. `Mounts` are the directories required from, relative to the benchmark. `Count`
--- is how many players the server has, one unless given; `Instances` is Universe.Instances.
function World.Universe(Native: boolean, Mounts: { string }, Count: number?, Instances: boolean?): Universe
	local Root = Create("DataModel", "game")
	local ReplicatedStorage = Create("ReplicatedStorage")
	ReplicatedStorage.Parent = Root

	local Players = Create("Players")
	local Player = Create("Player", "Player")
	Hidden[Player].Properties.UserId = 1
	Player.Parent = Players
	Hidden[Players].Properties.PlayerAdded = Signal()
	Hidden[Players].Properties.PlayerRemoving = Signal()
	Hidden[Players].Properties.LocalPlayer = Player
	local Crowd = { Player }
	for Index = 2, Count or 1 do
		local Other = Create("Player", `Player{Index}`)
		Hidden[Other].Properties.UserId = Index
		Other.Parent = Players
		Crowd[Index] = Other
	end

	Hidden[Players].Properties.MaxPlayers = #Crowd
	Hidden[Players].Properties.GetPlayers = function()
		--> Roblox hands out a new table on every call, and the tools pay for it.
		return table.clone(Crowd)
	end

	local Universe: Universe = {
		Native = Native,
		Root = Root,
		ReplicatedStorage = ReplicatedStorage,
		Players = Players,
		Player = Player,
		Crowd = Crowd,
		Outbox = {},
		Inbox = {},
		Calls = 0,
		Bytes = 0,
		Instances = Instances == true,
		Modules = {},
		Deferred = {},
	}

	for _, Path in Mounts do
		Mount(Universe, Path, ReplicatedStorage)
	end

	return Universe
end

--- Runs every deferred thread, and whatever those defer in turn.
function World.Drain(Universe: Universe)
	Mocks.Drain(Universe.Deferred)
end

--- Delivers what the two sides sent each other while loading, both ways, until neither sends more,
--- then forgets it was sent: Warp's client learns its event ids from the server this way before it can
--- fire one. Call it once both sides are loaded, before anything is timed.
function World.Settle(Universe: Universe)
	World.Drain(Universe)
	for _ = 1, 8 do
		if #Universe.Outbox == 0 and #Universe.Inbox == 0 then
			break
		end
		local Outbox, Inbox = table.clone(Universe.Outbox), table.clone(Universe.Inbox)
		table.clear(Universe.Outbox)
		table.clear(Universe.Inbox)
		for _, Packet in Outbox do
			(Packet :: any).Remote.OnServerEvent:Fire(Universe.Player, Packet.Buffer, Packet.Instances)
		end
		for _, Packet in Inbox do
			(Packet :: any).Remote.OnClientEvent:Fire(Packet.Buffer, Packet.Instances)
		end
		World.Drain(Universe)
	end
	assert(#Universe.Outbox == 0 and #Universe.Inbox == 0, "The two sides never stopped talking while loading")
	Universe.Calls = 0
	Universe.Bytes = 0
end

--> What `typeof` says with Universe.Instances on: a mock instance is an "Instance".
local function MockTypeof(Value: any): string
	if Hidden[Value] then
		return "Instance"
	end
	return typeof(Value)
end

--- A part the scenarios send, for a universe with Instances on.
function World.Part(Name: string): any
	return Create("Part", Name)
end

export type World = {
	Require: (Path: string) -> any,
	Heartbeat: any,
}

--- One side of `Universe`. Its modules see `RunService:IsServer()` as `IsServer`.
function World.new(Universe: Universe, IsServer: boolean): World
	local Heartbeat = Signal()
	local RunService = {
		Heartbeat = Heartbeat,
		PostSimulation = Heartbeat,
		PreSimulation = Signal(),
		Stepped = Signal(),
		RenderStepped = Signal(),
		IsServer = function()
			return IsServer
		end,
		IsClient = function()
			return not IsServer
		end,
		IsRunning = function()
			return true
		end,
		IsStudio = function()
			return false
		end,
		--> True only in Studio's Run mode, which a live server is not: Warp takes the client's path when
		--> it says true.
		IsRunMode = function()
			return false
		end,
	}

	local Services = {
		RunService = RunService,
		ReplicatedStorage = Universe.ReplicatedStorage,
		Players = Universe.Players,
		Workspace = {
			GetServerTimeNow = function(_self)
				return os.clock()
			end,
		},
		HttpService = {
			JSONEncode = function(_self, Value: any)
				return serde.encode("json", Value)
			end,
			JSONDecode = function(_self, Value: string)
				return serde.decode("json", Value)
			end,
		},
	}

	local function GetService(_self, Name: string)
		return assert(Services[Name], `No mock for the {Name} service`)
	end
	--> Warp reaches a service as `game.RunService`, which Roblox resolves to the service by name.
	local Game = setmetatable({ GetService = GetService }, {
		__index = function(Self, Name: string)
			return GetService(Self, Name)
		end,
	})

	local Instance = {
		new = function(ClassName: string, Parent: any?)
			local Object = if ClassName == "RemoteEvent" or ClassName == "UnreliableRemoteEvent"
				then Remote(Universe, ClassName)
				else Create(ClassName)
			if Parent then
				Object.Parent = Parent
			end
			return Object
		end,
	}

	--> `_G` and `shared` are each side's own, as each Roblox peer runs its own VM.
	local Globals, Shared = {}, {}
	local Cache: { [string]: any } = {}
	local Loading: { [string]: boolean } = {}
	local Task = Mocks.Task(Universe.Deferred)
	local Enum = Mocks.Enum()
	local Warn = function() end

	local Require: (Target: any, From: string?) -> any
	local function Load(Path: string): any
		if Cache[Path] ~= nil then
			return Cache[Path]
		end
		assert(not Loading[Path], `{Path} requires itself`)
		Loading[Path] = true

		local Text, Declared = Source.Prepare(
			fs.readFile(Path),
			Universe.Native,
			if Universe.Instances then Source.GLOBALS_TYPEOF else Source.GLOBALS
		)
		local Bytecode = luau.compile(Text, {
			optimizationLevel = 2,
			debugLevel = 1,
		})
		local Chunk = luau.load(Bytecode, {
			debugName = Path,
			codegenEnabled = Universe.Native and Declared,
		})

		local Script = Universe.Modules[Path] or Create("ModuleScript", Path)
		local function LocalRequire(Target: any)
			return Require(Target, Path)
		end

		local Result = Chunk({
			game = Game,
			script = Script,
			require = LocalRequire,
			task = Task,
			warn = Warn,
			--> Nowhere, as `warn` does: ByteNet's release prints its whole instance list on every Instance it
			--> writes, and a terminal is far slower to print to than Roblox's output.
			print = Warn,
			_G = Globals,
			shared = Shared,
			Instance = Instance,
			CFrame = Mocks.CFrame,
			Vector3 = (Universe :: any).Vector3 or Mocks.Vector3,
			Vector2 = Mocks.Vector2,
			Color3 = Mocks.Color3,
			Enum = Enum,
			workspace = Universe.Root,
			typeof = MockTypeof,
		})
		Cache[Path] = Result
		Loading[Path] = nil
		return Result
	end

	function Require(Target: any, From: string?): any
		if type(Target) ~= "string" then
			local Path = Hidden[Target] and Hidden[Target].Path
			if Path and fs.isDir(Path) then
				Path = `{Path}/init.luau`
			end
			return Load((assert(Path, `Cannot require {Target}`)))
		end

		--> As Luau resolves a string: `@self` is an `init.luau`'s own folder, and `./` in one is the folder
		--> that holds it, whose siblings a module's `./` names anywhere else.
		local Folder = if From then string.match(From, "^(.*)/[^/]*$") or "." else "."
		local Base = Folder
		if string.sub(Target, 1, 6) == "@self/" then
			Target = string.sub(Target, 7)
		elseif From and string.match(From, "/init%.luau$") then
			Base = `{Folder}/..`
		end
		local Path = Source.Normalise(`{Base}/{Target}`)
		if string.sub(Path, -5) == ".luau" and fs.isFile(Path) then
			return Load(Path)
		elseif fs.isFile(`{Path}.luau`) then
			return Load(`{Path}.luau`)
		end
		return Load(`{Path}/init.luau`)
	end

	return {
		Require = function(Path: string)
			return Require(Source.Normalise(Path))
		end,
		Heartbeat = Heartbeat,
	}
end

return World
