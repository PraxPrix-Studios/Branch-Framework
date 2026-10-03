--!strict
--- Warns about `Priority: Low` in a schema that sets no outbound budget.
---
--- A low priority leaves a send to a player out while that player's budget is spent, and without
--- `option OutboundBytesPerSecond` there is no budget to spend: every send goes, as if the field were
--- not there. That is harmless, so it is a warning rather than a refusal, but it is almost always a
--- schema that meant to set the option and did not.
---
--- It descends into imported scopes, as InstanceSlots.luau does: an import's events share the option.
local Error = require("./Error")
local Lexer = require("../Lexer")

type Token = Lexer.Token
--- A structural stand-in for the parser's nodes. Requiring the parser here would close a cycle.
type Declaration = any

local function Check(Source: string, File: string?, Declarations: { Declaration }, Options: any)
	if Options.OutboundBytesPerSecond ~= nil then
		return
	end

	local function Visit(List: { Declaration }, Import: Token?): boolean
		for _, Declaration in List do
			local Kind = Declaration.Type
			if Kind == "Scope" then
				local Value = Declaration.Value
				if Visit(Value.Values, Import or (if Value.Imported then Declaration.Tokens.Path else nil)) then
					return true
				end
				continue
			elseif Kind ~= "Event" or Declaration.Value.Priority ~= "Low" then
				continue
			end

			local Diagnostic =
				Error.new(Error.AnalyzeInvalidPriority, Source, `Priority of "{Declaration.Name}" has no effect`, File)
			if Import then
				Diagnostic:Primary(Import, `This import declares "{Declaration.Name}" with Priority: Low`)
			else
				Diagnostic:Primary(Declaration.Tokens.Identifier, "Declared Priority: Low")
			end

			Diagnostic:Note("Without option OutboundBytesPerSecond there is no budget, and every send goes."):Warn()

			--> One warning says it; a schema of fifty low events would otherwise print fifty.
			return true
		end

		return false
	end

	Visit(Declarations, nil)
end

return {
	Check = Check,
}
