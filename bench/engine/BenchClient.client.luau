-- In-engine benchmark, client half: Branch vs NetRay vs Blink.
-- Modelled on the NetRay author's Benchmark.rbxl harness (same Entities, 50
-- fires per frame, CPU per Fire, bandwidth, RTT), plus flush cost, remote
-- calls, server->client sends and decode cost measured on captured packets.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Bench = ReplicatedStorage:WaitForChild("Bench")
local Control = ReplicatedStorage:WaitForChild("BenchControl") :: RemoteEvent
local Entities = require(ReplicatedStorage:WaitForChild("Entities")) :: any

local NAMES = { "Branch", "NetRay", "Blink" }
local api: { [string]: any } = {
	Branch = (require(Bench.Branch.Client) :: any).Services.Bench,
	NetRay = require(Bench.NetRay.Client) :: any,
	Blink = require(Bench.Blink.Client) :: any,
}
local remotes: { [string]: RemoteEvent } = {
	Branch = Bench.Branch:WaitForChild("Reliable") :: RemoteEvent,
	NetRay = ReplicatedStorage:WaitForChild("NetRay_RELIABLE") :: RemoteEvent,
	Blink = ReplicatedStorage:WaitForChild("BLINK_RELIABLE_REMOTE") :: RemoteEvent,
}

local CFG = {
	runs = 3,
	frames = 300,
	firesPerFrame = 50,
	pingSamples = 60,
	pingWarmup = 5,
	pingGapSec = 0.02,
	downFrames = 300,
	downPerFrame = 100,
	decodeMoves = 50,
}

local function report(...: any)
	print("BENCH|" .. table.concat({ ... }, "|"))
end

local function command(name: string, arg: any?)
	Control:FireServer(name, arg)
	Control.OnClientEvent:Wait()
end

local fire = {
	Branch = function(car: any)
		api.Branch.Cars.Fire(car.brand, car.carName, car.carId, car.available, car.dealers, car.price)
	end,
	NetRay = function(car: any)
		api.NetRay.Cars.Fire(car)
	end,
	Blink = function(car: any)
		api.Blink.Cars.Fire(car)
	end,
}
local ping = {
	Branch = function(t0: number)
		return api.Branch.Ping.Invoke(t0)
	end,
	NetRay = function(t0: number)
		return api.NetRay.Ping.Call(t0)
	end,
	Blink = function(t0: number)
		return api.Blink.Ping.Invoke(t0)
	end,
}

local movesSeen = { Branch = 0, NetRay = 0, Blink = 0 }
api.Branch.Moves.On(function()
	movesSeen.Branch += 1
end)
api.NetRay.Moves.On(function()
	movesSeen.NetRay += 1
end)
api.Blink.Moves.On(function()
	movesSeen.Blink += 1
end)

local capturing: string? = nil
local captured: { [string]: any } = {}
for _, name in NAMES do
	remotes[name].OnClientEvent:Connect(function(...)
		if capturing == name and captured[name] == nil then
			captured[name] = table.pack(...)
		end
	end)
end

local function counters(name: string): any
	return (_G :: any).__BENCH[name]
end

local function median(list: { number }): number
	local sorted = table.clone(list)
	table.sort(sorted)
	local n = #sorted
	if n == 0 then
		return 0
	end
	return if n % 2 == 1 then sorted[(n + 1) // 2] else (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function runPing(name: string)
	local call = ping[name]
	for _ = 1, CFG.pingWarmup do
		call(os.clock())
		task.wait(CFG.pingGapSec)
	end
	local samples = {}
	local wrong = 0
	for index = 1, CFG.pingSamples do
		local t0 = os.clock()
		local back = call(t0)
		samples[index] = os.clock() - t0
		if back ~= t0 then
			wrong += 1
		end
		task.wait(CFG.pingGapSec)
	end
	table.sort(samples)
	local sum = 0
	for _, value in samples do
		sum += value
	end
	report(
		"rtt",
		name,
		string.format("%.2f", sum / #samples * 1000),
		string.format("%.2f", median(samples) * 1000),
		string.format("%.2f", samples[math.ceil(#samples * 0.95)] * 1000),
		`{wrong} wrong`
	)
end

local results: { [string]: { fire: { number }, total: { number }, bytes: { number }, calls: { number }, engine: { number } } } = {}
for _, name in NAMES do
	results[name] = { fire = {}, total = {}, bytes = {}, calls = {}, engine = {} }
end

local function runUp(name: string, run: number)
	local c = counters(name)
	local bytes0, calls0, flush0, send0 = c.bytes, c.calls, c.flushCpu, c.sendCpu
	local send = fire[name]
	local count = #Entities
	local cpu = 0
	local sent = 0
	for _ = 1, CFG.frames do
		local t = os.clock()
		for _ = 1, CFG.firesPerFrame do
			send(Entities[sent % count + 1])
			sent += 1
		end
		cpu += os.clock() - t
		RunService.Heartbeat:Wait()
	end
	RunService.Heartbeat:Wait()
	RunService.Heartbeat:Wait()
	local flush = c.flushCpu - flush0
	local r = results[name]
	r.fire[run] = cpu / sent * 1e9
	r.total[run] = (cpu + flush) / sent * 1e9
	r.bytes[run] = (c.bytes - bytes0) / sent
	r.calls[run] = (c.calls - calls0) / CFG.frames
	r.engine[run] = (c.sendCpu - send0) / sent * 1e9
	report(
		"upRun",
		name,
		tostring(run),
		string.format("%.0f", r.fire[run]),
		string.format("%.0f", r.total[run]),
		string.format("%.1f", r.bytes[run]),
		string.format("%.2f", r.calls[run]),
		string.format("%.0f", r.engine[run])
	)
end

local function decodeDown(name: string)
	local args = captured[name]
	local recv = (_G :: any).__BENCH_RECV[name]
	if not args or not recv then
		report("decodeDown", name, "no packet captured")
		return
	end
	local a1, a2 = args[1], args[2]
	local iterations = 2000
	local best = math.huge
	local before = movesSeen[name]
	for _ = 1, 5 do
		local t = os.clock()
		for _ = 1, iterations do
			recv(a1, a2)
		end
		best = math.min(best, os.clock() - t)
	end
	local perCall = (movesSeen[name] - before) / (5 * iterations)
	report("decodeDown", name, string.format("%.0f", best / (iterations * perCall) * 1e9), string.format("%d", perCall))
end

task.wait(3)
local player = Players.LocalPlayer
report("start", string.format("%.2f", player:GetNetworkPing() * 1000), if (_G :: any).__BENCH then "instrumented" else "NOT instrumented")

-- 1. correctness: 50 cars through each library, compared field by field on the server
for _, name in NAMES do
	command("record", name)
	for index = 1, #Entities do
		fire[name](Entities[index])
	end
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end
	task.wait(0.3)
	command("verify", name)
end

-- 2. latency
for _, name in NAMES do
	runPing(name)
end

-- 3. client -> server throughput (the NetRay author's test)
for run = 1, CFG.runs do
	for _, name in NAMES do
		runUp(name, run)
		task.wait(0.5)
	end
end
for _, name in NAMES do
	local r = results[name]
	report("up", name, string.format("%.0f", median(r.fire)), string.format("%.0f", median(r.total)), string.format("%.1f", median(r.bytes)), string.format("%.2f", median(r.calls)), string.format("%.0f", median(r.engine)))
end

-- 4. server decode of one captured frame (50 cars)
for _, name in NAMES do
	command("capture", name)
	for index = 1, #Entities do
		fire[name](Entities[index])
	end
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end
	task.wait(0.3)
end
command("decodeUp")

-- 5. server -> client sends
command("down", { frames = CFG.downFrames, perFrame = CFG.downPerFrame })
command("downAll", { frames = CFG.downFrames, perFrame = CFG.downPerFrame })
task.wait(1)
report("movesSeen", `Branch {movesSeen.Branch}`, `NetRay {movesSeen.NetRay}`, `Blink {movesSeen.Blink}`, `expected {CFG.downFrames * CFG.downPerFrame * 2} each`)

-- 6. client decode of one captured FireAll frame
for _, name in NAMES do
	capturing = name
	captured[name] = nil
	command("sendMoves", { name = name, count = CFG.decodeMoves })
	task.wait(0.5)
	capturing = nil
	decodeDown(name)
end

report("end")
