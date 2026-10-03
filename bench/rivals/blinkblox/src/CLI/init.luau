--!strict
--!native
--!optimize 2

---- Imports ----

local process = require("@lune/process")
local stdio = require("@lune/stdio")

--> Before anything prints: run under LuneBlox when it is installed and this is not it. The path is
--> taken here because only the entry chunk names the file that was run -- the bundle, under pesde.
require("@self/Utility/Relaunch")(debug.info(1, "s"))

local Attributes = require("./Modules/Attributes")
local Compile = require("@self/Utility/Compile")
local Watch = require("@self/Utility/Watch")

---- Settings ----

type Argument = {
	Hidden: true?,
	Aliases: { string },
	Description: string,
}

local ARGUMENTS: { [string]: Argument } = {
	Help = {
		Aliases = { "-h", "--help" },
		Description = "Print help information",
	},
	Version = {
		Aliases = { "-v", "--version" },
		Description = "Print version information",
	},
	Watch = {
		Aliases = { "-w", "--watch" },
		Description = "Watch [CONFIG] for changes, automatically recompile upon one occuring",
	},
	Silent = {
		Aliases = { "-q", "--quiet" },
		Description = "Silence program output",
	},
	Compact = {
		Aliases = { "-c", "--compact" },
		Description = "Prints each diagnostic as a single line instead of the full rendering.",
	},
	YesToAll = {
		Aliases = { "-y", "--yes" },
		Description = "Accept all prompts",
	},
	Check = {
		Aliases = { "--check" },
		Description = "Check [CONFIG] for errors and warnings without writing any files",
	},
	Verify = {
		Aliases = { "--verify" },
		Description = "Compare the files [CONFIG] would generate with the ones on disk, writing nothing; exit 1 if any differ",
	},
	Json = {
		Aliases = { "--json" },
		Description = "Print diagnostics as one JSON document on standard output, and nothing else",
	},
	Profile = {
		Aliases = { "-p", "--profile" },
		Description = "Compile under a profile: dev, debug, test or release (the default). Takes a value.",
	},
	OutputAst = {
		Hidden = true,
		Aliases = { "--ast" },
		Description = "Output the AST of [CONFIG]",
	},
	Statistics = {
		Hidden = true,
		Aliases = { "-S", "--stats" },
		Description = "Output compilation time statistics",
	},
}

---- Functions -----

local function Style(Text: string, StyleName: stdio.Style): string
	return `{stdio.style(StyleName)}{Text}{stdio.style("reset")}`
end

local function Color(Text: string, ColorName: stdio.Color): string
	return `{stdio.color(ColorName)}{Text}{stdio.color("reset")}`
end

local function PrintHelpMessage()
	print(Color(Style("USAGE:", "bold"), "yellow"))
	--> The executable is only `blinkblox.exe` on Windows; every other release is plain `blinkblox`.
	print(`\tblinkblox{if process.os == "windows" then ".exe" else ""} [CONFIG] [OPTIONS]`)
	print(Color(Style("OPTIONS:", "bold"), "yellow"))

	local Sorted: { Argument } = {}
	for _, Argument in ARGUMENTS do
		if not Argument.Hidden then
			table.insert(Sorted, Argument)
		end
	end

	table.sort(Sorted, function(a, b)
		return a.Aliases[1] < b.Aliases[1]
	end)

	for _, Argument in Sorted do
		print(
			`\t{stdio.color("green")}{table.concat(Argument.Aliases, ", ")}{stdio.color("reset")}\t{Argument.Description}`
		)
	end
end

---- Main ----

--> `DEBUG` outside a release bundle is deliberate, not a placeholder: darklua replaces `_G.VERSION`
--> with a literal when it bundles, so reading it through `_G` is what lets an unbundled run tell you
--> it is unbundled.
local Version = _G.VERSION or "DEBUG"

local RawArguments = process.args

--> Parse optional arguments
local Arguments = {}
local IsFlag: { [string]: true } = {}
for Key, Argument in ARGUMENTS do
	local IsSupplied = false
	for _, Alias in Argument.Aliases do
		IsFlag[Alias] = true
		if table.find(RawArguments, Alias) ~= nil then
			IsSupplied = true
			break
		end
	end

	Arguments[Key] = IsSupplied
end

--> The config path is the first argument that is not a flag, rather than argument #1.
--> Taking position 1 blindly meant `blink --yes input.blink` read a file literally named "--yes",
--> so flag order was load-bearing in a way nothing announced -- and the failure surfaced as a
--> missing-file error naming the flag, which reads like a bug in the caller.
-->
--> `--profile` is the one flag that takes a value, and that value is skipped here so that
--> `blink --profile dev input.blink` does not read a file named "dev".
--> `--` too: `lune run init -- ...` hands it through as an argument, and it named no file either.
IsFlag["--"] = true

local Profile: string?
local ProfileAt = table.find(RawArguments, "--profile") or table.find(RawArguments, "-p")
if ProfileAt then
	Profile = RawArguments[ProfileAt + 1]
	if Profile == nil or not Attributes.IsProfile(Profile) then
		print(Color(`Expected a profile after "{RawArguments[ProfileAt]}": dev, debug, test or release`, "red"))
		process.exit(1)
	end
end

local Path: string?
for Index, Argument in RawArguments do
	if not IsFlag[Argument] and Index ~= (ProfileAt and ProfileAt + 1) then
		Path = Argument
		break
	end
end

--> Watch mode runs until it is stopped, so it never gets to the end of a JSON document.
if Arguments.Json and Arguments.Watch then
	print(Color(`"--json" cannot be combined with "--watch"`, "red"))
	process.exit(1)
end

--> A verify answers once, about the files on disk now; watching would answer about none of them.
if Arguments.Verify and Arguments.Watch then
	print(Color(`"--verify" cannot be combined with "--watch"`, "red"))
	process.exit(1)
end

--> `--json` owns standard output: a banner in front of the document is a document nothing parses.
if Arguments.Json then
	Arguments.Silent = true
end

--> The banner is decoration, and it used to be the FIRST statement in this file -- printed before
--> the flags that should have governed it were even looked at, so `--quiet` never suppressed it.
if not Arguments.Silent then
	print(`{Color("BlinkBlox", "green")} {Version}`)
end

if Arguments.Help or #RawArguments < 1 then
	PrintHelpMessage()
	return nil
end

--> Printed even under `--quiet`, because withholding the one thing the caller asked for is not what
--> quiet means. `--version` had no implementation at all before this: it returned, and the only
--> reason a version ever appeared was the unconditional banner it happened to fall through.
if Arguments.Version then
	if Arguments.Silent then
		print(`{Color("BlinkBlox", "green")} {Version}`)
	end

	return nil
end

--> Flags only, no config: the same situation as no arguments at all.
if not Path then
	PrintHelpMessage()
	return nil
end

if not Arguments.Watch then
	local CompileOptions: Compile.CompileOptions = {
		Debug = (_G.RELEASE == nil) or Arguments.Statistics,
		Silent = Arguments.Silent,
		Compact = Arguments.Compact,
		YesToEverything = Arguments.YesToAll,
		OutputAbstractSyntaxTree = Arguments.OutputAst,
		Profile = Profile,
		Check = Arguments.Check,
		Json = Arguments.Json,
		Verify = Arguments.Verify,
	}

	Compile.Compile(Path, CompileOptions)
else
	Watch.Watch(Path, Profile, Arguments.Check)
end

return nil
