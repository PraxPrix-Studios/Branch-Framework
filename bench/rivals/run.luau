--!strict
-- Runs round 2 from the repository root:
--   lune run bench/rivals/run
-- It goes through BlinkBlox's three Lune benchmarks (Runtime, Rivals, Ours) for
-- BlinkBlox, Branch, QuickNet, Blink and Warp. Takes a few minutes.

local process = require("@lune/process")

local DIR = "bench/rivals/blinkblox/benchmark"
local TOOLS = "blink,branch,quicknet,upstream,warp"

for _, script in { "Runtime", "Rivals", "Ours" } do
	print(`\n=== {script} ===\n`)
	local result = process.exec("lune", { "run", script, "--", "--tools", TOOLS }, { cwd = DIR, stdio = "inherit" })
	if not result.ok then
		print(`{script} failed`)
		process.exit(1)
	end
end
