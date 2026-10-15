--[[
	URL helpers on top of `net.url`.
]]

local net = require("@sonata/net")
local types = require("./types")

export type Url = types.Url
export type Query = types.Query

local url = {}

url.parse = net.url.parse
url.build = net.url.build
url.resolve = net.url.resolve
url.normalize = net.url.normalize
url.origin = net.url.origin
url.encode = net.url.encode
url.decode = net.url.decode
url.parseQuery = net.url.parseQuery
url.defaultPort = net.url.defaultPort

--- Encodes query parameters. Accepts a string (returned as is), a list of `{ name, value }`
--- pairs, or a map whose values are strings, numbers, booleans or lists of them. `false`
--- leaves a parameter out.
function url.buildQuery(query: Query?): string
	if query == nil then
		return ""
	end
	if type(query) == "string" then
		return (string.gsub(query, "^%?", ""))
	end
	local pairsList: { { string } } = {}
	if #query > 0 then
		for _, pair in query :: { { any } } do
			table.insert(pairsList, { tostring(pair[1]), tostring(pair[2]) })
		end
	else
		local names = {}
		for name in query :: { [string]: any } do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local value = (query :: any)[name]
			if type(value) == "table" then
				for _, v in value do
					table.insert(pairsList, { name, tostring(v) })
				end
			elseif value ~= nil and value ~= false then
				table.insert(pairsList, { name, tostring(value) })
			end
		end
	end
	if #pairsList == 0 then
		return ""
	end
	return net.url.buildQuery(pairsList)
end

--- Adds query parameters to a URL, keeping the ones it already has.
---
---     url.withQuery("https://a.com/s?x=1", { q = "a b" }) --> "https://a.com/s?x=1&q=a%20b"
function url.withQuery(target: string, query: Query?): string
	local extra = url.buildQuery(query)
	if extra == "" then
		return target
	end
	local base, fragment = string.match(target, "^([^#]*)(#?.*)$")
	assert(base and fragment)
	local sep = if string.find(base, "?", 1, true) then (if string.sub(base, -1) == "?" or string.sub(base, -1) == "&" then "" else "&") else "?"
	return base .. sep .. extra .. fragment
end

--- Joins a base URL and a path the way API clients expect: the path is appended to the
--- base's path, instead of replacing its last segment as RFC 3986 resolution would.
--- Absolute URLs (with a scheme) are returned unchanged.
---
---     url.join("https://api.x.com/v1", "users/1")  --> "https://api.x.com/v1/users/1"
---     url.join("https://api.x.com/v1/", "/users")  --> "https://api.x.com/v1/users"
function url.join(base: string?, path: string): string
	if base == nil or base == "" or string.match(path, "^%a[%w+.-]*://") then
		return path
	end
	if path == "" then
		return base
	end
	if string.sub(path, 1, 1) == "?" then
		return url.withQuery(base, string.sub(path, 2))
	end
	local left = string.gsub(base, "/+$", "")
	local right = string.gsub(path, "^/+", "")
	return `{left}/{right}`
end

--- The request target (path and query) of a parsed URL: "/a/b?x=1".
function url.target(parsed: Url): string
	local path = parsed.path
	if path == nil or path == "" then
		path = "/"
	end
	if parsed.query and parsed.query ~= "" then
		return `{path}?{parsed.query}`
	end
	return path :: string
end

--- The value of a Host header for a parsed URL: the host, with the port unless it is the
--- scheme's default. IPv6 addresses get their brackets back.
function url.hostHeader(parsed: Url): string
	local host = parsed.host or ""
	if string.find(host, ":", 1, true) then
		host = `[{host}]`
	end
	local port = parsed.port
	if port and port ~= net.url.defaultPort(parsed.scheme or "") then
		return `{host}:{port}`
	end
	return host
end

--- Splits a path into its segments, percent-decoding each one.
function url.segments(path: string): { string }
	local out = {}
	for segment in string.gmatch(path, "[^/]+") do
		table.insert(out, net.url.decode(segment))
	end
	return out
end

return url
