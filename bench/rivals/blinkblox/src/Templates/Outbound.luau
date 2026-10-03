--!strict
--- The server's per-player outbound budget, spliced in after OUTBOUND_RATE and OUTBOUND_BURST when the
--- schema sets `option OutboundBytesPerSecond`; see Generator/Outbound.luau.
return [[
--> OUTBOUND BUDGET. Each player's bucket holds its tokens, the clock it was last refilled at, and how
--> much of everyone's traffic it has already paid for. A send to everyone adds to OutboundShared once,
--> and each bucket pays that when it is next brought up to date, so a broadcast costs one addition
--> rather than one per player. Charges may take a bucket below zero: every send but a low-priority one
--> goes whatever the bucket holds, and the debt is what keeps the next low one out.
local OutboundShared = 0
local OutboundBudgets: {[Player]: {number}} = {}
--> The per-player stream families declared `Priority: Low`.
local OutboundLow: {[any]: boolean} = {}

--> A bucket is made when its player joins, or for everyone already in the game when the module loads.
--> It pays for everyone's traffic from then on, so one made later would miss the broadcasts before it.
local function OutboundJoin(Player: Player): {number}
    local Budget = { OUTBOUND_BURST, os.clock(), OutboundShared }
    --> One made for a player who has already left is not kept: PlayerRemoving has run, and nothing
    --> would drop it.
    if Player.Parent ~= nil then
        OutboundBudgets[Player] = Budget
    end
    return Budget
end

Players.PlayerAdded:Connect(OutboundJoin)
Players.PlayerRemoving:Connect(function(Player)
    OutboundBudgets[Player] = nil
end)
for _, Player in Players:GetPlayers() do
    OutboundJoin(Player)
end

--> `Player`'s bucket, brought up to now.
local function OutboundBudget(Player: Player): {number}
    local Budget = OutboundBudgets[Player]
    if Budget == nil then
        return OutboundJoin(Player)
    end

    local Now = os.clock()

    Budget[1] = math.min(OUTBOUND_BURST, Budget[1] + (Now - Budget[2]) * OUTBOUND_RATE) - (OutboundShared - Budget[3])
    Budget[2] = Now
    Budget[3] = OutboundShared
    return Budget
end

--> Charges `Bytes` sent to `Player` alone.
local function OutboundCharge(Player: Player, Bytes: number)
    local Budget = OutboundBudgets[Player] or OutboundBudget(Player)
    Budget[1] -= Bytes
end

--> Whether `Player` has spent their budget, so a low-priority send to them is left out.
local function OutboundSpent(Player: Player): boolean
    return OutboundBudget(Player)[1] <= 0
end
]]
