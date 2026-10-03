--!strict
return {
	Merge = function(...: { any }): { any }
		local Tables = { ... }
		local Allocate = 0

		for _, Table in Tables do
			Allocate += #Table
		end

		local Index = 1
		local Merged = table.create(Allocate)

		for _, Table in Tables do
			table.move(Table, 1, #Table, Index, Merged)
			Index += #Table
		end

		return Merged
	end,
	--- A copy of `Table` and everything it reaches, except the values of any key in `Shared`, which the
	--- copy refers to rather than copies.
	DeepClone = function(Table: { [any]: any }, Shared: { [any]: true }?): { [any]: any }
		local Cache = {}

		local function Clone(Original: any): any
			local Cached = Cache[Original]
			if Cached ~= nil then
				return Cached
			end

			local Copy = Original
			if type(Original) == "table" then
				Copy = {}
				Cache[Original] = Copy

				for Key, Value in Original do
					if Shared and Shared[Key] then
						Copy[Key] = Value
					else
						Copy[Clone(Key)] = Clone(Value)
					end
				end
			end

			return Copy
		end

		return Clone(Table)
	end,
}
