--[[
	Listening: opens the listening socket, accepts connections (each one in its own task),
	does TLS handshakes, and returns a handle to stop the server.
]]

local net = require("@sonata/net")
local task = require("@sonata/task")
local types = require("./types")
local errors = require("../core/errors")
local connection = require("./connection")

export type Server = types.Server
export type ListenOptions = types.ListenOptions

local listener = {}

local Server = {}
Server.__index = Server

--- The number of open connections.
function Server.connections(self: any): number
	local n = 0
	for _ in self._connections do
		n += 1
	end
	return n
end

--- Stops accepting connections. With `graceful`, waits up to `timeout` seconds (default 10)
--- for open connections to finish; then closes whatever is left.
function Server.close(self: any, options: { graceful: boolean?, timeout: number? }?)
	if self.closed then
		return
	end
	self.closed = true
	if self._acceptTask and self._acceptTask ~= task.running() then
		pcall(task.cancel, self._acceptTask)
	end
	self._socket:close()
	if options and options.graceful then
		local deadline = os.clock() + (options.timeout or 10)
		while Server.connections(self) > 0 and os.clock() < deadline do
			task.wait(0.05)
		end
	end
	for sock in self._connections do
		sock:close()
	end
	table.clear(self._connections)
	self._closedEvent:set()
end

--- Waits until the server is closed.
function Server.wait(self: any)
	self._closedEvent:wait()
end

Server.__tostring = function(self)
	return `Server({self.url})`
end

-- Builds a TLS server context from the `tls` option, or returns what was given if it already
-- is a context.
local function tlsContext(tls: any): any
	if tls == nil or tls == false then
		return nil
	end
	if type(tls) == "table" and (tls.cert or tls.certPem or tls.key or tls.keyPem) then
		local options = table.clone(tls)
		options.server = true
		options.alpn = options.alpn or { "http/1.1" }
		return net.tls.context(options)
	end
	return tls -- a TlsContext made with net.tls.context
end

--- Starts serving `app` (an App, or a `handler(req, res)` function). Returns the server, or
--- `nil, err` if the port can't be opened.
function listener.listen(app: any, options: ListenOptions?): (Server?, string?)
	local opts: ListenOptions = options or {}
	local okTls, ctx = pcall(tlsContext, opts.tls)
	if not okTls then
		return nil, errors.new("tls", `could not load the TLS certificate: {ctx}`)
	end

	local sock, err
	local host: string
	local port: number
	if opts.unix then
		sock, err = net.unix.listen(opts.unix, opts.backlog)
		host, port = opts.unix, 0
	else
		local wantedPort = if opts.port == nil then 8080 else opts.port
		sock, err = net.listen(opts.host, wantedPort, {
			backlog = opts.backlog,
			reuseAddress = true,
			reusePort = opts.reusePort,
			family = opts.family,
		})
		if sock then
			local boundHost, boundPort = sock:localAddress()
			host, port = boundHost, boundPort
		end
	end
	if sock == nil then
		local where = opts.unix or `{opts.host or "*"}:{opts.port or 8080}`
		return nil, errors.fromNet(err, `listening on {where}`)
	end

	local scheme = if ctx then "https" else "http"
	local displayHost = host
	if opts.unix then
		displayHost = "localhost"
	elseif host == "0.0.0.0" or host == "::" or host == "" then
		displayHost = "localhost"
	elseif string.find(host, ":", 1, true) then
		displayHost = `[{host}]`
	end

	local self = setmetatable({
		host = host,
		port = port,
		url = if opts.unix then `unix:{opts.unix}` else `{scheme}://{displayHost}:{port}`,
		secure = ctx ~= nil,
		closed = false,
		_socket = sock,
		_connections = {} :: { [any]: boolean },
		_closedEvent = task.event(),
		_acceptTask = nil :: thread?,
	}, Server)

	local serveOptions: connection.Options = {
		secure = ctx ~= nil,
		timeout = opts.timeout,
		keepAliveTimeout = opts.keepAliveTimeout,
		maxHeadSize = opts.maxHeadSize,
		maxHeaders = opts.maxHeaders,
		maxBodySize = opts.maxBodySize,
		trustProxy = opts.trustProxy,
		serverHeader = opts.serverHeader,
	}

	local function handle(client: any)
		if ctx then
			client:setTimeout(opts.timeout or 30)
			local ok = client:startTls({ context = ctx })
			if not ok then
				client:close()
				self._connections[client] = nil
				return
			end
		end
		local connOptions = table.clone(serveOptions)
		connOptions.onClose = function()
			self._connections[client] = nil
		end
		connection.serve(client, app, connOptions)
	end

	self._acceptTask = task.spawn(function()
		while not self.closed do
			local client = sock:accept()
			if client then
				if opts.maxConnections and Server.connections(self) >= opts.maxConnections then
					client:send("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
					client:close()
				else
					self._connections[client] = true
					task.spawn(handle, client)
				end
			elseif self.closed or sock:isClosed() then
				break
			else
				-- Accept failed (too many open files, ...): back off a little.
				task.wait(0.05)
			end
		end
	end)

	if opts.onListen then
		opts.onListen(self :: any)
	end
	return self :: any, nil
end

return listener
