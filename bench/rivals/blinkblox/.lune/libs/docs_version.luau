--!strict
--> The version as the docs print it. Two spellings carry it: the rokit pin, `XopoIII/BlinkBlox@0.36.2`,
--> and the banner the CLI prints on a line of its own, `BlinkBlox 0.36.2`. Prose that names a release
--> ("the run was made on BlinkBlox 0.36.2") is history rather than a pin, and neither pattern matches it.
-->
--> The docs sat three minor releases behind the compiler before this existed: every page told a new
--> user to pin 0.33.0. scripts/check-versions.sh reads the same two spellings, so a pin `bump` missed
--> fails the build.
local fs = require("@lune/fs")
local log = require("./log")

local DOCS = "docs/src/content/docs"
local VERSION = "%d+%.%d+%.%d+"

--> Every page under the docs, in a fixed order so the log reads the same on every run.
local function pages(directory: string, found: { string })
	local entries = fs.readDir(directory)
	table.sort(entries)
	for _, entry in entries do
		local path = `{directory}/{entry}`
		if fs.isDir(path) then
			pages(path, found)
		elseif string.match(entry, "%.mdx?$") then
			table.insert(found, path)
		end
	end
end

--> One line at a time, so the banner pattern can require the version to end the line.
local function rewrite(contents: string, version: string): string
	local lines = string.split(contents, "\n")
	for index, line in lines do
		line = string.gsub(line, `XopoIII/BlinkBlox@{VERSION}`, `XopoIII/BlinkBlox@{version}`)
		line = string.gsub(line, `^(%s*)BlinkBlox {VERSION}(%s*)$`, `%1BlinkBlox {version}%2`)
		lines[index] = line
	end

	return table.concat(lines, "\n")
end

local function write_version(version: string)
	local found: { string } = {}
	pages(DOCS, found)

	for _, path in found do
		local contents = fs.readFile(path)
		local updated = rewrite(contents, version)
		if updated ~= contents then
			fs.writeFile(path, updated)
			log(`Updated the version pinned in {path} to {version}`)
		end
	end
end

return table.freeze({
	write_to = write_version,
})
