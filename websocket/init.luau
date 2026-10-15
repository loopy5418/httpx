--[[
	httpx/websocket: WebSocket clients and servers.

	Client:

	    local websocket = require("@httpx/websocket")
	    local ws = assert(websocket.connect("wss://example.com/socket"))
	    ws:send("hello")
	    for message in ws:messages() do
	        print(message)
	    end

	Server (with httpx/server):

	    local room = websocket.hub()
	    app:ws("/chat", function(ws, req)
	        room:add(ws)
	        for message in ws:messages() do
	            room:broadcastExcept(ws, message)
	        end
	    end)

	On any socket (after your own handshake):

	    local ws = websocket.wrap(sock, { client = false })
]]

local types = require("./types")
local connectionLib = require("./connection")
local client = require("./client")
local server = require("./server")
local hub = require("../core/hub")

export type WebSocket = types.WebSocket
export type MessageKind = types.MessageKind
export type State = types.State
export type ConnectionOptions = types.ConnectionOptions
export type ConnectOptions = types.ConnectOptions
export type AcceptOptions = types.AcceptOptions

local websocket = {}

--- Connects to a server: `websocket.connect(url, options?)` -> `ws` or `nil, err`.
websocket.connect = client.connect

--- Upgrades a server request: `websocket.accept(req, res, options?)` -> `ws` or `nil, reason`.
websocket.accept = server.accept

--- A route handler for `app:get(path, websocket.handler(function(ws, req) ... end))`
--- (what `app:ws` uses).
websocket.handler = server.handler

--- Wraps an already-upgraded socket: `websocket.wrap(sock, { client = true | false })`.
websocket.wrap = connectionLib.new

--- A set of connections to broadcast to.
websocket.hub = hub.new

--- Close codes by name: `ws:close(websocket.codes.goingAway)`.
websocket.codes = connectionLib.codes

return websocket
