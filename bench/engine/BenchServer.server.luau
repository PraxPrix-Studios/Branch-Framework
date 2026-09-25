-- In-engine benchmark, server half: Branch vs NetRay vs Blink.
-- The client (BenchClient) drives the steps through ReplicatedStorage.BenchControl
-- and prints everything; this side measures what happens on the server and
-- sends its numbers back with each "done".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bench = ReplicatedStorage:WaitForChild("Bench")
local Control = ReplicatedStorage:WaitForChild("BenchControl") :: RemoteEvent
local Entities = require(ReplicatedStorage:WaitForChild("Entities")) :: any

-- "Run" starts only a server: this benchmark needs a player
task.delay(5, function()
	if #Players:GetPlayers() == 0 then
		print("[Benchmark] Press Play (F5), not Run: the benchmark needs a player to send to.")
	end
end)

local NAMES = { "Branch", "NetRay", "Blink" }
local api: { [string]: any } = {
	Branch = (require(Bench.Branch.Server) :: any).Services.Bench,
	NetRay = require(Bench.NetRay.Server) :: any,
	Blink = require(Bench.Blink.Server) :: any,
}
local remotes: { [string]: RemoteEvent } = {
	Branch = Bench.Branch:WaitForChild("Reliable") :: RemoteEvent,
	NetRay = ReplicatedStorage:WaitForChild("NetRay_RELIABLE") :: RemoteEvent,
	Blink = ReplicatedStorage:WaitForChild("BLINK_RELIABLE_REMOTE") :: RemoteEvent,
}

-- Every library hands the car over in its own shape; normalise for checking.
local seen = { Branch = 0, NetRay = 0, Blink = 0 }
local recording: string? = nil
local recorded: { any } = {}
local function got(name: string, car: any)
	seen[name] += 1
	if recording == name then
		table.insert(recorded, car)
	end
end
api.Branch.Cars.On(function(_, brand, carName, carId, available, dealers, price)
	got("Branch", if recording then { brand = brand, carName = carName, carId = carId, available = available, dealers = dealers, price = price } else nil)
end)
api.NetRay.Cars.On(function(_, brand, carName, carId, available, dealers, price)
	got("NetRay", if recording then { brand = brand, carName = carName, carId = carId, available = available, dealers = dealers, price = price } else nil)
end)
api.Blink.Cars.On(function(_, car)
	got("Blink", car)
end)
for _, name in NAMES do
	api[name].Ping.On(function(_, t0)
		return t0
	end)
end

-- Our own taps on each library's reliable remote capture one real packet.
local capturing: string? = nil
local captured: { [string]: any } = {}
for _, name in NAMES do
	remotes[name].OnServerEvent:Connect(function(_, ...)
		if capturing == name and captured[name] == nil then
			captured[name] = table.pack(...)
		end
	end)
end

local move = {
	pos = Vector3.new(1, 2, 3),
	vel = Vector3.new(4, 5, 6),
	yaw = 1.5,
	grounded = true,
	crouch = false,
	sprint = true,
	anim = 7,
}
local senders = {
	Branch = function(player: Player?)
		local m = move
		if player then
			api.Branch.Moves.Fire(player, m.pos, m.vel, m.yaw, m.grounded, m.crouch, m.sprint, m.anim)
		else
			api.Branch.Moves.FireAll(m.pos, m.vel, m.yaw, m.grounded, m.crouch, m.sprint, m.anim)
		end
	end,
	NetRay = function(player: Player?)
		if player then
			api.NetRay.Moves.Fire(player, move)
		else
			api.NetRay.Moves.FireAll(move)
		end
	end,
	Blink = function(player: Player?)
		if player then
			api.Blink.Moves.Fire(player, move)
		else
			api.Blink.Moves.FireAll(move)
		end
	end,
}

local function counters(name: string): any
	return (_G :: any).__BENCH[name]
end

-- ns per send: the Fire calls, the frame flush, both; bytes per send, remote calls per frame
local function down(name: string, player: Player, frames: number, perFrame: number, all: boolean): any
	local c = counters(name)
	local bytes0, calls0, flush0 = c.bytes, c.calls, c.flushCpu
	local send = senders[name]
	local target = if all then nil else player
	local cpu = 0
	for _ = 1, frames do
		local t = os.clock()
		for _ = 1, perFrame do
			send(target)
		end
		cpu += os.clock() - t
		RunService.Heartbeat:Wait()
	end
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	local sent = frames * perFrame
	local flush = c.flushCpu - flush0
	return {
		fire = cpu / sent * 1e9,
		flush = flush / sent * 1e9,
		total = (cpu + flush) / sent * 1e9,
		bytes = (c.bytes - bytes0) / sent,
		calls = (c.calls - calls0) / frames,
	}
end

local function sameCar(a: any, b: any): boolean
	return a.brand == b.brand
		and a.carName == b.carName
		and a.carId == b.carId
		and a.available == b.available
		and a.dealers == b.dealers
		and a.price == b.price
end

-- ns per car to read one captured frame of 50 cars (best of 5 x 2000)
local function decodeUp(player: Player): any
	local out = {}
	for _, name in NAMES do
		local args = captured[name]
		local recv = (_G :: any).__BENCH_RECV[name]
		if not args or not recv then
			out[name] = { failed = "no packet captured" }
			continue
		end
		local a1, a2 = args[1], args[2]
		local iterations = 2000
		local best = math.huge
		local before = seen[name]
		for _ = 1, 5 do
			local t = os.clock()
			for _ = 1, iterations do
				recv(player, a1, a2)
			end
			best = math.min(best, os.clock() - t)
		end
		local perCall = (seen[name] - before) / (5 * iterations)
		out[name] = { ns = best / (iterations * perCall) * 1e9, cars = perCall }
	end
	return out
end

Control.OnServerEvent:Connect(function(player: Player, command: string, arg: any)
	local result: any = nil
	if command == "capture" then
		capturing = arg
		captured[arg] = nil
	elseif command == "record" then
		recording = arg
		table.clear(recorded)
	elseif command == "verify" then
		recording = nil
		local ok = 0
		for index, car in recorded do
			if sameCar(car, Entities[index]) then
				ok += 1
			end
		end
		result = { ok = ok, of = #Entities, total = seen[arg] }
	elseif command == "decodeUp" then
		capturing = nil
		result = decodeUp(player)
	elseif command == "down" or command == "downAll" then
		result = {}
		for _, name in NAMES do
			result[name] = down(name, player, arg.frames, arg.perFrame, command == "downAll")
			task.wait(0.5)
		end
	elseif command == "sendMoves" then
		-- one FireAll frame for the client to capture and decode
		for _ = 1, arg.count do
			senders[arg.name](nil)
		end
	end
	Control:FireClient(player, "done", result)
end)
