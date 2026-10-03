--> A bench is a pool of payloads, fired in turn. This one is a single payload, the same every time:
--> the original methodology, kept so the numbers stay comparable with earlier runs.
local Array = {}
for Index = 1, 100 do
	table.insert(Array, {
		id = math.random(1, 255),
		x = math.random(1, 255),
		y = math.random(1, 255),
		z = math.random(1, 255),
		orientation = math.random(1, 255),
		animation = math.random(1, 255),
	})
end
return { Array }
