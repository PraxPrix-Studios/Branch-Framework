--!strict
-- Branch Network vs NetRay vs Blink, under Lune.
--   lune run bench/bench.luau [only] [frames] [repeats]      (from the Branch repository)
-- The benchmark itself is core.luau. Inputs are the modules each library generated from the same
-- schema: generated/Branch*, generated/Blink*, generated/netray*/.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

-- works from the Branch repository (bench/) and from Branch-Studio (tests/bench/)
local BASE = if fs.isDir("bench/generated") then "bench/" else "tests/bench/"

local FILES = {
	BranchServer = "generated/branch/Server.luau",
	BranchClient = "generated/branch/Client.luau",
	BranchUnpackServer = "generated/branch-unpack/Server.luau",
	BranchUnpackClient = "generated/branch-unpack/Client.luau",
	NetRayServer = "generated/netray/Server.luau",
	NetRayClient = "generated/netray/Client.luau",
	NetRayTypes = "generated/netray/Types.luau",
	NetRayFullServer = "generated/netrayfull/Server.luau",
	NetRayFullClient = "generated/netrayfull/Client.luau",
	NetRayFullTypes = "generated/netrayfull/Types.luau",
	BlinkServer = "generated/BlinkServer.luau",
	BlinkClient = "generated/BlinkClient.luau",
}
local sources: { [string]: string } = {}
for name, path in FILES do
	sources[name] = fs.readFile(BASE .. path)
end

local rows = {}
local core = luau.load(fs.readFile(BASE .. "core.luau"), { debugName = "core" })()
core({
	frames = tonumber(process.args[2]) or 300,
	repeats = tonumber(process.args[3]) or 5,
	only = if process.args[1] and process.args[1] ~= "" then process.args[1] else nil,
	load = function(name: string, env: any)
		return luau.load(sources[name], { debugName = name, environment = env })()
	end,
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	Enum = roblox.Enum,
	task = task,
	typeof = typeof,
	newPlayer = function(index: number, asInstance: boolean?): any
		if asInstance then
			local player = roblox.Instance.new("Player") -- NetRay checks typeof(player) == "Instance"
			player.Name = "P" .. index
			return player
		end
		return { Name = "P" .. index, UserId = index }
	end,
	print = print,
	result = function(row: any)
		table.insert(rows, row)
	end,
})

local out = {
	"| Workload | Library | Encode ms/frame | Decode ms/frame | Bytes/frame | Remote calls/frame | Largest packet |",
	"|---|---|---:|---:|---:|---:|---:|",
}
for _, r in rows do
	if r.failed then
		table.insert(out, string.format("| %s | %s | failed: %s | | | | |", r.workload, r.library, string.sub(r.failed, 1, 80)))
	else
		table.insert(out, string.format("| %s | %s | %.3f | %.3f | %d | %.1f | %d |", r.workload, r.library, r.encode, r.decode, r.bytes, r.calls, r.maxPacket))
	end
end
fs.writeDir("build/bench")
fs.writeFile("build/bench/results.md", table.concat(out, "\n") .. "\n")
