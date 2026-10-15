--[[
	A cookie jar (RFC 6265, simplified): stores cookies from Set-Cookie headers and produces
	the Cookie header for later requests.

	    local jar = cookies.jar()
	    local client = httpx.client({ cookies = jar })
	    ...
	    jar:save("cookies.json") -- keep them for the next run
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local fs = require("@sonata/fs")
local types = require("./types")

export type Cookie = types.Cookie
export type CookieJar = types.CookieJar

local Jar = {}
Jar.__index = Jar

local function now(): number
	return os.time()
end

local function domainMatches(host: string, domain: string): boolean
	if host == domain then
		return true
	end
	-- IP addresses only match exactly.
	if net.ip.isValid(host) then
		return false
	end
	return #host > #domain and string.sub(host, -#domain - 1) == "." .. domain
end

local function pathMatches(requestPath: string, cookiePath: string): boolean
	if requestPath == cookiePath then
		return true
	end
	if string.sub(requestPath, 1, #cookiePath) == cookiePath then
		return string.sub(cookiePath, -1) == "/" or string.sub(requestPath, #cookiePath + 1, #cookiePath + 1) == "/"
	end
	return false
end

local function defaultPath(requestPath: string?): string
	if requestPath == nil or string.sub(requestPath, 1, 1) ~= "/" then
		return "/"
	end
	local dir = string.match(requestPath, "^(.*)/[^/]*$")
	if dir == nil or dir == "" then
		return "/"
	end
	return dir
end

-- Breaks ties between cookies created in the same second: older first.
local sequence = 0
local function nextSeq(): number
	sequence += 1
	return sequence
end

local function key(c: { name: string, domain: string, path: string }): string
	return `{c.domain};{c.path};{c.name}`
end

local function expired(c: Cookie, t: number): boolean
	return c.expires ~= nil and c.expires <= t
end

--- Stores the cookies of one or more Set-Cookie header values received from `url`.
function Jar.store(self: any, target: string, setCookie: string | { string })
	local parsed = net.url.parse(target)
	if parsed == nil or parsed.host == nil then
		return
	end
	local host = string.lower(parsed.host)
	local values: { string }
	if type(setCookie) == "string" then
		-- A joined header uses "\n" between cookies.
		values = string.split(setCookie, "\n")
	else
		values = setCookie
	end
	local t = now()
	for _, value in values do
		if value ~= "" then
			local ok, sc = pcall(net.http.parseSetCookie, value)
			if ok and sc and sc.name and sc.name ~= "" then
				local domain = host
				local hostOnly = true
				if sc.domain and sc.domain ~= "" then
					local d = string.lower((string.gsub(sc.domain, "^%.", "")))
					if domainMatches(host, d) then
						domain = d
						hostOnly = false
					else
						continue -- a server can't set cookies for other domains
					end
				end
				local expires: number? = nil
				if sc.maxAge ~= nil then
					expires = t + sc.maxAge
				elseif sc.expires ~= nil then
					expires = if type(sc.expires) == "number" then sc.expires else net.http.parseDate(sc.expires)
				end
				local cookie: Cookie = {
					name = sc.name,
					value = sc.value or "",
					domain = domain,
					path = if sc.path and string.sub(sc.path, 1, 1) == "/" then sc.path else defaultPath(parsed.path),
					hostOnly = hostOnly,
					secure = sc.secure == true,
					httpOnly = sc.httpOnly == true,
					sameSite = sc.sameSite,
					expires = expires,
					created = t,
				}
				local k = key(cookie)
				if expires and expires <= t then
					self._cookies[k] = nil
				else
					local old = self._cookies[k]
					if old then
						cookie.created = old.created
						cookie.seq = old.seq
					else
						cookie.seq = nextSeq()
					end
					self._cookies[k] = cookie
				end
			end
		end
	end
end

--- The Cookie header to send to `url`, or `nil` if no cookie applies.
function Jar.header(self: any, target: string): string?
	local parsed = net.url.parse(target)
	if parsed == nil or parsed.host == nil then
		return nil
	end
	local host = string.lower(parsed.host)
	local requestPath = if parsed.path and parsed.path ~= "" then parsed.path else "/"
	local secure = parsed.scheme == "https" or parsed.scheme == "wss"
	local t = now()
	local matching: { Cookie } = {}
	for k, c: Cookie in self._cookies do
		if expired(c, t) then
			self._cookies[k] = nil
		elseif
			(if c.hostOnly then host == c.domain else domainMatches(host, c.domain))
			and pathMatches(requestPath, c.path)
			and (not c.secure or secure)
		then
			table.insert(matching, c)
		end
	end
	if #matching == 0 then
		return nil
	end
	-- Longer paths first, then older cookies first.
	table.sort(matching, function(a, b)
		if #a.path ~= #b.path then
			return #a.path > #b.path
		end
		if a.created ~= b.created then
			return a.created < b.created
		end
		return (a.seq or 0) < (b.seq or 0)
	end)
	local parts = {}
	for _, c in matching do
		table.insert(parts, `{c.name}={c.value}`)
	end
	return table.concat(parts, "; ")
end

--- The cookie called `name` (that applies to `url`, if given).
function Jar.get(self: any, name: string, target: string?): Cookie?
	local host: string? = nil
	if target then
		local parsed = net.url.parse(target)
		host = parsed and parsed.host and string.lower(parsed.host)
	end
	local t = now()
	for _, c: Cookie in self._cookies do
		if c.name == name and not expired(c, t) and (host == nil or domainMatches(host :: string, c.domain)) then
			return c
		end
	end
	return nil
end

--- Adds a cookie by hand: `{ name, value, domain, path?, secure?, httpOnly?, expires? }`.
function Jar.set(self: any, cookie: { [string]: any })
	assert(type(cookie.name) == "string", "cookie.name must be a string")
	assert(type(cookie.domain) == "string", "cookie.domain must be a string")
	local c: Cookie = {
		name = cookie.name,
		value = tostring(cookie.value or ""),
		domain = string.lower((string.gsub(cookie.domain, "^%.", ""))),
		path = cookie.path or "/",
		hostOnly = cookie.hostOnly == true,
		secure = cookie.secure == true,
		httpOnly = cookie.httpOnly == true,
		sameSite = cookie.sameSite,
		expires = cookie.expires,
		created = now(),
	}
	c.seq = nextSeq()
	self._cookies[key(c)] = c
end

--- Removes cookies called `name` (optionally only for `domain` and `path`).
function Jar.remove(self: any, name: string, domain: string?, cookiePath: string?)
	for k, c: Cookie in self._cookies do
		if c.name == name and (domain == nil or c.domain == domain) and (cookiePath == nil or c.path == cookiePath) then
			self._cookies[k] = nil
		end
	end
end

--- Every live cookie.
function Jar.all(self: any): { Cookie }
	local out = {}
	local t = now()
	for _, c: Cookie in self._cookies do
		if not expired(c, t) then
			table.insert(out, c)
		end
	end
	table.sort(out, function(a, b)
		return key(a) < key(b)
	end)
	return out
end

function Jar.clear(self: any)
	table.clear(self._cookies)
end

--- The persistent cookies (the ones with an expiry date) as JSON.
function Jar.toJSON(self: any): string
	local list = {}
	for _, c in Jar.all(self) do
		if c.expires then
			table.insert(list, c)
		end
	end
	return json.encode(json.array(list))
end

--- Loads cookies from JSON produced by `toJSON`, adding them to the jar.
function Jar.fromJSON(self: any, text: string)
	local list = json.decode(text)
	for _, c in list do
		self._cookies[key(c)] = c
	end
end

--- Saves the persistent cookies to a file.
function Jar.save(self: any, file: string)
	fs.writeFile(file, Jar.toJSON(self))
end

--- Loads cookies from a file written by `save`. A missing file is fine.
function Jar.load(self: any, file: string)
	if fs.isFile(file) then
		Jar.fromJSON(self, fs.readFile(file))
	end
end

local cookies = {}

--- Creates an empty cookie jar.
function cookies.jar(): CookieJar
	return setmetatable({ _cookies = {} }, Jar) :: any
end

--- Whether a value is a cookie jar.
function cookies.isJar(value: any): boolean
	return type(value) == "table" and getmetatable(value) == Jar
end

--- Parses a Cookie request header: "a=1; b=2" -> { a = "1", b = "2" }.
cookies.parse = net.http.parseCookies
--- Formats a Set-Cookie header value from `{ name, value, maxAge?, expires?, path?, ... }`.
cookies.serialize = net.http.formatSetCookie
--- Parses one Set-Cookie header value.
cookies.parseSetCookie = net.http.parseSetCookie

return cookies
