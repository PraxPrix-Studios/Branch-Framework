-- The Branch side of the in-engine benchmark: the same events as
-- Engine.blink (Blink) and Engine.idl (NetRay).
-- Branch Studio compiles this declaration into generated/engine/branch/.
Bench.Network = { -- a segment named Bench: Branch.Network.Server.Bench / .Client.Bench
	Cars = { From = "Client", Call = "Sync", Unpack = true, Data = { brand = "string", carName = "string", carId = "u16", available = "boolean", dealers = "u8", price = "f64" } },
	Moves = { From = "Server", Call = "Sync", Unpack = true, Data = { pos = "vector", vel = "vector", yaw = "f32", grounded = "boolean", crouch = "boolean", sprint = "boolean", anim = "u8" } },
	Ping = { Data = "f64", Return = "f64" },
}
