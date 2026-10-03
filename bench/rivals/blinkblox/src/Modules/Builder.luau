--!strict
--!native
--!optimize 2

local Builder = {}

function Builder.new(): Builder
	local Strings = table.create(512)

	local function PushLines(Lines: { string }, Returns: number?, Tabs: number?)
		local Size = #Lines
		local Last = Lines[Size]

		local TabCount = Tabs or 0
		local ReturnCount = Returns or 0

		--> FAST PATH :SUNGLASSES:
		if TabCount == 0 and ReturnCount == 0 then
			table.move(Lines, 1, Size, #Strings + 1, Strings)
			return
		end

		local Indentation = string.rep("\t", TabCount)

		--> A trailing empty line, as `string.split` leaves after a final newline, is not emitted. It used
		--> to be dropped by writing nil into the caller's list after the count was lowered, which erased
		--> the line before it instead and left the empty one in place.
		if Last == "" then
			Size -= 1
		end

		for Index = 1, Size do
			table.insert(Strings, `{Indentation}{Lines[Index]}{Index == Size and string.rep("\n", ReturnCount) or ""}`)
		end
	end

	return {
		Push = function(Text: string, Returns: number?, Tabs: number?)
			table.insert(Strings, `{string.rep("\t", Tabs or 0)}{Text}\n{string.rep("\n", Returns or 0)}`)
		end,

		PushFront = function(Text: string, Returns: number?, Tabs: number?)
			table.insert(Strings, 1, `{string.rep("\n", Returns or 1)}{Text}{string.rep("\t", Tabs or 0)}\n`)
		end,

		PushLines = PushLines,
		PushMultiline = function(Text: string, Returns: number?, Tabs: number?)
			PushLines(string.split(Text, "\n"), Returns, Tabs)
		end,

		Print = function()
			print(table.concat(Strings))
		end,

		DumpNoClear = function()
			return table.concat(Strings)
		end,

		Dump = function(): string
			local Text = table.concat(Strings)
			table.clear(Strings)
			return Text
		end,

		DumpLines = function(): { string }
			return Strings
		end,
	}
end

export type Builder = typeof(Builder.new())

return Builder
