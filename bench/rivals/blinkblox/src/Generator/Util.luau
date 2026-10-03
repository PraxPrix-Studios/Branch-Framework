--!strict
local Grammar = require("../Modules/Grammar")
local Parser = require("../Parser")
local Signature = require("../Modules/Signature")

local LUAU_KEYWORDS = Grammar.LUAU_KEYWORDS

type Scope = Parser.Scope

local function GetScopePrefix(ReferenceScope: Scope?, Dots: boolean?, CurrentScope: Scope): string
	local Prefix = ""
	local WorkingScope: Scope? = ReferenceScope or CurrentScope
	while WorkingScope and WorkingScope.Name.Value ~= "" do
		Prefix = `{WorkingScope.Name.Value}{Dots and "." or "_"}` .. Prefix
		WorkingScope = WorkingScope.Parent
	end

	return Prefix
end

local function GetScopeIndent(CurrentScope: Scope): number
	return math.max(#string.split(GetScopePrefix(nil, true, CurrentScope), "."), 1)
end

local function GetTypesPath(Name: string, Write: boolean, CurrentScope: Scope): string
	return `SerdesFunctions.{GetScopePrefix(nil, false, CurrentScope)}{Write and "Write" or "Read"}{Name}`
end

local function GetExportName(Name: string, CurrentScope: Scope): string
	return `{GetScopePrefix(nil, false, CurrentScope)}{Name}`
end

local function GenerateEnumLiterals(Variants: { string }): string
	local Literals = {}
	for _, EnumItem in Variants do
		table.insert(Literals, `"{EnumItem}"`)
	end
	return `{table.concat(Literals, " | ")}`
end

--- Whether a name can be written bare, as a key or after a dot. A Luau keyword cannot, though it is a
--- legal field, flag or tag in a schema: emitted bare, `end` made `{ end: number }` and `Value.end`,
--- and the generated module failed to load.
local function IsValidIdentifier(Identifier: string): boolean
	return Identifier:match("%a%w*") == Identifier and not LUAU_KEYWORDS[Identifier]
end

--- A table key as it is written in a constructor: bare when it is an identifier, bracketed when a
--- schema named the field something Luau will not take unquoted.
local function FormatKey(Key: string): string
	if not IsValidIdentifier(Key) then
		return `["{Key}"]`
	end
	return Key
end

--- The same decision for an access rather than a constructor: `.Field` or `["odd field"]`.
local function FormatIndex(Index: string): string
	if not IsValidIdentifier(Index) then
		return `["{Index}"]`
	end
	return `.{Index}`
end

local function BitIndexToHex(Index: number): string
	return `0x{string.format("%x", 2 ^ Index)}`
end

--- The constants the generated module opens with: the remotes' names, and the signature of the
--- schema it was built from.
---
--- Routed through here rather than written inline because Generator/init.luau was over its size
--- limit when this was added. Nothing else about it wants to be separate.
---
--- The remotes are still named `BLINK_*` after the rename to BlinkBlox, and must stay so: the client
--- finds them by name, so a server and a client built by versions either side of a rename would never
--- meet -- the client would wait on a remote that does not exist, before the signature check that
--- would otherwise say what is wrong.
local function Constants(RemoteScope: string?, Tree: any): { string }
	local Scope = if RemoteScope then RemoteScope .. "_" else ""
	return {
		`local BASE_EVENT_NAME = "{Scope}BLINK"\n`,
		`local SCHEMA_SIGNATURE = "{Signature.Of(Tree)}"\n`,
		--> Exported as the module's Remotes, so that nothing outside it spells the names out again.
		`local REMOTE_NAMES = table.freeze(\{ Reliable = BASE_EVENT_NAME .. "_RELIABLE_REMOTE", Unreliable = BASE_EVENT_NAME .. "_UNRELIABLE_REMOTE" \})\n`,
	}
end

---- Type text shared by the Luau and TypeScript emitters ----
--
-- Both emitters write these the same way, and a fix to one has to reach the other: the TypeScript
-- side left a tagged enum's tag unquoted for as long as it held its own copy.

--- A set's type: one boolean per flag.
local function SetType(Flags: { string }): string
	local Entries: { string } = {}
	for _, Flag in Flags do
		table.insert(Entries, `{FormatKey(Flag)}: boolean,`)
	end

	return `\{{table.concat(Entries)}\}`
end

--- A tagged enum's type: a union of its variants' struct types, each with the tag field spliced in
--- after the opening brace. `VariantType` renders a variant's struct in the emitter's language.
local function TagEnumType(
	Tag: string,
	Variants: { Parser.Struct },
	VariantType: (Variant: Parser.Struct) -> string
): string
	local Literals: { string } = {}
	for _, Variant in Variants do
		local TagField = `{FormatKey(Tag)}: "{Variant.Name}"`
		table.insert(Literals, `\{ {TagField},{string.sub(VariantType(Variant), 2)}`)
	end

	return table.concat(Literals, " | ")
end

--- A struct's type. `FieldType` renders one field's type; `MarkOptional` puts `?` on the name of an
--- optional field, which TypeScript wants and Luau does not.
local function StructType(
	Fields: { Parser.TypeNode },
	FieldType: (Field: Parser.TypeNode) -> string,
	MarkOptional: boolean
): string
	local Entries: { string } = {}
	for _, Field in Fields do
		local Optional = if MarkOptional and Field.Type == "Optional" then "?" else ""
		table.insert(Entries, `{FormatKey(Field.Name)}{Optional}: {FieldType(Field)}`)
	end

	return `\{ {table.concat(Entries, ", ")}\ }`
end

--- `<A,B>` after a generic declaration's name, or nothing for one that is not generic.
local function GenericsHeader(Generics: { List: { string } }?): string
	if not Generics then
		return ""
	end

	return `<{table.concat(Generics.List, ",")}>`
end

--- The values a polled event's iterator returns once its queue is empty: one nil, typed `any`, for
--- each it returns otherwise -- the index, the sender on the server, then the data. A bare `return`
--- is refused by strict mode from a function declared to return values, and declaring them optional
--- instead would make them optional inside every `for` loop over it too.
local function ExhaustedValues(Data: Parser.Declaration?, Context: string): string
	local Tuple = if Data and Data.Type == "Tuple" then (Data :: any).Value.Values else nil
	local Count = 1 + (if Context == "Server" then 1 else 0) + (if Tuple then math.max(#Tuple, 1) else 1)
	return table.concat(table.create(Count, "nil :: any"), ", ")
end

return {
	ExhaustedValues = ExhaustedValues,
	SetType = SetType,
	TagEnumType = TagEnumType,
	StructType = StructType,
	GenericsHeader = GenericsHeader,
	GetPath = GetTypesPath,
	GetExportName = GetExportName,
	GetScopePrefix = GetScopePrefix,
	GetScopeIndent = GetScopeIndent,
	GenerateEnumLiterals = GenerateEnumLiterals,
	Constants = Constants,

	FormatKey = FormatKey,
	FormatIndex = FormatIndex,
	BitIndexToHex = BitIndexToHex,
	IsValidIdentifier = IsValidIdentifier,
}
