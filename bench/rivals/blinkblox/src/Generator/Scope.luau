--!strict
--- A scope of its own for one field of a struct; see the function below. Apart from Blocks.luau, which
--- it works on, because that file is at its size cap.
local Blocks = require("./Blocks")

--- Runs `Emit` on `self`, then closes what it wrote at the block's level in a `do ... end` of its own
--- if it declared any local there, and forgets the names it declared.
---
--- Luau allows a function 200 locals, and every local a serialiser declares for one field of a struct
--- -- a string's `Length`, a vector's components, a CFrame's parts -- used to stay live until the
--- function ended. A struct of fifty CFrames, or two hundred strings, generated a module that failed to
--- load with "Out of local registers". Each field's own locals end with the field now. A bitfield two
--- fields share lives outside every such scope: `Block.Bit` declares it at the top of the block.
return function(self: Blocks.Block, Emit: () -> ())
	local Before = #self.Content
	local Front = self.FrontInserted
	local Declared = table.clone(self.Variables)

	Emit()

	local First = Before + (self.FrontInserted - Front) + 1
	local Declaration = `{string.rep("\t", self.Indent)}local `
	local Declares = false
	for Index = First, #self.Content do
		if string.sub(self.Content[Index], 1, #Declaration) == Declaration then
			Declares = true
			break
		end
	end

	if not Declares then
		return
	end

	for Index = First, #self.Content do
		self.Content[Index] = `\t{self.Content[Index]}`
	end

	local Indentation = string.rep("\t", self.Indent)
	table.insert(self.Content, First, `{Indentation}do\n`)
	table.insert(self.Content, `{Indentation}end\n`)
	self.Variables = Declared
end
