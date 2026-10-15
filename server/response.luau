--[[
	The response object handlers receive.

	    res:status(201):header("Location", "/items/7"):json({ id = 7 })
	    res:send("plain text")
	    res:html("<h1>Hi</h1>")
	    res:redirect("/login")
	    res:file("report.pdf")

	Streaming (chunked):

	    res:type("text/plain")
	    for i = 1, 5 do
	        res:write(`tick {i}\n`)
	        task.wait(1)
	    end
	    res:finish()
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local compress = require("@sonata/compress")
local types = require("./types")
local headersLib = require("../core/headers")
local bodyLib = require("../core/body")

export type Response = types.Response

local Response = {}
Response.__index = Response

local M = {}

local SMALL = 64 * 1024

local function sniff(data: string): string
	if string.match(data, "^%s*<") then
		return "text/html; charset=utf-8"
	end
	return "text/plain; charset=utf-8"
end

local function withCharset(contentType: string): string
	if string.find(contentType, "charset", 1, true) then
		return contentType
	end
	local essence = string.lower((string.match(contentType, "^[^;]*") :: string))
	if net.mime.isText(essence) or bodyLib.isJson(essence) then
		return contentType .. "; charset=utf-8"
	end
	return contentType
end

export type Init = {
	socket: any,
	request: any,
	serverHeader: (string | false)?,
	keepAlive: boolean,
}

function M.new(init: Init): Response
	local self = setmetatable({
		statusCode = 200,
		headers = headersLib.new(),
		sent = false,
		finished = false,
		upgraded = false,
		closeAfter = not init.keepAlive,
		request = init.request,
		bytesSent = 0,
		_sock = init.socket,
		_serverHeader = init.serverHeader,
		_chunked = false,
		_compress = nil,
	}, Response)
	return self :: any
end

--- Sets the status code.
function Response.status(self: any, code: number): Response
	self.statusCode = code
	return self
end

--- Sets a header, replacing any previous value. A list value sends the header repeatedly.
function Response.header(self: any, name: string, value: any): Response
	if value == nil then
		self.headers:delete(name)
	else
		self.headers:set(name, if type(value) == "table" then value else tostring(value))
	end
	return self
end

Response.set = Response.header

--- Appends a header value, keeping existing ones.
function Response.append(self: any, name: string, value: any): Response
	self.headers:add(name, if type(value) == "table" then value else tostring(value))
	return self
end

--- Reads a response header set so far.
function Response.get(self: any, name: string): string?
	return self.headers:get(name)
end

--- Sets the Content-Type: a full type, or a short name or extension ("json", "html", "png").
function Response.type(self: any, contentType: string): Response
	if not string.find(contentType, "/", 1, true) then
		contentType = net.mime.lookup(contentType) or "application/octet-stream"
	end
	self.headers:set("Content-Type", withCharset(contentType))
	return self
end

--- Adds a Set-Cookie header. Cookies are HttpOnly with Path=/ unless told otherwise.
function Response.cookie(self: any, name: string, value: string, options: types.CookieOptions?): Response
	local cookie: { [string]: any } = { name = name, value = value, path = "/", httpOnly = true }
	if options then
		for k, v in options :: { [string]: any } do
			cookie[k] = v
		end
	end
	self.headers:add("Set-Cookie", net.http.formatSetCookie(cookie))
	return self
end

--- Tells the client to delete a cookie (same path and domain as when it was set).
function Response.clearCookie(self: any, name: string, options: types.CookieOptions?): Response
	local cookie: { [string]: any } = { path = "/" }
	if options then
		for k, v in options :: { [string]: any } do
			cookie[k] = v
		end
	end
	cookie.maxAge = 0
	cookie.expires = 0
	return Response.cookie(self, name, "", cookie)
end

-- Builds the head. Called once, right before the first bytes go out.
function Response._head(self: any): string
	local headers = self.headers
	headers:setDefault("Date", net.http.formatDate())
	if self._serverHeader then
		headers:setDefault("Server", self._serverHeader)
	end
	local req = self.request
	if self.closeAfter then
		headers:set("Connection", "close")
	elseif req and req.version == "1.0" then
		headers:set("Connection", "keep-alive")
	end
	return net.http.formatResponse({
		status = self.statusCode,
		reason = net.http.statusText(self.statusCode) or "Unknown",
		headers = headers:list(),
	})
end

function Response._send(self: any, data: string): boolean
	local ok, err = self._sock:send(data)
	if not ok then
		self.closeAfter = true
		self.clientError = err
		return false
	end
	self.bytesSent += #data
	return true
end

-- Whether the request is a HEAD request (no body is sent).
function Response._isHead(self: any): boolean
	return self.request ~= nil and self.request.method == "HEAD"
end

--- Sends the response. `body` may be a string, a buffer, or a table (sent as JSON). Returns
--- `false` if the response was already sent or the client is gone.
function Response.send(self: any, body: any?): boolean
	if self.finished then
		return false
	end
	if self.sent then
		if body ~= nil then
			self:write(tostring(body))
		end
		return self:finish()
	end
	local headers = self.headers
	local data: string
	local contentType: string? = nil
	if body == nil then
		data = ""
	elseif type(body) == "string" then
		data = body
		contentType = sniff(body)
	elseif type(body) == "buffer" then
		data = buffer.tostring(body)
		contentType = "application/octet-stream"
	elseif type(body) == "table" then
		data = json.encode(body)
		contentType = "application/json; charset=utf-8"
	else
		data = tostring(body)
		contentType = "text/plain; charset=utf-8"
	end

	local status = self.statusCode
	if status == 204 or status == 304 or (status >= 100 and status < 200) then
		data = ""
		headers:delete("Content-Type")
		headers:delete("Content-Length")
		headers:delete("Transfer-Encoding")
	else
		if contentType and not headers:has("Content-Type") then
			headers:set("Content-Type", contentType)
		end
		local options = self._compress
		if
			options
			and #data >= (options.threshold or 1024)
			and not headers:has("Content-Encoding")
			and bodyLib.isCompressible(headers:get("Content-Type"))
		then
			local encoding, format = options.choose(self.request)
			if encoding then
				data = compress.compress(data, format or encoding, options.level)
				headers:set("Content-Encoding", encoding)
			end
			headers:add("Vary", "Accept-Encoding")
		end
		headers:set("Content-Length", tostring(#data))
		headers:delete("Transfer-Encoding")
	end

	local head = self:_head()
	self.sent = true
	self.finished = true
	if self:_isHead() or data == "" then
		return self:_send(head)
	end
	if #data <= SMALL then
		return self:_send(head .. data)
	end
	return self:_send(head) and self:_send(data)
end

--- Sends a value as JSON.
function Response.json(self: any, value: any, status: number?): boolean
	if status then
		self.statusCode = status
	end
	if not self.headers:has("Content-Type") then
		self.headers:set("Content-Type", "application/json; charset=utf-8")
	end
	return self:send(json.encode(value))
end

--- Sends plain text.
function Response.text(self: any, text: string, status: number?): boolean
	if status then
		self.statusCode = status
	end
	self.headers:set("Content-Type", "text/plain; charset=utf-8")
	return self:send(text)
end

--- Sends HTML.
function Response.html(self: any, html: string, status: number?): boolean
	if status then
		self.statusCode = status
	end
	self.headers:set("Content-Type", "text/html; charset=utf-8")
	return self:send(html)
end

--- Redirects to another location (302 Found by default).
function Response.redirect(self: any, location: string, status: number?): boolean
	self.statusCode = status or 302
	self.headers:set("Location", location)
	return self:text(`Redirecting to {location}`)
end

--- Sends an error status with a short body: JSON if the client prefers it, text otherwise.
function Response.error(self: any, status: number, message: string?): boolean
	self.statusCode = status
	local text = message or net.http.statusText(status) or "Error"
	local req = self.request
	if req and req.headers then
		local accept = req.headers:get("accept")
		if accept and string.find(accept, "json", 1, true) and not string.find(accept, "html", 1, true) then
			return self:json({ error = text, status = status })
		end
	end
	return self:text(text)
end

--- Sends a file (with ETag, Last-Modified, ranges and a guessed Content-Type).
function Response.file(self: any, file: string, options: types.StaticOptions?): boolean
	local static = require("./static") :: any
	return static.sendFile(self.request, self, file, options)
end

--- Starts a server-sent events stream. See `sse/stream.luau`.
function Response.sse(self: any, options: { [string]: any }?): any
	local stream = require("../sse/stream") :: any
	return stream.open(self.request, self, options)
end

--- Sends a piece of a streamed body, starting the response if needed. Without a
--- Content-Length the body is sent chunked. Returns `false, err` once the client is gone.
function Response.write(self: any, chunk: string): (boolean, string?)
	if self.finished then
		return false, "response already finished"
	end
	if not self.sent then
		local headers = self.headers
		headers:setDefault("Content-Type", "text/plain; charset=utf-8")
		if not headers:has("Content-Length") then
			local req = self.request
			if req and req.version == "1.0" then
				-- HTTP/1.0 has no chunked coding: the end of the body is the end of the connection.
				self.closeAfter = true
			else
				self._chunked = true
				headers:set("Transfer-Encoding", "chunked")
			end
		end
		self.sent = true
		if not self:_send(self:_head()) then
			self.finished = true
			return false, self.clientError
		end
		if self:_isHead() then
			return true, nil
		end
	end
	if self:_isHead() or chunk == "" then
		return true, nil
	end
	local ok = self:_send(if self._chunked then net.http.encodeChunk(chunk) else chunk)
	if not ok then
		self.finished = true
		return false, self.clientError
	end
	return true, nil
end

--- Ends the response, writing `chunk` first if given. Sends an empty response if nothing was
--- sent yet.
function Response.finish(self: any, chunk: string?): boolean
	if self.finished then
		return false
	end
	if not self.sent then
		return self:send(chunk)
	end
	if chunk and chunk ~= "" then
		self:write(chunk)
	end
	self.finished = true
	if self._chunked and not self:_isHead() then
		return self:_send(net.http.lastChunk())
	end
	return true
end

--- Registers a function called once the response is complete (also after errors), with
--- the request and the response. Middleware uses it to log or measure.
function Response.onFinish(self: any, fn: (req: any, res: any) -> ()): Response
	local hooks = self._onFinish
	if hooks == nil then
		hooks = {}
		self._onFinish = hooks
	end
	table.insert(hooks, fn)
	return self
end

-- Runs the onFinish hooks (once).
function Response._runFinishHooks(self: any)
	local hooks = self._onFinish
	if hooks == nil then
		return
	end
	self._onFinish = nil
	for _, fn in hooks do
		local ok, err = pcall(fn, self.request, self)
		if not ok then
			print(`httpx: error in an onFinish hook: {err}`)
		end
	end
end

--- Takes the raw socket away from the server, for protocol upgrades (WebSocket, ...). The
--- server stops handling the connection; the caller owns it from then on.
function Response.takeover(self: any): any
	self.upgraded = true
	self.sent = true
	self.finished = true
	return self._sock
end

Response.__tostring = function(self)
	return `Response({self.statusCode})`
end

M.Response = Response

return M
