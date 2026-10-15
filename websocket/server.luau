--[[
	Accepting WebSocket connections on the server.

	    app:ws("/echo", function(ws, req)
	        for message, kind in ws:messages() do
	            ws:send(message, kind)
	        end
	    end)

	Or by hand, inside any handler:

	    app:get("/socket", function(req, res)
	        local ws = websocket.accept(req, res, { protocols = { "chat.v1" } })
	        if ws then ... end
	    end)
]]

local net = require("@sonata/net")
local crypto = require("@sonata/crypto")
local types = require("./types")
local connectionLib = require("./connection")

export type AcceptOptions = types.AcceptOptions
export type WebSocket = types.WebSocket

local server = {}

local function headerHas(value: string?, token: string): boolean
	if value == nil then
		return false
	end
	for item in string.gmatch(string.lower(value), "[^,%s]+") do
		if item == token then
			return true
		end
	end
	return false
end

--- Upgrades a request to a WebSocket. On success returns the connection (the HTTP response
--- is finished and the socket belongs to the websocket). Otherwise answers the request with
--- an error status and returns `nil, reason`.
function server.accept(req: any, res: any, options: AcceptOptions?): (WebSocket?, string?)
	local opts: AcceptOptions = options or {}
	local headers = req.headers
	if not req:isWebSocket() or not headerHas(headers:get("connection"), "upgrade") then
		res:header("Upgrade", "websocket")
		res:error(426, "this endpoint expects a WebSocket upgrade")
		return nil, "not a websocket request"
	end
	if headers:get("sec-websocket-version") ~= "13" then
		res:header("Sec-WebSocket-Version", "13")
		res:error(426, "unsupported WebSocket version")
		return nil, "unsupported websocket version"
	end
	local key = headers:get("sec-websocket-key")
	local decoded = key and crypto.decode("base64", key)
	if key == nil or decoded == nil or #decoded ~= 16 then
		res:error(400, "invalid Sec-WebSocket-Key")
		return nil, "invalid key"
	end
	if opts.verify then
		local verdict = opts.verify(req)
		if verdict ~= true then
			local status = if type(verdict) == "number" then verdict else 403
			res:error(status)
			return nil, "refused"
		end
	end

	local offered: { string } = {}
	local header = headers:get("sec-websocket-protocol")
	if header then
		for p in string.gmatch(header, "[^,%s]+") do
			table.insert(offered, p)
		end
	end
	local protocol: string? = nil
	if type(opts.protocols) == "function" then
		protocol = opts.protocols(offered, req)
	elseif type(opts.protocols) == "table" then
		for _, p in opts.protocols do
			if table.find(offered, p) then
				protocol = p
				break
			end
		end
	end

	local responseHeaders: { { string } } = {
		{ "Upgrade", "websocket" },
		{ "Connection", "Upgrade" },
		{ "Sec-WebSocket-Accept", net.ws.acceptKey(key :: string) },
	}
	if protocol then
		table.insert(responseHeaders, { "Sec-WebSocket-Protocol", protocol })
	end
	if opts.headers then
		for name, value in opts.headers do
			table.insert(responseHeaders, { name, value })
		end
	end
	-- Headers set by middleware so far (cookies, ...) go out too.
	for name, value in res.headers do
		local lower = string.lower(name)
		if lower ~= "content-type" and lower ~= "content-length" then
			table.insert(responseHeaders, { name, value })
		end
	end

	res.statusCode = 101
	local sock = res:takeover()
	local ok = sock:send(net.http.formatResponse({ status = 101, headers = responseHeaders }))
	if not ok then
		sock:close()
		return nil, "client went away during the handshake"
	end
	-- Anything the client sent right after its handshake is already buffered in the socket.
	return connectionLib.new(sock, {
		client = false,
		protocol = protocol,
		request = req,
		maxMessageSize = opts.maxMessageSize,
		pingInterval = opts.pingInterval,
		pingTimeout = opts.pingTimeout,
		autoPong = opts.autoPong,
		closeTimeout = opts.closeTimeout,
	}),
		nil
end

--- A route handler that upgrades and calls `handler(ws, req)`. Used by `app:ws`.
function server.handler(handler: (ws: WebSocket, req: any) -> (), options: AcceptOptions?)
	return function(req: any, res: any)
		local ws = server.accept(req, res, options)
		if ws then
			handler(ws, req)
		end
	end
end

return server
