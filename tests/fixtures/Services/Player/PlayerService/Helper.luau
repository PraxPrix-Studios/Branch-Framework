table.insert(_G.log, "Helper required")
return { value = 42, Init = function() table.insert(_G.log, "Helper:Init SHOULD NOT RUN") end }
