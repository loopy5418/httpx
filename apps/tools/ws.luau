--[[
	ws: talk to a WebSocket server from the terminal, or run a quick echo/broadcast server.
]]

local task = require("@sonata/task")
local term = require("@sonata/term")
local process = require("@sonata/process")
local crypto = require("@sonata/crypto")
local cli = require("./cli")
local httpx = require("../../lib")

local tool = {}

tool.spec = {
	name = "ws",
	description = "WebSocket client and test server.",
	usage = { "<url> [options]", "--serve [options]" },
	options = {
		{ "header", "H", type = "list", value = "<name: value>", help = "add a handshake header" },
		{ "protocol", type = "list", value = "<name>", help = "offer a subprotocol" },
		{ "send", "x", type = "list", value = "<message>", help = "send a message, print replies, then exit" },
		{ "wait", "w", type = "number", default = 2, help = "with --send: seconds to wait for replies" },
		{ "insecure", "k", type = "boolean", help = "skip TLS certificate checks" },
		{ "serve", type = "boolean", help = "run a server instead" },
		{ "port", "p", type = "number", default = 8765, help = "--serve: port" },
		{ "host", type = "string", default = "127.0.0.1", help = "--serve: address to bind" },
		{ "broadcast", type = "boolean", help = "--serve: send each message to every client (default: echo)" },
	},
	examples = {
		"wss://echo.websocket.org",
		"ws://localhost:8765 -x hello -x '{\"type\":\"ping\"}'",
		"--serve --broadcast --port 9000",
	},
}

local function show(data: string, kind: string?)
	if kind == "binary" then
		term.stdout:writeLine(cli.style("< ", "green") .. cli.dim(`[binary {#data} bytes] `) .. crypto.encode("hex", string.sub(data, 1, 64)))
	else
		term.stdout:writeLine(cli.style("< ", "green") .. data)
	end
	term.stdout:flush()
end

local function serveMode(opts: { [string]: any }): number?
	local app = httpx.app()
	local room = httpx.websocket.hub()
	app:ws("/*", function(ws, req)
		room:add(ws)
		cli.info(cli.dim(`+ client {req.ip}:{req.port} ({room:count()} connected)`))
		for message, kind in ws:messages() do
			if opts.broadcast then
				room:broadcast(message, kind)
			else
				ws:send(message, kind)
			end
		end
		cli.info(cli.dim(`- client {req.ip}:{req.port} ({ws.closeCode})`))
	end)
	app:get("/*", function()
		return "WebSocket server: connect with ws://"
	end)
	local srv, err = app:listen({ port = opts.port, host = opts.host })
	if srv == nil then
		cli.fail(tostring(err))
	end
	assert(srv)
	local url = string.gsub(srv.url, "^http", "ws")
	cli.info(cli.style(if opts.broadcast then "Broadcast" else "Echo", "bold") .. " server on " .. cli.style(url, "cyan"))
	srv:wait()
	return 0
end

function tool.main(argv: { string }): number?
	local opts, rest = cli.parse(argv, tool.spec)
	if opts.serve then
		return serveMode(opts)
	end
	local url = rest[1]
	if url == nil then
		print(cli.help(tool.spec))
		return 2
	end
	local ws, err = httpx.websocket.connect(url, {
		headers = cli.headers(opts.header),
		protocols = if #opts.protocol > 0 then opts.protocol else nil,
		insecure = opts.insecure,
	})
	if ws == nil then
		cli.fail(tostring(err))
	end
	assert(ws)

	if #opts.send > 0 then
		for _, message in opts.send do
			ws:send(message)
			term.stdout:writeLine(cli.style("> ", "cyan") .. message)
		end
		local deadline = os.clock() + opts.wait
		while not ws.closed do
			local remaining = deadline - os.clock()
			if remaining <= 0 then
				break
			end
			local data, kind = ws:recv(remaining)
			if data then
				show(data, kind)
			elseif kind ~= "timed out" then
				break
			end
		end
		ws:close()
		return 0
	end

	cli.info(cli.style("Connected", "green", "bold") .. " to " .. url .. (if ws.protocol then cli.dim(` ({ws.protocol})`) else ""))
	cli.info(cli.dim("Type a message and press Enter. Commands: /ping, /close [code] [reason], /quit"))
	ws:on("message", show)
	ws:on("pong", function()
		cli.info(cli.dim("< pong"))
	end)
	ws:on("close", function(code, reason)
		cli.info(cli.dim(`connection closed ({code}{if reason ~= "" then ", " .. reason else ""})`))
		process.exit(0)
	end)
	ws:start()

	task.spawn(function()
		while not ws.closed do
			local line = term.stdin:readLine()
			if line == nil or line == "/quit" then
				ws:close()
				process.exit(0)
			end
			assert(line)
			if line == "/ping" then
				ws:ping()
			elseif string.sub(line, 1, 6) == "/close" then
				local code, reason = string.match(line, "^/close%s*(%d*)%s*(.*)$")
				ws:close(tonumber(code) or 1000, reason or "")
			elseif line ~= "" then
				local ok, sendErr = ws:send(line)
				if not ok then
					cli.warn(tostring(sendErr))
				end
			end
		end
	end)
	ws:wait()
	return 0
end

return tool
