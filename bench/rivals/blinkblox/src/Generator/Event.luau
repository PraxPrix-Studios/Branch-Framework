--!strict
--!native
--!optimize 2

--- Emits one `event`: its serialisers, the branch that receives it, and the API the game calls --
--- `On`, `Iter` or `Fire` and its variants, depending on which side this is and which side sends.
---
--- Adds `Event` to the Serde table, which the declaration walk in Generators.luau dispatches through.
local Batches = require("./Batches")
local Blocks = require("./Blocks")
local Builder = require("../Modules/Builder")
local Decode = require("./Decode")
local Generators = require("./Generators")
local Listeners = require("./Listeners")
local Outbound = require("./Outbound")
local Parser = require("../Parser")
local Prefabs = require("./Prefabs")
local Queues = require("./Queue")
local Send = require("./Send")
local Serde = require("./Serde")
local Stamps = require("./Stamp")
local State = require("./State")
local Streams = require("./Stream")
local Traffic = require("./Traffic")
local Util = require("./Util")
local Writes = require("./Writes")

type Type = Parser.TypeNode

local Types = Prefabs.Types
local RateGuardExpression = Decode.RateGuardExpression
local OrderGuardExpression = Decode.OrderGuardExpression
local Declarations = Serde

function Declarations.Event(Declaration: Parser.Event)
	local Value = Declaration.Value

	local Identifier = `EVENT_{Declaration.Name}`
	local Reliability = Value.Type

	local IsReliable = (Reliability == "Reliable")
	--> Ordered events travel the unreliable channel; the ordering is a sequence number on top of it.
	local IsOrdered = (Reliability == "OrderedUnreliable")
	local IsUnreliable = (Reliability == "Unreliable" or IsOrdered)
	--> Whether a sequence number travels with the event. A stream is OrderedUnreliable too, but it is
	--> ordered by the server time its every packet already carries; see StreamAccept.
	local IsSequenced = IsOrdered and not Value.Stream

	if IsSequenced then
		State.UsesOrdering = true
	end
	--> A stream or a stamped event always has a listener: it hands the game the stamp unwrapped, which
	--> a poll would not.
	local IsPolling = not Value.Stream and not Value.Stamp and (Value.Call == "Polling" or State.Options.UsePolling)
	local IsSameContext = Value.From == State.Context

	local Channel = IsUnreliable and State.Channels.Unreliable or State.Channels.Reliable
	local Counters = Traffic.Register(Declaration.Name, Value.Data, IsSequenced)

	local Index = Channel.Count
	--> Ordered events ride the unreliable channel, so they share its queue and listener tables --
	--> naming those after the declared reliability would index a third table that does not exist.
	local ChannelName = if IsUnreliable then "Unreliable" else "Reliable"
	local Queue = `Queue.{ChannelName}[{Index}]`
	local Connection = `Events.{ChannelName}[{Index}]`

	--> Data body
	--> Two spellings of the payload: with the schema's names, for what the game sees, and positional,
	--> for the decode branch, where a name like `Player` or `Index` would shadow the loop's own.
	local DataTypes, Values, Arguments, _ = "nil", "Value: nil", "Value", nil
	local InnerValues, InnerArguments = "Value: nil", "Value"
	local Read, Write = Generators.Event(Value.Data, Index, Identifier, nil, IsSequenced)

	if Value.Data then
		DataTypes, Values, _, Arguments = Generators.LuauType(Value.Data :: Type, true)
		_, InnerValues, _, InnerArguments = Generators.LuauType(Value.Data :: Type, true, nil, true)
	end

	if IsSameContext then
		State.UserTypes.PushLines(Write, 1, 0)
	else
		State.UserTypes.PushLines(Read, 1, 0)
	end

	--> A stamped event's Fire takes the declared values, and the module writes the stamp after them.
	local FireValues, WriteArguments = Values, Arguments
	if Value.Stamp and IsSameContext then
		FireValues, WriteArguments = Stamps.Outgoing(Value.Stamp)
	end

	--> Return body
	local Body = Builder.new()
	local Indent = Util.GetScopeIndent(State.Scope)
	local WriteEvent = `{Util.GetPath(Identifier, true, State.Scope)}({WriteArguments})`
	--> The same call, protected: an unreliable Fire writes into the scratch buffer under it, so the
	--> batch is put back whatever happens. How a Fire writes into a batch that outlives it is
	--> Writes.luau's.
	local TryWriteEvent = `pcall({Util.GetPath(Identifier, true, State.Scope)}, {WriteArguments})`
	local Writer = Writes.new(Identifier, WriteArguments, WriteEvent, Value.Data, Counters)

	Body.Push(`{Declaration.Name} = \{`, 0, Indent)
	State.Noop.Push(`{Declaration.Name} = \{`, 0, Indent)

	if Value.From ~= State.Context and IsPolling ~= true then
		local IsSync = (Value.Call == "SingleSync" or Value.Call == "ManySync")
		local IsSingle = (Value.Call == "SingleSync" or Value.Call == "SingleAsync")

		--> Binding the listener. A Single event keeps one, and a second `.On()` replaces it -- which
		--> is the documented behaviour and stays that way. What it did not do is say so, and the
		--> silence hides a second-order effect: the FIRST listener's returned disconnect function is
		--> guarded by `Events[n] == Listener`, so once it has been replaced that disconnect quietly
		--> stops doing anything. Two systems that each connect and later disconnect therefore leave a
		--> listener attached that neither of them believes it owns. Upstream #167.
		local function BindListener(Target: Blocks.Block): Blocks.Block
			--> A Many event's list is replaced, never edited in place: a dispatch in progress iterates
			--> the list it started with. Removing from that list shifted the next listener into an index
			--> the loop had already passed, so a listener that disconnected itself -- a "once" -- made
			--> the one after it miss the event. Copying costs an allocation per connect and disconnect,
			--> and nothing per event.
			if not IsSingle then
				return Target:Line(`local Listeners = table.clone({Connection})`)
					:Line("table.insert(Listeners, Listener)")
					:Line(`{Connection} = Listeners`)
			end

			return Target:Line(`if {Connection} ~= nil then`)
				:Line(
					`\twarn("[BlinkBlox]: \\"{Declaration.Name}\\" already has a listener. {Value.Call} keeps only the newest one, and the replaced listener's disconnect stops working.")`
				)
				:Line("end")
				:Line(`{Connection} = Listener`)
		end

		--> Create queue and event branch
		if not IsSingle then
			State.Events.Push(`{Connection} = \{}`)
		end

		State.Events.Push(`{Queue} = table.create(256)`)
		State.Events.Push(`EventNames.{ChannelName}[{Index}] = "{Declaration.Name}"`)
		local Block = Decode.Open(IsUnreliable, Index)

		--> Event recieve body
		local Listener: Blocks.Block
		local ContextArguments = `Listener: ({State.Context == "Server" and "Player: Player, " or ""}{Values}) -> ()`
		local Sender = if State.Context == "Server" then "Player, " else ""

		local Event: Listeners.Event = {
			Name = Declaration.Name,
			Context = State.Context,
			Connection = Connection,
			IsSync = IsSync,
			Validating = State.Options.SyncValidation == true,
		}

		--> Read before the payload, because that is the order it was written in. The DECISION comes
		--> after the payload is decoded, for the same reason the rate limit's does: a variable-length
		--> payload cannot be skipped without reading it.
		if IsSequenced then
			Types.u16.Read("OrderIdentifier", Block)
		end

		Traffic.Start(Block, Counters, IsSequenced)
		Block:Line(`local {InnerValues} = {Util.GetPath(Identifier, false, State.Scope)}()`)
		Traffic.Received(Block, Counters)
		local StreamStamp: string? = nil
		if Value.Stream then
			StreamStamp = Streams.Unwrap(Block, InnerArguments)
		elseif Value.Stamp then
			Stamps.Unwrap(Block, InnerArguments, Value.Stamp)
		end

		--> The decode above has to happen either way: payloads are variable length, so skipping an
		--> event without reading it would leave the cursor mid-event and turn the rest of the packet
		--> into garbage. What the limit saves is the listener and everything behind it.
		local RateGuard = RateGuardExpression(Value, Declaration.Name)
		if RateGuard then
			Block = Block:Compare(RateGuard, "true", "Equals")
		end

		local OrderGuard = if StreamStamp
			then Decode.StreamGuardExpression(Index, StreamStamp)
			else OrderGuardExpression(IsSequenced, Index)
		if OrderGuard then
			Block = Block:Compare(OrderGuard, "true", "Equals")
		end

		local Disconnect = Blocks.Function("", "", "()")
		if IsSingle then
			Disconnect = Disconnect:Compare(Connection, "Listener", "Equals"):Line(`{Connection} = nil`):End()
		else
			Disconnect = Disconnect:Line(`local Index = table.find({Connection}, Listener)`)
			Disconnect = Disconnect:Compare("Index", "nil", "Not")
				:Line(`local Listeners = table.clone({Connection})`)
				:Line("table.remove(Listeners, Index)")
				:Line(`{Connection} = Listeners`)
				:Line("ListenerEpoch += 1")
				:End()
		end

		Disconnect = Disconnect:End():Wrap("return ", "")

		--> Hands the event to its listeners, or -- for a reliable event with none bound -- queues it for
		--> the listener to come. The receive branch and Predict both go through this, so an event
		--> predicted locally is delivered exactly as one received from the network would be.
		--> A Single event's listener is read once, into a local, rather than looked up through two tables
		--> for the check and again for the call.
		--> `Received` is the decode loop's delivery, whose Single listener goes without a pcall of its own;
		--> see Listeners.Call.
		local function Deliver(Target: Blocks.Block, Payload: string, Received: boolean)
			local ListenerArguments = `{Sender}{Payload}`
			local Call =
				Listeners.Call(Event, "BOUND_LISTENER", ListenerArguments, "Player", true, Received and IsSingle)
			if IsSingle then
				Target:Line(`local BOUND_LISTENER = {Connection}`)
			end

			if not IsReliable then
				if IsSingle then
					Target:Compare("BOUND_LISTENER", "nil", "Not"):Lines(Call.Content, Target.Indent):End()
				else
					Listeners.Each(Target, Event, ListenerArguments)
				end

				return
			end

			local Bound: Blocks.Block
			if IsSingle then
				Bound = Target:Compare("BOUND_LISTENER", "nil", "Not"):Lines(Call.Content, Target.Indent)
			else
				Bound = Listeners.Each(Target:Compare(`#{Connection}`, "0", "Greater"), Event, ListenerArguments)
			end

			Queues.Enqueue(Bound:Branch("Default"), State.Context, Queue, ListenerArguments, Declaration.Name):End()
		end

		Deliver(Block, InnerArguments, true)

		if IsReliable then
			Listener = Listeners.Replay(
				BindListener(Blocks.Function(State.Casing.On, ContextArguments, `() -> ()`, true)),
				Event,
				Queue
			)
				:Lines(Disconnect.Content, 1)
				:End()
		else
			Listener = BindListener(Blocks.Function(State.Casing.On, ContextArguments, `() -> ()`, true))
				:Lines(Disconnect.Content, 1)
				:End()
		end

		if OrderGuard then
			Block = Block:End()
		end

		if RateGuard then
			Block = Block:End()
		end

		--> Predict (upstream issue #59, and the other half of #81).
		-->
		--> Delivers an event to this side's own listeners without going near a remote, so a test or a
		--> story can drive receiving code directly. It mirrors the receive path deliberately, queue
		--> included: a Predict that skipped the queue would behave differently from the network
		--> whenever no listener is attached yet, which is exactly the case tests hit most.
		if State.Options.Predict then
			local PredictArguments = `{State.Context == "Server" and "Player: Player, " or ""}{Values}`
			local Predict = Blocks.Function(State.Casing.Predict, PredictArguments, "()", true)

			--> A Many event with no listener used to be dropped here while the network queued it, and a
			--> Single one was queued past the cap the network stops at. Both now share the receive path.
			Deliver(Predict, Arguments, false)
			Predict:End()

			State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING,`, 0, Indent + 1)
			State.Noop.Push(`{State.Casing.Predict} = NOOP`, 0, Indent + 1)
			Body.PushLines(Listener:Wrap("", ",").Content, 0, Indent + 1)
			Body.PushLines(Predict.Content, 0, Indent + 1)
		else
			State.Noop.Push(`{State.Casing.On} = NOOP_RETURNING`, 0, Indent + 1)
			Body.PushLines(Listener.Content, 0, Indent + 1)
		end
	elseif Value.From ~= State.Context and IsPolling then
		State.Events.Push(`{Queue} = CreateQueue()`)
		State.Events.Push(`EventNames.{ChannelName}[{Index}] = "{Declaration.Name}"`)
		local Block = Decode.Open(IsUnreliable, Index)

		if IsSequenced then
			Types.u16.Read("OrderIdentifier", Block)
		end

		local PollArguments = `table.pack({State.Context == "Server" and "Player, " or ""}{Util.GetPath(
			Identifier,
			false,
			State.Scope
		)}())`
		local PollOrderGuard = OrderGuardExpression(IsSequenced, Index)
		local PollRateGuard = RateGuardExpression(Value, Declaration.Name)

		--> On the server the queue is filled by clients, so it stops at a cap; see MAX_POLLED in the
		--> server template. Every check gates the same enqueue, so they combine into one condition.
		local Checks = {}
		if State.Context == "Server" then
			table.insert(Checks, `{Queue}.count < MAX_POLLED`)
		end

		if PollRateGuard then
			table.insert(Checks, PollRateGuard)
		end

		if PollOrderGuard then
			table.insert(Checks, PollOrderGuard)
		end

		PollRateGuard = if #Checks > 0 then table.concat(Checks, " and ") else nil

		Traffic.Start(Block, Counters, IsSequenced)
		if PollRateGuard then
			--> Split because the one-liner decodes and enqueues at once, and only the enqueue may be
			--> skipped.
			Block:Line(`local Arguments = {PollArguments}`)
			Block:Line(`if {PollRateGuard} then`)
			Block:Line(`\tPush({Queue}, Arguments)`)
			Block:Line("end")
		else
			Block:Line(`Push({Queue}, {PollArguments})`)
		end
		Traffic.Received(Block, Counters)

		local IterTypes = `number, {State.Context == "Server" and "Player, " or ""}{DataTypes}`

		local Next = Blocks.Function("", "", `({IterTypes})`)
			:Line("index += 1")
			:Line("local arguments = Pop(queue)")
			:Compare("arguments", "nil", "Not")
			:Return("index, unpack(arguments, 1, arguments.n)")
			:End()
			:Return(Util.ExhaustedValues(Value.Data :: any, State.Context))
			:End()
			:Wrap("return ", "")

		--> `Next` is the deprecated name of `Iter`, and the two are the same function.
		local function Iterator(Name: string): Blocks.Block
			return Blocks.Function(Name, "", `() -> ({IterTypes})`, true)
				:Line(`local index = 0`)
				:Line(`local queue = {Queue}`)
				:Lines(Next.Content, 1)
				:End()
		end

		local Deprecated = Iterator(State.Casing.Next)
		local Iter = Iterator(State.Casing.Iter):Wrap("", ",")

		State.Noop.Push(`{State.Casing.Iter} = NOOP_RETURNING,`, 0, Indent + 1)
		State.Noop.Push(`{State.Casing.Next} = NOOP_RETURNING`, 0, Indent + 1)

		Body.PushLines(Iter.Content, 0, Indent + 1)
		Body.Push("--- @deprecated v0.14.1 -- Use `Iter` instead.", 0, Indent + 1)
		Body.PushLines(Deprecated.Content, 0, Indent + 1)
	elseif State.Context == "Client" then
		local Fire = Blocks.Function(State.Casing.Fire, FireValues, "()", true)
		if IsReliable then
			--> Rolled back rather than left, because this write lands in the batch every other event
			--> is queued in. Half an event in there is not one bad send: the receiver reads the
			--> truncated event and then decodes the REST of the batch from the wrong offset.
			Writer.Begun(Fire)
			Traffic.Sent(Fire, Counters, "SendCursor - Cursor", false)
		else
			Fire:Line("Hold()")
			Fire:Line(`local Sent: boolean, Failure: any = {TryWriteEvent}`)
			--> Wrapped rather than returned out of: the saved buffer has to be restored either way,
			--> and an early return here would leave the caller's outgoing state swapped out.
			-->
			--> Which is exactly why the write is protected. A throw used to skip restoring the batch
			--> entirely, leaving this temporary buffer installed as the outgoing one -- so the next
			--> RELIABLE flush sent the scratch buffer and dropped everything already batched.
			Fire:Line(`if Sent and CheckUnreliableSize("{Declaration.Name}") then`)
			if Batches.Events() then
				--> Gathered with the frame's other unreliable events; see Batches.luau.
				State.UsesBatches = true
				Fire:Line("\tAppendUnreliable()")
			else
				Fire:Line("\tlocal Buffer = buffer.create(SendCursor)")
				Fire:Line("\tbuffer.copy(Buffer, 0, SendBuffer, 0, SendCursor)")
				Fire:Line("\tUnreliable:FireServer(Buffer, SendInstances)")
			end
			Traffic.Sent(Fire, Counters, "SendCursor", true, nil, "\t")
			Fire:Line("end")
			Fire:Line("Release()")
			Fire:Compare("Sent", "true", "Not"):Line("error(Failure, 0)"):End()
		end
		Fire:End()

		State.Noop.Push(`{State.Casing.Fire} = NOOP`, 0, Indent + 1)
		Body.PushLines(Fire.Content, 0, Indent + 1)
	elseif Value.Stream then
		--> Sent by the scheduler rather than by the game, so the server has Set and its friends in
		--> place of the Fire family. See Stream.luau.
		Streams.Server(Declaration, Index, Values, WriteEvent, Body, Indent, Counters)
	else
		local Outgoing: Send.Send = {
			IsReliable = IsReliable,
			WriteEvent = WriteEvent,
			Name = Declaration.Name,
			Ordered = if IsSequenced then Index else nil,
			Instances = Writes.CarriesInstances(Value.Data),
			Traffic = Counters,
			Low = Outbound.Low(Value.Priority),
		}
		local Fire = Blocks.Function(State.Casing.Fire, `Player: Player, {Values}`, "()", true)
		if IsReliable then
			Fire:Line("LoadPlayer(Player)")
			Writer.Player(Fire)
			Traffic.Sent(Fire, Counters, "SendCursor - Cursor", false)
			Fire:Line("SavePlayerBuffer(Player)")
		else
			Send.One(Fire, Outgoing)
		end
		Fire:End()

		local FireAll = Send.Broadcast(
			Blocks.Function(State.Casing.FireAll, Values, "()", true),
			Outgoing,
			"Players:GetPlayers()",
			{ AllClients = true }
		)
		local FireList = Send.Broadcast(
			Blocks.Function(State.Casing.FireList, `List: \{Player\}, {Values}`, "()", true),
			Outgoing,
			"List",
			{}
		)
		local FireExcept = Send.Broadcast(
			Blocks.Function(State.Casing.FireExcept, `Except: Player, {Values}`, "()", true),
			Outgoing,
			"Players:GetPlayers()",
			{ SkipExcept = true }
		)

		State.Noop.PushLines({
			`{State.Casing.Fire} = NOOP,\n`,
			`{State.Casing.FireAll} = NOOP,\n`,
			`{State.Casing.FireList} = NOOP,\n`,
			`{State.Casing.FireExcept} = NOOP\n`,
		}, 0, Indent + 1)

		Body.PushLines(Fire:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireAll:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireList:Wrap("", ",").Content, 0, Indent + 1)
		Body.PushLines(FireExcept:Wrap("", ",").Content, 0, Indent + 1)
	end

	Channel.Count += 1

	Body.Push(`\},`, 0, Indent)
	State.Noop.Push(`\},`, 0, Indent)
	State.Return.PushLines(Body.DumpLines(), 0)
end

return Declarations
