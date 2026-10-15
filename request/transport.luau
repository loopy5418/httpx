--[[
	The transport: opens connections (plain, TLS, through proxies), keeps idle ones for
	reuse, and performs one request/response exchange on them.

	Most code should use a client (`request/client.luau`); this layer is exposed for protocol
	work that needs the raw connection.
]]

local net = require("@sonata/net")
local types = require("./types")
local errors = require("../core/errors")
local urlLib = require("../core/url")
local io = require("../core/io")
local headersLib = require("../core/headers")
local bodyLib = require("../core/body")
local responseLib = require("./response")

export type Request = types.Request
export type Response = types.Response

local transport = {}

-- Connection pool -------------------------------------------------------------------------

export type Pool = {
	acquire: (self: Pool, key: string) -> any?,
	release: (self: Pool, key: string, sock: any) -> (),
	closeAll: (self: Pool) -> (),
	maxIdlePerHost: number,
	idleTimeout: number,
	[string]: any,
}

local Pool = {}
Pool.__index = Pool

--- A pool of idle keep-alive connections, keyed by origin.
function transport.pool(options: { maxIdlePerHost: number?, idleTimeout: number? }?): Pool
	return setmetatable({
		_idle = {} :: { [string]: { { sock: any, since: number } } },
		maxIdlePerHost = (options and options.maxIdlePerHost) or 8,
		idleTimeout = (options and options.idleTimeout) or 30,
	}, Pool) :: any
end

--- An idle connection for `key` that is still usable, or `nil`.
function Pool.acquire(self: any, key: string): any?
	local list = self._idle[key]
	if list == nil then
		return nil
	end
	local now = os.clock()
	while #list > 0 do
		local entry = table.remove(list) :: { sock: any, since: number }
		local sock = entry.sock
		if not sock:isClosed() and now - entry.since < self.idleTimeout then
			-- An idle connection must have nothing to read: readable means the server closed
			-- it (or sent garbage), so it can't be used.
			local readable = net.select({ sock }, nil, 0)
			if #readable == 0 and sock:buffered() == 0 then
				return sock
			end
		end
		sock:close()
	end
	self._idle[key] = nil
	return nil
end

--- Gives a connection back for later reuse.
function Pool.release(self: any, key: string, sock: any)
	if sock:isClosed() then
		return
	end
	local list = self._idle[key]
	if list == nil then
		list = {}
		self._idle[key] = list
	end
	if #list >= self.maxIdlePerHost then
		local oldest = table.remove(list, 1)
		if oldest then
			oldest.sock:close()
		end
	end
	table.insert(list, { sock = sock, since = os.clock() })
end

--- Closes every idle connection.
function Pool.closeAll(self: any)
	for _, list in self._idle do
		for _, entry in list do
			entry.sock:close()
		end
	end
	table.clear(self._idle)
end

-- Connecting --------------------------------------------------------------------------------

export type ConnectOptions = {
	timeout: (number | false)?,
	connectTimeout: number?,
	tls: types.Tls?,
	insecure: boolean?,
	proxy: (string | { [string]: any })?,
	family: ("any" | "ipv4" | "ipv6")?,
	localAddress: string?,
}

local SECURE = { https = true, wss = true }
local KNOWN = { http = true, https = true, ws = true, wss = true }

--- The TLS setting to use for a URL: `nil` for plain connections.
local function tlsFor(parsed: types.Url, options: ConnectOptions): any
	if not SECURE[parsed.scheme or ""] then
		return nil
	end
	local tls = options.tls
	if options.insecure then
		if type(tls) == "table" and getmetatable(tls :: any) == nil then
			local copy = table.clone(tls :: any)
			copy.verify = false
			return copy
		end
		return { verify = false }
	end
	if tls == nil or tls == false then
		return true
	end
	return tls
end

--- Parses and checks a URL. Returns the parsed URL and its port, or `nil, err`.
function transport.target(target: string): (types.Url?, number | string)
	local parsed = net.url.parse(target)
	if parsed == nil or parsed.scheme == nil or parsed.host == nil or parsed.host == "" then
		return nil, errors.new("invalid", `not an absolute URL: {target}`)
	end
	local scheme = string.lower(parsed.scheme)
	if not KNOWN[scheme] then
		return nil, errors.new("invalid", `unsupported URL scheme '{scheme}' in {target}`)
	end
	parsed.scheme = scheme
	return parsed, parsed.port or net.url.defaultPort(scheme)
end

--- The pool key of a connection: connections are only shared between requests that would
--- have opened the same one.
function transport.key(parsed: types.Url, port: number, options: ConnectOptions): string
	local tls = tlsFor(parsed, options)
	local tlsKey = if tls == nil then "plain" elseif tls == true then "tls" else tostring(tls)
	if type(tls) == "table" and tls.verify == false and getmetatable(tls :: any) == nil then
		tlsKey = "tls-insecure"
	end
	local proxy = options.proxy
	local proxyKey = if proxy == nil then "" elseif type(proxy) == "string" then proxy else tostring(proxy)
	return `{parsed.host}:{port}|{tlsKey}|{proxyKey}|{options.family or ""}|{options.localAddress or ""}`
end

--- Opens a connection to the host of a parsed URL. Returns the socket or `nil, err`.
function transport.connect(parsed: types.Url, port: number, options: ConnectOptions): (any, string?)
	local host = parsed.host :: string
	local sock, err = net.connect(host, port, {
		timeout = options.connectTimeout or (if type(options.timeout) == "number" then options.timeout else 30),
		tls = tlsFor(parsed, options),
		proxy = options.proxy,
		family = options.family,
		localAddress = options.localAddress,
		nodelay = true,
	})
	if sock == nil then
		return nil, errors.fromNet(err, `connecting to {host}:{port}`)
	end
	return sock, nil
end

-- One exchange ------------------------------------------------------------------------------

local SMALL_BODY = 64 * 1024

-- Sends the request on `sock` and reads the response head.
local function sendAndReadHead(sock: any, req: Request, b: types.Body?, headList: { { string } }): (any, string?, boolean)
	local head = net.http.formatRequest({
		method = req.method,
		target = req._target,
		headers = headList,
	})
	-- `sentAnything` tells the caller whether a failure happened before the server could have
	-- acted on the request (so a stale pooled connection can be retried safely).
	local ok, err
	if b and b.data and #b.data <= SMALL_BODY then
		ok, err = sock:send(head .. b.data)
	else
		ok, err = sock:send(head)
		if ok and b then
			local sent, sendErr = io.writeBody(sock, b, b.length == nil)
			if not sent then
				return nil, sendErr, true
			end
		end
	end
	if not ok then
		return nil, errors.fromNet(err, "sending the request"), false
	end
	local response, readErr = io.readHead(sock, "response")
	-- Skip informational responses (100 Continue, 103 Early Hints, ...), but not 101.
	while response and response.status >= 100 and response.status < 200 and response.status ~= 101 do
		response, readErr = io.readHead(sock, "response")
	end
	if response == nil then
		if readErr == "closed" then
			return nil, errors.new("closed", "the server closed the connection without responding"), false
		end
		return nil, readErr, false
	end
	return response, nil, true
end

--- Sends `req` and returns the response, with its body not read yet (the caller decides).
--- `pool` is optional: without it, the connection is closed once the body is read.
function transport.exchange(req: Request, pool: Pool?): (Response?, string?)
	local options = req.options
	local parsed, portOrErr = transport.target(req.url)
	if parsed == nil then
		return nil, portOrErr :: string
	end
	local port = portOrErr :: number
	req._target = urlLib.target(parsed)

	-- Headers every request needs, unless set explicitly.
	local headers = req.headers
	headers:setDefault("Host", urlLib.hostHeader(parsed))
	local b = req.body
	if b then
		if b.contentType then
			headers:setDefault("Content-Type", b.contentType)
		end
		if b.length then
			headers:set("Content-Length", tostring(b.length))
			headers:delete("Transfer-Encoding")
		else
			headers:set("Transfer-Encoding", "chunked")
			headers:delete("Content-Length")
		end
	elseif req.method == "POST" or req.method == "PUT" or req.method == "PATCH" then
		headers:setDefault("Content-Length", "0")
	end
	local keepAlive = options.keepAlive ~= false and pool ~= nil
	if not keepAlive then
		headers:set("Connection", "close")
	end
	local headList = headers:list()

	local key = transport.key(parsed, port, options :: any)
	local started = os.clock()
	local sock: any = nil
	local response: any = nil
	local lastErr: string? = nil
	-- Try a pooled connection first; if it turns out to be dead before the server answered,
	-- retry once on a fresh connection.
	for attempt = 1, 2 do
		local reused = false
		if keepAlive and attempt == 1 and pool then
			sock = pool:acquire(key)
			reused = sock ~= nil
		end
		if sock == nil then
			local err
			sock, err = transport.connect(parsed, port, options :: any)
			if sock == nil then
				return nil, err
			end
		end
		sock:setTimeout(if options.timeout == false then nil else (options.timeout or 30))
		local sentAnything
		response, lastErr, sentAnything = sendAndReadHead(sock, req, b, headList)
		if response then
			break
		end
		sock:close()
		sock = nil
		local canRetry = reused and (not sentAnything or errors.kind(lastErr) == "closed")
		if not canRetry or (b and not b.replayable) then
			return nil, lastErr
		end
		if b and (b :: any).reopen then
			b = (b :: any).reopen()
		end
	end
	if response == nil then
		return nil, lastErr
	end
	local elapsed = os.clock() - started

	local responseHeaders = headersLib.fromHead(response)
	local mode, length = net.http.bodyLength(response, { requestMethod = req.method })
	if mode == nil then
		sock:close()
		return nil, errors.new("protocol", `invalid response framing: {length}`)
	end

	-- 101 Switching Protocols and successful CONNECT hand the socket over.
	if mode == "tunnel" then
		return responseLib.new({
			status = response.status,
			reason = response.reason,
			version = response.version,
			headers = responseHeaders,
			url = req.url,
			method = req.method,
			request = req,
			elapsed = elapsed,
			socket = sock,
		}), nil
	end

	local encoding = nil
	if options.decompress ~= false then
		local ce = responseHeaders:get("content-encoding")
		if ce and bodyLib.canDecode(ce) then
			encoding = ce
		end
	end
	local reader = io.bodyReader(sock, mode :: string, length :: number?, {
		encoding = encoding,
		maxSize = options.maxBodySize,
		onData = options.onProgress,
	})
	local reusable = keepAlive and mode ~= "close" and net.http.keepAlive(response)
	local released = false
	local function release(ok: boolean)
		if released then
			return
		end
		released = true
		if ok and reusable and pool and reader:isDone() then
			pool:release(key, sock)
		else
			sock:close()
		end
	end
	if mode == "none" then
		reader:read() -- marks it done
	end
	local res = responseLib.new({
		status = response.status,
		reason = response.reason,
		version = response.version,
		headers = responseHeaders,
		url = req.url,
		method = req.method,
		request = req,
		elapsed = elapsed,
		reader = reader,
		release = release,
	})
	if mode == "none" then
		res.body = ""
		release(true)
	end
	return res, nil
end

return transport
