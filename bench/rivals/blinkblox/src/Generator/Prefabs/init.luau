--!strict
--!native
--!optimize 2

--- How each primitive is read from and written to a buffer, and the runtime checks that go with it.
---
--- Common.luau holds the registries every other file adds to. They load in dependency order: f16
--- reads through u16, and CFrame through vector.
local AssertsModule = require("@self/Asserts")
local Common = require("@self/Common")

--> Each adds its prefabs to the registries as it loads. Only Lengths's value is used: the length
--> prefixes arrays share with strings.
local Lengths = require("@self/Lengths")
local _ = require("@self/Numbers")
local _ = require("@self/Roblox")

return {
	Types = Common.Types,
	Asserts = AssertsModule.Asserts,
	EmitCapacityGuard = AssertsModule.EmitCapacityGuard,
	EmitLengthGuard = AssertsModule.EmitLengthGuard,
	EmitReceivedLength = AssertsModule.EmitReceivedLength,
	Primitives = Common.Primitives,
	Required = Common.Required,
	GetTypeToUse = Common.GetTypeToUse,
	GetTypeToUseByBits = Common.GetTypeToUseByBits,
	ReadPrefix = Lengths.ReadPrefix,
	WritePrefix = Lengths.WritePrefix,
}
