--!strict
--!native
--!optimize 2

--- The Roblox datatypes: vectors, CFrames, colours, times, BrickColors, Instances and `unknown`.
local AssertsModule = require("./Asserts")
local Common = require("./Common")

type Block = Common.Block
type TypePrefab = Common.TypePrefab

local Types = Common.Types
local Required = Common.Required
local Primitives = Common.Primitives
local GeneratePrimitivePrefab = Common.GeneratePrimitivePrefab
local RECIEVE_BUFFER = Common.RECIEVE_BUFFER
local BYTE = Common.BYTE
local SHORT = Common.SHORT
local DOUBLE = Common.DOUBLE
local Asserts = AssertsModule.Asserts

--> Vector
do
	Types.vector = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Prefab.Read("X", Block)
			Prefab.Read("Y", Block)
			Prefab.Read("Z", Block)
			Block:Line(`{Block:Declare(Variable)} = Vector3.new(X, Y, Z)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[#Components]] or Prefab
			end

			Block:Line(`local Vector = {Value}`)
			Prefab.Write("Vector.X", Block)
			Prefab.Write("Vector.Y", Block)
			Prefab.Write("Vector.Z", Block)
		end,
	}

	Primitives.vector = {
		Type = "Vector3",
		Generate = GeneratePrimitivePrefab("Vector3", Types.vector, Asserts.vector),
	}
end

--> CFrame
do
	--- `CFrame<quat>`: the position in the other component (or f32), then the rotation as the three
	--- smallest components of a unit quaternion. 7 bytes of rotation where three Euler angles take 12,
	--- at a worst-case error near 0.002 degrees. Opt-in, because it is lossy where `f32` is not.
	local function QuaternionCFrame(Components: { string }): TypePrefab
		local Position: TypePrefab = Types.f32
		for _, Component in Components do
			if Component ~= "quat" then
				Position = Types[Component]
			end
		end

		return {
			Read = function(Variable: string, Block: Block)
				Position.Read("X", Block)
				Position.Read("Y", Block)
				Position.Read("Z", Block)
				Types.u8.Read("QIndex", Block)
				Types.i16.Read("QA", Block)
				Types.i16.Read("QB", Block)
				Types.i16.Read("QC", Block)
				Block:Line(`{Block:Declare(Variable)} = UnpackRotation(X, Y, Z, QIndex, QA, QB, QC)`)
			end,
			Write = function(Value: string, Block: Block)
				Block:Line(`local Position = {Value}.Position`)
				Block:Line(`local QIndex, QA, QB, QC = PackRotation({Value})`)
				Position.Write("Position.X", Block)
				Position.Write("Position.Y", Block)
				Position.Write("Position.Z", Block)
				Types.u8.Write("QIndex", Block)
				Types.i16.Write("QA", Block)
				Types.i16.Write("QB", Block)
				Types.i16.Write("QC", Block)
			end,
		}
	end

	Types.CFrame = {
		Read = function(Variable: string, Block: Block, _, Components: { string }?)
			if Components and table.find(Components, "quat") then
				Required.Rotation = true
				QuaternionCFrame(Components).Read(Variable, Block)
				return
			end

			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Read("Position", Block, nil, Components)
			Prefab.Read("rX", Block)
			Prefab.Read("rY", Block)
			Prefab.Read("rZ", Block)
			Block:Line(`{Block:Declare(Variable)} = CFrame.new(Position) * CFrame.fromOrientation(rX, rY, rZ)`)
		end,
		Write = function(Value: string, Block: Block, _, Components: { string }?)
			if Components and table.find(Components, "quat") then
				Required.Rotation = true
				QuaternionCFrame(Components).Write(Value, Block)
				return
			end

			local Prefab: TypePrefab = Types.f32
			if Components then
				Prefab = Types[Components[1]]
			end

			Types.vector.Write(`{Value}.Position`, Block, nil, Components)
			Block:Line(`local rX, rY, rZ = {Value}:ToOrientation()`)
			Prefab.Write("rX", Block)
			Prefab.Write("rY", Block)
			Prefab.Write("rZ", Block)
		end,
	}

	Primitives.CFrame = {
		Type = "CFrame",
		Generate = GeneratePrimitivePrefab("CFrame", Types.CFrame),
	}
end

--> Color3
do
	Types.Color3 = {
		Read = function(Variable: string, Block: Block)
			local R = Block:Read(BYTE)
			local G = Block:Read(BYTE)
			local B = Block:Read(BYTE)
			Block:Line(
				`{Block:Declare(Variable)} = Color3.fromRGB(buffer.readu8({RECIEVE_BUFFER}, {R}), buffer.readu8({RECIEVE_BUFFER}, {G}), buffer.readu8({RECIEVE_BUFFER}, {B}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			--> Rounded, not truncated, and clamped: `writeu8` keeps the low byte, so an HDR channel of
			--> 2.0 -- which Highlight and neon colours use -- wrapped to 254, and a negative one to near
			--> 255. A channel written as 127.5 now reaches the other side as 128 rather than 127.
			Block:Line(`local Color = {Value}`)
			Types.u8.Write("math.clamp(math.round(Color.R * 255), 0, 255)", Block)
			Types.u8.Write("math.clamp(math.round(Color.G * 255), 0, 255)", Block)
			Types.u8.Write("math.clamp(math.round(Color.B * 255), 0, 255)", Block)
		end,
	}

	Primitives.Color3 = {
		Type = "Color3",
		Generate = GeneratePrimitivePrefab("Color3", Types.Color3),
	}
end

--> DateTime
do
	Types.DateTime = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestamp = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestamp(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestamp}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTime = {Value}`)
			Types.f64.Write(`DateTime.UnixTimestamp`, Block)
		end,
	}

	Primitives.DateTime = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTime),
	}
end

--> DateTimeMillis
do
	Types.DateTimeMillis = {
		Read = function(Variable: string, Block: Block)
			local UnixTimestampMillis = Block:Read(DOUBLE)
			Block:Line(
				`{Block:Declare(Variable)} = DateTime.fromUnixTimestampMillis(buffer.readf64({RECIEVE_BUFFER}, {UnixTimestampMillis}))`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local DateTimeMillis = {Value}`)
			Types.f64.Write(`DateTimeMillis.UnixTimestampMillis`, Block)
		end,
	}

	Primitives.DateTimeMillis = {
		Type = "DateTime",
		Generate = GeneratePrimitivePrefab("DateTime", Types.DateTimeMillis),
	}
end

--> BrickColor
do
	Types.BrickColor = {
		Read = function(Variable: string, Block: Block)
			local Number = Block:Read(SHORT)
			Block:Line(`{Block:Declare(Variable)} = BrickColor.new(buffer.readu16({RECIEVE_BUFFER}, {Number}))`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`local BrickColor = {Value}`)
			Types.u16.Write("BrickColor.Number", Block)
		end,
	}

	Primitives.BrickColor = {
		Type = "BrickColor",
		Generate = GeneratePrimitivePrefab("BrickColor", Types.BrickColor),
	}
end

--> Instance
do
	Types.Instance = {
		Read = function(Variable: string, Block: Block)
			--Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, {Value} or Null)`)
		end,
	}

	Primitives.Instance = {
		Type = function(Declaration)
			--> The parser defaults an Instance without an explicit class to "Instance", so this is never
			--> nil in practice; the fallback states that instead of asserting it.
			return Declaration.Value.Class or "Instance"
		end,
		Generate = GeneratePrimitivePrefab("any", Types.Instance, Asserts.Instance),
	}
end

--> unknown
do
	Types.unknown = {
		Read = function(Variable: string, Block: Block)
			Block:Line("RecieveInstanceCursor += 1")
			Block:Line(`{Block:Declare(Variable)} = RecieveInstances[RecieveInstanceCursor]`)
			--> The sender substitutes `Null` for a nil, so a nil here is never a value the client
			--> meant to send -- it means the packet claimed more of them than it carried. Unlike an
			--> `Instance`, whose class check fails on the same condition, `unknown` accepts anything
			--> and would otherwise let a decode loop run on a table that ran out long ago.
			Block:Line(
				`if {Variable} == nil then error(\`Expected a value for "{Variable}", the packet carried only \{#RecieveInstances} of them.\`) end`
			)
		end,
		Write = function(Value: string, Block: Block)
			Block:Line(`table.insert(SendInstances, if {Value} == nil then Null else {Value})`)
		end,
	}

	Primitives.unknown = {
		Type = "any",
		Generate = GeneratePrimitivePrefab("any", Types.unknown),
	}
end

return {}
