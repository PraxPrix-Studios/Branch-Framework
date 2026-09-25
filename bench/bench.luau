--!strict
-- Branch Network vs Blink vs NetRay: same schemas, same data, same mocked wire.
--   lune run tests/bench/bench.luau
-- Encode = Fire calls + the frame flush; Decode = receiving the packets and
-- dispatching to a no-op listener; Bytes = buffer payload per frame.
-- Generated inputs: tests/bench/generated/Blink*.luau (Blink CLI), tests/bench/generated/netray*/ (NetRay CLI).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local NetCompile = require("../lib/NetCompile")

local Vector3 = roblox.Vector3

local process = require("@lune/process")
local ONLY = process.args[1] -- optional: run workloads whose name contains this
local FRAMES = tonumber(process.args[2]) or 300
local WARMUP = 30
local REPEATS = 5

local function Signal()
	local signal = { handlers = {} :: { any } }
	function signal:Connect(fn)
		table.insert(self.handlers, fn)
		return { Disconnect = function() end }
	end
	function signal:Fire(...)
		for _, handler in self.handlers do
			handler(...)
		end
	end
	return signal
end

local function makeWorld(kind: string, sources: { server: string, client: string, types: string? }, clientCount: number, instancePlayers: boolean?): any
	local world: any = { clients = {}, players = {}, clientOf = {}, toServer = {}, toClient = {}, bytesUp = 0, bytesDown = 0, packetsUp = 0, packetsDown = 0, callsUp = 0, callsDown = 0 }

	local Players: any = { PlayerAdded = Signal(), PlayerRemoving = Signal(), list = {} }
	function Players:GetPlayers()
		return table.clone(self.list)
	end

	local function runService(isServer: boolean)
		local rs = { Heartbeat = Signal() }
		function rs:IsServer() return isServer end
		function rs:IsClient() return not isServer end
		function rs:IsRunning() return true end
		function rs:IsStudio() return false end
		return rs
	end

	local TYPES = {}

	local function env(remotes: any, rs: any)
		local lookup = {
			Reliable = remotes.Reliable,
			Unreliable = remotes.Unreliable,
			BLINK_RELIABLE_REMOTE = remotes.Reliable,
			BLINK_UNRELIABLE_REMOTE = remotes.Unreliable,
			NetRay_RELIABLE = remotes.Reliable,
			NetRay_UNRELIABLE = remotes.Unreliable,
			NetRay_FUNCTION = remotes.Function,
		}
		local container = {
			Types = TYPES,
			FindFirstChild = function(_, name) return lookup[name] end,
			WaitForChild = function(_, name) return lookup[name] end,
		}
		local typesModule = nil
		return {
			game = {
				GetService = function(_, name)
					if name == "Players" then return Players
					elseif name == "RunService" then return rs
					elseif name == "ReplicatedStorage" then return container end
					error(name)
				end,
			},
			script = { Parent = container },
			require = function(target)
				if target == TYPES then
					if not typesModule then
						typesModule = luau.load(sources.types :: string, { debugName = kind .. "Types" })()
					end
					return typesModule
				end
				error("unexpected require")
			end,
			_G = {},
			task = task,
			Vector3 = roblox.Vector3,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
			typeof = typeof,
			warn = function() end,
			print = print,
		}
	end

	local serverRemotes: any = {}
	for _, name in { "Reliable", "Unreliable" } do
		local remote = { OnServerEvent = Signal(), ClassName = if name == "Reliable" then "RemoteEvent" else "UnreliableRemoteEvent" }
		local function deliver(player, ...)
			local b = ...
			world.bytesDown += buffer.len(b)
			world.packetsDown += 1
			table.insert(world.toClient, { world.clientOf[player], name, table.pack(...) })
		end
		function remote:FireClient(player, ...)
			world.callsDown += 1
			deliver(player, ...)
		end
		function remote:FireAllClients(...)
			world.callsDown += 1 -- one engine call, serialised once
			for _, player in Players.list do
				deliver(player, ...)
			end
		end
		serverRemotes[name] = remote
	end
	serverRemotes.Function = { ClassName = "RemoteFunction" }
	world.serverRun = runService(true)
	local serverChunk = luau.load(sources.server, { debugName = kind .. "Server", environment = env(serverRemotes, world.serverRun) })

	for index = 1, clientCount do
		local client: any = {}
		local player: any
		if instancePlayers then
			player = roblox.Instance.new("Player") -- NetRay checks typeof(player) == "Instance"
			player.Name = "P" .. index
		else
			player = { Name = "P" .. index, Parent = Players, UserId = index }
		end
		world.clientOf[player] = client
		client.player = player
		local remotes: any = {}
		for _, name in { "Reliable", "Unreliable" } do
			local remote = { OnClientEvent = Signal(), ClassName = if name == "Reliable" then "RemoteEvent" else "UnreliableRemoteEvent" }
			function remote:FireServer(...)
				local b = ...
				world.callsUp += 1
				world.bytesUp += buffer.len(b)
				world.packetsUp += 1
				table.insert(world.toServer, { player, name, table.pack(...) })
			end
			remotes[name] = remote
		end
		remotes.Function = { ClassName = "RemoteFunction" }
		client.remotes = remotes
		client.run = runService(false)
		client.envTable = env(remotes, client.run)
		table.insert(Players.list, player)
		table.insert(world.players, player)
		table.insert(world.clients, client)
	end
	world.server = serverChunk()
	for _, client in world.clients do
		client.api = luau.load(sources.client, { debugName = kind .. "Client", environment = client.envTable })()
	end
	world.serverRemotes = serverRemotes
	return world
end

local function deliverToServer(world: any)
	local queue = world.toServer
	world.toServer = {}
	for _, message in queue do
		local args = message[3]
		world.serverRemotes[message[2]].OnServerEvent:Fire(message[1], table.unpack(args, 1, args.n))
	end
end

local function deliverToClients(world: any)
	local queue = world.toClient
	world.toClient = {}
	for _, message in queue do
		local args = message[3]
		message[1].remotes[message[2]].OnClientEvent:Fire(table.unpack(args, 1, args.n))
	end
end

-- ------------------------------------------------------------------------
-- Libraries under test

local BRANCH_SCHEMA = [[{
	Booleans = { From = "Client", Call = "Sync", Data = "boolean[..1000]" },
	Entities = { From = "Client", Call = "Sync", Data = "{ id: u8, x: u8, y: u8, z: u8, orientation: u8, animation: u8 }[..1000]" },
	Chat = { From = "Client", Call = "Sync", Data = { "string", "u8" } },
	Cars = { From = "Client", Call = "Sync", Data = { brand = "string", carName = "string", carId = "u16", available = "boolean", dealers = "u8", price = "f64" } },
	Moves = { From = "Server", Call = "Sync", Data = { pos = "vector", vel = "vector", yaw = "f32", grounded = "boolean", crouch = "boolean", sprint = "boolean", anim = "u8" } },
	MovesU = { From = "Server", Type = "Unreliable", Call = "Sync", Data = { pos = "vector", vel = "vector", yaw = "f32", grounded = "boolean", crouch = "boolean", sprint = "boolean", anim = "u8" } },
}]]

local branch = assert(NetCompile.compile({ Bench = BRANCH_SCHEMA }, { checks = "Never", version = "bench" }))

-- Same schema with Unpack on the struct events (like NetRay's default DecodeStruct = Locals).
local UNPACKED = string.gsub(string.gsub(BRANCH_SCHEMA, 'Cars = { From = "Client", Call = "Sync",', 'Cars = { From = "Client", Call = "Sync", Unpack = true,'), 'Moves(U?) = { From = "Server",', 'Moves%1 = { From = "Server", Unpack = true,')
local branchUnpacked = assert(NetCompile.compile({ Bench = UNPACKED }, { checks = "Never", version = "bench" }))

-- Callers that hold their data in tables pay for the field reads here.
local function unpackedClient(api: any): any
	local cars = api.Cars
	return setmetatable({
		Cars = { On = cars.On, Fire = function(car)
			cars.Fire(car.brand, car.carName, car.carId, car.available, car.dealers, car.price)
		end },
	}, { __index = api })
end
local function unpackedServer(api: any): any
	local function wrap(event)
		return {
			On = event.On,
			Fire = function(player, m)
				event.Fire(player, m.pos, m.vel, m.yaw, m.grounded, m.crouch, m.sprint, m.anim)
			end,
			FireAll = function(m)
				event.FireAll(m.pos, m.vel, m.yaw, m.grounded, m.crouch, m.sprint, m.anim)
			end,
		}
	end
	return setmetatable({ Moves = wrap(api.Moves), MovesU = wrap(api.MovesU) }, { __index = api })
end

local function read(path: string): string
	return fs.readFile("tests/bench/generated/" .. path)
end

local LIBS = {
	{
		name = "Blink",
		sources = { server = read("BlinkServer.luau"), client = read("BlinkClient.luau") },
		server = function(world) return world.server end,
		client = function(client) return client.api end,
	},
	{
		name = "NetRay",
		instancePlayers = true,
		sources = { server = read("netray/Server.luau"), client = read("netray/Client.luau"), types = read("netray/Types.luau") },
		server = function(world) return world.server end,
		client = function(client) return client.api end,
	},
	{
		name = "NetRay (Validate=Full)",
		instancePlayers = true,
		sources = { server = read("netrayfull/Server.luau"), client = read("netrayfull/Client.luau"), types = read("netrayfull/Types.luau") },
		server = function(world) return world.server end,
		client = function(client) return client.api end,
	},
	{
		name = "Branch",
		sources = { server = branch.server, client = branch.client },
		server = function(world) return world.server.Services.Bench end,
		client = function(client) return client.api.Services.Bench end,
	},
	{
		name = "Branch (Unpack)",
		sources = { server = branchUnpacked.server, client = branchUnpacked.client },
		server = function(world) return unpackedServer(world.server.Services.Bench) end,
		client = function(client) return unpackedClient(client.api.Services.Bench) end,
	},
}

-- ------------------------------------------------------------------------
-- Workloads

math.randomseed(1)
local entities = {}
for _ = 1, 100 do
	table.insert(entities, {
		id = math.random(1, 255),
		x = math.random(1, 255),
		y = math.random(1, 255),
		z = math.random(1, 255),
		orientation = math.random(1, 255),
		animation = math.random(1, 255),
	})
end
local booleans = table.create(1000, true)
local move = {
	pos = Vector3.new(120.5, 3, -44.25),
	vel = Vector3.new(0, -9.8, 16),
	yaw = 1.25,
	grounded = true,
	crouch = false,
	sprint = true,
	anim = 7,
}
-- Same shape and ranges as NetRay's own Benchmark.rbxl (ReplicatedStorage.Entities):
-- two strings of 2..100 bytes, u16, boolean, u8, f64. (Lune has no Random class.)
local cars = table.create(50)
for index = 1, 50 do
	math.randomseed(index * index)
	table.insert(cars, {
		brand = string.rep(string.char(math.random(0, 255)), math.random(2, 100)),
		carName = string.rep(string.char(math.random(0, 255)), math.random(2, 100)),
		carId = math.random(0, 65535),
		available = math.random(0, 1) == 1,
		dealers = math.random(0, 127),
		price = math.random() * 1e12,
	})
end

local noop = function() end

local WORKLOADS = {
	{
		name = "Cars: NetRay's own benchmark (50 structs/frame)",
		clients = 1,
		direction = "up",
		listen = function(api) api.Cars.On(noop) end,
		fire = function(api) for index = 1, 50 do api.Cars.Fire(cars[index]) end end,
	},
	{
		name = "Booleans (1000 bools x10/frame)",
		clients = 1,
		direction = "up",
		listen = function(api) api.Booleans.On(noop) end,
		fire = function(api) for _ = 1, 10 do api.Booleans.Fire(booleans) end end,
	},
	{
		name = "Entities (100 structs x10/frame)",
		clients = 1,
		direction = "up",
		listen = function(api) api.Entities.On(noop) end,
		fire = function(api) for _ = 1, 10 do api.Entities.Fire(entities) end end,
	},
	{
		name = "Chat (string, u8) x500/frame",
		clients = 1,
		direction = "up",
		listen = function(api) api.Chat.On(noop) end,
		fire = function(api) for index = 1, 500 do api.Chat.Fire("hello there", index % 256) end end,
	},
	{
		name = "Moves server->1 player x500/frame",
		clients = 1,
		direction = "down",
		listenClient = function(api) api.Moves.On(noop) end,
		fireServer = function(api, world) local p = world.players[1] for _ = 1, 500 do api.Moves.Fire(p, move) end end,
	},
	{
		name = "Moves FireAll 20 players x50/frame",
		clients = 20,
		direction = "down",
		listenClient = function(api) api.Moves.On(noop) end,
		fireServer = function(api) for _ = 1, 50 do api.Moves.FireAll(move) end end,
	},
	{
		name = "Unreliable moves x200/frame",
		clients = 1,
		direction = "down",
		listenClient = function(api) api.MovesU.On(noop) end,
		fireServer = function(api, world) local p = world.players[1] for _ = 1, 200 do api.MovesU.Fire(p, move) end end,
		unreliable = true,
	},
}

local function run(lib: any, workload: any)
	local world = makeWorld(lib.name, lib.sources, workload.clients, lib.instancePlayers)
	local serverApi = lib.server(world)
	if workload.listen then
		workload.listen(serverApi)
	end
	if workload.listenClient then
		for _, client in world.clients do
			workload.listenClient(lib.client(client))
		end
	end

	local encode, decode = 0, 0
	local maxPacket = 0
	for frame = 1, WARMUP + FRAMES do
		if frame == WARMUP + 1 then
			encode, decode = 0, 0
			world.bytesUp, world.bytesDown, world.packetsUp, world.packetsDown = 0, 0, 0, 0
			world.callsUp, world.callsDown = 0, 0
		end
		local t0 = os.clock()
		if workload.direction == "up" then
			for _, client in world.clients do
				workload.fire(lib.client(client))
				client.run.Heartbeat:Fire(1 / 60)
			end
		else
			workload.fireServer(serverApi, world)
			world.serverRun.Heartbeat:Fire(1 / 60)
		end
		local t1 = os.clock()
		for _, message in (if workload.direction == "up" then world.toServer else world.toClient) do
			maxPacket = math.max(maxPacket, buffer.len(message[3][1]))
		end
		if workload.direction == "up" then
			deliverToServer(world)
		else
			deliverToClients(world)
		end
		local t2 = os.clock()
		encode += t1 - t0
		decode += t2 - t1
	end

	local bytes = if workload.direction == "up" then world.bytesUp else world.bytesDown
	local packets = if workload.direction == "up" then world.callsUp else world.callsDown
	return {
		encode = encode / FRAMES * 1000,
		decode = decode / FRAMES * 1000,
		bytes = bytes / FRAMES,
		packets = packets / FRAMES,
		maxPacket = maxPacket,
	}
end

local out = {
	"| Workload | Library | Encode ms/frame | Decode ms/frame | Bytes/frame | Remote calls/frame | Largest packet |",
	"|---|---|---:|---:|---:|---:|---:|",
}
for _, workload in WORKLOADS do
	if ONLY and not string.find(workload.name, ONLY, 1, true) then
		continue
	end
	local results = {}
	for _, lib in LIBS do
		local best
		for _ = 1, REPEATS do
			local ok, result = pcall(run, lib, workload)
			if not ok then
				result = { failed = tostring(result) }
				best = result
				break
			end
			if not best or result.encode + result.decode < best.encode + best.decode then
				best = result
			end
		end
		results[lib.name] = best
	end
	for _, lib in LIBS do
		local r = results[lib.name]
		if r.failed then
			table.insert(out, string.format("| %s | %s | failed: %s | | | | |", workload.name, lib.name, string.sub(r.failed, 1, 80)))
		else
			local note = if workload.unreliable and r.maxPacket > 900 then " ⚠ >900 B: Roblox drops it" else ""
			table.insert(out, string.format("| %s | %s | %.3f | %.3f | %d | %.1f | %d%s |", workload.name, lib.name, r.encode, r.decode, r.bytes, r.packets, r.maxPacket, note))
		end
	end
end
local text = table.concat(out, "\n")
print(text)
fs.writeDir("build/bench")
fs.writeFile("build/bench/results.md", text .. "\n")
