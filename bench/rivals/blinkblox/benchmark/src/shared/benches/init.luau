--> Each bench is a POOL of payloads: event N of a run sends payload (N - 1) % #Pool + 1. A pool of one
--> is the original methodology, the same data every time.
local Benches: { [string]: { any } } = {}
for Index, Bench in script:GetChildren() do
	--> Reset random seed to a constant value
	--> This results in the same values being generated on both server and client
	math.randomseed(0)
	Benches[Bench.Name] = require(Bench)
end
return Benches
