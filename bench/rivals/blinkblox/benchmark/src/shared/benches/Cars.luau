--> Branch's own bench (Branch-Studio/tests/bench): the entity of NetRay's Benchmark.rbxl -- two
--> strings of 2..100 letters, a u16, a boolean, a u8 and an f64 -- as a pool of 50 cars.
local function Text(): string
	local Length = math.random(2, 100)
	local Letters = table.create(Length)
	for Index = 1, Length do
		Letters[Index] = string.char(math.random(97, 122))
	end
	return table.concat(Letters)
end

local Pool = table.create(50)
for Index = 1, 50 do
	local Brand = Text()
	local CarName = Text()
	Pool[Index] = {
		brand = Brand,
		carName = CarName,
		carId = math.random(0, 65535),
		available = math.random(0, 1) == 1,
		dealers = math.random(0, 127),
		price = math.random(0, 1e9) * 1000,
	}
end
return Pool
