--[[
	Headers: case-insensitive, ordered and multi-valued.

	    local h = Headers.new({ ["Content-Type"] = "text/plain" })
	    h:add("Set-Cookie", "a=1"):add("Set-Cookie", "b=2")
	    print(h:get("content-type"))   --> text/plain
	    print(h["content-type"])       --> text/plain (indexing reads a header)
	    print(#h:getAll("set-cookie")) --> 2
	    for name, value in h do ... end -- every entry, in order, as written
]]

local types = require("./types")

export type Headers = types.Headers
export type HeadersInit = types.HeadersInit
export type HeaderValue = types.HeaderValue

type Entry = { name: string, lower: string, value: string }

local Headers = {}
local methods = {}
local M = {}

-- The entry list of a Headers object.
local function entriesOf(h: any): { Entry }
	return rawget(h, "_entries") :: any
end

local function isHeaders(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Headers
end

local function toValues(value: HeaderValue): { string }
	if type(value) == "table" then
		local out = {}
		for i, v in value do
			out[i] = tostring(v)
		end
		return out
	end
	return { tostring(value) }
end

Headers.__index = function(self, key)
	local method = methods[key]
	if method ~= nil then
		return method
	end
	if type(key) == "string" then
		return methods.get(self, key)
	end
	return nil
end

Headers.__iter = function(self)
	local entries: { Entry } = entriesOf(self)
	local i = 0
	return function()
		i += 1
		local e = entries[i]
		if e then
			return e.name, e.value
		end
		return nil
	end
end

Headers.__len = function(self)
	return #entriesOf(self)
end

Headers.__tostring = function(self)
	local lines = {}
	for _, e in entriesOf(self) do
		table.insert(lines, `{e.name}: {e.value}`)
	end
	return table.concat(lines, "\n")
end

--- Reads a header. Repeated headers are joined with ", " (Set-Cookie with "\n", like
--- `@sonata/net`). Returns `nil` when absent.
function methods.get(self: Headers, name: string): string?
	local lower = string.lower(name)
	local found: { string }? = nil
	for _, e in entriesOf(self) do
		if e.lower == lower then
			if found then
				table.insert(found, e.value)
			else
				found = { e.value }
			end
		end
	end
	if not found then
		return nil
	end
	if #found == 1 then
		return found[1]
	end
	return table.concat(found, if lower == "set-cookie" then "\n" else ", ")
end

--- Every value of a header, in order.
function methods.getAll(self: Headers, name: string): { string }
	local lower = string.lower(name)
	local out = {}
	for _, e in entriesOf(self) do
		if e.lower == lower then
			table.insert(out, e.value)
		end
	end
	return out
end

function methods.has(self: Headers, name: string): boolean
	local lower = string.lower(name)
	for _, e in entriesOf(self) do
		if e.lower == lower then
			return true
		end
	end
	return false
end

--- Removes every value of a header.
function methods.delete(self: Headers, name: string): Headers
	local lower = string.lower(name)
	local entries: { Entry } = entriesOf(self)
	local i = 1
	while i <= #entries do
		if entries[i].lower == lower then
			table.remove(entries, i)
		else
			i += 1
		end
	end
	return self
end

--- Appends a value (or several), keeping the ones already there.
function methods.add(self: Headers, name: string, value: HeaderValue): Headers
	local entries: { Entry } = entriesOf(self)
	local lower = string.lower(name)
	for _, v in toValues(value) do
		table.insert(entries, { name = name, lower = lower, value = v })
	end
	return self
end

--- Replaces every value of a header. `set(name, nil)` is not allowed; use `delete`.
function methods.set(self: Headers, name: string, value: HeaderValue): Headers
	methods.delete(self, name)
	return methods.add(self, name, value)
end

--- Sets a header only if it isn't there yet.
function methods.setDefault(self: Headers, name: string, value: HeaderValue): Headers
	if not methods.has(self, name) then
		methods.add(self, name, value)
	end
	return self
end

--- Copies the headers of `other` into this object, replacing headers of the same name.
function methods.merge(self: Headers, other: HeadersInit?): Headers
	if other == nil then
		return self
	end
	local incoming = M.new(other)
	local replaced: { [string]: boolean } = {}
	for _, e in entriesOf(incoming) do
		if not replaced[e.lower] then
			methods.delete(self, e.name)
			replaced[e.lower] = true
		end
		methods.add(self, e.name, e.value)
	end
	return self
end

function methods.clone(self: Headers): Headers
	return M.new(self)
end

--- The entries as a list of `{ name, value }` pairs, in order, names as written. This is
--- the form `net.http.formatRequest` and `formatResponse` accept.
function methods.list(self: Headers): { { string } }
	local out = {}
	for i, e in entriesOf(self) do
		out[i] = { e.name, e.value }
	end
	return out
end

--- The headers as a map of lower-case name to (joined) value.
function methods.map(self: Headers): { [string]: string }
	local out = {}
	for _, e in entriesOf(self) do
		if out[e.lower] == nil then
			out[e.lower] = methods.get(self, e.lower)
		end
	end
	return out
end

--- The distinct header names, lower-case, in order of first appearance.
function methods.names(self: Headers): { string }
	local out, seen = {}, {}
	for _, e in entriesOf(self) do
		if not seen[e.lower] then
			seen[e.lower] = true
			table.insert(out, e.lower)
		end
	end
	return out
end

--- The number of entries (a repeated header counts once per value).
function methods.count(self: Headers): number
	return #entriesOf(self)
end

--- Creates headers from a map, a list of pairs or another `Headers` object (which is copied).
function M.new(init: HeadersInit?): Headers
	local self = setmetatable({ _entries = {} }, Headers) :: any
	if init == nil then
		return self
	end
	if isHeaders(init) then
		for _, e in entriesOf(init) do
			table.insert(self._entries, { name = e.name, lower = e.lower, value = e.value })
		end
		return self
	end
	if type(init) ~= "table" then
		error(`headers must be a table, got {typeof(init)}`, 2)
	end
	-- A list of pairs keeps its order; a map is added in sorted order so output is stable.
	if #init > 0 then
		for _, pair in init :: { { string } } do
			methods.add(self, pair[1], pair[2])
		end
	else
		local names = {}
		for name in init :: { [string]: any } do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			methods.add(self, name, (init :: any)[name])
		end
	end
	return self
end

--- Creates headers from the `headerList` of a head parsed by `@sonata/net`.
function M.fromHead(head: { headerList: { { string } }? }): Headers
	local self = M.new()
	if head.headerList then
		for _, pair in head.headerList do
			methods.add(self, pair[1], pair[2])
		end
	end
	return self
end

--- Whether a value is a `Headers` object.
M.is = isHeaders

--- Returns `init` itself when it already is a `Headers` object, or a new one built from it.
function M.from(init: HeadersInit?): Headers
	if isHeaders(init) then
		return init :: Headers
	end
	return M.new(init)
end

return M
