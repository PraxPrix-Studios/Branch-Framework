--!strict

---- Imports ----

---- Settings ----

---- Constants ----

local Utility = {}

---- Variables ----

---- Private Functions ----

---- Public Functions ----

function Utility.PathType(Path: string): "absolute" | "relative"
	-- on unix-based systems, '/' is root
	if string.sub(Path, 1, 1) == "/" then
		return "absolute"
	end

	-- on windows systems, it is %w:[\\/]
	if string.sub(Path, 2, 2) == ":" then
		return "absolute"
	end

	return "relative"
end

function Utility.Components(Path: string): (string?, string?, string?)
	local Filename: string?
	local Directory, FilenameExt, Extension = string.match(Path, "(.-)([^\\/]-%.?([^%.\\/]*))$")

	if FilenameExt then
		if FilenameExt == Extension then
			Extension = nil
			Filename = FilenameExt
		elseif Extension then
			Filename = string.sub(FilenameExt, 1, #FilenameExt - (#Extension + 1))
		end
	end

	return Directory, Filename, Extension
end

function Utility.Filename(Path: string): string?
	local _, Filename = Utility.Components(Path)
	return Filename
end

function Utility.Directory(Path: string): string?
	local Directory = Utility.Components(Path)
	return Directory
end

function Utility.Extension(Path: string): string?
	local _, _, Extension = Utility.Components(Path)
	return Extension
end

function Utility.NameWithExtension(Path: string): string?
	local _, Name, Extension = Utility.Components(Path)
	if Name and Extension then
		return `{Name}.{Extension}`
	end

	return
end

--- Collapses "." and ".." so that two spellings of one file compare equal.
---
--- An import path is resolved by concatenating it onto the importing file's directory, and that
--- directory is itself a resolved path, so a chain of imports produces ever longer spellings of the
--- same place: "Sources/Invalid/./A.blink", then "Sources/Invalid/.././B.blink", and so on. Left
--- uncollapsed those never compare equal, which defeats anything keyed on a file -- and the
--- concatenation grows without bound, so a cyclic import ends with the operating system refusing a
--- path that has outgrown its limit rather than with the cycle being reported.
---
--- A leading ".." is kept: there is nothing above the start of a relative path to cancel it with.
function Utility.Normalise(Path: string): string
	local Absolute = (string.sub(Path, 1, 1) == "/")
	local Segments: { string } = {}

	for Segment in string.gmatch(Path, "[^/]+") do
		if Segment == "." then
			continue
		end

		if Segment == ".." and #Segments > 0 and Segments[#Segments] ~= ".." then
			Segments[#Segments] = nil
			continue
		end

		table.insert(Segments, Segment)
	end

	local Joined = table.concat(Segments, "/")
	return if Absolute then `/{Joined}` else Joined
end

---- Initialization ----

---- Connections ----

return Utility
