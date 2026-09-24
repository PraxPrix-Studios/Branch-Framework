local Zeta = {}
function Zeta:Init() _G.zetaReady = true; table.insert(_G.log, "Zeta:Init") end
function Zeta:Heartbeat(dt) error("zeta hook boom") end
return Zeta
