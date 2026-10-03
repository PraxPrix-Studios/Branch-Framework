--!strict
--- The server's limits on what one client may cost it: rate buckets, calls in flight, the inbound
--- budget, and what a refusal says and to whom. Spliced into the server module between the remotes
--- and the invocation state (the second `-- SPLIT --` in Server.luau), because PlayerRemoving there
--- clears the tables declared here. Split out of Server.luau when that reached the 500-line cap.
return [[
--> RATE LIMITING. One table per player, four numbers per limited event: tokens left, the clock
--> reading those tokens were last refilled at, the clock reading the last report was made at, and
--> the refusals made since that report, which the next one carries.
--> A flat array rather than a table per event because a player who fires nothing still pays for the
--> allocation, and this is on the path of every inbound packet.
local RateBuckets: {[Player]: {number}} = {}
local RateHandler: ((Player: Player, Event: string?, Refused: number) -> ())? = nil

--> CALLS IN FLIGHT. For each player, how many calls of each function that declares a `Concurrency`
--> the server has accepted and not yet answered, keyed by the function's event index; and beside it
--> the refusals made since the last report. `Rate` bounds how many calls START a second. It says
--> nothing about how many are still RUNNING, and a listener that waits -- a DataStore request, an
--> invocation back to the same client, which that client can leave unanswered for the whole timeout
--> -- turns a steady stream of calls into a growing pile of suspended threads. A hostile client is
--> not held to the 32 outstanding calls an honest one is: it writes whatever invocation ids it likes.
local InFlight: {[Player]: {[number]: number}} = {}
local InFlightRefused: {[Player]: {[number]: number}} = {}

--> THE INBOUND BUDGET. Bytes a player's packets may cost the server, refilled every second, charged
--> before a packet is decoded: tokens left, refill clock, report clock, refusals since that report.
--> Every other limit is per packet or per event, and a client that sends many packets each frame
--> passed all of them while the server decoded every one.
local InboundBudgets: {[Player]: {number}} = {}

--> WHAT A CLIENT CAN MAKE THE SERVER SAY. A packet refused for its shape, its size or its instance
--> count, a packet cut short by the event cap, and a packet that failed to decode are each reported
--> at most once a second per player -- per channel and event, for a decode failure -- the schedule
--> the rate limit's reports already keep. They used
--> to be reported per packet, so a client could put a line in the output, or a call to the game's
--> handler, for every packet it sent: hundreds a second, and the malformed and oversized ones
--> without even being charged to the inbound budget first.
local Reports: {[Player]: {[string]: number}} = {}

local function ShouldReport(Player: Player, Kind: string): boolean
    local Times = Reports[Player]
    if not Times then
        if Player.Parent == nil then
            return false
        end

        Times = {}
        Reports[Player] = Times
    end

    local Now = os.clock()
    local Last = Times[Kind]
    if Last ~= nil and (Now - Last) < 1 then
        return false
    end

    Times[Kind] = Now
    return true
end

--> PACKET REFUSALS, for the game to act on. A packet refused before it is decoded -- malformed
--> arguments, oversized, over the inbound budget, too many instances -- or cut short by the event cap
--> is something only a modified client sends, and a game may want to strike or ban for it. The
--> warning alone told the output, not the game. `Refused` is how many packets of that kind the call
--> stands for, once a second per player and reason. `Detail` is the packet's byte length for
--> Oversized and Budget, its instance count for Instances, the events decoded for Events, 0 otherwise.
--> With a handler installed the warnings are not printed, and Budget no longer reaches the rate-limit
--> handler: the game has said where it wants to hear about packets.
type BLINK_DROP_REASON = "Malformed" | "Oversized" | "Budget" | "Instances" | "Events"
local DropHandler: ((Player: Player, Reason: BLINK_DROP_REASON, Refused: number, Detail: number) -> ())? = nil
local Drops: {[Player]: {[string]: number}} = {}

local function SetPacketDropHandler(Handler: ((Player: Player, Reason: BLINK_DROP_REASON, Refused: number, Detail: number) -> ())?)
    DropHandler = Handler
end

--> The warnings as they were before the handler existed, word for word. Budget has its own, in
--> InboundAccept, since it names the budget.
local DROP_WARNINGS: {[string]: string} = {
    Malformed = "Dropped a malformed packet from %s.",
    Oversized = "Dropped an oversized packet from %s.",
    Instances = "Dropped a packet with too many instances from %s.",
    Events = "Dropped the rest of a packet from %s, too many events.",
}

local function ReportDrop(Player: Player, Reason: BLINK_DROP_REASON, Detail: number)
    local Counts = Drops[Player]
    if not Counts then
        if Player.Parent == nil then
            return
        end

        Counts = {}
        Drops[Player] = Counts
    end

    local Refused = (Counts[Reason] or 0) + 1
    if not ShouldReport(Player, Reason) then
        Counts[Reason] = Refused
        return
    end

    Counts[Reason] = 0
    local Handler = DropHandler
    if Handler then
        --> Spawned: a handler that throws or yields must not reach back into the connection.
        Spawn(Handler, Player, Reason, Refused, Detail)
    else
        warn(`[BlinkBlox]: {string.format(DROP_WARNINGS[Reason], Player.Name)}`)
    end
end

--> Installs the callback told about refused events: at most once per player per event per second,
--> with `Refused` the number of refusals that report stands for. `Event` is nil when what was refused
--> was whole packets over the inbound budget rather than one event, which is reported here only while
--> no packet-drop handler is installed. Nothing is kicked automatically:
--> a false positive under server lag would eject a legitimate player, and whether that is the right
--> response is a decision only the game can make.
local function SetRateLimitHandler(Handler: ((Player: Player, Event: string?, Refused: number) -> ())?)
    RateHandler = Handler
end

--> DECODE FAILURES (upstream issue #102). A packet that cannot be decoded is abandoned where it
--> failed, since the cursor is left mid-event and nothing after it can be trusted. That stays silent
--> by default -- a client sending garbage every frame must not be able to fill the output -- but the
--> game is entitled to know who sent it and what it claimed to be, to log it, flag the account or
--> kick. `Event` is nil when the index named no event at all.
local DecodeHandler: ((Player: Player, Event: string?, Failure: string) -> ())? = nil

local function SetDecodeErrorHandler(Handler: ((Player: Player, Event: string?, Failure: string) -> ())?)
    DecodeHandler = Handler
end

local function ReportDecodeFailure(Player: Player, Channel: string, Event: string?, Failure: unknown)
    local Handler = DecodeHandler
    --> Once a second per player, per channel and per event it claimed to be.
    if Handler and ShouldReport(Player, `{Channel} {Event or "?"}`) then
        --> Spawned for the same reason RateAccept spawns its handler: one that throws or yields must
        --> not reach back into the receive loop that called it.
        Spawn(Handler, Player, Event, tostring(Failure))
    end
end

--> LISTENER ERRORS. A listener that throws on the server -- an event's, Sync or Async, or a function's
--> -- is the game's bug, but the arguments that set it off are a client's: a modified client can make
--> one throw on every packet it sends. With no handler installed the error surfaces as it always did,
--> in the output with nobody named. With one, the handler owns it and the output stays silent: it is
--> told the player, the event, the error and `Count`, the errors that report stands for, at most once
--> a second per player and event on the schedule every other report keeps. A player who has already
--> left is reported at once with a count of 1, since there is no schedule left to hold it on.
local ListenerHandler: ((Player: Player, Event: string, Failure: string, Count: number) -> ())? = nil
local ListenerErrors: {[Player]: {[string]: number}} = {}

local function SetListenerErrorHandler(Handler: ((Player: Player, Event: string, Failure: string, Count: number) -> ())?)
    ListenerHandler = Handler
end

--> Reports a listener's error, or returns false when no handler is installed and the caller should
--> surface it the way it did before the handler existed. Never throws or yields: it runs inside the
--> decode loop's pcall, or in the connection itself after a listener threw, before the decode goes on.
local function ListenerFailed(Player: Player, Event: string, Failure: unknown): boolean
    local Handler = ListenerHandler
    if not Handler then
        return false
    end

    local Counts = ListenerErrors[Player]
    if not Counts then
        if Player.Parent == nil then
            Spawn(Handler, Player, Event, tostring(Failure), 1)
            return true
        end

        Counts = {}
        ListenerErrors[Player] = Counts
    end

    local Count = (Counts[Event] or 0) + 1
    if not ShouldReport(Player, `Listener {Event}`) then
        Counts[Event] = Count
        return true
    end

    Counts[Event] = 0
    --> Spawned for RateAccept's reason: a handler that throws or yields must not reach the decoder.
    Spawn(Handler, Player, Event, tostring(Failure), Count)
    return true
end

--> Runs an Async listener, or replays a queued event to one of either kind. Without a handler the
--> listener is called bare, so its error surfaces on its own thread exactly as before; with one it is
--> protected and reported.
local function RunListener<T...>(Event: string, Listener: (Player, T...) -> (), Player: Player, ...: T...)
    if ListenerHandler == nil then
        Listener(Player, ...)
        return
    end

    local Ran: boolean, Failure: any = pcall(Listener, Player, ...)
    if not Ran then
        ListenerFailed(Player, Event, Failure)
    end
end

--> Charges a packet against its sender's inbound budget, or reports and refuses it.
-->
--> Called from the connection before the packet is decoded, so a refusal costs the server a table
--> lookup rather than a decode. The burst is a whole second of budget because the clock here is the
--> server's: after a hitch Roblox delivers the queued packets together, and a refused reliable packet
--> takes every event in it along. Reported on the same once-a-second schedule as RateAccept.
--> When the packet being decoded arrived. Every event in a packet arrived at the same moment, so the
--> rate buckets refill once a packet, at this, rather than asking the clock once an event.
local PacketClock = 0

local function InboundAccept(Player: Player, Length: number, Floor: number, Rate: number, Burst: number): boolean
    local Cost = math.max(Length, Floor)
    if Player.Parent == nil then
        InboundBudgets[Player] = nil
        return false
    end

    local Now = os.clock()
    PacketClock = Now
    local Budget = InboundBudgets[Player]
    if not Budget then
        --> The report clock starts at minus infinity so the first refusal is always reported.
        Budget = {Burst, Now, -math.huge, 0}
        InboundBudgets[Player] = Budget
    end

    local Tokens = math.min(Burst, Budget[1] + ((Now - Budget[2]) * Rate))
    Budget[2] = Now

    if Tokens >= Cost then
        Budget[1] = Tokens - Cost
        return true
    end

    Budget[1] = Tokens
    local Refused = Budget[4] + 1
    if (Now - Budget[3]) < 1 then
        Budget[4] = Refused
        return false
    end

    Budget[3] = Now
    Budget[4] = 0

    --> Spawned, either handler: this runs in the remote's connection, outside any pcall, and a
    --> throwing handler would take the connection's thread with it.
    local Dropped = DropHandler
    if Dropped then
        Spawn(Dropped, Player, "Budget" :: BLINK_DROP_REASON, Refused, Length)
        return false
    end

    --> Without a packet-drop handler, as before it existed: a warning, and the rate-limit handler
    --> with `Event` nil. Kept so a game written against 0.27 to 0.36 hears what it always heard.
    warn(`[BlinkBlox]: Dropped packets from {Player.Name} over the inbound budget of {Rate} bytes a second, {Refused} refused.`)
    local Handler = RateHandler
    if Handler then
        Spawn(Handler, Player, nil, Refused)
    end

    return false
end

--> Refills lazily and spends one token, or reports and refuses.
--> 
--> Called after an event has been DESERIALIZED, never before: payloads are variable length, so an
--> event cannot be skipped without decoding it -- the cursor would be left mid-event and the rest of
--> the packet would decode as garbage. So this bounds listener dispatch and the game logic behind
--> it, while MaxEventsPerPacket bounds the decoding of one packet and InboundAccept how many packets
--> a second get decoded at all. The three limits are different axes.
--> Called only from the decode loop, which stops before any event once the player has left, and
--> no game code runs between that check and this call: a player still here when the loop checked
--> is still here now, so a bucket made below is one PlayerRemoving will clear.
local function RateAccept(Player: Player, Slot: number, Rate: number, Burst: number, Name: string): boolean
    local Bucket = RateBuckets[Player]
    if not Bucket then
        Bucket = table.clone(RATE_TEMPLATE)
        RateBuckets[Player] = Bucket
    end

    local Now = PacketClock
    local Tokens = math.min(Burst, Bucket[Slot] + ((Now - Bucket[Slot + 1]) * Rate))
    Bucket[Slot + 1] = Now

    if Tokens < 1 then
        Bucket[Slot] = Tokens

        --> One report per player per event per second, the warning and the handler alike. An exploit
        --> client sends hundreds a frame; a report per drop would bury the console it is trying to
        --> inform, and spawn the game's handler as often. Refusals in between are counted instead.
        local Refused = Bucket[Slot + 3] + 1
        if (Now - Bucket[Slot + 2]) < 1 then
            Bucket[Slot + 3] = Refused
            return false
        end

        Bucket[Slot + 2] = Now
        Bucket[Slot + 3] = 0
        warn(`[BlinkBlox]: Rate limited event "{Name}" from {Player.Name}, {Refused} refused.`)

        local Handler = RateHandler
        if Handler then
            --> Spawned, not called. This runs inside the decode loop's pcall that contains a truncated
            --> packet, so a throwing handler would abort the rest of the packet; and a handler that
            --> yields -- an analytics write, a datastore call -- would stall decoding.
            Spawn(Handler, Player, Name, Refused)
        end

        return false
    end

    Bucket[Slot] = Tokens - 1
    return true
end

--> Claims one of a player's `Limit` running calls of function `Index`, or reports and refuses.
-->
--> Called once a call has been decoded and passed its rate limit, before it is dispatched or queued,
--> so a call waiting in the queue for its listener counts as running: it holds the same thread and
--> the same promise of a reply. Refusals are reported on RateAccept's schedule and through its
--> handler, once a second per player per function, carrying the refusals since the last report.
local function ConcurrencyAccept(Player: Player, Index: number, Limit: number, Name: string): boolean
    if Player.Parent == nil then
        InFlight[Player] = nil
        InFlightRefused[Player] = nil
        return false
    end

    local Counts = InFlight[Player]
    if not Counts then
        Counts = {}
        InFlight[Player] = Counts
    end

    local Running = Counts[Index] or 0
    if Running < Limit then
        Counts[Index] = Running + 1
        return true
    end

    local Pending = InFlightRefused[Player]
    if not Pending then
        Pending = {}
        InFlightRefused[Player] = Pending
    end

    local Refused = (Pending[Index] or 0) + 1
    if not ShouldReport(Player, `Concurrency {Index}`) then
        Pending[Index] = Refused
        return false
    end

    Pending[Index] = 0
    warn(`[BlinkBlox]: "{Name}" from {Player.Name} already has {Limit} calls running, {Refused} refused.`)

    local Handler = RateHandler
    if Handler then
        --> Spawned for RateAccept's reason: this runs inside the decode loop's pcall.
        Spawn(Handler, Player, Name, Refused)
    end

    return false
end

--> Gives back the running call ConcurrencyAccept claimed, once its reply has been written. Every
--> accepted call is answered exactly once -- the listener's reply, its failure reply, or the failure
--> written when the queue is full -- and each of those paths releases, so the count cannot leak. A
--> player who left has no counts to give back to: PlayerRemoving dropped them.
local function ConcurrencyRelease(Player: Player, Index: number)
    local Counts = InFlight[Player]
    if Counts and (Counts[Index] or 0) > 0 then
        Counts[Index] -= 1
    end
end
]]
