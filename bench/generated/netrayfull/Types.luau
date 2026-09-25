--!strict
--!native
--!optimize 2
-- Name: Types
-- Purpose: Generated Luau types for NetRay schema
-- Generated-by: NetRay-Compiler

export type TypeBranding = "Off" | "On"
export type ActiveTypeBranding = "Off"
export type Brand<T, B> = T & { __brand: B }
export type u8 = number
export type i8 = number
export type u16 = number
export type i16 = number
export type u32 = number
export type i32 = number
export type f16 = number
export type f32 = number
export type f64 = number

export type Connection = {
    Connected: boolean,
    Disconnect: (self: Connection) -> (),
}

export type EventSender1<T> = {
    Fire: (T) -> boolean,
}
export type EventReceiver1<T> = {
    On: ((T) -> ()) -> Connection,
}
export type EventDuplex1<T> = EventSender1<T> & EventReceiver1<T>

export type NetStats = {
    GetReliableDropped: () -> number,
    GetUnreliableDropped: () -> number,
    GetReliableQueueSize: () -> number,
    GetUnreliableQueueSize: () -> number,
}

export type Entity = {
    id: u8,
    x: u8,
    y: u8,
    z: u8,
    orientation: u8,
    animation: u8,
}

export type Move = {
    pos: Vector3,
    vel: Vector3,
    yaw: f32,
    grounded: boolean,
    crouch: boolean,
    sprint: boolean,
    anim: u8,
}

export type Car = {
    brand: string,
    carName: string,
    carId: u16,
    available: boolean,
    dealers: u8,
    price: f64,
}

export type Net_Booleans_reliable_Args = () -> { boolean }
export type Net_Booleans_reliable_TupleHandler = ({ boolean }) -> ()
export type Net_Booleans_reliable_ClientEventCallback = (v1: { boolean }) -> ()
export type Net_Booleans_reliable_ServerEventCallback = (player: Player, v1: { boolean }) -> ()
export type Net_Booleans_reliable_ClientApi = {
    Fire: ({ boolean }) -> boolean,
}
export type Net_Booleans_reliable_ServerApi = {
    On: (Net_Booleans_reliable_ServerEventCallback) -> Connection,
}

export type Net_Entities_reliable_Args = () -> { Entity }
export type Net_Entities_reliable_TupleHandler = ({ Entity }) -> ()
export type Net_Entities_reliable_ClientEventCallback = (v1: { Entity }) -> ()
export type Net_Entities_reliable_ServerEventCallback = (player: Player, v1: { Entity }) -> ()
export type Net_Entities_reliable_ClientApi = {
    Fire: ({ Entity }) -> boolean,
}
export type Net_Entities_reliable_ServerApi = {
    On: (Net_Entities_reliable_ServerEventCallback) -> Connection,
}

export type Net_Chat_reliable_Args = () -> (string, u8)
export type Net_Chat_reliable_TupleHandler = (string, u8) -> ()
export type Net_Chat_reliable_ClientEventCallback = (v1: string, v2: u8) -> ()
export type Net_Chat_reliable_ServerEventCallback = (player: Player, v1: string, v2: u8) -> ()
export type Net_Chat_reliable_ClientApi = {
    Fire: (string, u8) -> boolean,
}
export type Net_Chat_reliable_ServerApi = {
    On: (Net_Chat_reliable_ServerEventCallback) -> Connection,
}

export type Net_Cars_reliable_Args = () -> Car
export type Net_Cars_reliable_TupleHandler = (string, string, u16, boolean, u8, f64) -> ()
export type Net_Cars_reliable_ClientEventCallback = (data_brand: string, data_carName: string, data_carId: u16, data_available: boolean, data_dealers: u8, data_price: f64) -> ()
export type Net_Cars_reliable_ServerEventCallback = (player: Player, data_brand: string, data_carName: string, data_carId: u16, data_available: boolean, data_dealers: u8, data_price: f64) -> ()
export type Net_Cars_reliable_ClientApi = {
    Fire: (Car) -> boolean,
}
export type Net_Cars_reliable_ServerApi = {
    On: (Net_Cars_reliable_ServerEventCallback) -> Connection,
}

export type Net_Moves_reliable_Args = () -> Move
export type Net_Moves_reliable_TupleHandler = (Vector3, Vector3, f32, boolean, boolean, boolean, u8) -> ()
export type Net_Moves_reliable_ClientEventCallback = (data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ()
export type Net_Moves_reliable_ServerEventCallback = (player: Player, data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ()
export type Net_Moves_reliable_ClientApi = {
    On: (Net_Moves_reliable_ClientEventCallback) -> Connection,
}
export type Net_Moves_reliable_ServerApi = {
    Fire: (Player, Move) -> boolean,
    FireAll: (Move) -> boolean,
    FireList: ({ Player }, Move) -> boolean,
    FireExcept: (Player, Move) -> boolean,
}

export type Net_MovesU_unreliable_Args = () -> Move
export type Net_MovesU_unreliable_TupleHandler = (Vector3, Vector3, f32, boolean, boolean, boolean, u8) -> ()
export type Net_MovesU_unreliable_ClientEventCallback = (data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ()
export type Net_MovesU_unreliable_ServerEventCallback = (player: Player, data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ()
export type Net_MovesU_unreliable_ClientApi = {
    On: (Net_MovesU_unreliable_ClientEventCallback) -> Connection,
}
export type Net_MovesU_unreliable_ServerApi = {
    Fire: (Player, Move) -> boolean,
    FireAll: (Move) -> boolean,
    FireList: ({ Player }, Move) -> boolean,
    FireExcept: (Player, Move) -> boolean,
}

export type NetClient = {
Booleans: Net_Booleans_reliable_ClientApi,
Entities: Net_Entities_reliable_ClientApi,
Chat: Net_Chat_reliable_ClientApi,
Cars: Net_Cars_reliable_ClientApi,
Moves: Net_Moves_reliable_ClientApi,
MovesU: Net_MovesU_unreliable_ClientApi,
StepReplication: () -> (),
Stats: NetStats,
}

export type NetServer = {
Booleans: Net_Booleans_reliable_ServerApi,
Entities: Net_Entities_reliable_ServerApi,
Chat: Net_Chat_reliable_ServerApi,
Cars: Net_Cars_reliable_ServerApi,
Moves: Net_Moves_reliable_ServerApi,
MovesU: Net_MovesU_unreliable_ServerApi,
StepReplication: () -> (),
Stats: NetStats,
}

export type Net = NetClient | NetServer

local Types = {
    u8 = (0 :: any) :: u8,
    i8 = (0 :: any) :: i8,
    u16 = (0 :: any) :: u16,
    i16 = (0 :: any) :: i16,
    u32 = (0 :: any) :: u32,
    i32 = (0 :: any) :: i32,
    f16 = (0 :: any) :: f16,
    f32 = (0 :: any) :: f32,
    f64 = (0 :: any) :: f64,
    Connection = ({ Connected = true, Disconnect = function(_self) end } :: any) :: Connection,
    NetStats = ({ GetReliableDropped = function() return 0 end, GetUnreliableDropped = function() return 0 end, GetReliableQueueSize = function() return 0 end, GetUnreliableQueueSize = function() return 0 end } :: any) :: NetStats,
    Entity = ({} :: any) :: Entity,
    Move = ({} :: any) :: Move,
    Car = ({} :: any) :: Car,
    Net_Booleans_reliable_ClientEventCallback = ((function(...) end) :: any) :: Net_Booleans_reliable_ClientEventCallback,
    Net_Booleans_reliable_ServerEventCallback = ((function(...) end) :: any) :: Net_Booleans_reliable_ServerEventCallback,
    Net_Booleans_reliable_ClientApi = ({} :: any) :: Net_Booleans_reliable_ClientApi,
    Net_Booleans_reliable_ServerApi = ({} :: any) :: Net_Booleans_reliable_ServerApi,
    Net_Entities_reliable_ClientEventCallback = ((function(...) end) :: any) :: Net_Entities_reliable_ClientEventCallback,
    Net_Entities_reliable_ServerEventCallback = ((function(...) end) :: any) :: Net_Entities_reliable_ServerEventCallback,
    Net_Entities_reliable_ClientApi = ({} :: any) :: Net_Entities_reliable_ClientApi,
    Net_Entities_reliable_ServerApi = ({} :: any) :: Net_Entities_reliable_ServerApi,
    Net_Chat_reliable_ClientEventCallback = ((function(...) end) :: any) :: Net_Chat_reliable_ClientEventCallback,
    Net_Chat_reliable_ServerEventCallback = ((function(...) end) :: any) :: Net_Chat_reliable_ServerEventCallback,
    Net_Chat_reliable_ClientApi = ({} :: any) :: Net_Chat_reliable_ClientApi,
    Net_Chat_reliable_ServerApi = ({} :: any) :: Net_Chat_reliable_ServerApi,
    Net_Cars_reliable_ClientEventCallback = ((function(...) end) :: any) :: Net_Cars_reliable_ClientEventCallback,
    Net_Cars_reliable_ServerEventCallback = ((function(...) end) :: any) :: Net_Cars_reliable_ServerEventCallback,
    Net_Cars_reliable_ClientApi = ({} :: any) :: Net_Cars_reliable_ClientApi,
    Net_Cars_reliable_ServerApi = ({} :: any) :: Net_Cars_reliable_ServerApi,
    Net_Moves_reliable_ClientEventCallback = ((function(...) end) :: any) :: Net_Moves_reliable_ClientEventCallback,
    Net_Moves_reliable_ServerEventCallback = ((function(...) end) :: any) :: Net_Moves_reliable_ServerEventCallback,
    Net_Moves_reliable_ClientApi = ({} :: any) :: Net_Moves_reliable_ClientApi,
    Net_Moves_reliable_ServerApi = ({} :: any) :: Net_Moves_reliable_ServerApi,
    Net_MovesU_unreliable_ClientEventCallback = ((function(...) end) :: any) :: Net_MovesU_unreliable_ClientEventCallback,
    Net_MovesU_unreliable_ServerEventCallback = ((function(...) end) :: any) :: Net_MovesU_unreliable_ServerEventCallback,
    Net_MovesU_unreliable_ClientApi = ({} :: any) :: Net_MovesU_unreliable_ClientApi,
    Net_MovesU_unreliable_ServerApi = ({} :: any) :: Net_MovesU_unreliable_ServerApi,
    NetClient = ({} :: any) :: NetClient,
    NetServer = ({} :: any) :: NetServer,
    Net = ({} :: any) :: Net,
}

return table.freeze(Types)

