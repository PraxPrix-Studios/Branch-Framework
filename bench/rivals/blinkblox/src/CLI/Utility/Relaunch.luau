--!strict
--- Hands the run over to LuneBlox when it is installed and this runtime is not it.
---
--- pesde runs the bundled compiler on the user's own Lune, and pesde's engines cannot name another
--- runtime. LuneBlox (github.com/XopoIII/LuneBlox) is Lune on the Luau version Roblox runs, with
--- Roblox's fast flags, and it is what BlinkBlox is built and tested on. So when `luneblox` is on the
--- PATH, the same script is run again under it with the same arguments and the same terminal, and
--- this process exits with its code. When it is not, nothing changes: the compiler runs here, on any
--- Lune, as it always has.
---
--- The native executables rokit installs are LuneBlox already, and never get this far.
local process = require("@lune/process")

--> Set in the child, so a `luneblox` that is not what it says never relaunches in a loop.
local RELAUNCHED = "BLINKBLOX_RELAUNCHED"
--> Set by the user to keep the compiler on the runtime that started it.
local OPT_OUT = "BLINKBLOX_NO_LUNEBLOX"

return function(Source: string)
	if string.match(_VERSION, "^LuneBlox ") or process.env[RELAUNCHED] or process.env[OPT_OUT] then
		return
	end

	local Arguments = { "run", Source }
	for _, Argument in process.args do
		table.insert(Arguments, Argument)
	end

	--> A missing program throws; a program that ran and failed returns its code, which is the answer.
	--> `env` is added to the inherited environment, not put in its place.
	local Options: process.ExecOptions = {
		env = { [RELAUNCHED] = "1" },
		stdio = "inherit",
	}
	local Launched, Result = pcall(process.exec, "luneblox", Arguments, Options)
	if not Launched then
		return
	end

	process.exit((Result :: process.ExecResult).code)
end
