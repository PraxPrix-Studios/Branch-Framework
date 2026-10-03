--!strict
--> The server's deferred start, emitted under `option AutoStart = false`. See Generator/Lifecycle.
-->
--> `Before` replaces the remote lookup at the top of the server template: stand-ins until Start, and
--> the lookup itself moved into CreateRemotes, which the generator indents into place between
--> `Before` and `After`. `Guard` opens SavePlayerBuffer and InvokePlayer. `Start` follows the
--> connections, which the generator wraps in `Listen`.
return {
	Before = [[--> option AutoStart = false: requiring this module creates nothing. The remotes are made, and the
--> Heartbeat and both remotes' connections are made, when the game calls Start.
local Started = false
local DroppedBeforeStart = false

--> Sends before Start go nowhere, and are said to have gone nowhere once. They are dropped rather
--> than queued: in a build that never calls Start -- the reason the option exists -- a queue would
--> hold every player's events for as long as they stayed, and an event queued for a minute is
--> rarely still true when it arrives.
local function DropBeforeStart()
    if DroppedBeforeStart then
        return
    end

    DroppedBeforeStart = true
    warn("[BlinkBlox]: Something was sent before Start() was called, and was dropped. The server module sends nothing until it is started.")
end

--> What Reliable and Unreliable are until Start: reliable sends stop at SavePlayerBuffer, and an
--> unreliable send, which fires the remote directly, lands here.
local NOT_STARTED = table.freeze({
    FireClient = DropBeforeStart,
    FireAllClients = DropBeforeStart,
})

local Reliable: RemoteEvent = NOT_STARTED :: any
local Unreliable: UnreliableRemoteEvent = NOT_STARTED :: any

local function CreateRemotes(): (RemoteEvent, UnreliableRemoteEvent)
]],

	After = [[
    return Reliable, Unreliable
end
]],

	Guard = {
		SavePlayerBuffer = [[    if not Started then
        DropBeforeStart()
        return
    end

]],
		--> Failing at once, where the call would otherwise go nowhere and wait out the whole timeout.
		InvokePlayer = [[    if not Started then
        error(`[BlinkBlox]: Cannot invoke {Player.Name} before Start() was called.`)
    end

]],
	},

	Start = [[
--> Creates the remotes and starts listening and sending. Calling it again does nothing, so every
--> script that needs the network can make sure of it without agreeing which one goes first.
local function Start()
    if Started then
        return
    end

    Reliable, Unreliable = CreateRemotes()
    Started = true
    Listen()
end
]],
}
