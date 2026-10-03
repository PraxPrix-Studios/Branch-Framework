--!strict
--!native
--!optimize 2

--- Emits one `function`: the invocation on the side that calls, and the listener and its reply on the
--- side that answers.
---
--- Adds `Function` to the Serde table, which the declaration walk in Generators.luau dispatches through.
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Fragments = require("./Fragments")
local Generators = require("./Generators")
local Lifecycle = require("./Lifecycle")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Queues = require("./Queue")
local Serde = require("./Serde")
local State = require("./State")
local Util = require("./Util")

type Type = Parser.TypeNode

local DEFAULT_INVOCATION_TIMEOUT = Fragments.DEFAULT_INVOCATION_TIMEOUT
local Types = Prefabs.Types
local RateGuardExpression = Decode.RateGuardExpression
local Declarations = Serde

function Declarations.Function(Declaration: Parser.Function)
	local Name = Declaration.Name
	local Value = Declaration.Value

	local DataIdentifier = `FUNCTION_DATA_{Name}`
	local ReturnIdentifier = `FUNCTION_RETURN_{Name}`

	local Yield = Value.Yield
	local IsFuture = (Yield == "Future")
	local IsPromise = (Yield == "Promise")

	if IsFuture and (State.Options.FutureLibrary or "") == "" then
		error(`Cannot use yield type: "Future", without providing a path to the future library.`)
	end

	if IsPromise and (State.Options.PromiseLibrary or "") == "" then
		error(`Cannot use yield type: "Promise", without providing a path to the promise library.`)
	end

	local Channel = State.Channels.Reliable

	local Index = Channel.Count
	local Queue = `Queue.Reliable[{Index}]`
	local Connection = `Events.Reliable[{Index}]`

	--> WHICH SIDE IS WHICH. `From` names the side that INVOKES; the other side listens. Until this
	--> existed the answer was always "the client invokes", and the fork below was written as
	--> `Context == "Server"` -- true only because that meant the same thing.
	local IsCaller = (Value.From == State.Context)
	local OnServer = (State.Context == "Server")

	--> A server calling a client needs per-player invocation state, because the id is a u8 the client
	--> sends back and one shared id space would let a client answer a call made to somebody else. See
	--> Templates/Server.luau.
	local ServerCalls = OnServer and IsCaller
	--> The set of outstanding calls this one is claimed in: the target player's on the server, the
	--> module's own on a client. See Templates/Base.luau for why a call is known by its id AND its
	--> function index.
	local Owner = if ServerCalls then "PlayerInvocations[Player]" else "Invocations"
	local Timeout = State.Options.InvocationTimeout or DEFAULT_INVOCATION_TIMEOUT
	local ClaimSlot = if ServerCalls then `InvokePlayer(Player, {Index})` else `ClaimInvocation(Invocations, {Index})`
	local ReleaseSlot = `ReleaseInvocation({Owner}, InvocationIdentifier)`
	local ParkCaller = `ParkInvocation({Owner}, InvocationIdentifier, coroutine.running())`
	local TakeCaller = `TakeInvocation({Owner}, InvocationIdentifier, {Index})`
	local ArmTimeout = if ServerCalls
		then `TimeoutPlayerInvocation(Player, InvocationIdentifier, {Timeout}, "{Name}")`
		else `TimeoutInvocation(Invocations, InvocationIdentifier, {Timeout}, '"{Name}" was never answered')`

	--> Data and return body
	--> Positional names everywhere but the parameters of `Invoke`, the one place the game sees them;
	--> see `Generators.LuauType`. A pack element named `Success` or `InvocationIdentifier` used to
	--> shadow the generated code's own local of that name.
	local DataTypes, DataValues, _, DataArguments = "nil", "Value: nil", nil, "Value"
	local PublicValues, PublicArguments = DataValues, DataArguments
	local ReturnTypes, ReturnValues, _, ReturnArguments = "nil", "ReturnValue: nil", nil, "ReturnValue"

	if Value.Data then
		_, PublicValues, _, PublicArguments = Generators.LuauType(Value.Data :: Type, true)
		DataTypes, DataValues, _, DataArguments = Generators.LuauType(Value.Data :: Type, true, nil, true)
	end

	if Value.Return then
		ReturnTypes, ReturnValues, _, ReturnArguments = Generators.LuauType(Value.Return :: Type, true, "Return", true)
	end

	do
		local DataRead, DataWrite = Generators.Event(Value.Data :: Type, Index, DataIdentifier, "Data")
		local ReturnRead, ReturnWrite = Generators.Event(Value.Return :: Type, Index, ReturnIdentifier, "Return")

		--> By DIRECTION, not by context. The caller writes the arguments and reads the answer; the
		--> listener reads the arguments and writes the answer. Keying this on `Context == "Client"`
		--> was correct only while the client was always the caller.
		if IsCaller then
			State.UserTypes.PushLines(DataWrite, 1, 0)
			State.UserTypes.PushLines(ReturnRead, 1, 0)
		else
			State.UserTypes.PushLines(DataRead, 1, 0)
			State.UserTypes.PushLines(ReturnWrite, 1, 0)
		end
	end

	--> Main
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)

	State.Noop.Push(`{Name} = \{`, 0, Indent)
	Body.Push(`{Name} = \{`, 0, Indent)

	--> Create queue and event branch
	State.Events.Push(`{Queue} = table.create(256)`)
	State.Events.Push(`EventNames.Reliable[{Index}] = "{Name}"`)
	local Block = Decode.Open(false, Index)

	if not IsCaller then
		--> Data recieve body
		Types.u8.Read("InvocationIdentifier", Block)
		Block:Line(`local {DataValues} = {Util.GetPath(DataIdentifier, false, State.Scope)}()`)

		--> A refused invocation still has to be ANSWERED; see Queue.Refuse.
		local RateGuard = RateGuardExpression(Value, Name)
		if RateGuard then
			Queues.Refuse(Block:Line(`if not {RateGuard} then`), Index, Block.Indent + 1):Line("end")
		end

		--> After the rate limit, so a refused call is not counted as running; before dispatch, so a
		--> call waiting in the queue is. Released below wherever the call is answered. The client has
		--> no such check: the server it listens to is trusted.
		local Limit = if OnServer then Value.Concurrency else nil
		local Release = if Limit then `ConcurrencyRelease(Player, {Index})` else nil
		if Limit then
			local Guard = `if not ConcurrencyAccept(Player, {Index}, {Limit}, "{Name}") then`
			Queues.Refuse(Block:Line(Guard), Index, Block.Indent + 1):Line("end")
		end

		--> The listening side passes a Player only when it IS the server. A client listening to a
		--> function the server invokes has no player to name: the caller is the server.
		local Caller = if OnServer then "Player, " else ""
		local Queued = Block:Compare(Connection, "nil", "Not")
			:Line(`Spawn({Connection}, {Caller}{DataArguments}, InvocationIdentifier)`)
			:Branch("Default")
		Queues.Enqueue(
			Queued,
			State.Context,
			Queue,
			`{Caller}{DataArguments}, InvocationIdentifier`,
			Name,
			Index,
			Release
		)
			:End()

		--> Data listener body
		local FlushQueue = Blocks.Function("", "", "()")
			:Line(`local EventQueue = {Queue} or \{\}`)
			:Line(`{Queue} = nil`)
			:Iterator("Index", "Arguments", "EventQueue")
			:Line(`{Connection}(table.unpack(Arguments, 1, Arguments.n))`)
			:End()
			:End()
			:Wrap("Spawn(", ")")

		local Serialize = Blocks.Function("", "")
			:Line(`{ReturnArguments} = Listener({if OnServer then "Player, " else ""}{DataArguments})`)
			:End()
			:Wrap("local Success, Error = pcall(", ")")

		--> Writing the reply. The server holds one send buffer per player and has to swap the right one
		--> in first; the client has a single buffer aimed at the server and nothing to select.
		local TrueListener = Blocks.Function(
			Connection,
			`{if OnServer then "Player: Player, " else ""}{DataValues}, InvocationIdentifier: number`,
			"()",
			true
		)
			:Line(`local {ReturnValues};`)
			:Lines(Serialize.Content, 1)

		if OnServer then
			TrueListener:Line("LoadPlayer(Player)")
		else
			--> The failure reply below writes without Mark, and has to land after a Fire that threw
			--> has been undone rather than behind it.
			TrueListener:Line("Settle()")
			TrueListener:Line("local ReplyStart, ReplyInstances = SendCursor, #SendInstances")
		end

		--> Serialising the reply is protected for the same reason calling the listener is.
		-->
		--> It was not, and the gap was the worst shape a gap can take: the return serialiser carries
		--> the same hard type asserts every write does, so a listener returning the wrong type threw
		--> from OUTSIDE the pcall above. That skipped the reply and the save both, and the caller --
		--> who is owed exactly one answer -- got none, waiting out the full invocation timeout for
		--> what is really an immediate, local, reportable mistake.
		-->
		--> Failing the write folds into the failure reply below instead of adding a second path,
		--> which is also what keeps "exactly one reply, always" true by construction.
		TrueListener:Compare("Success", "true", "Equals")
			:Line("local Cursor, Instances = Mark()")
			:Line(
				`Success, Error = pcall({Util.GetPath(ReturnIdentifier, true, State.Scope)}, {ReturnArguments}, InvocationIdentifier)`
			)
			:Compare("Success", "true", "Not")
			:Line("Rollback(Cursor, Instances)")
			:End()
			:End()

		TrueListener
			:Compare("Success", "true", "Not")
			:Line("local Position = Allocate(3)")
			:Line(`buffer.writeu8(SendBuffer, Position, {Index})`)
			:Line(`buffer.writeu8(SendBuffer, Position + 1, InvocationIdentifier)`)
			:Line(`buffer.writeu8(SendBuffer, Position + 2, 0)`)
			--> On the server the error is the game's to hear through SetListenerErrorHandler, a throwing
			--> return serialiser included; the warning is what it gets without one, as before.
			:Line(
				if OnServer
					then `if not ListenerFailed(Player, "{Name}", Error) then warn(\`"{Name}" encountered an error, \{Error\}\`) end`
					else `warn(\`"{Name}" encountered an error, \{Error\}\`)`
			)
			:End()

		--> The reply is written, success or failure: the call is no longer running.
		if Release then
			TrueListener:Line(Release)
		end

		if OnServer then
			TrueListener:Line("SavePlayerBuffer(Player)")
		else
			TrueListener:Line("Close(ReplyStart, ReplyInstances)")
		end

		TrueListener:End()

		local ListenerSignature = `Listener: ({if OnServer then "Player, " else ""}{DataTypes}) -> ({ReturnTypes})`
		local Listener = Blocks.Function(State.Casing.On, ListenerSignature, "()", true)
			:Lines(TrueListener.Content, 1)
			:Lines(FlushQueue.Content, 1)
			:End()

		State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
		Body.PushLines(Listener.Content, 0, 2)
	else
		--> Return recieve body. The flag after the id says whether a payload follows at all: a failure
		--> reply stops there. The payload is only read when it is there, and a read that fails leaves
		--> the cursor inside it -- so after the caller has been told, the failure is raised again, and
		--> the packet stops and is reported like any other that cannot be decoded.
		local Deserialize = Blocks.Function("", "")
			:Compare("Answered", "1", "Not")
			:Line(`error("The call failed on the side that answered it.")`)
			:End()
			:Return(`{Util.GetPath(ReturnIdentifier, false, State.Scope)}()`)
			:End()
			:Wrap(`local Success, {ReturnArguments} = pcall(`, ")")

		Types.u8.Read("InvocationIdentifier", Block)
		Types.u8.Read("Answered", Block)
		Block:Lines(Deserialize.Content, Block.Indent + 1)
		--> Taking the caller settles the call -- its id goes back, its timer is cancelled -- before the
		--> thread is resumed, so a caller that immediately invokes again from inside its own
		--> continuation gets an id rather than an exhaustion error. It yields nothing when the id is
		--> not outstanding for THIS function. A server looks the reply up in the REPLYING PLAYER's own
		--> set, so an id belonging to a call made to somebody else simply is not there.
		-->
		--> The status check is not paranoia: a Future that already completed leaves a thread that is
		--> dead or running. `task.spawn` on either of those throws from inside the remote handler,
		--> where no user pcall can reach it.
		Block:Line(`local Thread = {TakeCaller}`)
			:Compare("Thread", "nil", "Not")
			:Compare("coroutine.status(Thread)", `"suspended"`, "Equals")
			:Line(`task.spawn(Thread, Success, {ReturnArguments})`)
			:End()
			:End()

		local Failure = string.split(ReturnArguments, ",")[1]
		Block:Line(`if Answered == 1 and Success ~= true then error({Failure}, 0) end`)

		local Error = `"There was an exception while processing \\"{Name}\\"."`
		--> A server invoking has to say WHICH client it is asking.
		local InvokeValues = `{if ServerCalls then "Player: Player, " else ""}{PublicValues}`
		--> Claiming a slot and writing the call. Again the server has to select the target player's
		--> buffer around the write. Shared by every yield style: a Promise does it inside its executor.
		local function SendCall(Target: Blocks.Block): Blocks.Block
			Target:Line(`local InvocationIdentifier = {ClaimSlot}`)
			if ServerCalls then
				Target:Line("LoadPlayer(Player)")
			end

			--> Releasing the slot when the ARGUMENTS fail to serialise.
			-->
			--> The slot is claimed before the write and the caller is parked after it, so a throw in
			--> between used to strand the slot with nothing outstanding: no parked caller, so
			--> nothing for the timeout to find and reclaim. Thirty-two rejected calls -- the same wrong
			--> argument thirty-two times -- and every later invocation fails for the lifetime of the
			--> session. This is the one leak the timeout cannot cover, because it is armed after it.
			Target:Line("local Cursor, Instances = Mark()")
			Target:Line(
				`local Sent: boolean, Failure: any = pcall({Util.GetPath(DataIdentifier, true, State.Scope)}, {PublicArguments}, InvocationIdentifier)`
			)
			Target:Compare("Sent", "true", "Not")
				:Line("Rollback(Cursor, Instances)")
				:Line(ReleaseSlot)
				:Line("error(Failure, 0)")
				:End()

			if ServerCalls then
				Target:Line("SavePlayerBuffer(Player)")
			else
				Target:Line("Close(Cursor, Instances)")
			end

			return Target
		end

		local Contents = SendCall(Blocks.Block())
			:Line(ParkCaller)
			:Line(ArmTimeout)
			:Line(`local Success, {ReturnValues} = coroutine.yield()`)
			:Compare("Success", "true", "Not")
			:Line(`error({Error})`)
			:End()
			:Return(ReturnArguments).Content

		local Invoke
		if IsFuture then
			State.UsesFuture = true
			local Wrapper = Blocks.Function("", ""):Lines(Contents):End():Wrap("return Future.Try(", ")")

			Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, `Future.Future<boolean, {ReturnTypes}>`, true)
			Invoke:Lines(Wrapper.Content, 1)
		elseif IsPromise then
			State.UsesPromise = true

			--> A cancelled promise gives its slot back too, otherwise cancelling enough calls would
			--> exhaust the bitset with nothing outstanding.
			local OnCancel = Blocks.Function("", ""):Line(ReleaseSlot):End():Wrap("OnCancel(", ")")

			local Promise = SendCall(Blocks.Function("", "Resolve, Reject, OnCancel"))
				:Line(ParkCaller)
				:Line(ArmTimeout)
				:Lines(OnCancel.Content, 1)
				:Line(`local Success, {ReturnValues} = coroutine.yield()`)
				:Compare("Success", "true", "Not")
				:Line(`Reject({Error})`)
				:Return("")
				:End()
				:Line(`Resolve({ReturnArguments})`)
				:End()
				:Wrap(`return Promise.new(`, ")")

			Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, nil, true)
			Invoke:Lines(Promise.Content, 1)
		else
			Invoke = Blocks.Function(State.Casing.Invoke, InvokeValues, `({ReturnTypes})`, true)
			Invoke:Lines(Contents, 0)
		end

		Invoke:End()
		State.Noop.Push(`{State.Casing.Invoke} = {Lifecycle.InvokeStub(State.Context, State.Options)}`, 0, Indent + 1)
		Body.PushLines(Invoke.Content, 0, Indent + 1)
	end

	Channel.Count += 1

	State.Noop.Push(`\},`, 0, Indent)
	Body.Push(`\},`, 0, Indent)
	State.Return.PushLines(Body.DumpLines(), 0)
end

return Declarations
