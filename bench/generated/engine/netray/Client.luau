--!strict
--!native
--!optimize 2
--!nolint LocalShadow
--#selene: allow(shadowing)
-- Name: Client
-- Purpose: Generated runtime for client networking
-- Generated-by: NetRay-Compiler
-- Version: 0.1.1

local Types = require(script.Parent.Types)
type u8 = typeof(Types.u8)
type i8 = typeof(Types.i8)
type u16 = typeof(Types.u16)
type i16 = typeof(Types.i16)
type u32 = typeof(Types.u32)
type i32 = typeof(Types.i32)
type f16 = typeof(Types.f16)
type f32 = typeof(Types.f32)
type f64 = typeof(Types.f64)
type NetRoot = typeof(Types.NetClient)
type NetStats = typeof(Types.NetStats)
type Connection = typeof(Types.Connection)
type Car = typeof(Types.Car)
type Move = typeof(Types.Move)
type Net_Cars_reliable_ClientApi = typeof(Types.Net_Cars_reliable_ClientApi)
type Net_Cars_reliable_ClientEventCallback = typeof(Types.Net_Cars_reliable_ClientEventCallback)
type Net_Moves_reliable_ClientApi = typeof(Types.Net_Moves_reliable_ClientApi)
type Net_Moves_reliable_ClientEventCallback = typeof(Types.Net_Moves_reliable_ClientEventCallback)
type Net_Ping_function_ClientApi = typeof(Types.Net_Ping_function_ClientApi)
type Net_Ping_function_ClientFunctionCallback = typeof(Types.Net_Ping_function_ClientFunctionCallback)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Reliable = ReplicatedStorage:WaitForChild("NetRay_RELIABLE") :: RemoteEvent
local Unreliable = ReplicatedStorage:WaitForChild("NetRay_UNRELIABLE") :: UnreliableRemoteEvent
local FunctionRemote = ReplicatedStorage:WaitForChild("NetRay_FUNCTION") :: RemoteFunction

local function WithCount(...)
    return select("#", ...), ...
end

local DEFAULT_ARENA_CAPACITY = 65536
local create = buffer.create
local copy = buffer.copy
local len = buffer.len
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16

local writef64 = buffer.writef64
local writestring = buffer.writestring
local readu8 = buffer.readu8

local readf32 = buffer.readf32
local readf64 = buffer.readf64
local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

local ERR_BOUNDS = "E_BOUNDS"
local ERR_SCHEMA = "E_SCHEMA"
local ERR_TAG = "E_TAG"
local ERR_TYPE = "E_TYPE"
local SEGMENT_MARKER_ID = 0

local function VarUIntSize(value)
    if value < 128 then return 1 end
    if value < 16384 then return 2 end
    if value < 2097152 then return 3 end
    if value < 268435456 then return 4 end
    return 5
end

local function WriteVarUInt(payload, offset, value)
    if value < 128 then
        writeu8(payload, offset, value)
        return offset + 1
    end
    if value < 16384 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, band(rshift(value, 7), 127))
        return offset + 2
    end
    if value < 2097152 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
        writeu8(payload, offset + 2, band(rshift(value, 14), 127))
        return offset + 3
    end
    if value < 268435456 then
        writeu8(payload, offset, bor(band(value, 127), 128))
        writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
        writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))
        writeu8(payload, offset + 3, band(rshift(value, 21), 127))
        return offset + 4
    end
    writeu8(payload, offset, bor(band(value, 127), 128))
    writeu8(payload, offset + 1, bor(band(rshift(value, 7), 127), 128))
    writeu8(payload, offset + 2, bor(band(rshift(value, 14), 127), 128))
    writeu8(payload, offset + 3, bor(band(rshift(value, 21), 127), 128))
    writeu8(payload, offset + 4, band(rshift(value, 28), 15))
    return offset + 5
end

local function ReadVarUInt(payload, payloadLength, offset)
    local next1 = offset + 1
    if next1 > payloadLength then error(ERR_BOUNDS) end
    local b1 = readu8(payload, offset)
    if b1 < 128 then return b1, next1 end
    local next2 = next1 + 1
    if next2 > payloadLength then error(ERR_BOUNDS) end
    local b2 = readu8(payload, next1)
    local value = band(b1, 127) + lshift(band(b2, 127), 7)
    if b2 < 128 then return value, next2 end
    local next3 = next2 + 1
    if next3 > payloadLength then error(ERR_BOUNDS) end
    local b3 = readu8(payload, next2)
    value += lshift(band(b3, 127), 14)
    if b3 < 128 then return value, next3 end
    local next4 = next3 + 1
    if next4 > payloadLength then error(ERR_BOUNDS) end
    local b4 = readu8(payload, next3)
    value += lshift(band(b4, 127), 21)
    if b4 < 128 then return value, next4 end
    local next5 = next4 + 1
    if next5 > payloadLength then error(ERR_BOUNDS) end
    local b5 = readu8(payload, next4)
    if b5 >= 16 then error(ERR_SCHEMA) end
    value += lshift(b5, 28)
    return value, next5
end

local function CreateConnection(disconnectFn: () -> ()): Connection
    local active = true
    local connection = {} :: any
    connection.Connected = true
    function connection:Disconnect()
        if not active then
            return
        end
        active = false
        connection.Connected = false
        disconnectFn()
    end
    return connection :: Connection
end

local MAX_RELIABLE_ID = 2
local MAX_UNRELIABLE_ID = 0
local MAX_FUNCTION_ID = 1
local RELIABLE_DISPATCH = table.create(MAX_RELIABLE_ID)
local UNRELIABLE_DISPATCH = table.create(MAX_UNRELIABLE_ID)
local RELIABLE_SKIP = table.create(MAX_RELIABLE_ID)
local UNRELIABLE_SKIP = table.create(MAX_UNRELIABLE_ID)
local FUNCTION_DISPATCH = table.create(MAX_FUNCTION_ID)

local RELIABLE_ARENA_CAPACITY = DEFAULT_ARENA_CAPACITY
local RELIABLE_ARENA = create(RELIABLE_ARENA_CAPACITY)
local RELIABLE_CURSOR = 0
local RELIABLE_QUEUE_SIZE = 0
local RELIABLE_DROPPED = 0
local RELIABLE_SEGMENT_HEADER_BYTES = 2
local RELIABLE_SEGMENT_MIN_COUNT = 4
local RELIABLE_SEGMENT_MIN_TAIL_BYTES = 3

local function FlushReliable()
    if RELIABLE_CURSOR == 0 then
        RELIABLE_QUEUE_SIZE = 0
        return
    end
    local payloadToSend = create(RELIABLE_CURSOR)
    local payloadOffset = RELIABLE_CURSOR
    if RELIABLE_QUEUE_SIZE >= RELIABLE_SEGMENT_MIN_COUNT then
        -- Only scan runs when the batch is large enough to amortize segment headers.
        local sourceOffset = 0
        payloadOffset = 0
        while sourceOffset < RELIABLE_CURSOR do
            local runStart = sourceOffset
            local messageId = readu8(RELIABLE_ARENA, sourceOffset)
            sourceOffset += 1
            local skip = RELIABLE_SKIP[messageId]
            local firstBodyEnd = skip(RELIABLE_ARENA, RELIABLE_CURSOR, sourceOffset)
            local runEnd = firstBodyEnd
            local runCount = 1
            if RELIABLE_CURSOR - firstBodyEnd < RELIABLE_SEGMENT_MIN_TAIL_BYTES then
                -- Remaining bytes cannot fit enough repeated IDs to make segmentation pay off.
                local tailSize = RELIABLE_CURSOR - runStart
                if tailSize > 0 then
                    copy(payloadToSend, payloadOffset, RELIABLE_ARENA, runStart, tailSize)
                    payloadOffset += tailSize
                end
                break
            end
            while runEnd < RELIABLE_CURSOR do
                local nextMessageId = readu8(RELIABLE_ARENA, runEnd)
                if nextMessageId ~= messageId then
                    break
                end
                local nextBodyStart = runEnd + 1
                runEnd = skip(RELIABLE_ARENA, RELIABLE_CURSOR, nextBodyStart)
                runCount += 1
            end
            if runCount * 1 > RELIABLE_SEGMENT_HEADER_BYTES + VarUIntSize(runCount) then
                writeu8(payloadToSend, payloadOffset, SEGMENT_MARKER_ID)
                payloadOffset += 1
                writeu8(payloadToSend, payloadOffset, messageId)
                payloadOffset += 1
                payloadOffset = WriteVarUInt(payloadToSend, payloadOffset, runCount)
                local copyCursor = sourceOffset
                local bodyEnd = firstBodyEnd
                while true do
                    local bodySize = bodyEnd - copyCursor
                    if bodySize > 0 then
                        copy(payloadToSend, payloadOffset, RELIABLE_ARENA, copyCursor, bodySize)
                        payloadOffset += bodySize
                    end
                    if bodyEnd >= runEnd then
                        break
                    end
                    copyCursor = bodyEnd + 1
                    bodyEnd = skip(RELIABLE_ARENA, RELIABLE_CURSOR, copyCursor)
                end
            else
                local runSize = runEnd - runStart
                if runSize > 0 then
                    copy(payloadToSend, payloadOffset, RELIABLE_ARENA, runStart, runSize)
                    payloadOffset += runSize
                end
            end
            sourceOffset = runEnd
        end
    else
        -- For tiny batches, a direct copy is cheaper than any merge scan.
        copy(payloadToSend, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
    end
    if payloadOffset < RELIABLE_CURSOR then
        local compactPayload = create(payloadOffset)
        copy(compactPayload, 0, payloadToSend, 0, payloadOffset)
        payloadToSend = compactPayload
    end
    Reliable:FireServer(payloadToSend)
    RELIABLE_CURSOR = 0
    RELIABLE_QUEUE_SIZE = 0
end

local UNRELIABLE_ARENA_CAPACITY = DEFAULT_ARENA_CAPACITY
local UNRELIABLE_ARENA = create(UNRELIABLE_ARENA_CAPACITY)
local UNRELIABLE_CURSOR = 0
local UNRELIABLE_QUEUE_SIZE = 0
local UNRELIABLE_DROPPED = 0
local UNRELIABLE_SEGMENT_HEADER_BYTES = 2
local UNRELIABLE_SEGMENT_MIN_COUNT = 4
local UNRELIABLE_SEGMENT_MIN_TAIL_BYTES = 3

local function FlushUnreliable()
    if UNRELIABLE_CURSOR == 0 then
        UNRELIABLE_QUEUE_SIZE = 0
        return
    end
    local payloadToSend = create(UNRELIABLE_CURSOR)
    local payloadOffset = UNRELIABLE_CURSOR
    if UNRELIABLE_QUEUE_SIZE >= UNRELIABLE_SEGMENT_MIN_COUNT then
        -- Only scan runs when the batch is large enough to amortize segment headers.
        local sourceOffset = 0
        payloadOffset = 0
        while sourceOffset < UNRELIABLE_CURSOR do
            local runStart = sourceOffset
            local messageId = readu8(UNRELIABLE_ARENA, sourceOffset)
            sourceOffset += 1
            local skip = UNRELIABLE_SKIP[messageId]
            local firstBodyEnd = skip(UNRELIABLE_ARENA, UNRELIABLE_CURSOR, sourceOffset)
            local runEnd = firstBodyEnd
            local runCount = 1
            if UNRELIABLE_CURSOR - firstBodyEnd < UNRELIABLE_SEGMENT_MIN_TAIL_BYTES then
                -- Remaining bytes cannot fit enough repeated IDs to make segmentation pay off.
                local tailSize = UNRELIABLE_CURSOR - runStart
                if tailSize > 0 then
                    copy(payloadToSend, payloadOffset, UNRELIABLE_ARENA, runStart, tailSize)
                    payloadOffset += tailSize
                end
                break
            end
            while runEnd < UNRELIABLE_CURSOR do
                local nextMessageId = readu8(UNRELIABLE_ARENA, runEnd)
                if nextMessageId ~= messageId then
                    break
                end
                local nextBodyStart = runEnd + 1
                runEnd = skip(UNRELIABLE_ARENA, UNRELIABLE_CURSOR, nextBodyStart)
                runCount += 1
            end
            if runCount * 1 > UNRELIABLE_SEGMENT_HEADER_BYTES + VarUIntSize(runCount) then
                writeu8(payloadToSend, payloadOffset, SEGMENT_MARKER_ID)
                payloadOffset += 1
                writeu8(payloadToSend, payloadOffset, messageId)
                payloadOffset += 1
                payloadOffset = WriteVarUInt(payloadToSend, payloadOffset, runCount)
                local copyCursor = sourceOffset
                local bodyEnd = firstBodyEnd
                while true do
                    local bodySize = bodyEnd - copyCursor
                    if bodySize > 0 then
                        copy(payloadToSend, payloadOffset, UNRELIABLE_ARENA, copyCursor, bodySize)
                        payloadOffset += bodySize
                    end
                    if bodyEnd >= runEnd then
                        break
                    end
                    copyCursor = bodyEnd + 1
                    bodyEnd = skip(UNRELIABLE_ARENA, UNRELIABLE_CURSOR, copyCursor)
                end
            else
                local runSize = runEnd - runStart
                if runSize > 0 then
                    copy(payloadToSend, payloadOffset, UNRELIABLE_ARENA, runStart, runSize)
                    payloadOffset += runSize
                end
            end
            sourceOffset = runEnd
        end
    else
        -- For tiny batches, a direct copy is cheaper than any merge scan.
        copy(payloadToSend, 0, UNRELIABLE_ARENA, 0, UNRELIABLE_CURSOR)
    end
    if payloadOffset < UNRELIABLE_CURSOR then
        local compactPayload = create(payloadOffset)
        copy(compactPayload, 0, payloadToSend, 0, payloadOffset)
        payloadToSend = compactPayload
    end
    Unreliable:FireServer(payloadToSend)
    UNRELIABLE_CURSOR = 0
    UNRELIABLE_QUEUE_SIZE = 0
end

local Net_Cars_reliable_1: Net_Cars_reliable_ClientApi = {} :: Net_Cars_reliable_ClientApi
local MESSAGE_ID_Net_Cars_reliable_1 = 1

local function Encode_Net_Cars_reliable_1(data)
    local prefixSize = 0
    local varSize = 0
    local stringLen_1 = #data.brand
    if stringLen_1 > 4294967295 then
        error(ERR_SCHEMA)
    end
    prefixSize += VarUIntSize(stringLen_1)
    varSize += stringLen_1
    local stringLen_2 = #data.carName
    if stringLen_2 > 4294967295 then
        error(ERR_SCHEMA)
    end
    prefixSize += VarUIntSize(stringLen_2)
    varSize += stringLen_2
    local totalSize = 1 + prefixSize + 12 + varSize
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Cars_reliable_1)
    local prefixOffset = 1
    local fixedOffset = prefixOffset + prefixSize
    local varOffset = fixedOffset + 12
    prefixOffset = WriteVarUInt(payload, prefixOffset, stringLen_1)
    writestring(payload, varOffset, data.brand)
    varOffset += stringLen_1
    prefixOffset = WriteVarUInt(payload, prefixOffset, stringLen_2)
    writestring(payload, varOffset, data.carName)
    varOffset += stringLen_2
    writeu16(payload, fixedOffset, data.carId)
    fixedOffset += 2
    writeu8(payload, fixedOffset, data.available and 1 or 0)
    fixedOffset += 1
    writeu8(payload, fixedOffset, data.dealers)
    fixedOffset += 1
    writef64(payload, fixedOffset, data.price)
    fixedOffset += 8
    return payload
end

local Handler_Net_Cars_reliable_1: ((data_brand: string, data_carName: string, data_carId: u16, data_available: boolean, data_dealers: u8, data_price: f64) -> ())? = nil
local HandlerToken_Net_Cars_reliable_1 = 0

local function Skip_Net_Cars_reliable_1(payload, payloadLength, offset)
    local prefixCursor_1 = offset
    local stringLen_2
    stringLen_2, prefixCursor_1 = ReadVarUInt(payload, payloadLength, prefixCursor_1)
    local stringLen_3
    stringLen_3, prefixCursor_1 = ReadVarUInt(payload, payloadLength, prefixCursor_1)
    local fixedCursor_4 = prefixCursor_1
    local varCursor_5 = fixedCursor_4 + 12
    if varCursor_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    local skipStringNext_6 = varCursor_5 + stringLen_2
    if skipStringNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    varCursor_5 = skipStringNext_6
    local skipStringNext_7 = varCursor_5 + stringLen_3
    if skipStringNext_7 > payloadLength then
        error(ERR_BOUNDS)
    end
    varCursor_5 = skipStringNext_7
    fixedCursor_4 += 2
    fixedCursor_4 += 1
    fixedCursor_4 += 1
    fixedCursor_4 += 8
    offset = varCursor_5
    return offset
end

RELIABLE_SKIP[1] = Skip_Net_Cars_reliable_1

function Net_Cars_reliable_1.Fire(data: Car): boolean
    local __nr_prefixSize = 0
    local __nr_varSize = 0
    local stringLen_1 = #data.brand
    if stringLen_1 > 4294967295 then
        error(ERR_SCHEMA)
    end
    __nr_prefixSize += VarUIntSize(stringLen_1)
    __nr_varSize += stringLen_1
    local stringLen_2 = #data.carName
    if stringLen_2 > 4294967295 then
        error(ERR_SCHEMA)
    end
    __nr_prefixSize += VarUIntSize(stringLen_2)
    __nr_varSize += stringLen_2
    local __nr_totalSize = 1 + __nr_prefixSize + 12 + __nr_varSize
    local __nr_base = RELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > RELIABLE_ARENA_CAPACITY then
        local nextCapacity = RELIABLE_ARENA_CAPACITY
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        local nextArena = create(nextCapacity)
        if RELIABLE_CURSOR > 0 then
            copy(nextArena, 0, RELIABLE_ARENA, 0, RELIABLE_CURSOR)
        end
        RELIABLE_ARENA = nextArena
        RELIABLE_ARENA_CAPACITY = nextCapacity
    end
    RELIABLE_CURSOR = __nr_required
    local __nr_payload = RELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Cars_reliable_1)
    local __nr_prefix = __nr_base + 1
    local __nr_fixed = __nr_prefix + __nr_prefixSize
    local __nr_var = __nr_fixed + 12
    __nr_prefix = WriteVarUInt(__nr_payload, __nr_prefix, stringLen_1)
    writestring(__nr_payload, __nr_var, data.brand)
    __nr_var += stringLen_1
    __nr_prefix = WriteVarUInt(__nr_payload, __nr_prefix, stringLen_2)
    writestring(__nr_payload, __nr_var, data.carName)
    __nr_var += stringLen_2
    writeu16(__nr_payload, __nr_fixed, data.carId)
    __nr_fixed += 2
    writeu8(__nr_payload, __nr_fixed, data.available and 1 or 0)
    __nr_fixed += 1
    writeu8(__nr_payload, __nr_fixed, data.dealers)
    __nr_fixed += 1
    writef64(__nr_payload, __nr_fixed, data.price)
    __nr_fixed += 8
    RELIABLE_QUEUE_SIZE += 1
    return true
end

local Net_Moves_reliable_2: Net_Moves_reliable_ClientApi = {} :: Net_Moves_reliable_ClientApi
local MESSAGE_ID_Net_Moves_reliable_2 = 2

local function Decode_Net_Moves_reliable_2(payload, payloadLength, offset)
    local decoded_data_pos
    local decoded_data_vel
    local decoded_data_yaw
    local decoded_data_grounded
    local decoded_data_crouch
    local decoded_data_sprint
    local decoded_data_anim
    local vectorNext_1 = offset + 12
    if vectorNext_1 > payloadLength then
        error(ERR_BOUNDS)
    end
    local vectorX_2 = readf32(payload, offset)
    local vectorY_3 = readf32(payload, offset + 4)
    local vectorZ_4 = readf32(payload, offset + 8)
    decoded_data_pos = Vector3.new(vectorX_2, vectorY_3, vectorZ_4)
    offset = vectorNext_1
    local vectorNext_5 = offset + 12
    if vectorNext_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    local vectorX_6 = readf32(payload, offset)
    local vectorY_7 = readf32(payload, offset + 4)
    local vectorZ_8 = readf32(payload, offset + 8)
    decoded_data_vel = Vector3.new(vectorX_6, vectorY_7, vectorZ_8)
    offset = vectorNext_5
    local fixedBlock_9 = offset
    local fixedBlockNext_10 = fixedBlock_9 + 8
    if fixedBlockNext_10 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = fixedBlockNext_10
    decoded_data_yaw = (readf32(payload, fixedBlock_9) :: f32)
    local rawBool_11 = readu8(payload, fixedBlock_9 + 4)
    decoded_data_grounded = rawBool_11 == 1
    local rawBool_12 = readu8(payload, fixedBlock_9 + 5)
    decoded_data_crouch = rawBool_12 == 1
    local rawBool_13 = readu8(payload, fixedBlock_9 + 6)
    decoded_data_sprint = rawBool_13 == 1
    decoded_data_anim = (readu8(payload, fixedBlock_9 + 7) :: u8)
    return decoded_data_pos, decoded_data_vel, decoded_data_yaw, decoded_data_grounded, decoded_data_crouch, decoded_data_sprint, decoded_data_anim, offset
end

local Handler_Net_Moves_reliable_2: ((data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ())? = nil
local HandlerToken_Net_Moves_reliable_2 = 0

function Net_Moves_reliable_2.On(callback: Net_Moves_reliable_ClientEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Moves_reliable_2 += 1
    local token = HandlerToken_Net_Moves_reliable_2
    Handler_Net_Moves_reliable_2 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Moves_reliable_2 == token then
            HandlerToken_Net_Moves_reliable_2 += 1
            Handler_Net_Moves_reliable_2 = nil
        end
    end)
end

RELIABLE_DISPATCH[2] = function(payload, payloadLength, offset)
    local decoded_data_pos, decoded_data_vel, decoded_data_yaw, decoded_data_grounded, decoded_data_crouch, decoded_data_sprint, decoded_data_anim, nextOffset = Decode_Net_Moves_reliable_2(payload, payloadLength, offset)
    local callback = Handler_Net_Moves_reliable_2
    if callback == nil then
        return nextOffset
    end
    callback(decoded_data_pos, decoded_data_vel, decoded_data_yaw, decoded_data_grounded, decoded_data_crouch, decoded_data_sprint, decoded_data_anim)
    return nextOffset
end

local Net_Ping_function_1: Net_Ping_function_ClientApi = {} :: Net_Ping_function_ClientApi
local MESSAGE_ID_Net_Ping_function_1 = 1

local function Encode_Net_Ping_function_1(v1)
    local totalSize = 9
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Ping_function_1)
    local offset = 1
    local fixedWriteBase_1 = offset
    writef64(payload, fixedWriteBase_1, v1)
    return payload
end

local function Decode_Net_Ping_function_1(payload, payloadLength, offset)
    local decoded_v1
    local fixedBlock_1 = offset
    local fixedBlockNext_2 = fixedBlock_1 + 8
    if fixedBlockNext_2 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = fixedBlockNext_2
    decoded_v1 = (readf64(payload, fixedBlock_1) :: f64)
    return decoded_v1, offset
end

local function EncodeReturn_Net_Ping_function_1(r1)
    local totalSize = 9
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Ping_function_1)
    local offset = 1
    local fixedWriteBase_1 = offset
    writef64(payload, fixedWriteBase_1, r1)
    return payload
end

local function DecodeReturn_Net_Ping_function_1(payload, payloadLength, offset)
    local decoded_r1
    local fixedBlock_1 = offset
    local fixedBlockNext_2 = fixedBlock_1 + 8
    if fixedBlockNext_2 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = fixedBlockNext_2
    decoded_r1 = (readf64(payload, fixedBlock_1) :: f64)
    return decoded_r1, offset
end

local Handler_Net_Ping_function_1: ((v1: f64) -> f64)? = nil
local HandlerToken_Net_Ping_function_1 = 0

function Net_Ping_function_1.On(callback: Net_Ping_function_ClientFunctionCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Ping_function_1 += 1
    local token = HandlerToken_Net_Ping_function_1
    Handler_Net_Ping_function_1 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Ping_function_1 == token then
            HandlerToken_Net_Ping_function_1 += 1
            Handler_Net_Ping_function_1 = nil
        end
    end)
end

function Net_Ping_function_1.Call(v1: f64): f64
    local requestPayload = Encode_Net_Ping_function_1(v1)
    local responseCount, responsePayload = WithCount(FunctionRemote:InvokeServer(requestPayload))
    if responseCount < 1 then
        error(ERR_SCHEMA)
    end
    if typeof(responsePayload) ~= "buffer" then
        error(ERR_TYPE)
    end
    local responseLength = len(responsePayload)
    if responseLength < 1 then
        error(ERR_BOUNDS)
    end
    local responseId = readu8(responsePayload, 0)
    if responseId ~= MESSAGE_ID_Net_Ping_function_1 then
        error(ERR_SCHEMA)
    end
    local decoded_r1, responseOffset = DecodeReturn_Net_Ping_function_1(responsePayload, responseLength, 1)
    if responseOffset ~= responseLength then
        error(ERR_SCHEMA)
    end
    return decoded_r1
end

FUNCTION_DISPATCH[1] = function(payload, payloadLength)
    local decoded_v1, offset = Decode_Net_Ping_function_1(payload, payloadLength, 1)
    if offset ~= payloadLength then
        error(ERR_SCHEMA)
    end
    local callback = Handler_Net_Ping_function_1
    if callback == nil then
        error(ERR_SCHEMA)
    end
    local callbackRet_1 = callback(decoded_v1)
    local responsePayload = EncodeReturn_Net_Ping_function_1(callbackRet_1)
    return responsePayload
end

local function StepReplication()
    FlushReliable()
    FlushUnreliable()
end

RunService.Heartbeat:Connect(StepReplication)

Reliable.OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "buffer" then
        return
    end
    local payloadLength = len(payload)
    if payloadLength < 1 then
        return
    end
    local offset = 0
    while offset < payloadLength do
        local messageId = readu8(payload, offset)
        offset += 1
        local segmentCount = 1
        local dispatch
        if messageId == SEGMENT_MARKER_ID then
            if offset >= payloadLength then
                return
            end
            messageId = readu8(payload, offset)
            offset += 1
            dispatch = RELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
            segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)
            if segmentCount < 1 then
                return
            end
        else
            dispatch = RELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
        end
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(payload, payloadLength, offset)
            offset = nextOffset
        end
    end
end)

Unreliable.OnClientEvent:Connect(function(payload)
    if typeof(payload) ~= "buffer" then
        return
    end
    local payloadLength = len(payload)
    if payloadLength < 1 then
        return
    end
    local offset = 0
    while offset < payloadLength do
        local messageId = readu8(payload, offset)
        offset += 1
        local segmentCount = 1
        local dispatch
        if messageId == SEGMENT_MARKER_ID then
            if offset >= payloadLength then
                return
            end
            messageId = readu8(payload, offset)
            offset += 1
            dispatch = UNRELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
            segmentCount, offset = ReadVarUInt(payload, payloadLength, offset)
            if segmentCount < 1 then
                return
            end
        else
            dispatch = UNRELIABLE_DISPATCH[messageId]
            if dispatch == nil then
                return
            end
        end
        for _segmentIndex = 1, segmentCount do
            local nextOffset = dispatch(payload, payloadLength, offset)
            offset = nextOffset
        end
    end
end)

FunctionRemote.OnClientInvoke = function(payload, ...)
    if typeof(payload) ~= "buffer" then
        error(ERR_TYPE)
    end
    local payloadLength = len(payload)
    if payloadLength < 1 then
        error(ERR_BOUNDS)
    end
    local messageId = readu8(payload, 0)
    local dispatch = FUNCTION_DISPATCH[messageId]
    if dispatch == nil then
        error(ERR_SCHEMA)
    end
    return dispatch(payload, payloadLength)
end

local Stats: NetStats = {
    GetReliableDropped = function() return RELIABLE_DROPPED end,
    GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,
    GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE end,
    GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,
}

local Net = {
Cars = Net_Cars_reliable_1,
Moves = Net_Moves_reliable_2,
Ping = Net_Ping_function_1,
}

Net.StepReplication = StepReplication
Net.Stats = Stats
local NetTyped: NetRoot = Net

return table.freeze(NetTyped)
