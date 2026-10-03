local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../upstream/Server")
end
return require("../upstream/Client")
