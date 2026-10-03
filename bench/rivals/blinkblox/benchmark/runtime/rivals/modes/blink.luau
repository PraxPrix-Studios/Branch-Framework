local RunService = game:GetService("RunService")
if RunService:IsServer() then
	return require("../blink/Server")
end
return require("../blink/Client")
