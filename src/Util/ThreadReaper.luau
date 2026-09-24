--!strict
--!native
--!optimize 2

--[[
    Thread Handler(Type of) & Recycler
    @divine.no
    
    usage is similiar to native
]]

export type ThreadLibrary = {
	Spawn: <A..., R...>(Callback: (A...) -> R..., A...) -> (),
	Defer: <A..., R...>(Callback: (A...) -> R..., A...) -> (),
	Delay: <A..., R...>(Duration: number, Callback: (A...) -> R..., A...) -> number,
	Timeout: <A..., R...>(Duration: number, Callback: (A...) -> R..., A...) -> number,
	Cancel: (Token: number) -> boolean,
	Reserve: (Count: number) -> (),
}

type AnyCallback = (...unknown) -> ...unknown
type PackedArguments = { n: number, [number]: unknown }
type ResumeFunction = (Thread: thread, ...unknown) -> (unknown, unknown)

local EngineResume: boolean = false

local Max_Idle: number = 65536

local Queue_Presize: number = 1024

local TokenRadix: number = 2 ^ 21
local TokenSerials: number = 2 ^ 32

local DeadoThreat: string = "cannot resume dead coroutine"

local Resume: ResumeFunction = (if EngineResume then task.spawn else coroutine.resume) :: any

local Hot: thread? = nil
local Pool: { thread } = {}
local Idle: number = 0

local Queue: { unknown } = table.create(Queue_Presize)
local Spare: { unknown } = table.create(Queue_Presize)
local Tail: number = 0
local Scheduled: boolean = false
local DrainBuffer: { unknown } = Spare
local DrainHead: number = 0
local DrainTail: number = 0
local Epoch: number = 0

local SlotToken: { number } = {}
local SlotCallback: { unknown } = {}
local SlotArity: { number } = {}
local SlotFirst: { unknown } = {}
local SlotSecond: { unknown } = {}
local SlotThird: { unknown } = {}
local SlotRest: { unknown } = {}
local FreeSlots: { number } = {}
local FreeSlotCount: number = 0
local SlotHighWater: number = 0
local Serial: number = 0

local RunDue: { number } = {}
local RunToken: { number } = {}
local RunHead: number = 1
local RunTail: number = 0
local HeapDue: { number } = {}
local HeapToken: { number } = {}
local HeapSize: number = 0

local Armed: { number } = {}
local ArmedCount: number = 0
local TimerLimit: number = -1
local TimerEpoch: number = 0

local function Report(Thread: thread, Message: unknown): ()
	task.spawn(error, debug.traceback(Thread, tostring(Message)), 0)
end

local function Execute<A..., R...>(Callback: (A...) -> R..., ...: A...): ()
	Callback(...)
end

local function Runner(Self: thread): ()
	while true do
		Execute(coroutine.yield())
		if Hot == nil then
			Hot = Self
		else
			local Index = Idle
			if Index >= Max_Idle then
				return
			end
			Index += 1
			Idle = Index
			Pool[Index] = Self
		end
	end
end

local function Create(): thread
	local Thread = coroutine.create(Runner)
	coroutine.resume(Thread, Thread)
	return Thread
end

local function Acquire(): thread
	local Thread = Hot
	if Thread then
		Hot = nil
		return Thread
	end
	local Index = Idle
	if Index > 0 then
		local Parked = Pool[Index]
		Pool[Index] = nil
		Idle = Index - 1
		return Parked
	end
	return Create()
end

local function AcquireLive(): thread
	local Thread = Acquire()
	while coroutine.status(Thread) ~= "suspended" do
		Thread = Acquire()
	end
	return Thread
end

local function Recover<A..., R...>(Thread: thread, Message: unknown, Callback: (A...) -> R..., ...: A...): ()
	if Message ~= DeadoThreat then
		Report(Thread, Message)
		return
	end
	local Fresh = AcquireLive()
	local Ok, Again = Resume(Fresh, Callback, ...)
	if not Ok then
		Report(Fresh, Again)
	end
end

local function Spawn<A..., R...>(Callback: (A...) -> R..., ...: A...): ()
	local Thread = Acquire()
	local Ok, Message = Resume(Thread, Callback, ...)
	if not Ok then
		Recover(Thread, Message, Callback, ...)
	end
end

local function Drain(): ()
	local Mine = Epoch
	local Buffer = DrainBuffer
	local Last = DrainTail
	local Index = DrainHead
	while Index < Last do
		local Callback = Buffer[Index + 1] :: AnyCallback
		local Count = Buffer[Index + 2] :: number
		local Next = Index + 2 + Count
		DrainHead = Next
		if Count == 0 then
			Callback()
		elseif Count == 1 then
			Callback(Buffer[Next])
		elseif Count == 2 then
			Callback(Buffer[Index + 3], Buffer[Next])
		elseif Count == 3 then
			Callback(Buffer[Index + 3], Buffer[Index + 4], Buffer[Next])
		else
			Callback(table.unpack(Buffer, Index + 3, Next))
		end
		if Epoch ~= Mine then
			return
		end
		Index = Next
	end
end

local function DrainWith<A..., R...>(Callback: (A...) -> R..., ...: A...): ()
	local Mine = Epoch
	Callback(...)
	if Epoch ~= Mine then
		return
	end
	Drain()
end

local function Lead<A..., R...>(Callback: (A...) -> R..., ...: A...): ()
	Scheduled = false
	local Used = Tail
	if Used == 0 then
		Callback(...)
		return
	end

	local Buffer = Queue
	Queue = Spare
	Spare = Buffer
	Tail = 0
	DrainBuffer = Buffer
	DrainHead = 0
	DrainTail = Used

	Epoch += 1
	local Thread = AcquireLive()
	local Ok, Message = Resume(Thread, DrainWith, Callback, ...)
	if not Ok then
		Report(Thread, Message)
	end
	while DrainHead < Used do
		Epoch += 1
		Thread = AcquireLive()
		Ok, Message = Resume(Thread, Drain)
		if not Ok then
			Report(Thread, Message)
		end
	end
	Epoch += 1

	for Index = 1, Used do
		Buffer[Index] = nil
	end
end

local function Defer<A..., R...>(Callback: (A...) -> R..., ...: A...): ()
	if not Scheduled then
		Scheduled = true
		task.defer(AcquireLive(), Lead, Callback, ...)
		return
	end

	local Count = select("#", ...)
	local Buffer = Queue
	local Index = Tail
	Buffer[Index + 1] = Callback
	Buffer[Index + 2] = Count
	for Offset = 1, Count do
		Buffer[Index + 2 + Offset] = (select(Offset, ...))
	end
	Tail = Index + 2 + Count
end

local function HeapPush(Due: number, Token: number): ()
	local Index = HeapSize + 1
	HeapSize = Index
	while Index > 1 do
		local Parent = Index // 2
		local ParentDue = HeapDue[Parent]
		if ParentDue < Due or (ParentDue == Due and HeapToken[Parent] < Token) then
			break
		end
		HeapDue[Index] = ParentDue
		HeapToken[Index] = HeapToken[Parent]
		Index = Parent
	end
	HeapDue[Index] = Due
	HeapToken[Index] = Token
end

local function HeapPop(): ()
	local Size = HeapSize
	local Due = HeapDue[Size]
	local Token = HeapToken[Size]
	HeapDue[Size] = nil
	HeapToken[Size] = nil
	Size -= 1
	HeapSize = Size
	if Size == 0 then
		return
	end
	local Index = 1
	while true do
		local Child = Index * 2
		if Child > Size then
			break
		end
		local ChildDue = HeapDue[Child]
		if Child < Size then
			local OtherDue = HeapDue[Child + 1]
			if OtherDue < ChildDue or (OtherDue == ChildDue and HeapToken[Child + 1] < HeapToken[Child]) then
				Child += 1
				ChildDue = OtherDue
			end
		end
		if Due < ChildDue or (Due == ChildDue and Token < HeapToken[Child]) then
			break
		end
		HeapDue[Index] = ChildDue
		HeapToken[Index] = HeapToken[Child]
		Index = Child
	end
	HeapDue[Index] = Due
	HeapToken[Index] = Token
end

local function PopDue(Limit: number): number
	while true do
		local Head = RunHead
		local FromRun = Head <= RunTail
		local Due: number
		local Token: number
		if FromRun then
			Due = RunDue[Head]
			Token = RunToken[Head]
			if HeapSize > 0 then
				local TopDue = HeapDue[1]
				if TopDue < Due or (TopDue == Due and HeapToken[1] < Token) then
					FromRun = false
					Due = TopDue
					Token = HeapToken[1]
				end
			end
		elseif HeapSize > 0 then
			Due = HeapDue[1]
			Token = HeapToken[1]
		else
			return 0
		end
		if Due > Limit then
			return 0
		end
		if FromRun then
			Head += 1
			if Head > 1024 and Head * 2 > RunTail then
				local Live = RunTail - Head + 1
				table.move(RunDue, Head, RunTail, 1)
				table.move(RunToken, Head, RunTail, 1)
				Head = 1
				RunTail = Live
			end
			RunHead = Head
		else
			HeapPop()
		end
		local Slot = Token % TokenRadix
		if SlotToken[Slot] == Token then
			return Slot
		end
	end
end

local function Run(Slot: number): ()
	local Callback = SlotCallback[Slot] :: AnyCallback
	local Count = SlotArity[Slot]
	SlotToken[Slot] = 0
	SlotCallback[Slot] = nil
	local Free = FreeSlotCount + 1
	FreeSlotCount = Free
	FreeSlots[Free] = Slot
	if Count == 0 then
		Callback()
		return
	end
	local First = SlotFirst[Slot]
	SlotFirst[Slot] = nil
	if Count == 1 then
		Callback(First)
		return
	end
	local Second = SlotSecond[Slot]
	SlotSecond[Slot] = nil
	if Count == 2 then
		Callback(First, Second)
		return
	end
	local Third = SlotThird[Slot]
	SlotThird[Slot] = nil
	if Count == 3 then
		Callback(First, Second, Third)
		return
	end
	local Rest = SlotRest[Slot] :: PackedArguments
	SlotRest[Slot] = nil
	Callback(First, Second, Third, table.unpack(Rest, 1, Rest.n))
end

local function FireLoop(Slot: number): ()
	local Mine = TimerEpoch
	local Limit = TimerLimit
	repeat
		Run(Slot)
		if TimerEpoch ~= Mine then
			return
		end
		Slot = PopDue(Limit)
	until Slot == 0
end

local Wake: (ArmedFor: number) -> ()

local function Earliest(): number
	local Next = math.huge
	if RunHead <= RunTail then
		Next = RunDue[RunHead]
	end
	if HeapSize > 0 and HeapDue[1] < Next then
		Next = HeapDue[1]
	end
	return Next
end

local function Rearm(Next: number): ()
	local Top = ArmedCount
	if Next ~= math.huge and (Top == 0 or Next < Armed[Top]) then
		Top += 1
		ArmedCount = Top
		Armed[Top] = Next
		task.delay(math.max(Next - os.clock(), 0), AcquireLive(), Wake, Next)
	end
end

function Wake(ArmedFor: number): ()
	local Top = ArmedCount
	while Top > 0 and Armed[Top] <= ArmedFor do
		Armed[Top] = nil
		Top -= 1
	end
	ArmedCount = Top

	local Limit = math.max(os.clock(), ArmedFor)
	TimerLimit = Limit
	local Slot = PopDue(Limit)
	if Slot == 0 then
		Rearm(Earliest())
		return
	end

	local Next = Earliest()
	if Next > Limit then
		Rearm(Next)
		Run(Slot)
		return
	end

	repeat
		TimerEpoch += 1
		local Thread = AcquireLive()
		local Ok, Message = Resume(Thread, FireLoop, Slot)
		if not Ok then
			Report(Thread, Message)
		end
		Slot = PopDue(Limit)
	until Slot == 0
	TimerEpoch += 1
	Rearm(Earliest())
end

local function Delay<A..., R...>(Duration: number, Callback: (A...) -> R..., ...: A...): number
	-- NaN would break the ordering of every pending timer; negative means now
	if type(Duration) ~= "number" or Duration ~= Duration then
		error("Thread/Delay > Duration must be a number (got " .. tostring(Duration) .. ")", 2)
	end
	if Duration < 0 then
		Duration = 0
	end
	local Slot: number
	local Free = FreeSlotCount
	if Free > 0 then
		Slot = FreeSlots[Free]
		FreeSlotCount = Free - 1
	else
		Slot = SlotHighWater + 1
		if Slot >= TokenRadix then
			error("Thread/Delay > more than 2^21 timers pending at once", 2)
		end
		SlotHighWater = Slot
	end

	local Stamp = (Serial + 1) % TokenSerials
	Serial = Stamp
	local Token = Stamp * TokenRadix + Slot

	local Count = select("#", ...)
	SlotToken[Slot] = Token
	SlotCallback[Slot] = Callback
	SlotArity[Slot] = Count
	if Count > 0 then
		SlotFirst[Slot] = (select(1, ...))
		if Count > 1 then
			SlotSecond[Slot] = (select(2, ...))
			if Count > 2 then
				SlotThird[Slot] = (select(3, ...))
				if Count > 3 then
					local Rest: PackedArguments = { n = Count - 3 }
					for Offset = 4, Count do
						Rest[Offset - 3] = (select(Offset, ...))
					end
					SlotRest[Slot] = Rest
				end
			end
		end
	end

	local Due = os.clock() + Duration
	if Due <= TimerLimit then
		Due = TimerLimit + 1e-6
	end

	local Last = RunTail
	if RunHead > Last then
		RunHead = 1
		RunTail = 1
		RunDue[1] = Due
		RunToken[1] = Token
	elseif Due >= RunDue[Last] then
		Last += 1
		RunTail = Last
		RunDue[Last] = Due
		RunToken[Last] = Token
	else
		HeapPush(Due, Token)
	end

	local Top = ArmedCount
	if Top == 0 or Due < Armed[Top] then
		Top += 1
		ArmedCount = Top
		Armed[Top] = Due
		task.delay(Duration, AcquireLive(), Wake, Due)
	end
	return Token
end

local function Cancel(Token: number): boolean
	local Slot = Token % TokenRadix
	if SlotToken[Slot] ~= Token then
		return false
	end
	SlotToken[Slot] = 0
	SlotCallback[Slot] = nil
	local Count = SlotArity[Slot]
	if Count > 0 then
		SlotFirst[Slot] = nil
		if Count > 1 then
			SlotSecond[Slot] = nil
			if Count > 2 then
				SlotThird[Slot] = nil
				SlotRest[Slot] = nil
			end
		end
	end
	local Free = FreeSlotCount + 1
	FreeSlotCount = Free
	FreeSlots[Free] = Slot
	local Last = RunTail
	if Last >= RunHead and RunToken[Last] == Token then
		RunTail = Last - 1
	end
	return true
end

local function Reserve(Count: number): ()
	local Target = math.min(math.floor(Count), Max_Idle)
	for Index = Idle + 1, Target do
		Pool[Index] = Create()
		Idle = Index
	end
end

return table.freeze({
	Spawn = Spawn,
	Defer = Defer,
	Delay = Delay,
	Timeout = Delay,
	Cancel = Cancel,
	Reserve = Reserve,
} :: ThreadLibrary)
