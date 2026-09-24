local Broken = {}
function Broken:Init() error("init boom") end
function Broken:Start() table.insert(_G.log, "Broken:Start SHOULD NOT RUN") end
return Broken
