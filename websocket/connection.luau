--[[
	A WebSocket connection (RFC 6455), on any socket, as client or server.

	    ws:send("hello")                  -- text
	    ws:sendBinary(bytes)
	    ws:sendJson({ type = "join" })

	    for message, kind in ws:messages() do
	        print(kind, message)
	    end
	    print("closed", ws.closeCode, ws.closeReason)

	Or with event handlers:

	    ws:on("message", function(data, kind) ... end)
	    ws:on("close", function(code, reason) ... end)
	    ws:start() -- reads in the background
]]

local net = require("@sonata/net")
local task = require("@sonata/task")
local json = require("@sonata/json")
local types = require("./types")
local errors = require("../core/errors")

export type WebSocket = types.WebSocket

local OPCODES: { [any]: string } = {
	[0] = "continuation",
	[1] = "text",
	[2] = "binary",
	[8] = "close",
	[9] = "ping",
	[10] = "pong",
	continuation = "continuation",
	text = "text",
	binary = "binary",
	close = "close",
	ping = "ping",
	pong = "pong",
}

-- Close codes
local NORMAL = 1000
local PROTOCOL_ERROR = 1002
local NO_STATUS = 1005
local ABNORMAL = 1006
local INVALID_DATA = 1007
local TOO_BIG = 1009

local READ_SIZE = 64 * 1024

local WebSocket = {}
WebSocket.__index = WebSocket

local M = {}

M.codes = {
	normal = NORMAL,
	goingAway = 1001,
	protocolError = PROTOCOL_ERROR,
	unsupportedData = 1003,
	noStatus = NO_STATUS,
	abnormal = ABNORMAL,
	invalidData = INVALID_DATA,
	policyViolation = 1008,
	tooBig = TOO_BIG,
	missingExtension = 1010,
	internalError = 1011,
	serviceRestart = 1012,
	tryAgainLater = 1013,
}

function M.new(sock: any, options: { [string]: any }?): WebSocket
	local opts = options or {}
	local self = setmetatable({
		state = "open",
		closed = false,
		closeCode = nil,
		closeReason = nil,
		protocol = opts.protocol,
		isClient = opts.client == true,
		url = opts.url,
		request = opts.request,
		headers = opts.headers,
		locals = {},
		socket = sock,
		_maxMessage = opts.maxMessageSize or 16 * 1024 * 1024,
		_autoPong = opts.autoPong ~= false,
		_closeTimeout = opts.closeTimeout or 5,
		_buf = opts.buffered or "",
		_fragments = nil :: { string }?,
		_fragmentKind = nil :: string?,
		_fragmentSize = 0,
		_sendLock = task.mutex(),
		_closeSent = false,
		_closedEvent = task.event(),
		_handlers = {} :: { [string]: { (...any) -> () } },
		_heartbeat = nil :: thread?,
		_lastPong = os.clock(),
		_readers = 0,
	}, WebSocket)
	sock:setTimeout(nil)
	if opts.pingInterval and opts.pingInterval > 0 then
		self:_startHeartbeat(opts.pingInterval, opts.pingTimeout or 20)
	end
	return self :: any
end

function WebSocket._emit(self: any, event: string, ...: any)
	local list = self._handlers[event]
	if list == nil then
		return
	end
	for _, handler in list do
		local ok, err = pcall(handler, ...)
		if not ok then
			print(`httpx: error in a websocket '{event}' handler: {err}`)
		end
	end
end

-- Marks the connection closed and releases everything.
function WebSocket._finalize(self: any, code: number, reason: string)
	if self.closed then
		return
	end
	self.closed = true
	self.state = "closed"
	self.closeCode = self.closeCode or code
	self.closeReason = self.closeReason or reason
	if self._heartbeat and self._heartbeat ~= task.running() then
		pcall(task.cancel, self._heartbeat)
	end
	self.socket:close()
	self._closedEvent:set()
	self:_emit("close", self.closeCode, self.closeReason)
end

-- Sends one frame (whole), serialized with other senders.
function WebSocket._sendFrame(self: any, opcode: string, payload: string): (boolean, string?)
	if self.closed or (self._closeSent and opcode ~= "close") then
		return false, errors.new("closed", "the websocket is closed")
	end
	local frame = net.ws.encode(opcode, payload, { mask = self.isClient })
	self._sendLock:lock()
	local ok, err = self.socket:send(frame)
	self._sendLock:unlock()
	if not ok then
		self:_finalize(ABNORMAL, tostring(err))
		return false, errors.fromNet(err, "sending a websocket frame")
	end
	return true, nil
end

-- Closes because the peer broke the protocol.
function WebSocket._fail(self: any, code: number, reason: string): (nil, string)
	if not self._closeSent and not self.closed then
		self._closeSent = true
		pcall(function()
			local frame = net.ws.encode("close", net.ws.closePayload(code, reason), { mask = self.isClient })
			self.socket:send(frame)
		end)
	end
	self.closeCode = code
	self.closeReason = reason
	self:_finalize(code, reason)
	self:_emit("error", errors.new("protocol", reason))
	return nil, errors.new("protocol", reason)
end

-- Reads one frame. Returns the frame, or nil and an error ("timed out" untouched).
function WebSocket._readFrame(self: any): (any, string?)
	while true do
		if #self._buf > 0 then
			local frame, used = net.ws.decode(self._buf, { maxPayload = self._maxMessage })
			if frame then
				self._buf = string.sub(self._buf, (used :: number) + 1)
				return frame, nil
			elseif used ~= nil then
				local message = tostring(used)
				local lower = string.lower(message)
				local code = if string.find(lower, "large", 1, true) or string.find(lower, "max", 1, true) then TOO_BIG else PROTOCOL_ERROR
				return self:_fail(code, message)
			end
		end
		local data, err = self.socket:recv(READ_SIZE)
		if data == nil then
			if err == "timed out" then
				return nil, "timed out"
			end
			self:_finalize(ABNORMAL, tostring(err))
			return nil, errors.fromNet(err, "reading from the websocket")
		end
		if data == "" then
			self:_finalize(ABNORMAL, "connection closed without a close frame")
			return nil, errors.new("closed", "connection closed without a close frame")
		end
		self._buf ..= data
	end
end

--- Receives the next message. Returns `data, kind` ("text" or "binary"); `nil, "timed out"`
--- if `timeout` seconds passed; or `nil` once the connection is closed (see `closeCode`).
--- Pings are answered on the way.
function WebSocket.recv(self: any, timeout: number?): (string?, string?)
	if self.closed then
		return nil, nil
	end
	if timeout then
		self.socket:setTimeout(timeout)
	end
	self._readers += 1
	local function done(...)
		self._readers -= 1
		if timeout and not self.closed then
			self.socket:setTimeout(nil)
		end
		return ...
	end
	while true do
		local frame, err = self:_readFrame()
		if frame == nil then
			if err == "timed out" then
				return done(nil, "timed out")
			end
			return done(nil, nil)
		end
		local opcode = OPCODES[frame.opcode]
		if frame.rsv1 or frame.rsv2 or frame.rsv3 then
			return done(self:_fail(PROTOCOL_ERROR, "reserved bits set (no extension was agreed)"))
		end
		if self.isClient and frame.masked then
			return done(self:_fail(PROTOCOL_ERROR, "the server sent a masked frame"))
		elseif not self.isClient and not frame.masked then
			return done(self:_fail(PROTOCOL_ERROR, "the client sent an unmasked frame"))
		end
		local payload: string = frame.payload or ""
		if opcode == "close" or opcode == "ping" or opcode == "pong" then
			if not frame.fin or #payload > 125 then
				return done(self:_fail(PROTOCOL_ERROR, "invalid control frame"))
			end
		end

		if opcode == "ping" then
			if self._autoPong then
				self:_sendFrame("pong", payload)
			end
			self:_emit("ping", payload)
		elseif opcode == "pong" then
			self._lastPong = os.clock()
			self:_emit("pong", payload)
		elseif opcode == "close" then
			local code, reason = nil, ""
			if #payload > 0 then
				code, reason = net.ws.parseClose(payload)
			end
			self.closeCode = code or NO_STATUS
			self.closeReason = reason or ""
			self.state = "closing"
			if not self._closeSent then
				self._closeSent = true
				-- Echo the close frame, then end the connection.
				local echo = if code then net.ws.closePayload(code) else ""
				pcall(function()
					self.socket:send(net.ws.encode("close", echo, { mask = self.isClient }))
				end)
			end
			self:_finalize(self.closeCode, self.closeReason)
			return done(nil, nil)
		elseif opcode == "text" or opcode == "binary" then
			if self._fragments then
				return done(self:_fail(PROTOCOL_ERROR, "a new message started before the last one ended"))
			end
			if frame.fin then
				if opcode == "text" and utf8.len(payload) == nil then
					return done(self:_fail(INVALID_DATA, "text message is not valid UTF-8"))
				end
				self:_emit("message", payload, opcode)
				self:_emit(opcode, payload)
				return done(payload, opcode)
			end
			self._fragments = { payload }
			self._fragmentKind = opcode
			self._fragmentSize = #payload
		elseif opcode == "continuation" then
			local fragments = self._fragments
			if fragments == nil then
				return done(self:_fail(PROTOCOL_ERROR, "continuation frame without a message"))
			end
			table.insert(fragments, payload)
			self._fragmentSize += #payload
			if self._fragmentSize > self._maxMessage then
				return done(self:_fail(TOO_BIG, "message too large"))
			end
			if frame.fin then
				local message = table.concat(fragments)
				local kind = self._fragmentKind :: string
				self._fragments = nil
				self._fragmentKind = nil
				self._fragmentSize = 0
				if kind == "text" and utf8.len(message) == nil then
					return done(self:_fail(INVALID_DATA, "text message is not valid UTF-8"))
				end
				self:_emit("message", message, kind)
				self:_emit(kind, message)
				return done(message, kind)
			end
		else
			return done(self:_fail(PROTOCOL_ERROR, `unknown opcode {frame.opcode}`))
		end
	end
end

--- Receives a message and decodes it as JSON. `nil, err` if it isn't JSON.
function WebSocket.recvJson(self: any, timeout: number?): (any, string?)
	local data, kind = self:recv(timeout)
	if data == nil then
		return nil, kind
	end
	local ok, value = pcall(json.decode, data)
	if not ok then
		return nil, errors.new("body", `invalid JSON message: {value}`)
	end
	return value, nil
end

--- Iterates over messages until the connection closes: `for data, kind in ws:messages()`.
function WebSocket.messages(self: any): () -> (string?, string?)
	return function()
		while true do
			local data, kind = self:recv()
			if data ~= nil or kind ~= "timed out" then
				return data, kind
			end
		end
	end
end

--- Sends a message. Strings are sent as text unless `kind` is "binary"; buffers as binary;
--- tables as JSON text.
function WebSocket.send(self: any, data: any, kind: string?): (boolean, string?)
	if type(data) == "table" then
		return self:_sendFrame("text", json.encode(data))
	elseif type(data) == "buffer" then
		return self:_sendFrame("binary", buffer.tostring(data))
	end
	return self:_sendFrame(if kind == "binary" then "binary" else "text", tostring(data))
end

function WebSocket.sendText(self: any, text: string): (boolean, string?)
	return self:_sendFrame("text", text)
end

function WebSocket.sendBinary(self: any, data: string | buffer): (boolean, string?)
	return self:_sendFrame("binary", if type(data) == "buffer" then buffer.tostring(data) else data)
end

function WebSocket.sendJson(self: any, value: any): (boolean, string?)
	return self:_sendFrame("text", json.encode(value))
end

function WebSocket.ping(self: any, payload: string?): (boolean, string?)
	return self:_sendFrame("ping", payload or "")
end

function WebSocket.pong(self: any, payload: string?): (boolean, string?)
	return self:_sendFrame("pong", payload or "")
end

--- Adds an event handler: "message" (data, kind), "text" (data), "binary" (data),
--- "ping" (payload), "pong" (payload), "close" (code, reason), "error" (err).
function WebSocket.on(self: any, event: string, handler: (...any) -> ()): WebSocket
	local list = self._handlers[event]
	if list == nil then
		list = {}
		self._handlers[event] = list
	end
	table.insert(list, handler)
	return self
end

--- Reads messages (firing the handlers) until the connection closes.
function WebSocket.run(self: any)
	while not self.closed do
		local data, kind = self:recv()
		if data == nil and kind ~= "timed out" then
			break
		end
	end
end

--- Starts `run` in its own task. Returns the websocket.
function WebSocket.start(self: any): WebSocket
	task.spawn(function()
		self:run()
	end)
	return self
end

--- Waits until the connection is closed. Returns `false` on timeout.
function WebSocket.wait(self: any, timeout: number?): boolean
	return self._closedEvent:wait(timeout)
end

--- Closes the connection: sends a close frame and waits (up to `closeTimeout`) for the
--- peer's answer.
function WebSocket.close(self: any, code: number?, reason: string?)
	if self.closed then
		return
	end
	if not self._closeSent then
		self._closeSent = true
		self.state = "closing"
		self.closeCode = code or NORMAL
		self.closeReason = reason or ""
		local payload = net.ws.closePayload(code or NORMAL, reason or "")
		local frame = net.ws.encode("close", payload, { mask = self.isClient })
		self._sendLock:lock()
		local ok = self.socket:send(frame)
		self._sendLock:unlock()
		if not ok then
			self:_finalize(ABNORMAL, "could not send the close frame")
			return
		end
	end
	-- Someone else may be reading (ws:start()); they'll see the peer's close frame. Otherwise
	-- read it here. Either way, don't wait forever.
	if self._readers > 0 then
		self._closedEvent:wait(self._closeTimeout)
	else
		task.timeout(self._closeTimeout, function()
			while not self.closed do
				local data, kind = self:recv(self._closeTimeout)
				if data == nil and kind ~= "timed out" then
					break
				end
			end
		end)
	end
	self:_finalize(self.closeCode or NORMAL, self.closeReason or "")
end

function WebSocket._startHeartbeat(self: any, interval: number, timeout: number)
	self._heartbeat = task.spawn(function()
		while not self.closed do
			task.wait(interval)
			if self.closed then
				break
			end
			if os.clock() - self._lastPong > interval + timeout then
				self:_finalize(ABNORMAL, "no pong received")
				break
			end
			self:ping()
		end
	end)
end

WebSocket.__tostring = function(self)
	return `WebSocket({self.state}{if self.url then ", " .. self.url else ""})`
end

M.WebSocket = WebSocket

return M
