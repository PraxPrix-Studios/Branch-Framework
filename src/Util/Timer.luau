--!optimize 2
--!native

-- Timer (from Branch 1). Same API; Branch 2 fixes:
--  * Resume continues from where Pause stopped (the paused time no longer
--    counts as elapsed, so a resumed timer does not finish early);
--  * IncrementTime re-sorts a running timer, so a longer timer no longer
--    holds back every timer due before it;
--  * Stop wakes threads waiting in :Wait(), and a finished/stopped timer
--    does not run its callbacks again;
--  * callbacks run in their own threads: one that errors is reported and
--    cannot break the scheduler; Wait() on a dead timer returns at once.

local Timer = {}

local TimerEnum = setmetatable({
	Running = "Running",
	Paused = "Paused",
	Finished = "Finished",
	Stopped = "Stopped",
	Dead = "Dead",
	Died = "Died"
}, {
	__index = function(_, key)
		return error(string.format("%s is not a valid member of %s", key, "TimerEnum"), 2)
	end,
	__newindex = function()
		return error("attempt to modify a readonly table", 2)
	end,
	__metatable = false,
	__tostring = "TimerEnum"
})

local TimerArrays = {}
local RunService = game:GetService("RunService")

local TimerClass = {}
TimerClass.__index = TimerClass

local SchedulerConnection

local function GetRemainingAt(TimerObject, Now)
	local Time = TimerObject.FrozenRemaining

	if Time == nil then
		Time = TimerObject.Length - (Now - TimerObject.Started)
	end

	return Time > 0 and Time or 0
end

local function StateCallback(TimerObject, State, ...)
	if not TimerObject.BotherChecking then
		return
	end

	for _, Function in next, TimerObject.CallbackStates[State] do
		task.spawn(Function, State, ...)
	end
end

local function WakeWaiting(TimerObject, State, Elapsed)
	local Threads = TimerObject.YieldedThreads
	TimerObject.YieldedThreads = {}

	for _, Thread in next, Threads do
		task.spawn(Thread, State, Elapsed)
	end
end

local function EndTimer(TimerObject, State, Elapsed)
	local Callback = TimerObject.Callback

	if Callback then
		task.spawn(Callback, State)
	end

	if TimerObject.BotherChecking then
		local CallbackStates = TimerObject.CallbackStates

		if State == TimerEnum.Stopped or State == TimerEnum.Finished then
			for _, StateName in next, {TimerEnum.Dead, TimerEnum.Died} do
				for _, Function in next, CallbackStates[StateName] do
					task.spawn(Function, StateName, Elapsed)
				end
			end
		end

		for _, Function in next, CallbackStates[State] do
			task.spawn(Function, State, Elapsed)
		end
	end

	TimerObject.State = TimerEnum.Dead
	TimerObject.EndState = State
	TimerObject.EndElapsed = Elapsed
	WakeWaiting(TimerObject, State, Elapsed)
end

local function ProcessTimers()
	local Now = time()

	while true do
		local DyingObj = TimerArrays[#TimerArrays]

		if DyingObj == nil or GetRemainingAt(DyingObj, Now) > 0 then
			break
		end

		TimerArrays[#TimerArrays] = nil
		EndTimer(DyingObj, TimerEnum.Finished, Now - DyingObj.Started)
	end

	if #TimerArrays == 0 and SchedulerConnection then
		SchedulerConnection:Disconnect()
		SchedulerConnection = nil
	end
end

-- Sorted by remaining time, soonest last.
local function FindBestSpot(CompletionTime, Now)
	local LeftIdx = 1
	local RightIdx = #TimerArrays

	while LeftIdx <= RightIdx do
		local CenterIdx = (LeftIdx + RightIdx) // 2
		local CenterRemaining = GetRemainingAt(TimerArrays[CenterIdx], Now)

		if CompletionTime > CenterRemaining then
			RightIdx = CenterIdx - 1
		else
			LeftIdx = CenterIdx + 1
		end
	end

	return LeftIdx
end

local function AddToArray(TimerObj, Now)
	table.insert(TimerArrays, FindBestSpot(GetRemainingAt(TimerObj, Now), Now), TimerObj)

	if not SchedulerConnection then
		SchedulerConnection = RunService.PreSimulation:Connect(ProcessTimers)
	end
end

local function RemoveFromArray(TimerObj)
	local Index = table.find(TimerArrays, TimerObj)

	if Index then
		table.remove(TimerArrays, Index)
	end

	if #TimerArrays == 0 and SchedulerConnection then
		SchedulerConnection:Disconnect()
		SchedulerConnection = nil
	end
end

function TimerClass:GetLength()
	return self.Length
end

function TimerClass:GetRemaining()
	return GetRemainingAt(self, time())
end

function TimerClass:GetState()
	return self.State
end

for _, Enum in next, TimerEnum do
	TimerClass["Is" .. Enum] = function(self)
		assert(self, "Expected ':' not '.' calling member function Is" .. Enum)
		return self.State == Enum
	end
end

-- Starts (or restarts) the timer with its full length.
function TimerClass:Start()
	RemoveFromArray(self)

	local Started = time()
	self.Started = Started
	self.FrozenRemaining = nil
	self.EndState = nil
	self.EndElapsed = nil
	AddToArray(self, Started)
	self.State = TimerEnum.Running
	StateCallback(self, self.State, self:GetRemaining())
end

-- Yields until the timer finishes or is stopped; returns (state, elapsed).
function TimerClass:Wait()
	if self.State == TimerEnum.Dead then
		return self.EndState or TimerEnum.Dead, self.EndElapsed or 0
	end
	table.insert(self.YieldedThreads, coroutine.running())
	return coroutine.yield()
end

function TimerClass:Pause()
	if self.State ~= TimerEnum.Running then
		return
	end
	local Now = time()
	self.FrozenRemaining = GetRemainingAt(self, Now)
	RemoveFromArray(self)
	self.State = TimerEnum.Paused
	StateCallback(self, self.State, Now - self.Started)
end

function TimerClass:Resume()
	assert(self.State == TimerEnum.Paused, "Attempt to resume a non-frozen timer (State: " .. self.State .. ")")

	-- continue from the frozen remaining time: the pause does not count
	local Now = time()
	self.Started = Now - (self.Length - (self.FrozenRemaining or self.Length))
	self.FrozenRemaining = nil
	AddToArray(self, Now)
	self.State = TimerEnum.Running
	StateCallback(self, self.State, Now - self.Started)
end

function TimerClass:Stop()
	if self.State ~= TimerEnum.Running and self.State ~= TimerEnum.Paused then
		return -- already finished or stopped: nothing runs twice
	end

	self.State = TimerEnum.Stopped
	RemoveFromArray(self)
	EndTimer(self, TimerEnum.Stopped, time() - self.Started)
end

function TimerClass:IncrementTime(Delta)
	self.Length += Delta

	if self.State == TimerEnum.Running then
		-- re-sort: the queue is ordered by remaining time
		RemoveFromArray(self)
		AddToArray(self, time())
	elseif self.State == TimerEnum.Paused and self.FrozenRemaining then
		self.FrozenRemaining = math.max(self.FrozenRemaining + Delta, 0)
	end
end

TimerClass.Yield = TimerClass.Wait
TimerClass.Play = TimerClass.Start
TimerClass.Cancel = TimerClass.Stop
TimerClass.Kill = TimerClass.Stop

for State in next, TimerEnum do
	TimerClass["On" .. State] = function(self, f)
		assert(type(f) == "function", "Invalid argument #1 to On" .. State .. " (function expected, got " .. typeof(f) .. ")")
		self.BotherChecking = true
		table.insert(self.CallbackStates[State], f)
	end
end

Timer.new = function(Wait)
	assert(type(Wait) == "number" and Wait == Wait, "Timer.new expects a length in seconds")
	local CallbackStates = {}

	for State in next, TimerEnum do
		CallbackStates[State] = {}
	end

	return setmetatable({
		Length = Wait,
		Started = time(),
		State = TimerEnum.Paused,
		YieldedThreads = {},
		CallbackStates = CallbackStates
	}, TimerClass)
end

Timer.Enums = TimerEnum

function Timer:GetEnums()
	return TimerEnum
end

return Timer
