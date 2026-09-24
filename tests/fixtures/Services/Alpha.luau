local Alpha = { Dependencies = { "Zeta" } }
function Alpha:Init() table.insert(_G.log, "Alpha:Init after Zeta=" .. tostring(_G.zetaReady)) end
function Alpha:Start() table.insert(_G.log, "Alpha:Start") end
function Alpha:PlayerAdded(player) table.insert(_G.log, "Alpha:PlayerAdded " .. player.Name) end
function Alpha:Heartbeat(dt) _G.beats += 1 end
return Alpha
