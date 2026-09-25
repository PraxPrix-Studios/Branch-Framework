--!strict
-- Branch Network vs NetRay vs Blink: the benchmark itself, independent of
-- where it runs: bench.luau runs it under Lune.
--
-- Every library gets the same schema, the same data and the same mocked
-- wire. Encode = the Fire calls + the frame flush; Decode = receiving the
-- packets and dispatching them to a no-op listener; Bytes = buffer payload.
--
-- The host (bench.luau) passes:
--   load(name, env)   runs a generated module (BlinkServer, NetRayClient, ...) with `env` as its globals
--   Vector3, CFrame, Color3, Enum, task, typeof   what the generated code expects
--   newPlayer(index, asInstance)   a Player (an Instance for NetRay, which checks)
--   print(text)       output
--   result(row)       one measured row (optional)
--   frames, repeats, only   how long to run, and an optional workload filter

return function(host: any)
	local FRAMES = host.frames or 300
	local WARMUP = math.min(30, FRAMES)
	local REPEATS = host.repeats or 5
	local Vector3 = host.Vector3
	local print = host.print

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

	local function makeWorld(prefix: string, hasTypes: boolean, clientCount: number, instancePlayers: boolean?): any
		local world: any = { clients = {}, players = {}, clientOf = {}, toServer = {}, toClient = {}, bytesUp = 0, bytesDown = 0, callsUp = 0, callsDown = 0 }

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
		local typesModule = nil

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
			local globals: any
			globals = {
				game = {
					GetService = function(_, name)
						if name == "Players" then return Players
						elseif name == "RunService" then return rs
						elseif name == "ReplicatedStorage" then return container end
						error(name)
					end,
				},
				script = { Parent = container, FindFirstChild = function() return nil end },
				require = function(target)
					if target == TYPES and hasTypes then
						if not typesModule then
							typesModule = host.load(prefix .. "Types", env(remotes, rs))
						end
						return typesModule
					end
					error("unexpected require")
				end,
				_G = {},
				task = host.task,
				Vector3 = host.Vector3,
				CFrame = host.CFrame,
				Color3 = host.Color3,
				Enum = host.Enum,
				typeof = host.typeof,
				warn = function() end,
				print = function() end,
			}
			return globals
		end

		local serverRemotes: any = {}
		for _, name in { "Reliable", "Unreliable" } do
			local remote = { OnServerEvent = Signal(), ClassName = if name == "Reliable" then "RemoteEvent" else "UnreliableRemoteEvent" }
			local function deliver(player, ...)
				local b = ...
				world.bytesDown += buffer.len(b)
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
		local serverEnv = env(serverRemotes, world.serverRun)

		for index = 1, clientCount do
			local client: any = {}
			local player = host.newPlayer(index, instancePlayers)
			world.clientOf[player] = client
			client.player = player
			local remotes: any = {}
			for _, name in { "Reliable", "Unreliable" } do
				local remote = { OnClientEvent = Signal(), ClassName = if name == "Reliable" then "RemoteEvent" else "UnreliableRemoteEvent" }
				function remote:FireServer(...)
					local b = ...
					world.callsUp += 1
					world.bytesUp += buffer.len(b)
					table.insert(world.toServer, { player, name, table.pack(...) })
				end
				remotes[name] = remote
			end
			remotes.Function = { ClassName = "RemoteFunction" }
			client.remotes = remotes
			client.run = runService(false)
			client.env = env(remotes, client.run)
			table.insert(Players.list, player)
			table.insert(world.players, player)
			table.insert(world.clients, client)
		end
		world.server = host.load(prefix .. "Server", serverEnv)
		for _, client in world.clients do
			client.api = host.load(prefix .. "Client", client.env)
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

	-- --------------------------------------------------------------------
	-- Libraries under test. Branch (Unpack) passes struct fields as plain
	-- arguments (like NetRay's default); callers that hold their data in
	-- tables pay for the field reads here.

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

	local LIBS = {
		{
			name = "Branch",
			prefix = "Branch",
			server = function(world) return world.server.Services.Bench end,
			client = function(client) return client.api.Services.Bench end,
		},
		{
			name = "Branch (Unpack)",
			prefix = "BranchUnpack",
			server = function(world) return unpackedServer(world.server.Services.Bench) end,
			client = function(client) return unpackedClient(client.api.Services.Bench) end,
		},
		{
			name = "NetRay",
			prefix = "NetRay",
			types = true,
			instancePlayers = true,
			server = function(world) return world.server end,
			client = function(client) return client.api end,
		},
		{
			name = "NetRay (Validate=Full)",
			prefix = "NetRayFull",
			types = true,
			instancePlayers = true,
			server = function(world) return world.server end,
			client = function(client) return client.api end,
		},
		{
			name = "Blink",
			prefix = "Blink",
			server = function(world) return world.server end,
			client = function(client) return client.api end,
		},
	}

	-- --------------------------------------------------------------------
	-- Workloads (the data is deterministic: the same on every run and host)

	local seed = 1
	local function random(low: number, high: number): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return low + math.floor(seed / 2147483648 * (high - low + 1))
	end
	local entities = {}
	for _ = 1, 100 do
		table.insert(entities, {
			id = random(1, 255),
			x = random(1, 255),
			y = random(1, 255),
			z = random(1, 255),
			orientation = random(1, 255),
			animation = random(1, 255),
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
	-- two strings of 2..100 bytes, u16, boolean, u8, f64.
	local cars = table.create(50)
	for _ = 1, 50 do
		table.insert(cars, {
			brand = string.rep(string.char(random(0, 255)), random(2, 100)),
			carName = string.rep(string.char(random(0, 255)), random(2, 100)),
			carId = random(0, 65535),
			available = random(0, 1) == 1,
			dealers = random(0, 127),
			price = random(0, 1e9) * 1000,
		})
	end

	local noop = function() end

	local WORKLOADS = {
		{
			name = "Cars: NetRay's own benchmark (50 structs per frame)",
			clients = 1,
			direction = "up",
			listen = function(api) api.Cars.On(noop) end,
			fire = function(api) for index = 1, 50 do api.Cars.Fire(cars[index]) end end,
		},
		{
			name = "1000 booleans x10 per frame",
			clients = 1,
			direction = "up",
			listen = function(api) api.Booleans.On(noop) end,
			fire = function(api) for _ = 1, 10 do api.Booleans.Fire(booleans) end end,
		},
		{
			name = "Entities: 100 small structs x10 per frame",
			clients = 1,
			direction = "up",
			listen = function(api) api.Entities.On(noop) end,
			fire = function(api) for _ = 1, 10 do api.Entities.Fire(entities) end end,
		},
		{
			name = "Chat: (string, u8) x500 per frame",
			clients = 1,
			direction = "up",
			listen = function(api) api.Chat.On(noop) end,
			fire = function(api) for index = 1, 500 do api.Chat.Fire("hello there", index % 256) end end,
		},
		{
			name = "Moves: server -> 1 player x500 per frame",
			clients = 1,
			direction = "down",
			listenClient = function(api) api.Moves.On(noop) end,
			fireServer = function(api, world) local p = world.players[1] for _ = 1, 500 do api.Moves.Fire(p, move) end end,
		},
		{
			name = "Moves: FireAll to 20 players x50 per frame",
			clients = 20,
			direction = "down",
			listenClient = function(api) api.Moves.On(noop) end,
			fireServer = function(api) for _ = 1, 50 do api.Moves.FireAll(move) end end,
		},
		{
			name = "Unreliable moves x200 per frame",
			clients = 1,
			direction = "down",
			listenClient = function(api) api.MovesU.On(noop) end,
			fireServer = function(api, world) local p = world.players[1] for _ = 1, 200 do api.MovesU.Fire(p, move) end end,
			unreliable = true,
		},
	}

	local function run(lib: any, workload: any)
		local world = makeWorld(lib.prefix, lib.types == true, workload.clients, lib.instancePlayers)
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
				world.bytesUp, world.bytesDown, world.callsUp, world.callsDown = 0, 0, 0, 0
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

		local up = workload.direction == "up"
		return {
			encode = encode / FRAMES * 1000,
			decode = decode / FRAMES * 1000,
			bytes = (if up then world.bytesUp else world.bytesDown) / FRAMES,
			calls = (if up then world.callsUp else world.callsDown) / FRAMES,
			maxPacket = maxPacket,
		}
	end

	-- "X% faster": the other library needs X% more time for the same work.
	local function faster(branch: number, other: number): string
		if branch <= 0 or other <= 0 then
			return "?"
		end
		local percent = (other / branch - 1) * 100
		if math.abs(percent) < 0.5 then
			return "a tie with"
		elseif percent > 0 then
			return string.format("%.0f%% faster than", percent)
		end
		return string.format("%.0f%% slower than", (branch / other - 1) * 100) -- Branch needs that much more time
	end

	local selected = {}
	for _, workload in WORKLOADS do
		if not host.only or string.find(workload.name, host.only, 1, true) then
			table.insert(selected, workload)
		end
	end

	print(`Branch Network vs NetRay vs Blink: {#selected} benchmarks, one after another.`)
	print(`Each library runs {WARMUP} warm-up frames + {FRAMES} measured frames, best of {REPEATS}.`)
	print("Times are milliseconds per frame (lower is better).")
	print("")

	local summary = {}
	for index, workload in selected do
		print(`[{index}/{#selected}] {workload.name}`)
		local results = {}
		for _, lib in LIBS do
			local best
			for _ = 1, REPEATS do
				local ok, result = pcall(run, lib, workload)
				if not ok then
					best = { failed = tostring(result) }
					break
				end
				if not best or result.encode + result.decode < best.encode + best.decode then
					best = result
				end
			end
			results[lib.name] = best
			if best.failed then
				print(string.format("    %-24s failed: %s", lib.name, string.sub(best.failed, 1, 120)))
			else
				local note = if workload.unreliable and best.maxPacket > 900 then "  (a packet over 900 B: Roblox drops it)" else ""
				print(string.format(
					"    %-24s encode %.3f  decode %.3f  total %.3f  |  %d B/frame, %.1f remote calls%s",
					lib.name, best.encode, best.decode, best.encode + best.decode, best.bytes, best.calls, note
				))
			end
			if host.result then
				host.result({ workload = workload.name, index = index, library = lib.name, encode = best.encode, decode = best.decode, bytes = best.bytes, calls = best.calls, maxPacket = best.maxPacket, failed = best.failed })
			end
		end
		local b, n, nf, bl = results["Branch"], results["NetRay"], results["NetRay (Validate=Full)"], results["Blink"]
		if b and not b.failed then
			local total = b.encode + b.decode
			local line = "    --> Branch is "
			local parts = {}
			if n and not n.failed then
				table.insert(parts, `{faster(total, n.encode + n.decode)} NetRay`)
			end
			if bl and not bl.failed then
				table.insert(parts, `{faster(total, bl.encode + bl.decode)} Blink`)
			end
			line ..= table.concat(parts, ", ")
			if nf and not nf.failed then
				line ..= ` ({faster(total, nf.encode + nf.decode)} NetRay with validation on)`
			end
			print(line)
			table.insert(summary, { name = workload.name, line = line, results = results })
		end
		print("")
	end

	print("Summary")
	for _, row in summary do
		print(`  {row.name}`)
		print(`  {string.sub(row.line, 5)}`)
	end
	print("Done.")
	return summary
end
