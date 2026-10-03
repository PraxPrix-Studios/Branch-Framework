--> Branch's generated network for one schema folder (Definition, DefinitionPack, Scenarios), as a
--> game gets it from Branch Studio: the server half and the client half beside their two remotes.
--> The server makes the remotes, the client waits for them. Returns the segment `Bench`'s events,
--> whose API matches BlinkBlox's: Fire / FireAll / On.
return function(Name: string)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	--> Studio's place keeps packages in ReplicatedStorage.Shared.Packages, the Lune world in ReplicatedStorage.
	local Shared = ReplicatedStorage:FindFirstChild("Shared")
	local Packages = if Shared then Shared:WaitForChild("Packages") else ReplicatedStorage
	local Folder = Packages:WaitForChild("branch"):WaitForChild(Name)
	if game:GetService("RunService"):IsServer() then
		if not Folder:FindFirstChild("Reliable") then
			local Reliable = Instance.new("RemoteEvent")
			Reliable.Name = "Reliable"
			Reliable.Parent = Folder
			local Unreliable = Instance.new("UnreliableRemoteEvent")
			Unreliable.Name = "Unreliable"
			Unreliable.Parent = Folder
		end
		return (require :: any)(Folder:WaitForChild("Server")).Services.Bench
	end
	return (require :: any)(Folder:WaitForChild("Client")).Services.Bench
end
