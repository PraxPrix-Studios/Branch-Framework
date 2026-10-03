--!strict
--- The clock stamps, in three parts split at `-- SPLIT --`: the unwrap both sides share, then the
--- server's clamp for a stamped event (docs/src/content/docs/language/stamps.mdx), then the client's
--- stamp for one. The first goes into a module that reads a stamp -- a client with a stream, a server
--- with a stamped event -- and the other two into the side that uses them.
---
--- Every stamp is a server time in milliseconds modulo 65536: a stream's is the server's own clock,
--- an event's is the client's estimate of it (`GetServerTimeNow`), which Roblox keeps within a ping.
return [[
--> STAMPS. A stamp is a server time in milliseconds modulo 65536; this puts it back in seconds, the
--> one nearest this side's own server clock.
local StampClock = game:GetService("Workspace")

local function UnwrapStamp(Stamp: number): number
    local Now = StampClock:GetServerTimeNow() * 1000
    local Time = Now - Now % 65536 + Stamp
    if Time > Now + 32768 then
        Time -= 65536
    elseif Time < Now - 32768 then
        Time += 65536
    end
    return Time / 1000
end
-- SPLIT --
--> STAMPS. When a client sent a stamped event: its own word for it, held between the moment the
--> event arrived and `Window` seconds before. A client cannot claim to have acted in the future, and
--> cannot reach further back than the schema allows, whatever it writes.
local function ClampStamp(Stamp: number, Window: number): number
    local Now = StampClock:GetServerTimeNow()
    return math.clamp(UnwrapStamp(Stamp), Now - Window, Now)
end
-- SPLIT --
--> STAMPS. The moment a stamped event is sent, in the server's clock as this client estimates it.
local function StampNow(): number
    return math.floor(StampClock:GetServerTimeNow() * 1000) % 65536
end
]]
