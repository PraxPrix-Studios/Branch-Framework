--!strict
--> The client's bounded wait for the remotes, emitted under `option ClientConnectTimeout`. The
--> generator writes `local CONNECT_TIMEOUT = <seconds>` in front of it. See Generator/Lifecycle.
return [[local ConnectedReliable: Instance? = nil
local ConnectedUnreliable: Instance? = nil

--> Waits for both remotes, CONNECT_TIMEOUT seconds in all, and says whether they came.
-->
--> Without the option this is a WaitForChild with no timeout, and a place where no server module is
--> ever required -- a showroom build, a test place -- blocked every script requiring this one forever.
--> When they do not come, the module returns the same stubs edit mode gets, with Connected false:
--> Fire does nothing, Invoke fails at once, and no listener is ever called.
-->
--> Remotes that appear after the timeout are not picked up. The module has already been returned,
--> `require` has cached it, and a client that connected half way through would have missed whatever
--> the server sent before it. A game that wants to connect later reloads.
local function ConnectRemotes(): boolean
    --> Required from the server: the context check below raises the error that belongs to it.
    if not RunService:IsClient() then
        return true
    end

    local Deadline = os.clock() + CONNECT_TIMEOUT
    ConnectedReliable = ReplicatedStorage:WaitForChild(REMOTE_NAMES.Reliable, CONNECT_TIMEOUT)
    if ConnectedReliable == nil then
        return false
    end

    --> The server creates both in the same frame, so what is left of the budget is plenty.
    local Remaining = Deadline - os.clock()
    ConnectedUnreliable = if Remaining > 0
        then ReplicatedStorage:WaitForChild(REMOTE_NAMES.Unreliable, Remaining)
        else ReplicatedStorage:FindFirstChild(REMOTE_NAMES.Unreliable)
    return ConnectedUnreliable ~= nil
end

]]
