--!strict
--- The schema parser: recursive descent from tokens to the AST in AST.luau, with the semantic checks
--- that need the whole file run once it is parsed (see Analysis.luau).
---
--- One class, written across the files of this directory. Class.luau declares the state and every
--- method's signature; each other file adds a group of methods to it:
---
---   Stream       looking at and consuming tokens
---   Document     a whole file: options, imports, top-level declarations, then analysis
---   Structures   events, functions and scope blocks
---   Streams      an event's `Stream` block, and the wire type it gives the event
---   Stamps       an event's `Stamp`, and the wire type it gives the event
---   Types        the type grammar's keyword dispatch, and primitives
---   Collections  sets, maps, enums, tagged enums, type packs and structs
---   Ranges       ranges, array brackets, components and the optional mark
---   Scales       a number's modifiers: its scale and `saturate`
---   Symbols      references, declarations and generic substitution
local Class = require("@self/Class")

--> Each adds its methods to the class as it loads; the values are not used.
local _ = {
	require("@self/Stream"),
	require("@self/Document"),
	require("@self/Structures"),
	require("@self/Streams"),
	require("@self/Stamps"),
	require("@self/Types"),
	require("@self/Collections"),
	require("@self/Ranges"),
	require("@self/Scales"),
	require("@self/Symbols"),
}

--> Re-exported so `Parser.TypeNode` and the rest keep resolving for everything that requires the
--> parser. The definitions are in AST.luau.
export type NumberRange = Class.NumberRange
export type Scope = Class.Scope
export type Options = Class.Options
export type Body = Class.Body
export type TypeNode = Class.TypeNode
export type Declaration = Class.Declaration
export type Array = Class.Array
export type Optional = Class.Optional
export type Set = Class.Set
export type Map = Class.Map
export type Enum = Class.Enum
export type TagEnum = Class.TagEnum
export type Struct = Class.Struct
export type Primitive = Class.Primitive
export type Generic = Class.Generic
export type Tuple = Class.Tuple
export type EventCall = Class.EventCall
export type Event = Class.Event
export type StreamSettings = Class.StreamSettings
export type StampSettings = Class.StampSettings
export type Function = Class.Function
export type ScopeNode = Class.ScopeNode

export type Parser = Class.Parser

return Class.Class
