--> Branch's workloads (definitions/Ours.blink) as BlinkBlox compiles them; Ours.luau compiles them.
if game:GetService("RunService"):IsServer() then
	return require("../blink/Server")
end
return require("../blink/Client")
