--!strict
--- The one description of how the AST nests, for every stage that has to visit all of it.
---
--- Before this, each walk spelled out the node kinds on its own -- which fields hold children, and
--- that a tagged enum's variants hold fields of their own -- and the copies had already drifted: the
--- generic substitution never descended into a type pack. A new node kind is now one edit here.
local AST = require("../AST")

type TypeNode = AST.TypeNode
type Declaration = AST.Declaration

local Walk = {}

--- The type nodes directly inside `Node`, in the order they are written. A tagged enum's children
--- are its variants, each a struct whose fields are one level further down.
function Walk.Children(Node: TypeNode): { TypeNode }
	if Node.Type == "Array" or Node.Type == "Optional" then
		return { Node.Value.Of }
	elseif Node.Type == "Map" or Node.Type == "Struct" or Node.Type == "Tuple" then
		return Node.Value.Values
	elseif Node.Type == "TagEnum" then
		return Node.Value.Values :: { any }
	end

	--> Primitive, Enum, Set and Generic hold no type nodes.
	return {}
end

--- Calls `Visit` on `Node` and then on everything inside it, depth first. Tolerates a missing node,
--- which is what an event without `Data` or a function without `Return` passes in.
function Walk.Type(Node: TypeNode?, Visit: (Node: TypeNode) -> ())
	if type(Node) ~= "table" or not Node.Type then
		return
	end

	Visit(Node)

	for _, Child in Walk.Children(Node) do
		Walk.Type(Child, Visit)
	end
end

--- Calls `Visit` on every declaration written in THIS file, descending into its scopes.
---
--- An imported scope is skipped: its nodes carry spans into the imported source, so the parse of
--- that file is the one that reports on them -- underlining those offsets against this source would
--- point at whatever text happens to sit there.
function Walk.Declarations(Declarations: { Declaration }, Visit: (Declaration: Declaration) -> ())
	for _, Declaration in Declarations do
		if Declaration.Type == "Scope" then
			local Scope = Declaration :: any
			if not Scope.Value.Imported then
				Walk.Declarations(Scope.Value.Values, Visit)
			end

			continue
		end

		Visit(Declaration)
	end
end

--- The type nodes through which a declaration reaches the wire: an event's data, a function's data
--- and return, or a standalone type itself -- which is exported with a public reader of its own, so
--- it is reachable whether an event names it or not.
---
--- A generic template has none. Its parameters are unresolved, and it is the substituted copies that
--- are sent; those are ordinary declarations by the time anything walks them.
function Walk.Roots(Declaration: Declaration): { TypeNode }
	local Value = Declaration.Value :: any
	if Value.Generics then
		return {}
	end

	if Declaration.Type ~= "Event" and Declaration.Type ~= "Function" then
		return { Declaration :: any }
	end

	--> Either may be absent -- an event with no data, a function that returns nothing -- and a nil
	--> written into a constructor would leave a hole the caller's loop could stop at.
	local Roots = {}
	if Value.Data then
		table.insert(Roots, Value.Data)
	end

	if Declaration.Type == "Function" and Value.Return then
		table.insert(Roots, Value.Return)
	end

	return Roots
end

--- Calls `Visit` on every type node this file's declarations contain, generics already substituted.
function Walk.Types(Declarations: { Declaration }, Visit: (Node: TypeNode) -> ())
	Walk.Declarations(Declarations, function(Declaration)
		for _, Root in Walk.Roots(Declaration) do
			Walk.Type(Root, Visit)
		end
	end)
end

return Walk
