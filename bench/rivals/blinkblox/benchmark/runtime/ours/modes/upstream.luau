--> Branch's workloads (definitions/Ours.upstream.blink) as upstream Blink compiles them.
if game:GetService("RunService"):IsServer() then
	return require("../upstream/Server")
end
return require("../upstream/Client")
