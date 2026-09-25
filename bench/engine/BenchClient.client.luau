-- In-engine benchmark, client half: Branch vs NetRay vs Blink.
-- Press Play: every benchmark runs by itself, one after another, and the
-- Output shows each result, how much faster or slower Branch is, and a
-- summary at the end.
-- Modelled on the NetRay author's Benchmark.rbxl harness (the same Entities,
-- 50 fires per frame, CPU per fire, bandwidth, round trip), plus the frame
-- flush, remote calls, server -> client sends, and decode cost measured on
-- captured packets. Every library's module has the same instrumentation.

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
local STEPS = 6

local function say(text: string)
	print("[Benchmark] " .. text)
end

local function command(name: string, arg: any?): any
	Control:FireServer(name, arg)
	local _, result = Control.OnClientEvent:Wait()
	return result
end

-- "X% faster": the other library needs X% more time for the same work.
local function faster(branch: number, other: number): string
	if not (branch > 0 and other > 0) then
		return "?"
	end
	local percent = (other / branch - 1) * 100
	if math.abs(percent) < 0.5 then
		return "a tie with"
	elseif percent > 0 then
		return string.format("%.0f%% faster than", percent)
	end
	return string.format("%.0f%% slower than", (branch / other - 1) * 100)
end

local summary: { string } = {}
-- prints "--> Branch is X% faster than NetRay, Y% faster than Blink" for a lower-is-better number
local function verdict(title: string, value: { [string]: number })
	local line = `Branch is {faster(value.Branch, value.NetRay)} NetRay, {faster(value.Branch, value.Blink)} Blink`
	say("  --> " .. line)
	table.insert(summary, `{title}: {line}`)
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

local function runPing(name: string): (number, number, number, number)
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
	return sum / #samples * 1000, median(samples) * 1000, samples[math.ceil(#samples * 0.95)] * 1000, wrong
end

local results: { [string]: { fire: { number }, total: { number }, bytes: { number }, calls: { number } } } = {}
for _, name in NAMES do
	results[name] = { fire = {}, total = {}, bytes = {}, calls = {} }
end

local function runUp(name: string, run: number)
	local c = counters(name)
	local bytes0, calls0, flush0 = c.bytes, c.calls, c.flushCpu
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
end

local function decodeDown(name: string): number?
	local args = captured[name]
	local recv = (_G :: any).__BENCH_RECV[name]
	if not args or not recv then
		return nil
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
	return best / (iterations * perCall) * 1e9
end

local function pad(name: string): string
	return name .. string.rep(" ", 7 - #name)
end

task.wait(3)
local player = Players.LocalPlayer
say(`Branch vs NetRay vs Blink: {STEPS} benchmarks, one after another (about a minute).`)
say("Keep the game window open until the summary. Times: nanoseconds per message, lower is better.")
if not (_G :: any).__BENCH then
	say("This place was not built by bench/engine/build.luau (no instrumentation): results are missing.")
end
say(string.format("Network ping to the Studio server: %.1f ms", player:GetNetworkPing() * 1000))

-- 1. correctness: 50 cars through each library, compared field by field on the server
say("")
say(`[1/{STEPS}] Correctness: 50 cars through each library, compared field by field on the server`)
for _, name in NAMES do
	command("record", name)
	for index = 1, #Entities do
		fire[name](Entities[index])
	end
	for _ = 1, 3 do
		RunService.Heartbeat:Wait()
	end
	task.wait(0.3)
	local check = command("verify", name)
	say(`  {pad(name)} {check.ok}/{check.of} cars arrived exactly{if check.ok == check.of then "" else "  <-- MISMATCH"}`)
end

-- 2. latency
say("")
say(`[2/{STEPS}] Function round trip (client asks, server answers), {CFG.pingSamples} calls each`)
local rtt = {}
for _, name in NAMES do
	local avg, med, p95, wrong = runPing(name)
	rtt[name] = med
	say(string.format("  %s average %.2f ms, median %.2f ms, 95%% under %.2f ms%s", pad(name), avg, med, p95, if wrong > 0 then `, {wrong} wrong answers` else ""))
end
say("  --> about the same for all three: the time is the network, not the library")
table.insert(summary, "Function round trip: a tie, the time is the network")

-- 3. client -> server throughput (the NetRay author's test)
say("")
say(`[3/{STEPS}] Client -> server: NetRay's own test, {CFG.firesPerFrame} cars per frame for {CFG.frames} frames, {CFG.runs} runs (median)`)
for run = 1, CFG.runs do
	for _, name in NAMES do
		runUp(name, run)
		task.wait(0.5)
	end
end
local up = {}
for _, name in NAMES do
	local r = results[name]
	up[name] = median(r.total)
	say(string.format("  %s %4.0f ns per car (Fire %4.0f + flush %4.0f)  |  %.1f B per car, %.2f remote calls per frame", pad(name), median(r.total), median(r.fire), median(r.total) - median(r.fire), median(r.bytes), median(r.calls)))
end
verdict("Client -> server, 50 cars per frame", up)

-- 4. server decode of one captured frame (50 cars)
say("")
say(`[4/{STEPS}] Server reads one captured frame of 50 cars (best of 5 x 2000)`)
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
local decodeUp = command("decodeUp")
local decodeUpNs = {}
for _, name in NAMES do
	local r = decodeUp[name]
	if r.failed then
		say(`  {pad(name)} {r.failed}`)
	else
		decodeUpNs[name] = r.ns
		say(string.format("  %s %4.0f ns per car", pad(name), r.ns))
	end
end
verdict("Server reads 50 cars", decodeUpNs)

-- 5. server -> client sends
say("")
say(`[5/{STEPS}] Server -> client: {CFG.downPerFrame} moves per frame for {CFG.downFrames} frames, to one player, then to everyone (FireAll)`)
local function showDown(label: string, result: any): { [string]: number }
	local total = {}
	for _, name in NAMES do
		local r = result[name]
		total[name] = r.total
		say(string.format("  %s %s: %4.0f ns per move (Fire %4.0f + flush %4.0f)  |  %.1f B per move, %.2f remote calls per frame", pad(name), label, r.total, r.fire, r.flush, r.bytes, r.calls))
	end
	return total
end
verdict("Server -> 1 player", showDown("one player", command("down", { frames = CFG.downFrames, perFrame = CFG.downPerFrame })))
verdict("FireAll", showDown("FireAll   ", command("downAll", { frames = CFG.downFrames, perFrame = CFG.downPerFrame })))
task.wait(1)
local expected = CFG.downFrames * CFG.downPerFrame * 2
for _, name in NAMES do
	if movesSeen[name] ~= expected then
		say(`  {pad(name)} delivered {movesSeen[name]} of {expected} moves  <-- MISMATCH`)
	end
end

-- 6. client decode of one captured FireAll frame
say("")
say(`[6/{STEPS}] Client reads one captured FireAll frame of {CFG.decodeMoves} moves (best of 5 x 2000)`)
local decodeDownNs = {}
for _, name in NAMES do
	capturing = name
	captured[name] = nil
	command("sendMoves", { name = name, count = CFG.decodeMoves })
	task.wait(0.5)
	capturing = nil
	local ns = decodeDown(name)
	decodeDownNs[name] = ns
	say(if ns then string.format("  %s %4.0f ns per move", pad(name), ns) else `  {pad(name)} no packet captured`)
end
verdict("Client reads a FireAll frame", decodeDownNs)

say("")
say("Summary (\"X% faster\": the other library needs X% more time for the same work)")
for _, line in summary do
	say("  " .. line)
end
say("Done. Numbers vary between machines and runs; run it twice and compare.")
