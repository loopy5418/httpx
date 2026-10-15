--[[
	Reading and writing HTTP/1.1 messages on a `@sonata/net` socket. Used by both the client
	(`request`) and the server (`server`).
]]

local net = require("@sonata/net")
local types = require("./types")
local errors = require("./errors")
local bodyLib = require("./body")

export type Body = types.Body
export type BodyReader = types.BodyReader

local io = {}

io.READ_SIZE = 64 * 1024
io.DEFAULT_MAX_HEAD = 64 * 1024

export type HeadLimits = { maxHeadSize: number?, maxHeaders: number? }

--- Reads and parses a request or response head. Returns the head, or `nil, err`. A peer that
--- closes cleanly before sending anything gives `nil, "closed"` (the exact string).
function io.readHead(sock: any, kind: "request" | "response", limits: HeadLimits?): (any, string?)
	local maxHead = (limits and limits.maxHeadSize) or io.DEFAULT_MAX_HEAD
	local data, err = sock:recvUntil("\r\n\r\n", maxHead)
	if data == nil then
		if err == "closed" then
			if sock:buffered() == 0 then
				return nil, "closed"
			end
			return nil, errors.new("closed", "connection closed in the middle of the message head")
		end
		return nil, errors.fromNet(err, `reading the {kind} head`)
	end
	local parse = if kind == "request" then net.http.parseRequest else net.http.parseResponse
	local head, used = parse(data, {
		maxHeadSize = maxHead,
		maxHeaders = (limits and limits.maxHeaders) or 100,
	})
	if head == nil then
		return nil, errors.new("protocol", `invalid {kind} head: {used or "incomplete"}`)
	end
	if type(used) == "number" and used < #data then
		sock:unread(string.sub(data, used + 1))
	end
	return head, nil
end

export type ReaderOptions = {
	encoding: string?, -- Content-Encoding to decode (nil: none)
	maxSize: number?, -- most bytes of (decoded) body allowed
	onData: ((received: number, total: number?) -> ())?, -- progress callback
	onFirstRead: (() -> ())?, -- called before the first read (for "100 Continue")
}

local Reader = {}
Reader.__index = Reader

--- Creates a reader for a body delimited as `net.http.bodyLength` described it.
function io.bodyReader(sock: any, mode: string, length: number?, options: ReaderOptions?): BodyReader
	local opts = options or {}
	local self = setmetatable({
		_sock = sock,
		_mode = mode,
		_remaining = length or 0,
		_rawDone = mode == "none" or (mode == "length" and (length or 0) == 0),
		_done = false,
		_chunked = if mode == "chunked" then net.http.chunkedDecoder() else nil,
		_trailers = nil,
		_opts = opts,
		_started = false,
		received = 0,
		rawReceived = 0,
		length = if mode == "length" then length else nil,
	}, Reader)
	if opts.encoding then
		local write, finish = bodyLib.decoder(opts.encoding, opts.maxSize)
		if write then
			self._decodeWrite = write
			self._decodeFinish = finish
		end
	end
	return self :: any
end

-- The next piece of raw (still encoded) body, "" when a read produced nothing usable yet,
-- or nil at the end. nil, err on failure.
function Reader._rawRead(self: any): (string?, string?)
	if self._rawDone then
		return nil, nil
	end
	if not self._started then
		self._started = true
		if self._opts.onFirstRead then
			self._opts.onFirstRead()
		end
	end
	local sock = self._sock
	local mode = self._mode
	if mode == "length" then
		local data, err = sock:recv(math.min(self._remaining, io.READ_SIZE))
		if data == nil then
			return nil, errors.fromNet(err, "reading the body")
		end
		if data == "" then
			return nil, errors.new("closed", `connection closed with {self._remaining} bytes of body missing`)
		end
		self._remaining -= #data
		if self._remaining <= 0 then
			self._rawDone = true
		end
		self.rawReceived += #data
		return data, nil
	elseif mode == "chunked" then
		local data, err = sock:recv(io.READ_SIZE)
		if data == nil then
			return nil, errors.fromNet(err, "reading the body")
		end
		if data == "" then
			return nil, errors.new("closed", "connection closed in the middle of a chunked body")
		end
		local out, done = self._chunked:push(data)
		if out == nil then
			return nil, errors.new("protocol", `invalid chunked body: {done}`)
		end
		if done then
			self._rawDone = true
			local rest = self._chunked:rest()
			if rest and rest ~= "" then
				sock:unread(rest)
			end
			self._trailers = self._chunked:trailers()
		end
		self.rawReceived += #out
		return out, nil
	elseif mode == "close" then
		local data, err = sock:recv(io.READ_SIZE)
		if data == nil then
			return nil, errors.fromNet(err, "reading the body")
		end
		if data == "" then
			self._rawDone = true
			return nil, nil
		end
		self.rawReceived += #data
		return data, nil
	end
	self._rawDone = true
	return nil, nil
end

--- The next piece of body, or `nil` at the end, or `nil, err`.
function Reader.read(self: any): (string?, string?)
	if self._done then
		return nil, nil
	end
	while true do
		local raw, err = self:_rawRead()
		if err then
			self._done = true
			return nil, err
		end
		local out: string
		if raw == nil then
			-- End of the raw body: flush the decoder.
			self._done = true
			if self._decodeFinish then
				local ok, tail = pcall(self._decodeFinish)
				if not ok then
					return nil, errors.new("body", `could not decode the body: {tail}`)
				end
				out = tail
			else
				return nil, nil
			end
		elseif self._decodeWrite then
			local ok, decoded = pcall(self._decodeWrite, raw)
			if not ok then
				self._done = true
				return nil, errors.new("body", `could not decode the body: {decoded}`)
			end
			out = decoded
		else
			out = raw
		end
		if out ~= "" then
			self.received += #out
			local max = self._opts.maxSize
			if max and self.received > max then
				self._done = true
				return nil, errors.new("body", `body larger than {max} bytes`)
			end
			if self._opts.onData then
				self._opts.onData(self.received, self.length)
			end
			return out, nil
		end
		if self._done then
			return nil, nil
		end
	end
end

--- The whole (rest of the) body. `max` caps its size.
function Reader.readAll(self: any, max: number?): (string?, string?)
	if max then
		local current = self._opts.maxSize
		if current == nil or max < current then
			self._opts.maxSize = max
		end
	end
	local parts = {}
	while true do
		local chunk, err = self:read()
		if err then
			return nil, err
		end
		if chunk == nil then
			break
		end
		table.insert(parts, chunk)
	end
	return table.concat(parts), nil
end

--- Reads and discards the rest of the body, so the connection can carry another message.
--- Returns `false` if that would take more than `max` bytes (default 1 MiB) or failed.
function Reader.drain(self: any, max: number?): boolean
	local limit = max or 1024 * 1024
	local seen = 0
	while not self._rawDone do
		local raw, err = self:_rawRead()
		if err then
			return false
		end
		if raw then
			seen += #raw
			if seen > limit then
				return false
			end
		end
	end
	self._done = true
	return true
end

--- Whether the whole body has been read.
function Reader.isDone(self: any): boolean
	return self._done or (self._rawDone and self._decodeWrite == nil)
end

--- Trailers of a chunked body, once it has been read.
function Reader.trailers(self: any): { [string]: string }?
	return self._trailers
end

--- Writes a body. With `chunked`, a stream is sent with chunked transfer coding.
function io.writeBody(sock: any, b: Body, chunked: boolean): (boolean, string?)
	if b.data then
		if b.data == "" then
			return true, nil
		end
		local ok, err = sock:send(b.data)
		if not ok then
			return false, errors.fromNet(err, "sending the body")
		end
		return true, nil
	end
	local stream = b.stream
	if stream == nil then
		return true, nil
	end
	while true do
		local chunk = stream()
		if chunk == nil then
			break
		end
		if chunk ~= "" then
			local ok, err = sock:send(if chunked then net.http.encodeChunk(chunk) else chunk)
			if not ok then
				return false, errors.fromNet(err, "sending the body")
			end
		end
	end
	if chunked then
		local ok, err = sock:send(net.http.lastChunk())
		if not ok then
			return false, errors.fromNet(err, "sending the body")
		end
	end
	return true, nil
end

return io
