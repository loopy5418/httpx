--[[
	The request object handlers receive.

	    app:post("/users/:id", function(req, res)
	        print(req.method, req.path, req.params.id, req.query.sort)
	        local data = req:json()       -- raises 400 if the body isn't JSON
	        local token = req.headers.authorization
	        return { ok = true }
	    end)
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local types = require("./types")
local httpErrors = require("./errors")
local errorsLib = require("../core/errors")
local headersLib = require("../core/headers")
local bodyLib = require("../core/body")

export type Request = types.Request

local Request = {}
local methods = {}

-- Fields computed on first access.
local lazy = {}

function lazy.body(self: any): string
	return methods.text(self)
end

function lazy.cookies(self: any): { [string]: string }
	local header = self.headers:get("cookie")
	if header == nil then
		return {}
	end
	local ok, parsed = pcall(net.http.parseCookies, header)
	return if ok and parsed then parsed else {}
end

function lazy.query(self: any): { [string]: string }
	if self.rawQuery == nil or self.rawQuery == "" then
		rawset(self, "queryList", {})
		return {}
	end
	local map, list = net.url.parseQuery(self.rawQuery)
	rawset(self, "queryList", list)
	return map
end

function lazy.queryList(self: any): { { string } }
	lazy.query(self)
	return rawget(self, "queryList") or {}
end

Request.__index = function(self, key)
	local method = methods[key]
	if method ~= nil then
		return method
	end
	local compute = lazy[key]
	if compute then
		local value = compute(self)
		rawset(self, key, value)
		return value
	end
	return nil
end

Request.__tostring = function(self)
	return `Request({self.method} {self.target})`
end

--- A request header.
function methods.header(self: any, name: string): string?
	return self.headers:get(name)
end

--- The next piece of the body, or `nil` at the end. Raises 400/413 errors on failure.
function methods.read(self: any): string?
	local reader = self._reader
	if reader == nil then
		return nil
	end
	local chunk, err = reader:read()
	if err then
		if errorsLib.kind(err) == "body" and string.find(err, "larger than", 1, true) then
			httpErrors.abort(413, "request body too large")
		end
		httpErrors.abort(400, `could not read the request body ({err})`)
	end
	return chunk
end

--- Iterates over the pieces of the body as they arrive, for large uploads.
function methods.chunks(self: any): () -> string?
	return function()
		return methods.read(self)
	end
end

--- The whole body as a string. Raises 413 if it is larger than `maxBodySize`.
function methods.text(self: any): string
	local cached = rawget(self, "body")
	if cached ~= nil then
		return cached
	end
	local parts = {}
	while true do
		local chunk = methods.read(self)
		if chunk == nil then
			break
		end
		table.insert(parts, chunk)
	end
	local text = table.concat(parts)
	rawset(self, "body", text)
	return text
end

--- The body decoded as JSON. Raises 400 if it isn't valid JSON.
function methods.json(self: any): any
	local text = methods.text(self)
	if text == "" then
		httpErrors.abort(400, "expected a JSON body")
	end
	local ok, value = pcall(json.decode, text)
	if not ok then
		httpErrors.abort(400, `invalid JSON body: {value}`)
	end
	return value
end

--- The body decoded as application/x-www-form-urlencoded.
function methods.form(self: any): { [string]: string }
	local text = methods.text(self)
	if text == "" then
		return {}
	end
	local map = net.url.parseQuery(text)
	return map
end

--- The parts of a multipart/form-data body: the list in order, and a map by field name.
--- Raises 400 if the body isn't multipart.
function methods.multipart(self: any): ({ types.Part }, { [string]: types.Part })
	local contentType = self.headers:get("content-type")
	if contentType == nil or not string.find(string.lower(contentType), "multipart/", 1, true) then
		httpErrors.abort(400, "expected a multipart body")
	end
	local parts = net.http.decodeMultipart(methods.text(self), contentType :: string)
	if parts == nil then
		httpErrors.abort(400, "invalid multipart body")
	end
	local byName = {}
	for _, part in parts :: { types.Part } do
		if part.name and byName[part.name] == nil then
			byName[part.name] = part
		end
	end
	return parts :: { types.Part }, byName
end

--- The best match among the given content types for the Accept header, or `nil` when none
--- is acceptable. Short names work: `req:accepts("json", "html")`.
function methods.accepts(self: any, ...: string): string?
	local offered = { ... }
	local header = self.headers:get("accept")
	if header == nil or header == "" then
		return offered[1]
	end
	local ok, ranges = pcall(net.http.parseQuality, header)
	if not ok or ranges == nil then
		return offered[1]
	end
	local function full(t: string): string
		if string.find(t, "/", 1, true) then
			return string.lower(t)
		end
		return net.mime.lookup(t) or t
	end
	-- `ranges` is sorted by preference.
	for _, range in ranges do
		if range.q > 0 then
			local value = string.lower(range.value)
			for _, t in offered do
				local mime = full(t)
				local typ = string.match(mime, "^([^/]+)/")
				if
					value == "*/*"
					or value == mime
					or (typ and string.sub(value, -2) == "/*" and string.sub(value, 1, -3) == typ)
				then
					return t
				end
			end
		end
	end
	return nil
end

--- Whether the request body has this content type: `req:is("json")`, `req:is("text/*")`.
function methods.is(self: any, contentType: string): boolean
	local header = self.headers:get("content-type")
	if header == nil then
		return false
	end
	local essence = string.lower((string.match(header, "^[^;]*") :: string))
	essence = string.gsub(essence, "%s", "")
	local wanted = string.lower(contentType)
	if wanted == "json" then
		return bodyLib.isJson(essence)
	end
	if not string.find(wanted, "/", 1, true) then
		wanted = net.mime.lookup(wanted) or wanted
	end
	if string.sub(wanted, -2) == "/*" then
		return string.sub(essence, 1, #wanted - 1) == string.sub(wanted, 1, -2)
	end
	return essence == wanted
end

--- Whether this is a WebSocket upgrade request.
function methods.isWebSocket(self: any): boolean
	local upgrade = self.headers:get("upgrade")
	return self.method == "GET" and upgrade ~= nil and string.lower(upgrade) == "websocket"
end

local M = {}

export type Init = {
	head: any, -- a request head from net.http.parseRequest
	reader: any, -- its BodyReader
	socket: any,
	secure: boolean,
	trustProxy: boolean?,
	app: any?,
}

function M.new(init: Init): Request
	local head = init.head
	local headers = headersLib.fromHead(head)
	local sock = init.socket
	local ip, port = "", 0
	local okPeer, peerHost, peerPort = pcall(sock.peerAddress, sock)
	if okPeer and peerHost then
		ip, port = peerHost, peerPort or 0
	end
	local protocol = if init.secure then "https" else "http"
	local hostHeader = headers:get("host") or ""
	if init.trustProxy then
		local forwardedFor = headers:get("x-forwarded-for")
		if forwardedFor then
			ip = string.match(forwardedFor, "^%s*([^,%s]+)") or ip
		end
		local forwardedProto = headers:get("x-forwarded-proto")
		if forwardedProto then
			protocol = string.lower((string.match(forwardedProto, "^%s*([^,%s]+)") or protocol))
		end
		local forwardedHost = headers:get("x-forwarded-host")
		if forwardedHost then
			hostHeader = string.match(forwardedHost, "^%s*([^,%s]+)") or hostHeader
		end
	end
	local host = string.match(hostHeader, "^%[([^%]]+)%]") or string.match(hostHeader, "^([^:]+)") or ""

	local path = head.path or "/"
	local self = setmetatable({
		method = head.method,
		path = path,
		originalPath = path,
		baseUrl = "",
		target = head.target,
		rawQuery = head.query,
		params = {},
		headers = headers,
		version = head.version or "1.1",
		ip = ip,
		port = port,
		host = host,
		protocol = protocol,
		secure = protocol == "https",
		url = `{protocol}://{if hostHeader ~= "" then hostHeader else "localhost"}{head.target}`,
		locals = {},
		app = init.app,
		socket = sock,
		_reader = init.reader,
	}, Request)
	return self :: any
end

M.Request = Request

return M
