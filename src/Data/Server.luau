--!strict

--[[
	Branch.Data.Server — player data on top of DataService/ProfileStore.

	What it adds over calling DataService directly:
	  * one Start call, no Networker/ProfileStore wiring;
	  * dot paths ("stats.kills") with generated autocomplete, parsed once;
	  * writes are checked against the template, so a typo or a wrong type
	    can never be saved into a player's profile;
	  * Increment / Update / Observe / Await / OnLoaded for the everyday cases;
	  * reads before the profile loads return nil instead of erroring;
	  * versioned migrations that run before the client ever sees the data;
	  * leaderstats that mirror data paths automatically;
	  * the session lock is released if a player leaves mid-load.

		local Data = Branch.Data.Server
		Data.Start({ Template = { coins = 0, stats = { kills = 0 } }, Leaderstats = { "coins" } })
		Data.Increment(player, "stats.kills")
		Data.Observe(player, "coins", function(new, old) end)
]]

local Players = game:GetService("Players")

local Types = require(script.Parent.Parent.Types)
local DataService = require(script.Parent.DataService)
local Path = require(script.Parent.Path)

type DataPath = Types.DataPath
type PlayerData = Types.PlayerData

export type Config = {
	Template: { [string]: any },
	Store: string?, -- ProfileStore name (default "PlayerData")
	KeyPrefix: string?, -- DataStore key prefix (default "PLAYER_")
	Mock: boolean?, -- keep data in memory only (tests)
	DontSave: boolean?, -- load real data but never write it
	Migrations: { (data: any) -> () }?, -- Migrations[n] upgrades version n-1 -> n
	Leaderstats: ({ string } | { [string]: string })?, -- paths (display = last segment) or path -> display name
}

local service = DataService.server
local Server = {}

local started = false
local template: { [string]: any } = {}
local loaded: { [Player]: any } = {}
local announced: { [Player]: boolean } = {} -- OnLoaded already ran for them
local waiting: { [Player]: { thread } } = {}
local loadedCallbacks: { (Player, any) -> () } = {}

local function announce(player: Player, data: any)
	if loaded[player] ~= data then
		return -- left (or reloaded) before we got here
	end
	announced[player] = true
	local threads = waiting[player]
	if threads then
		waiting[player] = nil
		for _, thread in threads do
			task.spawn(thread, data)
		end
	end
	for _, callback in table.clone(loadedCallbacks) do
		task.spawn(callback, player, data)
	end
end

local function requireLoaded(player: Player, action: string): any
	local data = loaded[player]
	if data == nil then
		error(`Branch.Data: {action} for {player.Name} before their data loaded; use Data.Await(player) or Data.OnLoaded`, 3)
	end
	return data
end

local function leaderstatsList(spec: any): { { path: string, name: string } }
	local list = {}
	if #spec > 0 then
		for _, path in spec do
			local parts = Path.parse(path)
			table.insert(list, { path = path, name = tostring(parts[#parts]) })
		end
	else
		for path, name in spec do
			table.insert(list, { path = path, name = name })
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
	end
	return list
end

local function bindLeaderstats(list: { { path: string, name: string } })
	Server.OnLoaded(function(player: Player)
		local folder = player:FindFirstChild("leaderstats") or Instance.new("Folder")
		folder.Name = "leaderstats"
		for _, stat in list do
			local current = Server.Get(player, stat.path)
			-- numbers use NumberValue: an IntValue would cut 2.5 down to 2 later
			local className = if type(current) == "number"
				then "NumberValue"
				elseif type(current) == "boolean" then "BoolValue"
				else "StringValue"
			local existing = folder:FindFirstChild(stat.name)
			local value: any
			if existing and existing.ClassName == className then
				value = existing -- the game made it already: drive that one
			elseif existing then
				warn(`[Branch.Data] leaderstats.{stat.name} already exists as a {existing.ClassName}; it is left alone`)
				continue
			else
				value = Instance.new(className)
				value.Name = stat.name
				value.Parent = folder
			end
			Server.Observe(player, stat.path, function(new)
				value.Value = if className == "StringValue" then tostring(new) else new
			end)
		end
		folder.Parent = player
	end)
end

function Server.Start(config: Config)
	assert(not started, "Branch.Data.Server.Start was already called")
	assert(type(config) == "table" and type(config.Template) == "table", "Branch.Data.Server.Start needs { Template = { ... } }")
	started = true
	template = config.Template

	local migrations = config.Migrations or {}
	local latest = #migrations

	local function deepCopy(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local copy = {}
		for key, item in value do
			copy[key] = deepCopy(item)
		end
		return copy
	end

	-- Runs inside DataService right after the profile loads and before the
	-- client receives its copy, so migrations are invisible to players.
	-- They run on a copy that replaces the data only when every step
	-- succeeded: a migration that throws halfway leaves the saved data as it
	-- was (and the player is asked to rejoin), never half-upgraded.
	local hooks: any = service
	hooks.onPlayerInit = function(self: any, player: Player, data: any)
		if latest > 0 then
			local profile = self:getProfile(player)
			local meta = profile.RobloxMetaData
			local version = if type(meta) == "table" then meta.BranchDataVersion else nil
			if version == nil and profile.SessionLoadCount <= 1 then
				version = latest -- brand-new profile: already in the newest shape
			end
			local from = (version or 0) + 1
			if from <= latest then
				local copy = deepCopy(data)
				local current = from
				local ok, problem = pcall(function()
					for index = from, latest do
						current = index
						migrations[index](copy)
					end
				end)
				if not ok then
					task.spawn(error, `[Branch.Data] Migrations[{current}] failed for {player.Name}: {problem}. Their saved data was left untouched.`, 0)
					player:Kick("Your saved data could not be upgraded right now. Please rejoin later.")
					return
				end
				table.clear(data)
				for key, value in copy do
					data[key] = value
				end
			end
			if type(meta) == "table" then
				meta.BranchDataVersion = latest
			end
		end
		loaded[player] = data
		task.defer(announce, player, data)
	end

	-- Released on the next resumption point, together with the profile, so
	-- segments' PlayerRemoving hooks can still Get/Set/Increment the leaving
	-- player's data (it is saved with the session).
	Players.PlayerRemoving:Connect(function(player: Player)
		task.defer(function()
			loaded[player] = nil
			announced[player] = nil
			local threads = waiting[player]
			if threads then
				waiting[player] = nil
				for _, thread in threads do
					task.spawn(thread, nil)
				end
			end
		end)
	end)

	service:init({
		template = config.Template,
		profileStoreIndex = config.Store or "PlayerData",
		profileStoreDataPrefix = config.KeyPrefix,
		useMock = config.Mock,
		dontSave = config.DontSave,
	})

	if config.Leaderstats then
		bindLeaderstats(leaderstatsList(config.Leaderstats))
	end
end

-- Value at `path`, or the whole data table. nil until the profile loads.
function Server.Get(player: Player, path: DataPath?): any
	local data = loaded[player]
	if data == nil or path == nil then
		return data
	end
	return Path.read(data, Path.parse(path :: any))
end

function Server.Set(player: Player, path: DataPath, value: any)
	local data = requireLoaded(player, "Set")
	local parts = Path.parse(path :: any)
	Path.check(template, parts, value)
	service:set(player, Path.resolve(data, parts) :: any, value)
end

function Server.Update(player: Player, path: DataPath, transform: (old: any) -> any): any
	local data = requireLoaded(player, "Update")
	local parts = Path.parse(path :: any)
	local new = transform(Path.read(data, parts))
	Path.check(template, parts, new)
	service:set(player, Path.resolve(data, parts) :: any, new)
	return new
end

function Server.Increment(player: Player, path: DataPath, delta: number?): number
	local data = requireLoaded(player, "Increment")
	local parts = Path.parse(path :: any)
	local current = Path.read(data, parts)
	if type(current) ~= "number" then
		error(`Branch.Data: cannot Increment "{Path.format(parts)}" ({typeof(current)})`, 2)
	end
	local new = current + (delta or 1)
	Path.assertFinite(parts, new, 2)
	service:set(player, Path.resolve(data, parts) :: any, new)
	return new
end

function Server.Insert(player: Player, path: DataPath, value: any, index: number?)
	local data = requireLoaded(player, "Insert")
	local parts = Path.parse(path :: any)
	Path.checkElement(template, parts, value)
	service:arrayInsert(player, Path.resolve(data, parts) :: any, value, index)
end

function Server.Remove(player: Player, path: DataPath, index: number): any
	local data = requireLoaded(player, "Remove")
	return service:arrayRemove(player, Path.resolve(data, Path.parse(path :: any)) :: any, index)
end

-- Calls `callback(value, old)` now (if loaded) and after every change.
-- Returns a function that stops observing.
function Server.Observe(player: Player, path: DataPath, callback: (new: any, old: any) -> ()): () -> ()
	local parts = Path.parse(path :: any)
	local connection: any = nil
	local stopped = false

	local function attach()
		if stopped or loaded[player] == nil then
			return
		end
		callback(Path.read(loaded[player], parts), nil)
		connection = service:getChangedSignal(player, Path.resolve(loaded[player], parts) :: any):Connect(callback)
	end

	if loaded[player] ~= nil then
		attach()
	else
		task.spawn(function()
			if Server.Await(player) ~= nil then
				attach()
			end
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

-- Yields until the player's data is ready. Returns nil if they leave first.
function Server.Await(player: Player): PlayerData?
	local data = loaded[player]
	if data ~= nil then
		return data
	end
	if player.Parent ~= Players then
		return nil
	end
	local threads = waiting[player]
	if not threads then
		threads = {}
		waiting[player] = threads
	end
	table.insert(threads, coroutine.running())
	return coroutine.yield()
end

function Server.IsLoaded(player: Player): boolean
	return loaded[player] ~= nil
end

-- Runs for every player whose data is already loaded, then for each new load.
function Server.OnLoaded(callback: (player: Player, data: PlayerData) -> ()): () -> ()
	table.insert(loadedCallbacks, callback)
	-- Only players already announced: one loaded but not yet announced gets
	-- this callback from the announcement itself (never twice).
	for player, data in loaded do
		if announced[player] then
			task.spawn(callback, player, data)
		end
	end
	return function()
		local index = table.find(loadedCallbacks, callback)
		if index then
			table.remove(loadedCallbacks, index)
		end
	end
end

-- Reads an offline player's saved data (no session lock). Yields.
function Server.Peek(userId: number): PlayerData?
	local profile = service:asyncGetProfile(userId)
	return if profile then profile.Data else nil
end

-- Wipes the player's profile and kicks them so the next join starts fresh.
function Server.Reset(player: Player)
	service:resetData(player)
end

-- Cross-server message to a player's profile (delivered when they are online).
function Server.Send(userId: number, key: string, payload: { any }): boolean
	return service:sendGlobalMessage(key, userId, payload)
end

function Server.OnMessage(key: string, handler: (player: Player, payload: { any }) -> boolean?)
	service:addGlobalCallback(key, handler)
end

-- Escape hatch: the underlying DataService / ProfileStore profile.
function Server.GetProfile(player: Player): any
	return if service:hasProfile(player) then service:getProfile(player) else nil
end

return table.freeze(Server)
