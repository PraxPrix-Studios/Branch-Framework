--!strict
--- Refuses `option MaxInstancesPerPacket = 0` beside anything a client sends an Instance in.
---
--- Zero is a real setting: a game whose clients never send an Instance says so, and the server drops
--- every packet that carries one before it is decoded. A schema that says so and then declares a
--- client-sent Instance anyway compiles into a module whose every such packet is refused -- the event
--- never arrives, and the only sign is a warning per second on the server. So it is refused here.
---
--- What a client sends: the data of a `From: Client` event or function, and the return of a
--- `From: Server` function, since the client's reply travels on the same remote as its events and
--- passes the same guard. Instances and `unknown` both ride the remote's instance table.
---
--- Unlike most checks, this one descends into imported scopes: an import's events share the remote
--- and the option. An offending declaration inside one is reported at its `import`, the only span
--- this file has for it, as the channel-size check does.
local Error = require("./Error")
local Lexer = require("../Lexer")
local Size = require("./Size")

type Token = Lexer.Token
--- Structural stand-ins for the parser's nodes. Requiring the parser here would close a cycle.
type Declaration = any

--- The type nodes of `Declaration` that a client writes, or none.
local function ClientSent(Declaration: Declaration): { any }
	local Value = Declaration.Value
	if Value.From == "Client" then
		return if Value.Data then { Value.Data } else {}
	elseif Declaration.Type == "Function" and Value.Return then
		return { Value.Return }
	end

	return {}
end

local function Check(Source: string, File: string?, Declarations: { Declaration }, Options: any)
	if Options.MaxInstancesPerPacket ~= 0 then
		return
	end

	local function Visit(List: { Declaration }, Import: Token?)
		for _, Declaration in List do
			local Kind = Declaration.Type
			if Kind == "Scope" then
				local Value = Declaration.Value
				Visit(Value.Values, Import or (if Value.Imported then Declaration.Tokens.Path else nil))
				continue
			elseif Kind ~= "Event" and Kind ~= "Function" then
				continue
			end

			for _, Root in ClientSent(Declaration) do
				if Size.Sealed(Root).Refs == 0 then
					continue
				end

				local Noun = string.lower(Kind)
				local Diagnostic = Error.new(
					Error.AnalyzeInstanceWithoutSlots,
					Source,
					`Client-sent {Noun} "{Declaration.Name}" carries an Instance`,
					File
				)

				if Import then
					Diagnostic:Primary(
						Import,
						`This import declares "{Declaration.Name}", which a client sends Instances in`
					)
				else
					Diagnostic:Primary(Declaration.Tokens.Identifier, "Its packets carry an Instance or unknown")
				end

				Diagnostic:Note("option MaxInstancesPerPacket is 0, so the server drops every packet that carries one.")
					:Note("Raise MaxInstancesPerPacket, or send the Instance some other way, such as an id.")
					:Emit()
				break
			end
		end
	end

	Visit(Declarations, nil)
end

return {
	Check = Check,
}
