--!strict
--- A short string that identifies what a schema puts ON THE WIRE, so the two generated modules can
--- notice at startup that they were built from different schemas.
---
--- The problem it solves is silent. Event ids are positional -- the first event declared is 0, the
--- next is 1 -- so inserting an event in the middle renumbers every event after it. A client running
--- last week's build then reads index 7 as whatever index 7 means now, decodes the payload of one
--- event as the payload of another, and dispatches it. Nothing errors. Several reports on the
--- devforum thread are this: someone edits a schema, forgets to recompile one side, and gets
--- `invalid argument #3 to 'writeu8'` or a listener firing with the wrong data.
---
--- THE RULE, which settles every case without judgement calls: options describe how the module is
--- GENERATED, declarations describe what goes ON THE WIRE, and only declarations are hashed. So
--- Casing, Typescript, the output paths, SyncValidation, Predict, the packet caps and the rate
--- options are all excluded by one rule rather than one at a time. RemoteScope is excluded too, for
--- a different reason: it is already part of the remote's name, so a scope mismatch means the client
--- never finds the remote at all and this never gets a chance to speak.
---
--- Pure Luau -- no @lune/*, no Roblox globals, structural `any` for the AST -- because the Studio
--- plugin runs the generator too. Modules/Size.luau has the same constraint and the same shape.
---
--- NOT a security measure, and the header of the generated file should not pretend otherwise: the
--- client owns its copy of the module and can edit the constant out. This detects drift between two
--- builds, never tampering by someone who has both.

--- Bumped BY HAND whenever Generator/Prefabs/ changes what bytes a type occupies.
---
--- An AST hash cannot see that. 0.21.0 packed booleans into a shared bitfield and started encoding
--- lengths relative to their declared minimum; both changed every packet on the wire and neither
--- touched a single schema. Without this, two builds straddling that release would have agreed on
--- their signature and disagreed on every byte -- which is the exact failure this module exists to
--- catch, arriving through the one door an AST walk cannot watch.
---
--- 2: 0.27.0 packed `boolean[]` eight elements to a byte, where every element had been a byte.
--- 3: 0.40.0 dropped a stream's sequence number, which it is now ordered by its server time instead,
---    wrote a length nobody bounded, or one of two-byte span, as a varint, and a span past two bytes in
---    three where it had taken four, and put an enum's index and a tagged enum's tag in the bitfield.
local WIRE_VERSION = 3

--- Structural stand-ins for the parser's nodes. Requiring the parser here would close a cycle.
type Node = any
type Body = any

local Signature = {}

---- Canonical form ----

--- Every `Values` container in the AST is an array in declaration ORDER -- the parser inserts
--- positionally -- so there is no `pairs` anywhere below and nothing to sort. That is what makes a
--- signature reproducible between runs, which test/Harness.luau already checks by recompiling and
--- demanding byte-identical output.
local Serialise

--- `{Min}..{Max}` when a range is declared, empty when it is not. A range changes how many bytes a
--- number occupies and how a length is encoded, so it belongs in the signature; its absence has to
--- be distinguishable from `0..0`, hence the marker rather than a bare pair.
local function Range(Value: Node): string
	local Declared = Value.Range
	if not Declared then
		return ""
	end

	return `r{Declared.Min}..{Declared.Max}`
end

--- `k{Scale}` for a scaled number, empty otherwise. A scale changes what a count of steps means, so
--- `u16<0.1>` and `u16<0.01>` must not agree; `saturate` changes only which value is sent, never how
--- one is read, so it stays out.
local function Scale(Value: Node): string
	return if Value.Scale then `k{Value.Scale}` else ""
end

local function Components(Value: Node): string
	local Declared = Value.Components
	if not Declared or #Declared == 0 then
		return ""
	end

	return `c{table.concat(Declared, ",")}`
end

function Serialise(Node: Node): string
	if type(Node) ~= "table" or not Node.Type then
		return "_"
	end

	local Kind = Node.Type
	local Value = Node.Value

	if Kind == "Primitive" then
		--> The primitive's NAME lives on the token, not on the value: `Value.Primitive` is the shared
		--> Settings table describing how to read it, which has no identity to write down. Size.luau
		--> never needed the name because it reads `.Bytes`; this is the first consumer that does.
		local Tokens = Node.Tokens
		local Name = (Tokens and Tokens.Primitive and Tokens.Primitive.Value) or "?"
		local Class = if Value.Class then `({Value.Class})` else ""

		return `p:{Name}{Class}{Range(Value)}{Components(Value)}{Scale(Value)}`
	elseif Kind == "Array" then
		return `a:[{Serialise(Value.Of)}]{Range(Value)}`
	elseif Kind == "Optional" then
		return `o:{Serialise(Value.Of)}`
	elseif Kind == "Struct" then
		local Fields = table.create(#Value.Values)
		for Index, Field in Value.Values do
			Fields[Index] = `{Field.Name}={Serialise(Field)}`
		end

		return `s:\{{table.concat(Fields, ",")}\}`
	elseif Kind == "Map" then
		return `m:\{{Serialise(Value.Values[1])}=>{Serialise(Value.Values[2])}\}`
	elseif Kind == "Enum" then
		return `e:[{table.concat(Value.Values, ",")}]`
	elseif Kind == "Set" then
		return `n:[{table.concat(Value.Values, ",")}]`
	elseif Kind == "TagEnum" then
		local Variants = table.create(#Value.Values)
		for Index, Variant in Value.Values do
			Variants[Index] = `{Variant.Name}={Serialise(Variant)}`
		end

		return `g:{Value.Tag}\{{table.concat(Variants, ",")}\}`
	elseif Kind == "Tuple" then
		local Elements = table.create(#Value.Values)
		for Index, Element in Value.Values do
			local Name = Value.Names and Value.Names[Index]
			Elements[Index] = if Name then `{Name}={Serialise(Element)}` else Serialise(Element)
		end

		return `u:({table.concat(Elements, ",")})`
	elseif Kind == "Generic" then
		--> Substituted by the time a declaration is reachable from an event, so this only shows up in
		--> an uninstantiated template, which nothing sends.
		return `?:{Value.Generic}`
	end

	return `?:{Kind}`
end

---- Walk ----

--- Reproduces the generator's numbering without running it.
---
--- This works only because the two are genuinely the same walk: depth-first in declaration order,
--- into every scope including imported ones, with two counters. Both increments in the generator sit
--- outside every branch, so the Client pass and the Server pass assign identical ids -- which is the
--- fact that lets a standalone walk agree with both.
local function Collect(Declarations: { Node }, Channels: { Reliable: number, Unreliable: number }, Parts: { string })
	for _, Declaration in Declarations do
		local Kind = Declaration.Type
		local Value = Declaration.Value

		if Kind == "Scope" then
			Collect(Value.Values, Channels, Parts)
		elseif Kind == "Event" then
			--> Ordered events ride the unreliable channel, exactly as the generator routes them.
			local Unreliable = (Value.Type == "Unreliable" or Value.Type == "OrderedUnreliable")
			local Name = if Unreliable then "Unreliable" else "Reliable"
			local Index = Channels[Name :: "Reliable"]
			Channels[Name :: "Reliable"] = Index + 1

			--> Call and Rate are deliberately absent. Call decides whether a listener is spawned,
			--> Rate whether the server accepts it -- neither changes a byte, and a schema that only
			--> differs there is one the two sides can still talk across.
			table.insert(Parts, `E|{Name}|{Index}|{Value.From}|{Value.Type}|{Declaration.Name}|{Serialise(Value.Data)}`)
		elseif Kind == "Function" then
			local Index = Channels.Reliable
			Channels.Reliable = Index + 1

			--> From is signed for a function exactly as it is for an event: it decides which side
			--> listens, so two builds that disagree about it have one side calling into silence.
			table.insert(
				Parts,
				`F|{Index}|{Value.From}|{Declaration.Name}|{Serialise(Value.Data)}|{Serialise(Value.Return)}`
			)
		end
	end
end

---- Hash ----

--- Both lanes in one pass over the bytes, which is what they cost: reading a byte and going round the
--- loop, twice over, took most of generating a module's signature -- 0.7 ms for Test.blink's 7 KB,
--- nearly 3% of generating it. One pass through a buffer takes 0.27.
---
--- The first lane is FNV-1a over 32 bits. Its multiply by the prime 16777619 is written as
--- `Hash * 403 + (Hash << 24)`, since 16777619 is 2^24 + 403: the product `Hash * 403` stays under
--- 2^41, exact in a double on every host, and the shift truncates to 32 bits itself.
---
--- The second is djb2 with xor. A second lane of FNV under a different basis would stay partly
--- correlated with the first; the point of a second lane is independence, so it is a structurally
--- different mixer. Its `Hash * 33` is under 2^38, exact as well.
local function Lanes(Text: string): (number, number)
	local Bytes = buffer.fromstring(Text)
	local Fnv, Djb = 2166136261, 5381
	for Index = 0, buffer.len(Bytes) - 1 do
		local Byte = buffer.readu8(Bytes, Index)
		Fnv = bit32.bxor(Fnv, Byte)
		Fnv = (Fnv * 403 + bit32.lshift(Fnv, 24)) % 4294967296
		Djb = bit32.bxor(Djb * 33 % 4294967296, Byte)
	end

	return Fnv, Djb
end

---- Public ----

--- The canonical string a signature is taken over. Exposed so a spec can say WHY two schemas differ
--- rather than only that they do.
function Signature.Canonical(Tree: Body): string
	local Parts = { `W{WIRE_VERSION}` }
	Collect(Tree.Value.Declarations, { Reliable = 0, Unreliable = 0 }, Parts)
	return table.concat(Parts, "\n")
end

--- Sixteen lowercase hex characters. Two independent 32-bit lanes, which is around 64 bits against
--- accidental drift -- the stated bar. Not cryptographic and not meant to be.
function Signature.Of(Tree: Body): string
	local Fnv, Djb = Lanes(Signature.Canonical(Tree))
	return string.format("%08x%08x", Fnv, Djb)
end

return Signature
