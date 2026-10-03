--!strict
--- What World.luau does to a module's text before loading it, and to the paths it requires by.
local Source = {}

--> The Roblox globals every module is given.
Source.GLOBALS = {
	"game",
	"script",
	"require",
	"task",
	"warn",
	"print",
	"_G",
	"shared",
	"Instance",
	"CFrame",
	"Vector3",
	"Vector2",
	"Color3",
	"Enum",
	"workspace",
}
--> `typeof` is replaced only where a scenario sends Instances: a replaced builtin is no longer a fastcall.
Source.GLOBALS_TYPEOF = table.clone(Source.GLOBALS)
table.insert(Source.GLOBALS_TYPEOF, "typeof")

--> Roblox's globals arrive as locals of the chunk, taken from the one table it is called with, and the
--> module's own code runs in a function inside it, where they are upvalues. A function holds at most
--> 200 locals, and a global takes none on Roblox: QuickNet's serialiser has nearly 200 of its own, and
--> would not load beside even a few more. One line, so the module's lines keep their numbers but one.
local function Prelude(Globals: { string }): string
	local Lines = { "local BENCHMARK_GLOBALS = ..." }
	for _, Name in Globals do
		table.insert(Lines, `local {Name} = BENCHMARK_GLOBALS.{Name}`)
	end
	table.insert(Lines, "return (function(...)")
	return table.concat(Lines, "; ")
end

--> The prelude goes after the directives, which count only above the first line of code, and never
--> inside a block comment, whose lines would not start with `--`.
--> Also says whether the module asks to be natively compiled. A Roblox server compiles only the ones
--> that do, where Lune's `codegenEnabled` compiles everything: left alone, a tool that never declares
--> `--!native` -- Packet does not, and ByteNet does in 7 of its 35 files -- would be timed natively
--> here and interpreted in a game. A module that marks functions `@native` instead, as QuickNet's do,
--> is compiled too: Luau then compiles those functions alone, as Roblox does.
function Source.Prepare(Text: string, Native: boolean, Globals: { string }): (string, boolean)
	local Lines = string.split(Text, "\n")
	local Index = 1
	local Declared = false
	while Lines[Index] do
		local Line = Lines[Index]
		if string.sub(Line, 1, 3) == "--!" then
			if string.match(Line, "^%-%-!native%s*$") then
				Declared = true
				if not Native then
					table.remove(Lines, Index)
					continue
				end
			end
		elseif Line ~= "" and (string.sub(Line, 1, 2) ~= "--" or string.sub(Line, 1, 3) == "--[") then
			break
		end
		Index += 1
	end

	table.insert(Lines, Index, Prelude(Globals))
	table.insert(Lines, "end)(...)")
	return table.concat(Lines, "\n"), Declared or string.find(Text, "@native", 1, true) ~= nil
end

function Source.Normalise(Path: string): string
	local Parts = {}
	for _, Part in string.split(Path, "/") do
		if Part == ".." and #Parts > 0 and Parts[#Parts] ~= ".." then
			table.remove(Parts)
		elseif Part ~= "." and Part ~= "" then
			table.insert(Parts, Part)
		end
	end
	return table.concat(Parts, "/")
end

return Source
