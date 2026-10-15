--[[
	The application: a router with error handling, 404/405 answers and `listen`.

	    local app = server.app()
	    app:use(server.middleware.logger())
	    app:get("/", function() return "<h1>Hello</h1>" end)
	    app:get("/users/:id", function(req) return { id = req.params.id } end)
	    assert(app:listen(8080))
]]

local types = require("./types")
local routerLib = require("./router")
local listener = require("./listener")
local httpErrors = require("./errors")

export type App = types.App
export type AppOptions = types.AppOptions

local App = setmetatable({}, { __index = routerLib.Router })
App.__index = App

local M = {}

--- Sets the handler for errors raised by handlers (or passed to `next(err)`). It receives the
--- error, which is an `HttpError` (with `status`) for `server.abort(...)`, or any other value.
function App.onError(self: any, handler: types.ErrorHandler): App
	self._onError = handler
	return self
end

--- Sets the handler for requests no route answered (default: a 404 response).
function App.notFound(self: any, handler: types.Handler): App
	self._notFound = handler
	return self
end

-- The default error answer.
local function defaultError(self: any, err: any, req: any, res: any)
	local status = 500
	local message: string? = nil
	if httpErrors.is(err) then
		status = err.status
		if err.expose or self.options.exposeErrors then
			message = err.message
		end
		if err.headers then
			for name, value in err.headers do
				res:header(name, value)
			end
		end
	elseif self.options.exposeErrors then
		message = tostring(err)
	end
	res:error(status, message)
end

-- Handles an error from anywhere in the chain.
function App._fail(self: any, err: any, traceback: string?, req: any, res: any)
	local isHttp = httpErrors.is(err)
	if self.options.logErrors ~= false and (not isHttp or err.status >= 500) then
		print(`httpx: error in {req.method} {req.originalPath}: {tostring(err)}`)
		if traceback and not isHttp then
			print(traceback)
		end
	end
	if res.sent then
		-- Too late for an error response; make sure the client isn't left waiting.
		res.closeAfter = true
		res:finish()
		return
	end
	if self._onError then
		local ok, handlerErr = pcall(self._onError, err, req, res)
		if ok and res.sent then
			return
		end
		if not ok then
			print(`httpx: error in the error handler: {tostring(handlerErr)}`)
		end
	end
	defaultError(self, err, req, res)
end

-- Answers a request no route finished.
function App._unhandled(self: any, req: any, res: any)
	local allowed = req._allowed
	if allowed then
		local list = {}
		for m in allowed do
			table.insert(list, m)
		end
		if allowed.GET then
			table.insert(list, "HEAD")
		end
		table.insert(list, "OPTIONS")
		table.sort(list)
		res:header("Allow", table.concat(list, ", "))
		if req.method == "OPTIONS" then
			res:status(204):send()
		else
			res:error(405)
		end
		return
	end
	if self._notFound then
		routerLib.respondWith(res, self._notFound(req, res, function() end))
		if res.sent then
			return
		end
	end
	res:error(404)
end

--- Runs a request through the app. Used by the connection loop; useful for embedding the app
--- in another server.
function App.dispatch(self: any, req: any, res: any)
	if req.app == nil then
		req.app = self
	end
	local caught = nil
	local traceback = nil
	local ok, err = xpcall(function()
		routerLib.Router.handle(self, req, res, function(nextErr: any?)
			if nextErr ~= nil then
				caught = nextErr
			end
		end)
	end, function(e)
		traceback = debug.traceback(nil, 2)
		return e
	end)
	if not ok then
		caught = err
	end
	if caught ~= nil then
		self:_fail(caught, traceback, req, res)
	elseif not res.finished and not res.sent then
		local okUnhandled, unhandledErr = pcall(App._unhandled, self, req, res)
		if not okUnhandled then
			self:_fail(unhandledErr, nil, req, res)
		end
	end
end

--- Mounted as a router inside another app, an app behaves like a router.
function App.handle(self: any, req: any, res: any, done: (err: any?) -> ())
	return routerLib.Router.handle(self, req, res, done)
end

--- Starts listening. Accepts a port, `(port, host)`, or a `ListenOptions` table; options given
--- to `server.app(options)` are the defaults. Returns the running server or `nil, err`.
function App.listen(self: any, port: (number | types.ListenOptions)?, host: string?): (types.Server?, string?)
	local options: { [string]: any } = table.clone(self.options)
	if type(port) == "table" then
		for k, v in port :: { [string]: any } do
			options[k] = v
		end
	elseif port ~= nil then
		options.port = port
	end
	if host then
		options.host = host
	end
	local srv, err = listener.listen(self, options :: any)
	if srv then
		table.insert(self._servers, srv)
	end
	return srv, err
end

--- Closes every server this app is listening with.
function App.close(self: any, options: { graceful: boolean?, timeout: number? }?)
	for _, srv in self._servers do
		srv:close(options)
	end
	table.clear(self._servers)
end

--- Creates an app.
function M.new(options: AppOptions?): App
	local self = setmetatable({
		_layers = {},
		_servers = {},
		_onError = nil,
		_notFound = nil,
		options = options or {},
		locals = {},
	}, App)
	return self :: any
end

M.App = App

return M
