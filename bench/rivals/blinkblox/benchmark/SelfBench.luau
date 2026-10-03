--!strict
--- SelfState only (one unreliable event to each of 50 players a frame), many frames, fire and flush
--- timed apart: a steadier look at the few microseconds Rivals.luau shows.
---     lune run SelfBench -- <tool> <native|interpreted> [frames]
local process = require("@lune/process")
local runtime = require("../.lune/libs/runtime")
runtime.ballast()
local Tools = require("./runtime/Tools")
local World = require("./runtime/World")

local TOOL = process.args[2] or process.args[1]
local ARGS = {}
for _, a in process.args do
	if a ~= "--" then
		table.insert(ARGS, a)
	end
end
TOOL = ARGS[1]
local NATIVE = ARGS[2] ~= "interpreted"
local FRAMES = tonumber(ARGS[3]) or 3000
local PLAYERS = 50

local function unit(id: number, frame: number)
	return { id = id, x = id * 3.5 + frame * 0.25, y = 12.75, z = id * -1.5 - frame * 0.125, health = (id * 7 + frame) % 101, moving = (id + frame) % 2 == 0, crouched = (id + frame) % 3 == 0 }
end

local Universe = World.Universe(NATIVE, Tools.Mounts(), PLAYERS, false)
local Mode = `runtime/rivals/modes/{TOOL}.luau`
local ServerWorld = World.new(Universe, true)
local Server = ServerWorld.Require(Mode)
local ClientWorld = World.new(Universe, false)
local Client = ClientWorld.Require(Mode)
World.Settle(Universe)
Client.SelfState.On(function() end)
Client.WorldState.On(function() end)

local fires, flushes = {}, {}
local worldUnits = {}
for index = 1, 16 do
	worldUnits[index] = unit(index, 1)
end
local units = {}
for index = 1, PLAYERS do
	units[index] = unit(index, 1)
end
local WORLD = ARGS[4] == "world"
local fire = Server.SelfState.Fire
local fireAll = Server.WorldState.FireAll
runtime.collect()
for frame = 1, 200 + FRAMES do
	table.clear(Universe.Outbox)
	table.clear(Universe.Inbox)
	local t0 = os.clock()
	if WORLD then
		fireAll(worldUnits)
	else
		for index, player in Universe.Crowd do
			fire(player, units[index])
		end
	end
	local t1 = os.clock()
	ServerWorld.Heartbeat:Fire(1 / 30)
	World.Drain(Universe)
	local t2 = os.clock()
	if frame > 200 then
		table.insert(fires, (t1 - t0) * 1e6)
		table.insert(flushes, (t2 - t1) * 1e6)
	end
end
table.sort(fires)
table.sort(flushes)
local function median(list)
	return list[#list // 2]
end
print(string.format((if WORLD then "WorldState " else "SelfState ") .. "%s %s: fire %.2f us + flush %.2f us = %.2f us per frame (50 players), median of %d frames", TOOL, if NATIVE then "native" else "interpreted", median(fires), median(flushes), median(fires) + median(flushes), FRAMES))
