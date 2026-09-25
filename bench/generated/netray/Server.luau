--!strict
--!native
--!optimize 2
--!nolint LocalShadow
--#selene: allow(shadowing)
-- Name: Server
-- Purpose: Generated runtime for server networking
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
type NetRoot = typeof(Types.NetServer)
type NetStats = typeof(Types.NetStats)
type Connection = typeof(Types.Connection)
type Entity = typeof(Types.Entity)
type Move = typeof(Types.Move)
type Car = typeof(Types.Car)
type Net_Booleans_reliable_ServerApi = typeof(Types.Net_Booleans_reliable_ServerApi)
type Net_Booleans_reliable_ServerEventCallback = typeof(Types.Net_Booleans_reliable_ServerEventCallback)
type Net_Entities_reliable_ServerApi = typeof(Types.Net_Entities_reliable_ServerApi)
type Net_Entities_reliable_ServerEventCallback = typeof(Types.Net_Entities_reliable_ServerEventCallback)
type Net_Chat_reliable_ServerApi = typeof(Types.Net_Chat_reliable_ServerApi)
type Net_Chat_reliable_ServerEventCallback = typeof(Types.Net_Chat_reliable_ServerEventCallback)
type Net_Cars_reliable_ServerApi = typeof(Types.Net_Cars_reliable_ServerApi)
type Net_Cars_reliable_ServerEventCallback = typeof(Types.Net_Cars_reliable_ServerEventCallback)
type Net_Moves_reliable_ServerApi = typeof(Types.Net_Moves_reliable_ServerApi)
type Net_Moves_reliable_ServerEventCallback = typeof(Types.Net_Moves_reliable_ServerEventCallback)
type Net_MovesU_unreliable_ServerApi = typeof(Types.Net_MovesU_unreliable_ServerApi)
type Net_MovesU_unreliable_ServerEventCallback = typeof(Types.Net_MovesU_unreliable_ServerEventCallback)

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local function FindOrCreateRemote(className, remoteName)
    local existing = ReplicatedStorage:FindFirstChild(remoteName)
    if existing ~= nil then
        if existing.ClassName ~= className then
            error(("Remote '%s' exists as '%s', expected '%s'"):format(remoteName, existing.ClassName, className))
        end
        return existing
    end
    local remote = Instance.new(className)
    remote.Name = remoteName
    remote.Parent = ReplicatedStorage
    return remote
end

local Reliable = FindOrCreateRemote("RemoteEvent", "NetRay_RELIABLE") :: RemoteEvent
local Unreliable = FindOrCreateRemote("UnreliableRemoteEvent", "NetRay_UNRELIABLE") :: UnreliableRemoteEvent
local FunctionRemote = FindOrCreateRemote("RemoteFunction", "NetRay_FUNCTION") :: RemoteFunction

local function WithCount(...)
    return select("#", ...), ...
end

local DEFAULT_ARENA_CAPACITY = 65536
local create = buffer.create
local copy = buffer.copy
local len = buffer.len
local writeu8 = buffer.writeu8

local writef32 = buffer.writef32
local readu8 = buffer.readu8
local readu16 = buffer.readu16

local readf64 = buffer.readf64
local readstring = buffer.readstring
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

local MAX_RELIABLE_ID = 5
local MAX_UNRELIABLE_ID = 1
local MAX_FUNCTION_ID = 0
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
    Reliable:FireAllClients(payloadToSend)
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
    Unreliable:FireAllClients(payloadToSend)
    UNRELIABLE_CURSOR = 0
    UNRELIABLE_QUEUE_SIZE = 0
end

local Net_Booleans_reliable_1: Net_Booleans_reliable_ServerApi = {} :: Net_Booleans_reliable_ServerApi
local MESSAGE_ID_Net_Booleans_reliable_1 = 1

local function Decode_Net_Booleans_reliable_1(payload, payloadLength, offset)
    local decoded_v1
    local prefixCursor_1 = offset
    local prefixNext_3 = prefixCursor_1 + 2
    if prefixNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    local arrayCount_2 = readu16(payload, prefixCursor_1)
    prefixCursor_1 = prefixNext_3
    local fixedCursor_4 = prefixCursor_1
    local varCursor_5 = fixedCursor_4
    if varCursor_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    local arrayValues_7 = table.create(arrayCount_2)
    local arrayPackedByteCount_9 = ((arrayCount_2 + 7) // 8)
    local arrayPackedCursor_10 = varCursor_5
    local arrayPackedNext_11 = arrayPackedCursor_10 + arrayPackedByteCount_9
    if arrayPackedNext_11 > payloadLength then
        error(ERR_BOUNDS)
    end
    local arrayUnpackIndex_13 = 1
    for arrayPackedIndex_12 = 1, arrayPackedByteCount_9 do
        local arrayPackedByte_14 = readu8(payload, arrayPackedCursor_10)
        arrayPackedCursor_10 += 1
        local arrayBitMask_16 = 1
        for arrayBitIndex_15 = 1, 8 do
            if arrayUnpackIndex_13 > arrayCount_2 then
                break
            end
            arrayValues_7[arrayUnpackIndex_13] = band(arrayPackedByte_14, arrayBitMask_16) ~= 0
            arrayUnpackIndex_13 += 1
            arrayBitMask_16 = lshift(arrayBitMask_16, 1)
        end
    end
    varCursor_5 = arrayPackedCursor_10
    decoded_v1 = arrayValues_7
    offset = varCursor_5
    return decoded_v1, offset
end

local Handler_Net_Booleans_reliable_1: ((player: Player, v1: { boolean }) -> ())? = nil
local HandlerToken_Net_Booleans_reliable_1 = 0

function Net_Booleans_reliable_1.On(callback: Net_Booleans_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Booleans_reliable_1 += 1
    local token = HandlerToken_Net_Booleans_reliable_1
    Handler_Net_Booleans_reliable_1 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Booleans_reliable_1 == token then
            HandlerToken_Net_Booleans_reliable_1 += 1
            Handler_Net_Booleans_reliable_1 = nil
        end
    end)
end

RELIABLE_DISPATCH[1] = function(player, payload, payloadLength, offset)
    local decoded_v1, nextOffset = Decode_Net_Booleans_reliable_1(payload, payloadLength, offset)
    local callback = Handler_Net_Booleans_reliable_1
    if callback == nil then
        return nextOffset
    end
    callback(player, decoded_v1)
    return nextOffset
end

local Net_Entities_reliable_2: Net_Entities_reliable_ServerApi = {} :: Net_Entities_reliable_ServerApi
local MESSAGE_ID_Net_Entities_reliable_2 = 2

local function Decode_Net_Entities_reliable_2(payload, payloadLength, offset)
    local decoded_v1
    local prefixCursor_1 = offset
    local prefixNext_3 = prefixCursor_1 + 2
    if prefixNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    local arrayCount_2 = readu16(payload, prefixCursor_1)
    prefixCursor_1 = prefixNext_3
    local fixedCursor_4 = prefixCursor_1
    local varCursor_5 = fixedCursor_4
    if varCursor_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    local arrayValues_7 = table.create(arrayCount_2)
    for arrayIndex_6 = 1, arrayCount_2 do
        local arrayValue_8
        local structValue_9 = {}
        local structField_10
        local fieldNext_11 = varCursor_5 + 1
        if fieldNext_11 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_10 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_11
        structValue_9["id"] = structField_10
        local structField_12
        local fieldNext_13 = varCursor_5 + 1
        if fieldNext_13 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_12 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_13
        structValue_9["x"] = structField_12
        local structField_14
        local fieldNext_15 = varCursor_5 + 1
        if fieldNext_15 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_14 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_15
        structValue_9["y"] = structField_14
        local structField_16
        local fieldNext_17 = varCursor_5 + 1
        if fieldNext_17 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_16 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_17
        structValue_9["z"] = structField_16
        local structField_18
        local fieldNext_19 = varCursor_5 + 1
        if fieldNext_19 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_18 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_19
        structValue_9["orientation"] = structField_18
        local structField_20
        local fieldNext_21 = varCursor_5 + 1
        if fieldNext_21 > payloadLength then
            error(ERR_BOUNDS)
        end
        structField_20 = (readu8(payload, varCursor_5) :: u8)
        varCursor_5 = fieldNext_21
        structValue_9["animation"] = structField_20
        arrayValue_8 = structValue_9
        arrayValues_7[arrayIndex_6] = arrayValue_8
    end
    decoded_v1 = arrayValues_7
    offset = varCursor_5
    return decoded_v1, offset
end

local Handler_Net_Entities_reliable_2: ((player: Player, v1: { Entity }) -> ())? = nil
local HandlerToken_Net_Entities_reliable_2 = 0

function Net_Entities_reliable_2.On(callback: Net_Entities_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Entities_reliable_2 += 1
    local token = HandlerToken_Net_Entities_reliable_2
    Handler_Net_Entities_reliable_2 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Entities_reliable_2 == token then
            HandlerToken_Net_Entities_reliable_2 += 1
            Handler_Net_Entities_reliable_2 = nil
        end
    end)
end

RELIABLE_DISPATCH[2] = function(player, payload, payloadLength, offset)
    local decoded_v1, nextOffset = Decode_Net_Entities_reliable_2(payload, payloadLength, offset)
    local callback = Handler_Net_Entities_reliable_2
    if callback == nil then
        return nextOffset
    end
    callback(player, decoded_v1)
    return nextOffset
end

local Net_Chat_reliable_3: Net_Chat_reliable_ServerApi = {} :: Net_Chat_reliable_ServerApi
local MESSAGE_ID_Net_Chat_reliable_3 = 3

local function Decode_Net_Chat_reliable_3(payload, payloadLength, offset)
    local decoded_v1
    local decoded_v2
    local prefixCursor_1 = offset
    local stringLen_2
    stringLen_2, prefixCursor_1 = ReadVarUInt(payload, payloadLength, prefixCursor_1)
    local fixedCursor_3 = prefixCursor_1
    local varCursor_4 = fixedCursor_3 + 1
    if varCursor_4 > payloadLength then
        error(ERR_BOUNDS)
    end
    local stringNext_5 = varCursor_4 + stringLen_2
    if stringNext_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    decoded_v1 = readstring(payload, varCursor_4, stringLen_2)
    varCursor_4 = stringNext_5
    decoded_v2 = (readu8(payload, fixedCursor_3) :: u8)
    fixedCursor_3 += 1
    offset = varCursor_4
    return decoded_v1, decoded_v2, offset
end

local Handler_Net_Chat_reliable_3: ((player: Player, v1: string, v2: u8) -> ())? = nil
local HandlerToken_Net_Chat_reliable_3 = 0

function Net_Chat_reliable_3.On(callback: Net_Chat_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Chat_reliable_3 += 1
    local token = HandlerToken_Net_Chat_reliable_3
    Handler_Net_Chat_reliable_3 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Chat_reliable_3 == token then
            HandlerToken_Net_Chat_reliable_3 += 1
            Handler_Net_Chat_reliable_3 = nil
        end
    end)
end

RELIABLE_DISPATCH[3] = function(player, payload, payloadLength, offset)
    local decoded_v1, decoded_v2, nextOffset = Decode_Net_Chat_reliable_3(payload, payloadLength, offset)
    local callback = Handler_Net_Chat_reliable_3
    if callback == nil then
        return nextOffset
    end
    callback(player, decoded_v1, decoded_v2)
    return nextOffset
end

local Net_Cars_reliable_4: Net_Cars_reliable_ServerApi = {} :: Net_Cars_reliable_ServerApi
local MESSAGE_ID_Net_Cars_reliable_4 = 4

local function Decode_Net_Cars_reliable_4(payload, payloadLength, offset)
    local decoded_data_brand
    local decoded_data_carName
    local decoded_data_carId
    local decoded_data_available
    local decoded_data_dealers
    local decoded_data_price
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
    local stringNext_6 = varCursor_5 + stringLen_2
    if stringNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    decoded_data_brand = readstring(payload, varCursor_5, stringLen_2)
    varCursor_5 = stringNext_6
    local stringNext_7 = varCursor_5 + stringLen_3
    if stringNext_7 > payloadLength then
        error(ERR_BOUNDS)
    end
    decoded_data_carName = readstring(payload, varCursor_5, stringLen_3)
    varCursor_5 = stringNext_7
    decoded_data_carId = (readu16(payload, fixedCursor_4) :: u16)
    fixedCursor_4 += 2
    local rawBool_8 = readu8(payload, fixedCursor_4)
    fixedCursor_4 += 1
    decoded_data_available = rawBool_8 == 1
    decoded_data_dealers = (readu8(payload, fixedCursor_4) :: u8)
    fixedCursor_4 += 1
    decoded_data_price = (readf64(payload, fixedCursor_4) :: f64)
    fixedCursor_4 += 8
    offset = varCursor_5
    return decoded_data_brand, decoded_data_carName, decoded_data_carId, decoded_data_available, decoded_data_dealers, decoded_data_price, offset
end

local Handler_Net_Cars_reliable_4: ((player: Player, data_brand: string, data_carName: string, data_carId: u16, data_available: boolean, data_dealers: u8, data_price: f64) -> ())? = nil
local HandlerToken_Net_Cars_reliable_4 = 0

function Net_Cars_reliable_4.On(callback: Net_Cars_reliable_ServerEventCallback): Connection
    if type(callback) ~= "function" then error(ERR_TYPE) end
    HandlerToken_Net_Cars_reliable_4 += 1
    local token = HandlerToken_Net_Cars_reliable_4
    Handler_Net_Cars_reliable_4 = callback
    return CreateConnection(function()
        if HandlerToken_Net_Cars_reliable_4 == token then
            HandlerToken_Net_Cars_reliable_4 += 1
            Handler_Net_Cars_reliable_4 = nil
        end
    end)
end

RELIABLE_DISPATCH[4] = function(player, payload, payloadLength, offset)
    local decoded_data_brand, decoded_data_carName, decoded_data_carId, decoded_data_available, decoded_data_dealers, decoded_data_price, nextOffset = Decode_Net_Cars_reliable_4(payload, payloadLength, offset)
    local callback = Handler_Net_Cars_reliable_4
    if callback == nil then
        return nextOffset
    end
    callback(player, decoded_data_brand, decoded_data_carName, decoded_data_carId, decoded_data_available, decoded_data_dealers, decoded_data_price)
    return nextOffset
end

local Net_Moves_reliable_5: Net_Moves_reliable_ServerApi = {} :: Net_Moves_reliable_ServerApi
local MESSAGE_ID_Net_Moves_reliable_5 = 5

local function Encode_Net_Moves_reliable_5(data)
    local totalSize = 1
    local vectorValue_1 = data.pos
    totalSize += 12
    local vectorValue_2 = data.vel
    totalSize += 12
    totalSize += 4
    totalSize += 1
    totalSize += 1
    totalSize += 1
    totalSize += 1
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_Moves_reliable_5)
    local offset = 1
    local vectorValue_3 = data.pos
    writef32(payload, offset, vectorValue_3.X)
    offset += 4
    writef32(payload, offset, vectorValue_3.Y)
    offset += 4
    writef32(payload, offset, vectorValue_3.Z)
    offset += 4
    local vectorValue_4 = data.vel
    writef32(payload, offset, vectorValue_4.X)
    offset += 4
    writef32(payload, offset, vectorValue_4.Y)
    offset += 4
    writef32(payload, offset, vectorValue_4.Z)
    offset += 4
    writef32(payload, offset, data.yaw)
    offset += 4
    writeu8(payload, offset, data.grounded and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.crouch and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.sprint and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.anim)
    offset += 1
    return payload
end

local Handler_Net_Moves_reliable_5: ((player: Player, data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ())? = nil
local HandlerToken_Net_Moves_reliable_5 = 0

local function Skip_Net_Moves_reliable_5(payload, payloadLength, offset)
    local skipVectorNext_1 = offset + 12
    if skipVectorNext_1 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipVectorNext_1
    local skipVectorNext_2 = offset + 12
    if skipVectorNext_2 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipVectorNext_2
    local skipNext_3 = offset + 4
    if skipNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipNext_3
    local skipBoolNext_4 = offset + 1
    if skipBoolNext_4 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_4
    local skipBoolNext_5 = offset + 1
    if skipBoolNext_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_5
    local skipBoolNext_6 = offset + 1
    if skipBoolNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_6
    local skipNext_7 = offset + 1
    if skipNext_7 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipNext_7
    return offset
end

RELIABLE_SKIP[5] = Skip_Net_Moves_reliable_5

function Net_Moves_reliable_5.FireAll(data: Move): boolean
    local __nr_totalSize = 1
    local vectorValue_1 = data.pos
    __nr_totalSize += 12
    local vectorValue_2 = data.vel
    __nr_totalSize += 12
    __nr_totalSize += 4
    __nr_totalSize += 1
    __nr_totalSize += 1
    __nr_totalSize += 1
    __nr_totalSize += 1
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
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_Moves_reliable_5)
    local __nr_p = __nr_base + 1
    local vectorValue_3 = data.pos
    writef32(__nr_payload, __nr_p, vectorValue_3.X)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_3.Y)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_3.Z)
    __nr_p += 4
    local vectorValue_4 = data.vel
    writef32(__nr_payload, __nr_p, vectorValue_4.X)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_4.Y)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_4.Z)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, data.yaw)
    __nr_p += 4
    writeu8(__nr_payload, __nr_p, data.grounded and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.crouch and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.sprint and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.anim)
    __nr_p += 1
    RELIABLE_QUEUE_SIZE += 1
    return true
end

function Net_Moves_reliable_5.Fire(player: Player, data: Move): boolean
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_Moves_reliable_5(data)
    Reliable:FireClient(player, __nr_payload)
    return true
end

function Net_Moves_reliable_5.FireList(players: { Player }, data: Move): boolean
    if type(players) ~= "table" then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_Moves_reliable_5(data)
    for __nr_index = 1, #players do
        local __nr_target = players[__nr_index]
        if typeof(__nr_target) ~= "Instance" or not __nr_target:IsA("Player") then
            error(ERR_TYPE)
        end
        Reliable:FireClient(__nr_target, __nr_payload)
    end
    return true
end

function Net_Moves_reliable_5.FireExcept(excludedPlayer: Player, data: Move): boolean
    if typeof(excludedPlayer) ~= "Instance" or not excludedPlayer:IsA("Player") then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_Moves_reliable_5(data)
    local __nr_players = Players:GetPlayers()
    for __nr_index = 1, #__nr_players do
        local __nr_target = __nr_players[__nr_index]
        if __nr_target ~= excludedPlayer then
            Reliable:FireClient(__nr_target, __nr_payload)
        end
    end
    return true
end

local Net_MovesU_unreliable_1: Net_MovesU_unreliable_ServerApi = {} :: Net_MovesU_unreliable_ServerApi
local MESSAGE_ID_Net_MovesU_unreliable_1 = 1

local function Encode_Net_MovesU_unreliable_1(data)
    local totalSize = 1
    local vectorValue_1 = data.pos
    totalSize += 12
    local vectorValue_2 = data.vel
    totalSize += 12
    totalSize += 4
    totalSize += 1
    totalSize += 1
    totalSize += 1
    totalSize += 1
    local payload = create(totalSize)
    writeu8(payload, 0, MESSAGE_ID_Net_MovesU_unreliable_1)
    local offset = 1
    local vectorValue_3 = data.pos
    writef32(payload, offset, vectorValue_3.X)
    offset += 4
    writef32(payload, offset, vectorValue_3.Y)
    offset += 4
    writef32(payload, offset, vectorValue_3.Z)
    offset += 4
    local vectorValue_4 = data.vel
    writef32(payload, offset, vectorValue_4.X)
    offset += 4
    writef32(payload, offset, vectorValue_4.Y)
    offset += 4
    writef32(payload, offset, vectorValue_4.Z)
    offset += 4
    writef32(payload, offset, data.yaw)
    offset += 4
    writeu8(payload, offset, data.grounded and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.crouch and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.sprint and 1 or 0)
    offset += 1
    writeu8(payload, offset, data.anim)
    offset += 1
    return payload
end

local Handler_Net_MovesU_unreliable_1: ((player: Player, data_pos: Vector3, data_vel: Vector3, data_yaw: f32, data_grounded: boolean, data_crouch: boolean, data_sprint: boolean, data_anim: u8) -> ())? = nil
local HandlerToken_Net_MovesU_unreliable_1 = 0

local function Skip_Net_MovesU_unreliable_1(payload, payloadLength, offset)
    local skipVectorNext_1 = offset + 12
    if skipVectorNext_1 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipVectorNext_1
    local skipVectorNext_2 = offset + 12
    if skipVectorNext_2 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipVectorNext_2
    local skipNext_3 = offset + 4
    if skipNext_3 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipNext_3
    local skipBoolNext_4 = offset + 1
    if skipBoolNext_4 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_4
    local skipBoolNext_5 = offset + 1
    if skipBoolNext_5 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_5
    local skipBoolNext_6 = offset + 1
    if skipBoolNext_6 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipBoolNext_6
    local skipNext_7 = offset + 1
    if skipNext_7 > payloadLength then
        error(ERR_BOUNDS)
    end
    offset = skipNext_7
    return offset
end

UNRELIABLE_SKIP[1] = Skip_Net_MovesU_unreliable_1

function Net_MovesU_unreliable_1.FireAll(data: Move): boolean
    local __nr_totalSize = 1
    local vectorValue_1 = data.pos
    __nr_totalSize += 12
    local vectorValue_2 = data.vel
    __nr_totalSize += 12
    __nr_totalSize += 4
    __nr_totalSize += 1
    __nr_totalSize += 1
    __nr_totalSize += 1
    __nr_totalSize += 1
    local __nr_base = UNRELIABLE_CURSOR
    local __nr_required = __nr_base + __nr_totalSize
    if __nr_required > UNRELIABLE_ARENA_CAPACITY then
        local nextCapacity = UNRELIABLE_ARENA_CAPACITY
        while nextCapacity < __nr_required do
            nextCapacity *= 2
        end
        local nextArena = create(nextCapacity)
        if UNRELIABLE_CURSOR > 0 then
            copy(nextArena, 0, UNRELIABLE_ARENA, 0, UNRELIABLE_CURSOR)
        end
        UNRELIABLE_ARENA = nextArena
        UNRELIABLE_ARENA_CAPACITY = nextCapacity
    end
    UNRELIABLE_CURSOR = __nr_required
    local __nr_payload = UNRELIABLE_ARENA
    writeu8(__nr_payload, __nr_base, MESSAGE_ID_Net_MovesU_unreliable_1)
    local __nr_p = __nr_base + 1
    local vectorValue_3 = data.pos
    writef32(__nr_payload, __nr_p, vectorValue_3.X)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_3.Y)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_3.Z)
    __nr_p += 4
    local vectorValue_4 = data.vel
    writef32(__nr_payload, __nr_p, vectorValue_4.X)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_4.Y)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, vectorValue_4.Z)
    __nr_p += 4
    writef32(__nr_payload, __nr_p, data.yaw)
    __nr_p += 4
    writeu8(__nr_payload, __nr_p, data.grounded and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.crouch and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.sprint and 1 or 0)
    __nr_p += 1
    writeu8(__nr_payload, __nr_p, data.anim)
    __nr_p += 1
    UNRELIABLE_QUEUE_SIZE += 1
    return true
end

function Net_MovesU_unreliable_1.Fire(player: Player, data: Move): boolean
    if typeof(player) ~= "Instance" or not player:IsA("Player") then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_MovesU_unreliable_1(data)
    Unreliable:FireClient(player, __nr_payload)
    return true
end

function Net_MovesU_unreliable_1.FireList(players: { Player }, data: Move): boolean
    if type(players) ~= "table" then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_MovesU_unreliable_1(data)
    for __nr_index = 1, #players do
        local __nr_target = players[__nr_index]
        if typeof(__nr_target) ~= "Instance" or not __nr_target:IsA("Player") then
            error(ERR_TYPE)
        end
        Unreliable:FireClient(__nr_target, __nr_payload)
    end
    return true
end

function Net_MovesU_unreliable_1.FireExcept(excludedPlayer: Player, data: Move): boolean
    if typeof(excludedPlayer) ~= "Instance" or not excludedPlayer:IsA("Player") then
        error(ERR_TYPE)
    end
    local __nr_payload = Encode_Net_MovesU_unreliable_1(data)
    local __nr_players = Players:GetPlayers()
    for __nr_index = 1, #__nr_players do
        local __nr_target = __nr_players[__nr_index]
        if __nr_target ~= excludedPlayer then
            Unreliable:FireClient(__nr_target, __nr_payload)
        end
    end
    return true
end

local function StepReplication()
    FlushReliable()
    FlushUnreliable()
end

RunService.Heartbeat:Connect(StepReplication)

Reliable.OnServerEvent:Connect(function(player, payload)
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
            local nextOffset = dispatch(player, payload, payloadLength, offset)
            offset = nextOffset
        end
    end
end)

Unreliable.OnServerEvent:Connect(function(player, payload)
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
            local nextOffset = dispatch(player, payload, payloadLength, offset)
            offset = nextOffset
        end
    end
end)

FunctionRemote.OnServerInvoke = function(player, payload, ...)
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
    return dispatch(player, payload, payloadLength)
end

local Stats: NetStats = {
    GetReliableDropped = function() return RELIABLE_DROPPED end,
    GetUnreliableDropped = function() return UNRELIABLE_DROPPED end,
    GetReliableQueueSize = function() return RELIABLE_QUEUE_SIZE end,
    GetUnreliableQueueSize = function() return UNRELIABLE_QUEUE_SIZE end,
}

local Net = {
Booleans = Net_Booleans_reliable_1,
Entities = Net_Entities_reliable_2,
Chat = Net_Chat_reliable_3,
Cars = Net_Cars_reliable_4,
Moves = Net_Moves_reliable_5,
MovesU = Net_MovesU_unreliable_1,
}

Net.StepReplication = StepReplication
Net.Stats = Stats
local NetTyped: NetRoot = Net

return table.freeze(NetTyped)
