--!strict
--- The parts of Roblox World.luau hands the tools that are not instances: signals, the `task` library,
--- and the datatypes they build while loading. Each is as little as the tools touch, and no more.
local Mocks = {}

function Mocks.Signal()
	local Callbacks: { (...any) -> () } = {}
	local Self = {}

	function Self.Connect(_self, Callback: (...any) -> ())
		table.insert(Callbacks, Callback)
		return {
			Disconnect = function()
				local Index = table.find(Callbacks, Callback)
				if Index then
					table.remove(Callbacks, Index)
				end
			end,
		}
	end
	Self.Once = Self.Connect

	function Self.Fire(_self, ...)
		for _, Callback in table.clone(Callbacks) do
			Callback(...)
		end
	end

	function Self.Wait()
		error("The benchmark cannot wait on a signal")
	end

	return Self
end

local function Resume(Thread: thread, ...)
	local Success, Error = coroutine.resume(Thread, ...)
	if not Success then
		error(debug.traceback(Thread, tostring(Error)), 0)
	end
end

--- `task`, running a spawned thread at once and queueing a deferred one on `Deferred`, which
--- World.Drain runs.
function Mocks.Task(Deferred: { { any } })
	local Task = {}

	function Task.spawn(Callback: any, ...): thread
		local Thread = if type(Callback) == "thread" then Callback else coroutine.create(Callback)
		Resume(Thread, ...)
		return Thread
	end

	function Task.defer(Callback: any, ...): thread
		local Thread = if type(Callback) == "thread" then Callback else coroutine.create(Callback)
		table.insert(Deferred, table.pack(Thread, ...))
		return Thread
	end

	function Task.delay(_Seconds: number, Callback: any, ...): thread
		--> Only invocation timeouts are delayed, and the benchmark invokes nothing.
		return if type(Callback) == "thread" then Callback else coroutine.create(Callback)
	end

	function Task.cancel(_Thread: thread) end

	function Task.wait()
		error("The benchmark cannot wait")
	end

	return table.freeze(Task)
end

--- Runs every thread on `Deferred`, and whatever those defer in turn.
function Mocks.Drain(Deferred: { { any } })
	local Index = 1
	while Index <= #Deferred do
		local Entry = Deferred[Index]
		Resume(Entry[1], table.unpack(Entry, 2, (Entry :: any).n))
		Index += 1
	end
	table.clear(Deferred)
end

--> Only what the tools touch while loading: zap builds CFrames for its special cases, Packet lists
--> Enums and a Vector3 among its statics, and QuickNet negates axes for its CFrame alignments.
function Mocks.Enum()
	return setmetatable({}, {
		__index = function(Self, Key)
			local Member = { Kind = "Enum", Name = Key }
			rawset(Self, Key, Member)
			return Member
		end,
	})
end

local function Vector(Kind: string)
	local Metatable = {}
	local function new(...)
		return setmetatable({ Kind = Kind, ... }, Metatable)
	end
	function Metatable.__unm(Self)
		local Negated = {}
		for Index, Component in ipairs(Self) do
			Negated[Index] = -Component
		end
		return new(table.unpack(Negated))
	end
	return { new = new, zero = new(0, 0, 0), one = new(1, 1, 1), fromRGB = new }
end

Mocks.Vector3 = Vector("Vector3")
Mocks.Vector2 = Vector("Vector2")
Mocks.Color3 = Vector("Color3")

local function CFrame(...)
	return { Kind = "CFrame", ... }
end

Mocks.CFrame = {
	new = CFrame,
	Angles = CFrame,
	fromMatrix = CFrame,
	identity = CFrame(),
}

return Mocks
