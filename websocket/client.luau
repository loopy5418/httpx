--[[
	Opening WebSocket connections (the client handshake).

	    local ws = assert(websocket.connect("wss://echo.websocket.org"))
	    ws:send("hello")
	    print(ws:recv())
	    ws:close()
]]

local net = require("@sonata/net")
local types = require("./types")
local connectionLib = require("./connection")
local errors = require("../core/errors")
local urlLib = require("../core/url")
local io = require("../core/io")
local headersLib = require("../core/headers")
local transport = require("../request/transport")
local clientLib = require("../request/client")

export type ConnectOptions = types.ConnectOptions
export type WebSocket = types.WebSocket

local client = {}

local SCHEMES = { ws = "ws", wss = "wss", http = "ws", https = "wss" }

--- Connects to a WebSocket server. Returns the open connection, or `nil, err`.
function client.connect(target: string, options: ConnectOptions?): (WebSocket?, string?)
	local opts: ConnectOptions = options or {}
	if opts.query then
		target = urlLib.withQuery(target, opts.query)
	end
	local parsed, portOrErr = transport.target(target)
	if parsed == nil then
		return nil, portOrErr :: string
	end
	parsed.scheme = SCHEMES[parsed.scheme :: string]
	local port = portOrErr :: number
	local timeout = opts.timeout or 30

	local sock, err = transport.connect(parsed, port, {
		timeout = timeout,
		tls = opts.tls,
		insecure = opts.insecure,
		proxy = opts.proxy,
	})
	if sock == nil then
		return nil, err
	end
	sock:setTimeout(timeout)

	local key = net.ws.generateKey()
	local headers = headersLib.new(opts.headers)
	headers:set("Host", urlLib.hostHeader(parsed))
	headers:set("Upgrade", "websocket")
	headers:set("Connection", "Upgrade")
	headers:set("Sec-WebSocket-Key", key)
	headers:set("Sec-WebSocket-Version", "13")
	headers:setDefault("User-Agent", clientLib.USER_AGENT)
	local offered: { string } = {}
	if type(opts.protocols) == "string" then
		offered = { opts.protocols }
	elseif type(opts.protocols) == "table" then
		offered = opts.protocols
	end
	if #offered > 0 then
		headers:set("Sec-WebSocket-Protocol", table.concat(offered, ", "))
	end
	if opts.origin then
		headers:set("Origin", opts.origin)
	end
	if opts.bearer then
		headers:set("Authorization", `Bearer {opts.bearer}`)
	end
	if opts.cookies then
		local cookie = opts.cookies:header(target)
		if cookie then
			headers:set("Cookie", cookie)
		end
	end

	local ok, sendErr = sock:send(net.http.formatRequest({
		method = "GET",
		target = urlLib.target(parsed),
		headers = headers:list(),
	}))
	if not ok then
		sock:close()
		return nil, errors.fromNet(sendErr, "sending the websocket handshake")
	end

	local head, headErr = io.readHead(sock, "response")
	if head == nil then
		sock:close()
		if headErr == "closed" then
			return nil, errors.new("closed", "the server closed the connection during the handshake")
		end
		return nil, headErr
	end
	local responseHeaders = headersLib.fromHead(head)
	if head.status ~= 101 then
		-- Read a little of the body: servers often explain the refusal there.
		local detail = ""
		local mode, length = net.http.bodyLength(head, { requestMethod = "GET" })
		if mode == "length" and (length :: number) > 0 and (length :: number) <= 4096 then
			detail = sock:recv(length, true) or ""
		end
		sock:close()
		local message = `handshake refused: {head.status} {head.reason}`
		if detail ~= "" then
			message ..= ` ({detail})`
		end
		return nil, errors.new(if head.status == 401 or head.status == 403 then "status" else "protocol", message)
	end
	local upgrade = responseHeaders:get("upgrade")
	if upgrade == nil or string.lower(upgrade) ~= "websocket" then
		sock:close()
		return nil, errors.new("protocol", "the server didn't upgrade to websocket")
	end
	if responseHeaders:get("sec-websocket-accept") ~= net.ws.acceptKey(key) then
		sock:close()
		return nil, errors.new("protocol", "invalid Sec-WebSocket-Accept from the server")
	end
	local protocol = responseHeaders:get("sec-websocket-protocol")
	if protocol and not table.find(offered, protocol) then
		sock:close()
		return nil, errors.new("protocol", `the server chose a subprotocol that wasn't offered: {protocol}`)
	end
	if responseHeaders:get("sec-websocket-extensions") then
		sock:close()
		return nil, errors.new("protocol", "the server enabled an extension that wasn't offered")
	end

	return connectionLib.new(sock, {
		client = true,
		protocol = protocol,
		url = target,
		headers = responseHeaders,
		maxMessageSize = opts.maxMessageSize,
		pingInterval = opts.pingInterval,
		pingTimeout = opts.pingTimeout,
		autoPong = opts.autoPong,
		closeTimeout = opts.closeTimeout,
	}), nil
end

return client
