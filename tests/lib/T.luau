--!strict
-- Minimal test runner for Lune.

local T = {}

local results = { passed = 0, failed = 0, failures = {} :: { string } }

local function describeValue(value: any): string
	if type(value) == "table" then
		local parts = {}
		for key, item in value do
			table.insert(parts, tostring(key) .. "=" .. describeValue(item))
			if #parts > 12 then
				table.insert(parts, "...")
				break
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function near(a: number, b: number, tolerance: number): boolean
	if a ~= a and b ~= b then
		return true
	end
	if a == b then
		return true
	end
	return math.abs(a - b) <= tolerance * math.max(1, math.abs(a), math.abs(b))
end

function T.same(actual: any, expected: any, tolerance: number?, path: string?): (boolean, string?)
	local where = path or "value"
	local ta, te = typeof(actual), typeof(expected)
	if ta ~= te then
		return false, `{where}: expected {te} {describeValue(expected)}, got {ta} {describeValue(actual)}`
	end
	if ta == "number" then
		if not near(actual, expected, tolerance or 0) then
			return false, `{where}: expected {expected}, got {actual}`
		end
		return true
	elseif ta == "table" then
		for key, item in expected do
			local ok, message = T.same(actual[key], item, tolerance, `{where}.{tostring(key)}`)
			if not ok then
				return false, message
			end
		end
		for key in actual do
			if expected[key] == nil then
				return false, `{where}.{tostring(key)}: unexpected value {describeValue(actual[key])}`
			end
		end
		return true
	elseif ta == "Vector3" then
		return T.same({ actual.X, actual.Y, actual.Z }, { expected.X, expected.Y, expected.Z }, tolerance or 1e-6, where)
	elseif ta == "CFrame" then
		local a = { actual:GetComponents() }
		local e = { expected:GetComponents() }
		return T.same(a, e, 1e-4, where)
	elseif ta == "Color3" then
		return T.same({ actual.R, actual.G, actual.B }, { expected.R, expected.G, expected.B }, 1 / 255, where)
	elseif ta == "buffer" then
		if buffer.tostring(actual) ~= buffer.tostring(expected) then
			return false, `{where}: buffers differ`
		end
		return true
	end
	if actual ~= expected then
		return false, `{where}: expected {describeValue(expected)}, got {describeValue(actual)}`
	end
	return true
end

function T.eq(actual: any, expected: any, tolerance: number?)
	local ok, message = T.same(actual, expected, tolerance)
	if not ok then
		error(message, 2)
	end
end

function T.truthy(value: any, message: string?)
	if not value then
		error(message or "expected truthy", 2)
	end
end

function T.errors(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	if ok then
		error("expected an error" .. (if pattern then " matching " .. pattern else ""), 2)
	end
	if pattern and not string.find(tostring(err), pattern) then
		error(`error "{tostring(err)}" does not match "{pattern}"`, 2)
	end
end

function T.test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
		print("  ok   " .. name)
	else
		results.failed += 1
		table.insert(results.failures, name .. ": " .. tostring(err))
		print("  FAIL " .. name .. "\n       " .. tostring(err))
	end
end

function T.finish(): boolean
	print(`\n{results.passed} passed, {results.failed} failed`)
	return results.failed == 0
end

return T
