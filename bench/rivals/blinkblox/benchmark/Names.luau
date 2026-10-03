--!strict
--- What the published tables call each tool, and the order they list them in. The harness knows a
--- tool by its mode's file name, src/shared/modes/<id>.luau, and those ids are not names a reader
--- knows: `blink` is BlinkBlox, a mode named before the fork was renamed, and `upstream` is Blink,
--- the original project BlinkBlox forked from. The ids stay what `--tools` and the mode files use.
local Names = {}

Names.ORDER = { "roblox", "branch", "blink", "upstream", "zap", "bytenet", "packet", "quicknet", "warp" }

local DISPLAY: { [string]: string } = {
	roblox = "Roblox remotes",
	blink = "BlinkBlox",
	upstream = "Blink",
	zap = "zap",
	bytenet = "ByteNet",
	packet = "Packet",
	quicknet = "QuickNet",
	warp = "Warp",
	branch = "Branch",
}

function Names.Display(Id: string): string
	return DISPLAY[Id] or Id
end

--- `Ids` in ORDER, and any the list does not know after them, alphabetically.
function Names.Sort(Ids: { string }): { string }
	local Sorted = table.clone(Ids)
	table.sort(Sorted, function(A, B)
		local RankA = table.find(Names.ORDER, A) or math.huge
		local RankB = table.find(Names.ORDER, B) or math.huge
		if RankA ~= RankB then
			return RankA < RankB
		end
		return A < B
	end)
	return Sorted
end

return Names
