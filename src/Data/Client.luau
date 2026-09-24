--!strict

--[[
	Branch.Data.Client — read-only mirror of the local player's data.
	Starts listening as soon as it is required (no manual init call).

		local Data = Branch.Data.Client
		Data.Observe("coins", function(coins) label.Text = coins end)
		local data = Data.Await()
]]

local Types = require(script.Parent.Parent.Types)
local DataService = require(script.Parent.DataService)
local Path = require(script.Parent.Path)

type DataPath = Types.DataPath
type PlayerData = Types.PlayerData

local service = DataService.client
local Client = {}

local data: any = nil
local waiting: { thread } = {}
local loadedCallbacks: { (any) -> () } = {}

task.delay(15, function()
	if data == nil then
		warn("[Branch.Data] the client is still waiting for its data after 15 s; is Branch.Data.Server.Start called on the server?")
	end
end)

task.spawn(function()
	service:init()
	data = service:get()
	for _, thread in waiting do
		task.spawn(thread, data)
	end
	table.clear(waiting)
	for _, callback in loadedCallbacks do
		task.spawn(callback, data)
	end
end)

function Client.Get(path: DataPath?): any
	if data == nil or path == nil then
		return data
	end
	return Path.read(data, Path.parse(path :: any))
end

function Client.IsLoaded(): boolean
	return data ~= nil
end

function Client.Await(): PlayerData
	if data ~= nil then
		return data
	end
	table.insert(waiting, coroutine.running())
	return coroutine.yield()
end

function Client.OnLoaded(callback: (data: PlayerData) -> ())
	if data ~= nil then
		task.spawn(callback, data)
	else
		table.insert(loadedCallbacks, callback)
	end
end

-- Connects once the data exists (signals live on the loaded data object).
local function whenLoaded(connect: () -> any, onAttach: (() -> ())?): () -> ()
	local connection: any = nil
	local stopped = false

	local function attach()
		if stopped then
			return
		end
		if onAttach then
			onAttach()
		end
		connection = connect()
	end

	if data ~= nil then
		attach()
	else
		task.spawn(function()
			Client.Await()
			attach()
		end)
	end

	return function()
		stopped = true
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end
end

-- Calls `callback(value, old)` once loaded and after every change.
function Client.Observe(path: DataPath, callback: (new: any, old: any) -> ()): () -> ()
	local parts = Path.parse(path :: any)
	return whenLoaded(function()
		return service:getChangedSignal(Path.resolve(data, parts) :: any):Connect(callback)
	end, function()
		callback(Path.read(data, parts), nil)
	end)
end

function Client.OnInserted(path: DataPath, callback: (index: number, value: any) -> ()): () -> ()
	local parts = Path.parse(path :: any)
	return whenLoaded(function()
		return service:getArrayInsertedSignal(Path.resolve(data, parts) :: any):Connect(callback)
	end)
end

function Client.OnRemoved(path: DataPath, callback: (index: number, value: any) -> ()): () -> ()
	local parts = Path.parse(path :: any)
	return whenLoaded(function()
		return service:getArrayRemovedSignal(Path.resolve(data, parts) :: any):Connect(callback)
	end)
end

return table.freeze(Client)
