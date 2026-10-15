--[[
	Serves the requests of one connection, one after another (HTTP/1.1 keep-alive).

	`connection.serve` is public so a server can be built on any socket: a Unix socket, a
	connection accepted by your own loop, a socket after a custom TLS handshake, ...

	    local sock = listener:accept()
	    task.spawn(connection.serve, sock, app)
]]

local net = require("@sonata/net")
local io = require("../core/io")
local errors = require("../core/errors")
local requestLib = require("./request")
local responseLib = require("./response")

local connection = {}

export type Options = {
	secure: boolean?,
	timeout: number?,
	keepAliveTimeout: number?,
	maxHeadSize: number?,
	maxHeaders: number?,
	maxBodySize: number?,
	trustProxy: boolean?,
	serverHeader: (string | false)?,
	onClose: (() -> ())?,
}

connection.DEFAULT_MAX_BODY = 10 * 1024 * 1024

-- Answers a request that couldn't be parsed, then gives up on the connection.
local function reject(sock: any, status: number, message: string)
	local body = message .. "\n"
	sock:send(net.http.formatResponse({
		status = status,
		headers = {
			{ "Content-Type", "text/plain; charset=utf-8" },
			{ "Content-Length", tostring(#body) },
			{ "Connection", "close" },
		},
	}) .. body)
end

--- Serves `sock` until the client leaves, the connection times out, or a response asks to
--- close. `app` is an App (anything with `dispatch(req, res)`), or a plain
--- `handler(req, res)` function.
function connection.serve(sock: any, app: any, options: Options?)
	local opts = options or {}
	local dispatch: (req: any, res: any) -> ()
	if type(app) == "function" then
		dispatch = function(req, res)
			local ok, err = pcall(app, req, res)
			if not ok then
				if not res.sent then
					res:error(500)
				end
				print(`httpx: unhandled error: {err}`)
			end
		end
	else
		dispatch = function(req, res)
			app:dispatch(req, res)
		end
	end
	local timeout = opts.timeout or 30
	local keepAliveTimeout = opts.keepAliveTimeout or 5
	local maxBody = opts.maxBodySize or connection.DEFAULT_MAX_BODY
	local first = true

	while true do
		sock:setTimeout(if first then timeout else keepAliveTimeout)
		local head, err = io.readHead(sock, "request", {
			maxHeadSize = opts.maxHeadSize,
			maxHeaders = opts.maxHeaders,
		})
		if head == nil then
			if err ~= "closed" and errors.kind(err) == "protocol" then
				local tooLarge = string.find(err :: string, "large", 1, true) or string.find(err :: string, "too many", 1, true)
				reject(sock, if tooLarge then 431 else 400, if tooLarge then "Request Header Fields Too Large" else "Bad Request")
			end
			break
		end
		first = false
		sock:setTimeout(timeout)

		local mode, length = net.http.bodyLength(head)
		if mode == nil or mode == "close" then
			reject(sock, 400, "Bad Request")
			break
		end
		if mode == "length" and (length :: number) > maxBody then
			reject(sock, 413, "Content Too Large")
			break
		end

		local expect = head.headers.expect
		local wantsContinue = expect ~= nil and string.lower(expect) == "100-continue"
		local continued = false
		local reader = io.bodyReader(sock, mode, length, {
			maxSize = maxBody,
			onFirstRead = if wantsContinue
				then function()
					continued = true
					sock:send("HTTP/1.1 100 Continue\r\n\r\n")
				end
				else nil,
		})
		local keepAlive = net.http.keepAlive(head)
		local req = requestLib.new({
			head = head,
			reader = reader,
			socket = sock,
			secure = opts.secure == true,
			trustProxy = opts.trustProxy,
			app = if type(app) == "table" then app else nil,
		})
		local res = responseLib.new({
			socket = sock,
			request = req,
			serverHeader = opts.serverHeader,
			keepAlive = keepAlive,
		})

		dispatch(req, res)

		if res.upgraded then
			res:_runFinishHooks()
			-- The socket belongs to whoever took it over (a WebSocket, a tunnel, ...).
			if opts.onClose then
				opts.onClose()
			end
			return
		end
		if not res.finished then
			res:finish()
		end
		res:_runFinishHooks()
		if res.closeAfter or not keepAlive then
			break
		end
		if not reader:isDone() then
			-- The handler didn't read the whole body. A client waiting for "100 Continue" never
			-- sent it; otherwise read and drop the rest (if it's small) to reach the next request.
			if wantsContinue and not continued then
				break
			end
			if not reader:drain(maxBody) then
				break
			end
		end
	end
	sock:close()
	if opts.onClose then
		opts.onClose()
	end
end

return connection
