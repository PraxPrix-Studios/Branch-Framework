--!strict
--- Reads a schema file for whichever target the compiler is running on.
---
--- Dual-target, like the lexer and the parser that use it: on Lune the schema is a file on disk, and
--- inside Roblox it is a StringValue under a folder in ServerStorage, reached by splitting the
--- dotted path the schema wrote. The branch is on `task`, the same test the parser uses.
---
--- Extracted from Parser.luau, which is over its recorded line budget and may only shrink.

---- Imports ----

local PathParser = require("./Path")

---- Constants ----

local Utility = {}

---- Public Functions ----

--- Returns the source, the directory it was found in, and the RESOLVED path.
---
--- The third is what Parser.Import keys its in-flight set on: an import path is written relative to
--- whichever file wrote it, so two files importing each other name the same file two different ways
--- and only the resolved, normalised form matches up.
function Utility.Read(Path: string, Directory: string): (string?, string?, string?)
	local IsROBLOX = (task ~= nil)
	if IsROBLOX then
		--> `FindFirstChild` rather than an index: the loop below already treats a missing level as
		--> "give up and return nil", and indexing would raise instead of producing that nil.
		local Parent: Instance? = game:GetService("ServerStorage"):FindFirstChild("BLINK_CONFIGURATION_FILES")
		local Indices = string.split(Path, ".")
		for _, Index in Indices do
			if not Parent then
				break
			end

			Parent = Parent:FindFirstChild(Index)
		end

		return (Parent ~= nil and Parent:IsA("StringValue")) and Parent.Value or nil, "", Path
	end

	local fs = require("@lune/fs")
	local GetDefinitionFilePath = require("../CLI/Utility/GetDefinitionFilePath")

	if PathParser.PathType(Path) == "relative" then
		Path = `{Directory}{Path}`
	end
	Path = GetDefinitionFilePath(Path)

	if not fs.isFile(Path) then
		return
	end

	local FileDirectory = PathParser.Directory(Path) or "./"
	return fs.readFile(Path), FileDirectory, Path
end

return Utility
