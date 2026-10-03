--!strict
return [[local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- SPLIT --
if not RunService:IsClient() then
    error("Client network module can only be required from the client.")
end

-- REMOTES --
local Reliable: RemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_RELIABLE_REMOTE") :: RemoteEvent
local Unreliable: UnreliableRemoteEvent = ReplicatedStorage:WaitForChild(BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE") :: UnreliableRemoteEvent
-- REMOTES --

--> WaitForChild returns whatever carries that name. A client can create an instance of any class in
--> ReplicatedStorage, so without this the first thing to answer to the name wins -- and every
--> outgoing packet is then handed to an object of the attacker's choosing.
assert(Reliable:IsA("RemoteEvent"), "[BlinkBlox]: The reliable remote is not a RemoteEvent.")
assert(Unreliable:IsA("UnreliableRemoteEvent"), "[BlinkBlox]: The unreliable remote is not an UnreliableRemoteEvent.")

--> Refuse to run against a server built from a different schema.
-->
--> Event ids are positional, so inserting an event renumbers every event after it. Without this the
--> two sides agree on nothing but the remote's NAME: a client one build behind reads index 7 as
--> whatever index 7 means now, decodes one event's payload as another's, and dispatches it. Nothing
--> errors, which is why this failure is usually found by its symptoms.
-->
--> Erroring at require time rather than warning and carrying on: a module that silently stops
--> sending is the very failure this removes, just relocated. It is also the house style -- the scope
--> guard errors, and both class checks above assert.
local Signature = Reliable:GetAttribute("SchemaSignature")
if Signature == nil then
    --> Absent when the server found its remote already in place and wrote the attribute after it had
    --> replicated. Bounded, because an attribute that never arrives means an older server rather than
    --> a slow one, and hanging is the diagnosis nobody can act on.
    local Waited = 0
    while Signature == nil and Waited < 5 do
        Waited += task.wait(0.1)
        Signature = Reliable:GetAttribute("SchemaSignature")
    end
end

if Signature == nil then
    error("[BlinkBlox]: The server did not publish a schema signature. It is running a build of BlinkBlox from before this check existed, or a different networking module created the remote.")
elseif Signature ~= SCHEMA_SIGNATURE then
    error(`[BlinkBlox]: This client was built from a different schema than the server (client {SCHEMA_SIGNATURE}, server {Signature}). Recompile both sides from the same .blink file.`)
end

--> Present so code shared between contexts can install a handler without branching on which module
--> it got. The client never rate limits: it is talking to the server, which is trusted.
local function SetRateLimitHandler(_Handler: ((Player: Player, Event: string?, Refused: number) -> ())?) end

--> The same for packets: only the server refuses them.
local function SetPacketDropHandler(
    _Handler: ((Player: Player, Reason: "Malformed" | "Oversized" | "Budget" | "Instances" | "Events", Refused: number, Detail: number) -> ())?
) end

--> And for listener errors. A listener on the client runs what the trusted server sent, so an error
--> there is the game's own bug with no hostile volume to bound and no player to name: it surfaces in
--> the output as it always has.
local function SetListenerErrorHandler(_Handler: ((Player: Player, Event: string, Failure: string, Count: number) -> ())?) end

--> A packet from the server that cannot be decoded is a bug in the game rather than an attack --
--> usually a Sync listener that yielded, or a client built from a different schema. It is said out
--> loud unless a handler takes it over, and either way it names the event and the error, because
--> "a packet could not be decoded" alone is what made the original report so hard to diagnose.
local DecodeHandler: ((Event: string?, Failure: string) -> ())? = nil

local function SetDecodeErrorHandler(Handler: ((Event: string?, Failure: string) -> ())?)
    DecodeHandler = Handler
end

local function ReportDecodeFailure(Event: string?, Failure: unknown)
    local Handler = DecodeHandler
    if Handler then
        Spawn(Handler, Event, tostring(Failure))
        return
    end

    warn(`[BlinkBlox]: Dropped a packet that could not be decoded, at event "{Event or "unknown"}": {Failure}`)
end

local SendUnderused = 0

--> The server refuses a packet past any of its limits and reports the player who sent it, and a game
--> may strike or ban on that report. A client that fires more in one frame than one packet may carry
--> -- after a hitch, or from a busy interface -- is not hostile, so its batch is cut into packets that
--> fit, each at an event's boundary. Most frames fit in one and pay a few comparisons an event; a
--> cut is recorded only where one is needed. An event too large to fit on its own goes in a packet
--> of its own, which the server refuses as it always did.
local PacketStart = 0
local PacketInstances = 0
local PacketEvents = 0
local Cuts: {number} = {}

--> Starts a new packet at the event that begins at `Start`, with `Instances` instances ahead of it,
--> unless it is the packet's first: an event too large on its own goes out alone.
local function Cut(Start: number, Instances: number)
    if Start > PacketStart then
        table.insert(Cuts, Start)
        table.insert(Cuts, Instances)
        PacketStart = Start
        PacketInstances = Instances
        PacketEvents = 1
    end
end

--> An event has been written into the batch from `Start`, with `Instances` instances ahead of it, by
--> a write that Mark began: a call, or a reply to one.
local function Close(Start: number, Instances: number)
    local Count = #SendInstances
    CommittedInstances = Count
    PacketEvents += 1
    if PacketEvents > MAX_EVENTS_PER_PACKET
        or SendCursor - PacketStart > MAX_PACKET_SIZE
        or Count - PacketInstances > MAX_INSTANCES_PER_PACKET
    then
        Cut(Start, Instances)
    end
end

--> The end of a Fire that Begin started, for an event that carries no Instance: the instance count is
--> what it was, and so is the instance cap. A Fire that can carry one writes its own end out; see
--> WriteBegun in Generator/Event.luau.
local function Commit()
    local Start = PendingCursor
    PendingCursor = -1
    PacketEvents += 1
    if PacketEvents > MAX_EVENTS_PER_PACKET or SendCursor - PacketStart > MAX_PACKET_SIZE then
        Cut(Start, CommittedInstances)
    end
end

local function SendPacket(From: number, To: number, FromInstances: number, ToInstances: number)
    local Buffer = buffer.create(To - From)
    buffer.copy(Buffer, 0, SendBuffer, From, To - From)
    Reliable:FireServer(Buffer, table.move(SendInstances, FromInstances + 1, ToInstances, 1, {}))
end

--> The last frame's packet, filled again when the next is the same size. A remote serialises what it
--> is fired with as it is called, so nothing still reads it; a new buffer every frame was an
--> allocation, zero-filled, the size of the frame's traffic, and a flush of a thousand events cost
--> several times QuickNet's, which keeps its buffers.
local LastPacket: buffer? = nil

local function StepReplication()
    Settle()
    local Used = SendCursor
    if Used > 0 then
        if #Cuts == 0 then
            local Buffer: buffer
            local Last = LastPacket
            if Last ~= nil and buffer.len(Last) == Used then
                Buffer = Last
            else
                Buffer = buffer.create(Used)
                LastPacket = Buffer
            end
            buffer.copy(Buffer, 0, SendBuffer, 0, Used)
            Reliable:FireServer(Buffer, SendInstances)
        else
            local From, FromInstances = 0, 0
            for Index = 1, #Cuts, 2 do
                local To, ToInstances = Cuts[Index], Cuts[Index + 1]
                SendPacket(From, To, FromInstances, ToInstances)
                From, FromInstances = To, ToInstances
            end
            SendPacket(From, Used, FromInstances, #SendInstances)
            table.clear(Cuts)
        end

        SendCursor = 0
        SendOffset = 0
        table.clear(SendInstances)
    end

    PacketStart = 0
    PacketInstances = 0
    PacketEvents = 0
    CommittedInstances = 0

    --> Kept for the next frame, as the server keeps each player's. Checked on a frame that sent
    --> nothing as well, or a client that went quiet after a burst would hold the burst's buffer.
    local Shrink
    Shrink, SendUnderused = ShouldShrink(SendSize, Used, SendUnderused)
    if Shrink then
        SendSize = 64
        SendBuffer = buffer.create(64)
        LastPacket = nil
    end
end
]]
