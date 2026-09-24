--!strict
-- Branch.Data: Branch.Data.Server on the server, Branch.Data.Client on clients.
-- Only the side you are on is loaded (ProfileStore never reaches clients' memory).

local RunService = game:GetService("RunService")

type Server = typeof(require(script.Server))
type Client = typeof(require(script.Client))

local function wrongSide(message: string): any
	return setmetatable({}, {
		__index = function()
			error(message, 2)
		end,
	})
end

local Data: { Server: Server, Client: Client, Path: typeof(require(script.Path)) }

if not RunService:IsRunning() then
	Data = {
		Server = wrongSide("Branch.Data only runs in a running game"),
		Client = wrongSide("Branch.Data only runs in a running game"),
		Path = require(script.Path),
	}
elseif RunService:IsServer() then
	Data = {
		Server = require(script.Server),
		Client = wrongSide("Branch.Data.Client is only available on the client"),
		Path = require(script.Path),
	}
else
	Data = {
		Server = wrongSide("Branch.Data.Server is only available on the server"),
		Client = require(script.Client),
		Path = require(script.Path),
	}
end

return table.freeze(Data)
