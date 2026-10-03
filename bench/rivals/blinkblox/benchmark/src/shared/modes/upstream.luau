--> Upstream Blink, the project BlinkBlox forked from, at its last release on main. Its definition is
--> definitions/Definition.upstream.blink, compiled by upstream's own compiler.
local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../upstream/Server")
elseif RunService:IsClient() then
	return require("../upstream/Client")
end
