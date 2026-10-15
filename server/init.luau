--[[
	httpx/server: an HTTP/1.1 server with routing, middleware, static files, WebSockets and
	server-sent events.

	Simple:

	    local server = require("@httpx/server")
	    local app = server.app()
	    app:get("/", function() return "Hello!" end)
	    app:get("/users/:id", function(req) return { id = req.params.id } end)
	    app:post("/echo", function(req, res) res:json(req:json()) end)
	    assert(app:listen(8080))

	One function for everything:

	    assert(server.serve(function(req, res)
	        res:text(`you asked for {req.path}`)
	    end, { port = 8080 }))

	Bigger apps: routers, middleware, error handling, TLS:

	    local api = server.router()
	    api:get("/health", function() return { ok = true } end)
	    app:use(server.middleware.logger())
	    app:mount("/api", api)
	    app:static("/", "public")
	    app:onError(function(err, req, res) res:json({ error = tostring(err) }, 500) end)
	    assert(app:listen({ port = 8443, tls = { cert = "cert.pem", key = "key.pem" } }))
]]

local types = require("./types")
local appLib = require("./app")
local routerLib = require("./router")
local listener = require("./listener")
local connection = require("./connection")
local static = require("./static")
local middleware = require("./middleware")
local httpErrors = require("./errors")
local requestLib = require("./request")
local responseLib = require("./response")

export type App = types.App
export type AppOptions = types.AppOptions
export type Router = types.Router
export type Request = types.Request
export type Response = types.Response
export type Handler = types.Handler
export type Next = types.Next
export type ErrorHandler = types.ErrorHandler
export type ListenOptions = types.ListenOptions
export type Server = types.Server
export type StaticOptions = types.StaticOptions
export type CookieOptions = types.CookieOptions
export type HttpError = httpErrors.HttpError

local server = {}

--- Creates an app: a router you can `listen` with.
server.app = appLib.new

--- Creates a router, to mount in an app with `app:mount(prefix, router)`.
server.router = routerLib.new

--- Serves a single handler function (or an app). Shorthand for
--- `server.app():use(handler):listen(options)`.
function server.serve(handler: Handler | App, options: (number | ListenOptions)?): (Server?, string?)
	local app: any = handler
	if type(handler) == "function" then
		app = appLib.new()
		app:use(handler)
	end
	return app:listen(options)
end

--- Lower level: listens with an app or a plain `handler(req, res)` (no routing, no 404
--- handling), with every option available.
server.listen = listener.listen

--- Lowest level: serves the requests of one already-connected socket.
server.serveConnection = connection.serve

--- Middleware serving static files from a folder (or another source).
server.static = static.handler
--- Sends one file as a response (what `res:file` does).
server.sendFile = static.sendFile

server.middleware = middleware

--- Raises an HTTP error from inside a handler: `server.abort(404, "no such user")`.
server.abort = httpErrors.abort
--- Creates an HTTP error without raising it (to pass to `next(err)`).
server.error = httpErrors.new
server.isError = httpErrors.is

server.Request = requestLib
server.Response = responseLib

return server
