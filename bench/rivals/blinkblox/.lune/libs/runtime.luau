--!strict
--> Which Luau runtime this is, and whether it is the one this repository's results come from.
-->
--> BlinkBlox's tests, benchmarks and release builds run on LuneBlox (github.com/XopoIII/LuneBlox): Lune
--> running the Luau version Roblox runs, with Roblox's fast flags, built for speed. Upstream Lune
--> 0.10.5 runs Luau 0.709 with Luau's defaults, where interpreted code measured over twice as slow on an
--> Apple M1 (15-35% on an i7-13700K) and large modules could stay interpreted. A benchmark there is not comparable with the published
--> figures, and a test there checks a VM no game runs -- so anything a contributor runs to reproduce
--> our results says so, loudly, instead of quietly producing other numbers.
-->
--> Only a release build refuses to run elsewhere, since its executables carry the runtime that built
--> them. The compiler itself must keep working on any Lune: pesde runs it on the user's.
local fs = require("@lune/fs")
local luauLibrary = require("@lune/luau")
local stdio = require("@lune/stdio")

--> The pin in rokit.toml, found from wherever the script runs: the root, test/, benchmark/, src/CLI.
local function pinned(): string?
	for _, path in { "rokit.toml", "../rokit.toml", "../../rokit.toml" } do
		if fs.isFile(path) then
			return string.match(fs.readFile(path), 'luneblox%s*=%s*"XopoIII/LuneBlox@([%w%.%-]+)"')
		end
	end
	return nil
end

local name, version, luau = string.match(_VERSION, "^(%a+) ([^+]+)%+(%d+)$")
local isLuneBlox = name == "LuneBlox"
local expected = pinned()

local runtime = {
	--> Whether this is LuneBlox at the version rokit.toml pins.
	matches = isLuneBlox and (expected == nil or expected == version),
	--> The command that runs a script on this same runtime, for anything a script shells out to.
	command = if isLuneBlox then "luneblox" else "lune",
	--> What to record beside a result, e.g. "LuneBlox 0.10.9 (Luau 0.740)".
	description = if name then `{name} {version} (Luau 0.{luau})` else _VERSION,
	expected = expected,
}

local function problem(): string
	if isLuneBlox then
		return `This is LuneBlox {version}, and rokit.toml pins {expected}.`
	end
	return `This is {runtime.description}, not LuneBlox.`
end

--> Warns when results here may differ from the repository's own, naming what runs them.
--> `purpose` completes "... may differ from ours": "The test results", "These timings".
function runtime.notice(purpose: string)
	if runtime.matches then
		return
	end
	local yellow, bold, reset = stdio.color("yellow"), stdio.style("bold"), stdio.style("reset")
	local lines = {
		`{bold}{problem()}{reset}{yellow}`,
		`BlinkBlox is tested and measured on LuneBlox {expected or ""}: the Luau version Roblox runs,`,
		"with Roblox's fast flags. " .. `{purpose} may differ from ours. To reproduce them:`,
		"",
		"    rokit install        (rokit.toml pins it)",
		"    luneblox run ...     (in place of lune run ...)",
		"",
		"https://github.com/XopoIII/LuneBlox",
	}
	local rule = string.rep("!", 78)
	stdio.ewrite(`{yellow}{rule}\n`)
	for _, line in lines do
		stdio.ewrite(`! {line}\n`)
	end
	stdio.ewrite(`{rule}{reset}\n`)
end

--> A full garbage collection, before each measurement: a benchmark times several tools in one process,
--> and each would otherwise inherit the heap the one before it left, which moved an allocating decode
--> by up to 40% with its place in the order. The sandbox leaves `collectgarbage` only "count", as on
--> Roblox; LuneBlox 0.10.9 added `luau.collect`, and a runtime without it does nothing here.
function runtime.collect()
	local collect = (luauLibrary :: any).collect
	if collect then
		collect()
	end
end

--> Memory held for the rest of the process, before any tool loads. Luau's collector paces itself on the
--> heap's size, so a tool that keeps a few megabytes of its own buffers alive was collected less often
--> than one that keeps none, and decoded faster for it: QuickNet holds about 12 MB. A game server's heap
--> is hundreds of megabytes, next to which any tool's own share is small; this makes the same true here.
local BALLAST_BYTES = 64 * 1024 * 1024
local held: buffer? = nil
function runtime.ballast()
	held = held or buffer.create(BALLAST_BYTES)
end

--> Refuses to go on unless this is LuneBlox at the pinned version.
function runtime.require(purpose: string)
	if not runtime.matches then
		error(`{purpose} needs LuneBlox {expected or ""}. {problem()} Run \`rokit install\`, then \`luneblox\`.`, 0)
	end
end

return table.freeze(runtime)
