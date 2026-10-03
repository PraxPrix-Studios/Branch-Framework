--!strict
--- `--verify`: compares what a compile would write with what is on disk, and writes nothing.
---
--- A game that commits its generated modules -- so that Rojo and Studio need no codegen step -- needs
--- a pre-commit or CI check that they still match the schema. Before this flag the only way was to
--- regenerate into the working tree and ask git for a diff, which rewrites files under the caller
--- and needs a repository. This takes each would-be file from the same compile a real build runs and
--- compares it with the file at the same path, byte for byte.
---
--- Only the files the compile would write are compared. The compiler never deletes anything in an
--- output folder, so an extra file there -- or a `.d.ts` left behind after `Typescript` was turned
--- off -- is not stale: a real build would leave it exactly where it is.

---- Imports ----

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local PathParser = require("../../Modules/Path")

---- Settings ----

--- `current` matches byte for byte, `stale` differs, `missing` is not a file at all.
export type Status = "current" | "stale" | "missing"

export type Entry = {
	--> Relative to the working directory when the file is inside it, as the caller will type it.
	Path: string,
	Status: Status,
	--> The first line that differs, counting from 1; nil unless `Status` is `stale`.
	Line: number?,
}

---- Constants ----

local Utility = {}

---- Private Functions ----

--- The path as the person who ran the command would name it: an output path is resolved against the
--- schema's directory, so a schema given by absolute path yields absolute outputs, which read badly
--- in a list of stale files. Inside the working directory it is shortened; outside, left whole.
local function Display(Path: string): string
	local Normalised = PathParser.Normalise(Path)
	local Cwd = PathParser.Normalise(process.cwd)
	if PathParser.PathType(Normalised) == "absolute" and string.sub(Normalised, 1, #Cwd + 1) == `{Cwd}/` then
		return string.sub(Normalised, #Cwd + 2)
	end

	return Normalised
end

--- The first line, counting from 1, on which two different texts disagree. When one text is the
--- other with more lines after it, that is the first line past the shorter one.
local function FirstDifference(Old: string, New: string): number
	local OldLines = string.split(Old, "\n")
	local NewLines = string.split(New, "\n")
	for Index = 1, math.max(#OldLines, #NewLines) do
		if OldLines[Index] ~= NewLines[Index] then
			return Index
		end
	end

	--> Unreachable for two texts that differ, since splitting on "\n" loses nothing; kept total.
	return 1
end

---- Public Functions ----

--- Compares one would-be output with the file at its path. Reads, never writes.
function Utility.Compare(Path: string, Contents: string): Entry
	local Shown = Display(Path)
	if not fs.isFile(Path) then
		return { Path = Shown, Status = "missing" }
	end

	local OnDisk = fs.readFile(Path)
	if OnDisk == Contents then
		return { Path = Shown, Status = "current" }
	end

	return { Path = Shown, Status = "stale", Line = FirstDifference(OnDisk, Contents) }
end

--- Whether every compared file matched. An empty list did not compare anything, so it is not a pass.
function Utility.Passed(Entries: { Entry }): boolean
	if #Entries == 0 then
		return false
	end

	for _, Entry in Entries do
		if Entry.Status ~= "current" then
			return false
		end
	end

	return true
end

--- The rendered report. Stale and missing files are printed even under `--quiet`: they are the one
--- thing the caller asked for, and a hook that fails with nothing printed is a hook nobody can fix.
function Utility.Print(Entries: { Entry }, Silent: boolean)
	local Failed = 0
	for _, Entry in Entries do
		if Entry.Status == "current" then
			continue
		end

		Failed += 1
		local Where = if Entry.Line then ` (first difference on line {Entry.Line})` else ""
		print(`{stdio.color("red")}{Entry.Status}: {Entry.Path}{Where}{stdio.color("reset")}`)
	end

	if Failed > 0 then
		print(`{Failed} of {#Entries} generated files do not match the schema. Compile it again to update them.`)
	elseif not Silent then
		print(`{stdio.color("green")}All {#Entries} generated files match the schema.{stdio.color("reset")}`)
	end
end

return Utility
