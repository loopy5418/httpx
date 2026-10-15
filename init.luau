--[[
	httpx: HTTP for Sonata. Clients, servers, WebSockets, server-sent events and webhooks, built
	on @sonata/net.

	    local httpx = require("@httpx")

	    -- Client
	    local res = assert(httpx.get("https://example.com"))
	    print(res.status, res.body)
	    local data = assert(httpx.json("https://api.example.com/items"))

	    -- Server
	    local app = httpx.app()
	    app:get("/", function() return "Hello!" end)
	    assert(app:listen(8080))

	Each category also stands alone: require("@httpx/request"), "@httpx/server",
	"@httpx/websocket", "@httpx/sse", "@httpx/webhook", "@httpx/core".

	Failures caused by the outside world return `nil, err` (wrap in `assert` to raise); `err`
	starts with its kind, e.g. "timeout: ...". See `httpx.errorKind`.
]]

local core = require("./core")
local request = require("./request")
local server = require("./server")
local websocket = require("./websocket")
local sse = require("./sse")
local webhook = require("./webhook")

-- Types ---------------------------------------------------------------------------------------

export type Headers = core.Headers
export type HeadersInit = core.HeadersInit
export type Query = core.Query
export type Cookie = core.Cookie
export type CookieJar = core.CookieJar
export type ErrorKind = core.ErrorKind

export type Client = request.Client
export type ClientOptions = request.ClientOptions
export type RequestOptions = request.RequestOptions
export type Request = request.Request
export type Response = request.Response
export type Middleware = request.Middleware
export type RetryOptions = request.RetryOptions

export type App = server.App
export type AppOptions = server.AppOptions
export type Router = server.Router
export type ServerRequest = server.Request
export type ServerResponse = server.Response
export type Handler = server.Handler
export type ListenOptions = server.ListenOptions
export type Server = server.Server
export type StaticOptions = server.StaticOptions

export type WebSocket = websocket.WebSocket
export type WebSocketConnectOptions = websocket.ConnectOptions
export type WebSocketAcceptOptions = websocket.AcceptOptions

export type Event = sse.Event
export type EventStream = sse.Stream
export type EventSource = sse.Source

export type Webhook = webhook.Webhook
export type WebhookEvent = webhook.Event

-- The module ----------------------------------------------------------------------------------

local httpx = require("./lib")

-- Run directly (`sn run`, or a program built with plain `sn build`), httpx is the all-in-one
-- command-line program; required as a library, it just returns the module.
if sonata.entry == debug.info(1, "s") then
	local cli = require("./apps/tools/cli")
	cli.run(require("./apps/tools/main").main, args)
end

return httpx
