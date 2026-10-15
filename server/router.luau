--[[
	Routing: path patterns, middleware layers, mounting.

	Patterns:

	    "/users"              literal
	    "/users/:id"          a parameter (one segment): params.id
	    "/users/:id(%d+)"     a parameter that must match a Lua pattern
	    "/files/*path"        the rest of the path (any number of segments): params.path
	    "/assets/*"           the same, unnamed (params["*"])

	Routes and middleware run in the order they were added. A trailing slash doesn't matter.

	    local api = router.new()
	    api:get("/users/:id", function(req, res) return { id = req.params.id } end)
	    app:mount("/api", api)
]]

local net = require("@sonata/net")
local types = require("./types")

export type Router = types.Router
export type Handler = types.Handler
export type Request = types.Request
export type Response = types.Response

type Segment = { kind: "literal", value: string } | { kind: "param", name: string, pattern: string? } | { kind: "rest", name: string }

type Matcher = (path: string) -> ({ [string]: string }?, string?)

type Layer = {
	kind: "route" | "use",
	methods: { [string]: boolean }?, -- nil = every method
	match: Matcher,
	handlers: { any }, -- functions, or routers for mounts
	path: string,
}

local router = {}

-- Pattern compilation -----------------------------------------------------------------------

local function splitPath(p: string): { string }
	local out = {}
	for segment in string.gmatch(p, "[^/]+") do
		table.insert(out, segment)
	end
	return out
end

local function compileSegments(pattern: string): { Segment }
	local segments: { Segment } = {}
	for _, raw in splitPath(pattern) do
		local first = string.sub(raw, 1, 1)
		if first == ":" then
			local name, constraint = string.match(raw, "^:([%w_]+)%((.*)%)$")
			if name then
				table.insert(segments, { kind = "param", name = name, pattern = `^{constraint}$` })
			else
				name = string.match(raw, "^:([%w_]+)$")
				if name == nil then
					error(`invalid route parameter '{raw}' in '{pattern}'`, 4)
				end
				table.insert(segments, { kind = "param", name = name :: string })
			end
		elseif first == "*" then
			local name = string.sub(raw, 2)
			table.insert(segments, { kind = "rest", name = if name == "" then "*" else name })
		else
			table.insert(segments, { kind = "literal", value = net.url.decode(raw) })
		end
	end
	return segments
end

--- Compiles a path pattern. With `prefix`, the pattern only needs to match the beginning of
--- the path; the matcher then also returns the rest of the path.
function router.compile(pattern: string, prefix: boolean?): Matcher
	local segments = compileSegments(pattern)
	return function(p: string)
		local parts = splitPath(p)
		local params: { [string]: string } = {}
		local i = 1
		for _, segment in segments do
			if segment.kind == "rest" then
				local rest = {}
				for j = i, #parts do
					table.insert(rest, net.url.decode(parts[j]))
				end
				params[segment.name] = table.concat(rest, "/")
				return params, "/"
			end
			local part = parts[i]
			if part == nil then
				return nil, nil
			end
			local decoded = net.url.decode(part)
			if segment.kind == "literal" then
				if decoded ~= segment.value then
					return nil, nil
				end
			else
				if segment.pattern and not string.match(decoded, segment.pattern) then
					return nil, nil
				end
				params[segment.name] = decoded
			end
			i += 1
		end
		if i <= #parts then
			if not prefix then
				return nil, nil
			end
			local rest = {}
			for j = i, #parts do
				table.insert(rest, parts[j])
			end
			local tail = "/" .. table.concat(rest, "/")
			if string.sub(p, -1) == "/" then
				tail ..= "/"
			end
			return params, tail
		end
		return params, "/"
	end
end

-- Handler results ---------------------------------------------------------------------------

--- Sends what a handler returned, if it returned something and hasn't answered itself.
function router.respondWith(res: any, ...: any)
	if res.finished or res.sent then
		return
	end
	local first = select(1, ...)
	if first == nil or first == res then
		return
	end
	if type(first) == "number" then
		res.statusCode = first
		local body = select(2, ...)
		local headers = select(3, ...)
		if type(headers) == "table" then
			for name, value in headers do
				res:header(name, value)
			end
		end
		if body == nil then
			res:send(net.http.statusText(first) or "")
		else
			res:send(body)
		end
		return
	end
	if type(first) == "string" or type(first) == "table" or type(first) == "buffer" then
		res:send(first)
	end
end

-- Router ------------------------------------------------------------------------------------

local Router = {}
Router.__index = Router

local function isRouter(value: any): boolean
	return type(value) == "table" and type(value.handle) == "function" and type(value._layers) == "table"
end

local function methodSet(method: string | { string }): { [string]: boolean }?
	local list = if type(method) == "string" then { method } else method
	local set: { [string]: boolean } = {}
	for _, m in list do
		local upper = string.upper(m)
		if upper == "*" or upper == "ALL" then
			return nil
		end
		set[upper] = true
	end
	return set
end

--- Adds a route for one or more methods. Several handlers may be given; each one can call
--- `next()` to hand over to the following one.
function Router.route(self: any, method: string | { string }, pattern: string, ...: Handler): Router
	local handlers = { ... }
	assert(#handlers > 0, "a route needs at least one handler")
	for _, h in handlers do
		assert(type(h) == "function", "route handlers must be functions")
	end
	table.insert(self._layers, {
		kind = "route",
		methods = methodSet(method),
		match = router.compile(pattern, false),
		handlers = handlers,
		path = pattern,
	})
	return self
end

for _, method in { "get", "post", "put", "patch", "delete", "head", "options" } do
	local upper = string.upper(method)
	Router[method] = function(self: any, pattern: string, ...: Handler): Router
		return Router.route(self, upper, pattern, ...)
	end
end

--- A route for every method.
function Router.all(self: any, pattern: string, ...: Handler): Router
	return Router.route(self, "*", pattern, ...)
end

--- Adds middleware or mounts routers: `use(fn)`, `use("/prefix", fn, ...)`,
--- `use("/prefix", router)`. Middleware under a prefix sees `req.path` without it.
function Router.use(self: any, ...: any): Router
	local args = { ... }
	local prefix = "/"
	if type(args[1]) == "string" then
		prefix = table.remove(args, 1)
	end
	assert(#args > 0, "use() needs middleware or a router")
	for _, h in args do
		assert(type(h) == "function" or isRouter(h), "use() takes functions or routers")
	end
	table.insert(self._layers, {
		kind = "use",
		match = router.compile(prefix, true),
		handlers = args,
		path = prefix,
	})
	return self
end

--- Mounts a router (or an app) under a prefix.
function Router.mount(self: any, prefix: string, child: Router): Router
	return Router.use(self, prefix, child)
end

--- Creates a router mounted under `prefix` and lets `build` fill it:
---
---     app:group("/api", function(api)
---         api:get("/health", function() return { ok = true } end)
---     end)
function Router.group(self: any, prefix: string, build: (Router) -> ()): Router
	local child = router.new()
	build(child)
	Router.use(self, prefix, child)
	return child
end

--- Serves static files from `root` under `prefix`.
function Router.static(self: any, prefix: string, root: string, options: types.StaticOptions?): Router
	local static = require("./static") :: any
	return Router.use(self, prefix, static.handler(root, options))
end

--- A WebSocket endpoint: `handler(ws, req)` runs once the connection is upgraded.
--- Requests that aren't WebSocket upgrades get 426 Upgrade Required.
function Router.ws(self: any, pattern: string, handler: (any, Request) -> (), options: { [string]: any }?): Router
	local websocket = require("../websocket/server") :: any
	return Router.route(self, "GET", pattern, websocket.handler(handler, options))
end

--- A server-sent events endpoint: `handler(stream, req)` runs with the stream open. The
--- stream stays open after the handler returns, until the client leaves or `stream:close()`,
--- so a handler may just subscribe the stream somewhere (a hub) and return.
function Router.sse(self: any, pattern: string, handler: (any, Request) -> (), options: { [string]: any }?): Router
	return Router.route(self, "GET", pattern, function(req: any, res: any)
		local stream = res:sse(options)
		handler(stream, req)
		if not stream.closed then
			stream:wait()
		end
	end)
end

-- Runs a chain of handlers; `after` is called when the last one calls next().
local function runChain(handlers: { any }, req: any, res: any, after: (err: any?) -> ())
	local index = 0
	local function step(err: any?)
		if err ~= nil then
			after(err)
			return
		end
		index += 1
		local h = handlers[index]
		if h == nil then
			after(nil)
			return
		end
		if isRouter(h) then
			h:handle(req, res, step)
			return
		end
		router.respondWith(res, h(req, res, step))
	end
	step(nil)
end

--- Dispatches a request through this router's layers. `done(err?)` is called if no layer
--- finished the response.
function Router.handle(self: any, req: any, res: any, done: (err: any?) -> ())
	local layers: { Layer } = self._layers
	local index = 0
	local path = req.path
	local baseUrl = req.baseUrl
	local parentParams = req.params

	local function nextLayer(err: any?)
		-- Restore what an earlier layer may have changed.
		req.path = path
		req.baseUrl = baseUrl
		req.params = parentParams
		if err == nil and res.finished then
			return
		end
		index += 1
		local layer = layers[index]
		if layer == nil then
			done(err)
			return
		end
		local params, rest = layer.match(path)
		if params == nil then
			nextLayer(err)
			return
		end
		if layer.kind == "route" then
			if err ~= nil then
				nextLayer(err)
				return
			end
			local methods = layer.methods
			local method = req.method
			if methods and not methods[method] and not (method == "HEAD" and methods.GET) then
				-- Remember which methods this path supports, for 405 and OPTIONS.
				local allowed = req._allowed or {}
				for m in methods do
					allowed[m] = true
				end
				req._allowed = allowed
				nextLayer(nil)
				return
			end
			local merged = table.clone(parentParams)
			for k, v in params do
				merged[k] = v
			end
			req.params = merged
			runChain(layer.handlers, req, res, nextLayer)
			return
		end
		-- "use" layers: strip the prefix for the duration of the middleware.
		if err ~= nil then
			nextLayer(err)
			return
		end
		local consumed = if rest == "/" then path else string.sub(path, 1, #path - #(rest :: string))
		if layer.path ~= "/" then
			req.baseUrl = baseUrl .. string.gsub(consumed, "/$", "")
			req.path = rest :: string
		end
		local merged = table.clone(parentParams)
		for k, v in params do
			merged[k] = v
		end
		req.params = merged
		runChain(layer.handlers, req, res, nextLayer)
		return
	end

	nextLayer(nil)
end

--- Creates an empty router.
function router.new(): Router
	return setmetatable({ _layers = {} }, Router) :: any
end

router.Router = Router
router.isRouter = isRouter

return router
