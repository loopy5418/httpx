--[[
	httpx/request: the HTTP client.

	Simple:

	    local request = require("@httpx/request")
	    local res = assert(request.get("https://example.com"))
	    print(res.status, res.body)

	    local res = assert(request.post("https://httpbin.org/post", { json = { hello = "world" } }))
	    print(res:json().json.hello)

	Reusable clients with defaults, middleware, retries and cookies:

	    local api = request.client({ baseUrl = "https://api.example.com", bearer = token, retry = 3 })
	    api:use(function(req, next)
	        local res, err = next(req)
	        print(req.method, req.url, res and res.status or err)
	        return res, err
	    end)
	    local users = assert(api:get("/users")):json()

	Failures (no connection, timeouts, ...) return `nil, err`; wrap calls in `assert` to raise.
	Error statuses (404, 500, ...) are ordinary responses: check `res.ok`, call
	`res:raiseForStatus()`, or pass `failOnStatus = true`.
]]

local types = require("./types")
local clientLib = require("./client")
local responseLib = require("./response")
local transport = require("./transport")

export type Client = types.Client
export type ClientOptions = types.ClientOptions
export type RequestOptions = types.RequestOptions
export type Request = types.Request
export type Response = types.Response
export type Middleware = types.Middleware
export type Next = types.Next
export type RetryOptions = types.RetryOptions
export type BasicAuth = types.BasicAuth


-- The shared client keeps no cookies between calls (each call gets its own jar, so
-- redirects that set cookies still work). Create a client to keep them.
local default = clientLib.new({ cookies = "per-request" :: any })

local request = {}

--- The shared client used by the functions below. Change its defaults with
--- `request.default.defaults.timeout = 10`, or add middleware with `request.default:use(...)`.
request.default = default

--- Creates a client with its own defaults, connection pool and cookie jar.
request.client = clientLib.new

--- Sends a request with the shared client: `request.request(options)` or
--- `request.request(method, url, options?)`.
function request.request(methodOrOptions: string | RequestOptions, target: string?, options: RequestOptions?): (Response?, string?, Response?)
	return default:request(methodOrOptions, target, options)
end

function request.get(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("GET", target, options)
end

function request.head(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("HEAD", target, options)
end

function request.delete(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("DELETE", target, options)
end

function request.options(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("OPTIONS", target, options)
end

function request.post(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("POST", target, options)
end

function request.put(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("PUT", target, options)
end

function request.patch(target: string, options: RequestOptions?): (Response?, string?, Response?)
	return default:request("PATCH", target, options)
end

--- Downloads a URL into a file. Returns the response once the file is complete.
function request.download(target: string, file: string, options: RequestOptions?): (Response?, string?)
	return default:download(target, file, options)
end

--- Fetches a URL and decodes its JSON body. Non-2xx statuses are failures.
---
---     local repo = assert(request.json("https://api.github.com/repos/luau-lang/luau"))
function request.json(target: string, options: RequestOptions?): (any, string?)
	local opts = table.clone(options or {})
	opts.failOnStatus = true
	local res, err = default:request(opts.method or "GET", target, opts)
	if res == nil then
		return nil, err
	end
	return res:json()
end

--- Fetches a URL and returns its body as a string. Non-2xx statuses are failures.
function request.text(target: string, options: RequestOptions?): (string?, string?)
	local opts = table.clone(options or {})
	opts.failOnStatus = true
	local res, err = default:request(opts.method or "GET", target, opts)
	if res == nil then
		return nil, err
	end
	return res:text()
end

request.Response = responseLib.Response
request.transport = transport
request.USER_AGENT = clientLib.USER_AGENT
request.VERSION = clientLib.VERSION

-- The category is callable too: `request(options)` / `request(method, url, options?)`.
return setmetatable(request, {
	__call = function(_, methodOrOptions: string | RequestOptions, target: string?, options: RequestOptions?)
		return default:request(methodOrOptions, target, options)
	end,
})
