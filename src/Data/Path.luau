--!strict
--!optimize 2

-- Data paths: "stats.kills" or { "stats", "kills" }. Numeric segments
-- ("inventory.3") become numbers so they index arrays. Parsed paths are
-- cached and frozen, so hot paths cost one table lookup.

local Path = {}

export type DataPath = string | { string | number }

local cache: { [string]: { string | number } } = {}
local cached = 0
-- Paths built at run time ("friends." .. userId) are all different: past
-- this many, the cache starts over instead of growing for the whole server.
local CACHE_LIMIT = 4096

function Path.parse(path: DataPath): { string | number }
	if type(path) == "table" then
		return path
	end

	local parsed = cache[path]
	if parsed then
		return parsed
	end

	assert(type(path) == "string" and path ~= "", "Branch.Data: a path must be a non-empty string or an array of keys")

	local parts: { string | number } = {}
	for _, segment in string.split(path, ".") do
		assert(segment ~= "", `Branch.Data: empty segment in path "{path}"`)
		local number = if string.match(segment, "^%d+$") then tonumber(segment) else nil
		table.insert(parts, number or segment)
	end

	table.freeze(parts)
	if cached >= CACHE_LIMIT then
		table.clear(cache)
		cached = 0
	end
	cache[path] = parts
	cached += 1
	return parts
end

function Path.format(parts: { string | number }): string
	local out = table.create(#parts)
	for index, part in parts do
		out[index] = tostring(part)
	end
	return table.concat(out, ".")
end

-- One step: a numeric segment indexes an array, or a string key when the
-- table is keyed by strings ("friends.12345" with UserIds as keys).
local function step(node: { [any]: any }, part: string | number): any
	local value = node[part]
	if value == nil and type(part) == "number" then
		value = node[tostring(part)]
	end
	return value
end

-- Walks `root` along `parts`; returns nil when any step is missing.
function Path.read(root: any, parts: { string | number }): any
	local node = root
	for _, part in parts do
		if type(node) ~= "table" then
			return nil
		end
		node = step(node, part)
	end
	return node
end

-- The parts to write through: a numeric segment becomes the string key when
-- the table it indexes is a dictionary (has that string key, or has keys but
-- no array part), or is empty and the number is not 1 (an array starts at 1,
-- so "friends.12345" starts a dictionary keyed by UserIds). Writing a number
-- key next to string keys would give a mixed table, which DataStores refuse
-- to save.
function Path.resolve(root: any, parts: { string | number }): { string | number }
	local node = root
	local out: { string | number }? = nil
	for index, part in parts do
		if type(part) == "number" and type(node) == "table" and node[part] == nil then
			local text = tostring(part)
			if node[text] ~= nil or (#node == 0 and (next(node) ~= nil or part ~= 1)) then
				local copy = out or table.clone(parts)
				copy[index] = text
				out = copy
				part = text
			end
		end
		node = if type(node) == "table" then node[part] else nil
	end
	return out or parts
end

-- Every key the template gives a table must be there, with the same type,
-- all the way down (arrays and empty tables are free-form).
local function checkShape(expected: any, value: any, parts: { string | number })
	if type(expected) ~= "table" or type(value) ~= "table" then
		return
	end
	for key, sub in expected do
		if type(key) == "string" then
			local got = value[key]
			local where = Path.format(parts) .. "." .. key
			if got == nil then
				error(`Branch.Data: "{where}" is missing (the template has it)`, 4)
			elseif typeof(got) ~= typeof(sub) then
				error(`Branch.Data: "{where}" holds a {typeof(sub)} in the template, got {typeof(got)}`, 4)
			end
			local deeper = table.clone(parts)
			table.insert(deeper, key)
			checkShape(sub, got, deeper)
		end
	end
end

-- The first NaN or ±inf inside `value` (nested tables included), or nil.
-- DataStores cannot hold them: one such number makes every later save of
-- the profile fail, so they are refused at the write.
local function nonFinite(value: any, depth: number): number?
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return value
		end
	elseif type(value) == "table" and depth < 32 then
		for _, item in value do
			local bad = nonFinite(item, depth + 1)
			if bad then
				return bad
			end
		end
	end
	return nil
end

-- Errors (blaming `level` frames up) when `value` holds NaN or infinity.
function Path.assertFinite(parts: { string | number }, value: any, level: number)
	local bad = nonFinite(value, 0)
	if bad then
		error(`Branch.Data: "{Path.format(parts)}" cannot hold {tostring(bad)} (DataStores cannot save NaN or infinity)`, level + 1)
	end
end

-- Refuses writes that would break the template's shape (the saved data
-- stays loadable). Paths the template does not describe (dynamic keys,
-- array elements) are allowed through; NaN and infinity never are.
function Path.check(template: any, parts: { string | number }, value: any)
	Path.assertFinite(parts, value, 3)
	local node = template
	for index = 1, #parts - 1 do
		if type(node) ~= "table" then
			return
		end
		node = node[parts[index]]
	end
	if type(node) ~= "table" then
		return
	end

	local expected = node[parts[#parts]]
	if expected == nil then
		return
	end

	if value == nil then
		error(`Branch.Data: "{Path.format(parts)}" is part of the template and cannot be set to nil`, 3)
	end

	local expectedType, actualType = typeof(expected), typeof(value)
	if expectedType ~= actualType then
		error(`Branch.Data: "{Path.format(parts)}" holds a {expectedType} in the template, got {actualType}`, 3)
	end
	checkShape(expected, value, parts)
end

-- For Insert: when the template's array shows an example element, the new
-- element must match it (type and shape).
function Path.checkElement(template: any, parts: { string | number }, value: any)
	Path.assertFinite(parts, value, 3)
	local node = template
	for _, part in parts do
		if type(node) ~= "table" then
			return
		end
		node = node[part]
	end
	if type(node) ~= "table" or node[1] == nil then
		return
	end
	local sample = node[1]
	if typeof(value) ~= typeof(sample) then
		error(`Branch.Data: "{Path.format(parts)}" holds {typeof(sample)} elements in the template, got {typeof(value)}`, 3)
	end
	checkShape(sample, value, parts)
end

return Path
