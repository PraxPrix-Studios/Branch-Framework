local Helper = require(script.Helper)
local PlayerService = { helper = Helper.value }
function PlayerService:Init() table.insert(_G.log, "PlayerService:Init") end
return PlayerService
