-- The Branch side of the Lune / browser benchmark: the same events as
-- Definition.blink (Blink) and netray/Bench.idl (NetRay).
-- Branch Studio compiles this declaration into generated/branch/, and the
-- same with Unpack = true on Cars / Moves / MovesU into generated/branch-unpack/.
Bench.Network = { -- a segment named Bench: Branch.Network.Server.Bench / .Client.Bench
	Booleans = { From = "Client", Call = "Sync", Data = "boolean[..1000]" },
	Entities = { From = "Client", Call = "Sync", Data = "{ id: u8, x: u8, y: u8, z: u8, orientation: u8, animation: u8 }[..1000]" },
	Chat = { From = "Client", Call = "Sync", Data = { "string", "u8" } },
	Cars = { From = "Client", Call = "Sync", Data = { brand = "string", carName = "string", carId = "u16", available = "boolean", dealers = "u8", price = "f64" } },
	Moves = { From = "Server", Call = "Sync", Data = { pos = "vector", vel = "vector", yaw = "f32", grounded = "boolean", crouch = "boolean", sprint = "boolean", anim = "u8" } },
	MovesU = { From = "Server", Type = "Unreliable", Call = "Sync", Data = { pos = "vector", vel = "vector", yaw = "f32", grounded = "boolean", crouch = "boolean", sprint = "boolean", anim = "u8" } },
}
