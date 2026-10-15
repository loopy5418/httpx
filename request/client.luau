--[[
	The HTTP client: defaults, middleware, retries, redirects, cookies and connection reuse.

	    local api = client.new({
	        baseUrl = "https://api.example.com/v1",
	        headers = { accept = "application/json" },
	        bearer = token,
	        retry = 3,
	    })
	    local res = assert(api:get("users", { query = { page = 2 } }))
]]

local net = require("@sonata/net")
local task = require("@sonata/task")
local types = require("./types")
local transport = require("./transport")
local errors = require("../core/errors")
local urlLib = require("../core/url")
local headersLib = require("../core/headers")
local bodyLib = require("../core/body")
local cookiesLib = require("../core/cookies")

export type Client = types.Client
export type ClientOptions = types.ClientOptions
export type RequestOptions = types.RequestOptions
export type Request = types.Request
export type Response = types.Response
export type Middleware = types.Middleware

local VERSION = "0.1.0"
local DEFAULT_USER_AGENT = `httpx/{VERSION} sonata/{sonata.version}`

local IDEMPOTENT = { "GET", "HEAD", "OPTIONS", "PUT", "DELETE", "TRACE" }
local RETRY_STATUSES = { 408, 425, 429, 500, 502, 503, 504 }
local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- Options that describe a body; a request's own body replaces the defaults' entirely.
local BODY_FIELDS = { "body", "json", "form", "multipart", "file" }

local Client = {}
Client.__index = Client

local M = {}

-- Merges request options over client defaults. Headers are merged, query strings combined,
-- and everything else replaced.
local function mergeOptions(defaults: ClientOptions, options: RequestOptions?): RequestOptions
	local merged: { [string]: any } = {}
	for k, v in defaults :: { [string]: any } do
		merged[k] = v
	end
	for _, field in BODY_FIELDS do
		merged[field] = nil
	end
	if options then
		for k, v in options :: { [string]: any } do
			if k ~= "headers" and k ~= "query" then
				merged[k] = v
			end
		end
		local headers = headersLib.new(defaults.headers)
		if options.headers then
			headers:merge(options.headers)
		end
		merged.headers = headers
		merged.query = options.query
		merged._defaultQuery = defaults.query
	else
		merged.headers = headersLib.new(defaults.headers)
		merged._defaultQuery = defaults.query
	end
	return merged :: any
end

local function retryPolicy(retry: any): types.RetryOptions?
	if retry == nil or retry == false or retry == 0 then
		return nil
	end
	if type(retry) == "number" then
		return { limit = retry }
	end
	return retry
end

-- How long to wait before retrying after `res` (Retry-After), or nil.
local function retryAfter(res: Response?): number?
	if res == nil then
		return nil
	end
	local value = res.headers:get("retry-after")
	if value == nil then
		return nil
	end
	local seconds = tonumber(value)
	if seconds then
		return math.max(0, seconds)
	end
	local date = net.http.parseDate(value)
	if date then
		return math.max(0, date - os.time())
	end
	return nil
end

local function backoff(policy: types.RetryOptions, attempt: number): number
	local base = policy.delay or 0.5
	local delay = base * 2 ^ (attempt - 1)
	-- Up to 25% jitter, so many clients don't retry in lockstep.
	delay *= 1 + math.random() * 0.25
	return math.min(delay, policy.maxDelay or 30)
end

-- Builds the Request middleware sees from merged options.
local function prepare(self: any, options: RequestOptions): (Request?, string?)
	local target = options.url
	if type(target) ~= "string" or target == "" then
		return nil, errors.new("invalid", "a request needs a url")
	end
	target = urlLib.join(options.baseUrl, target)
	local defaultQuery = (options :: any)._defaultQuery
	if defaultQuery then
		target = urlLib.withQuery(target, defaultQuery)
	end
	if options.query then
		target = urlLib.withQuery(target, options.query)
	end
	local method = string.upper(options.method or "GET")
	local headers = options.headers :: types.Headers

	local okBody, b = pcall(bodyLib.encode, options :: any)
	if not okBody then
		return nil, errors.new("invalid", tostring(b))
	end

	if options.userAgent ~= false then
		headers:setDefault("User-Agent", options.userAgent or DEFAULT_USER_AGENT)
	end
	headers:setDefault("Accept", "*/*")
	if options.decompress ~= false then
		headers:setDefault("Accept-Encoding", bodyLib.acceptEncoding())
	end
	if options.bearer then
		headers:set("Authorization", `Bearer {options.bearer}`)
	elseif options.auth then
		local auth = options.auth :: any
		local user = auth.username or auth[1]
		local password = auth.password or auth[2] or ""
		headers:set("Authorization", net.http.basicAuth(user, password))
	else
		-- user:password@ in the URL
		local parsed = net.url.parse(target)
		if parsed and parsed.username then
			headers:setDefault(
				"Authorization",
				net.http.basicAuth(net.url.decode(parsed.username), net.url.decode(parsed.password or ""))
			)
		end
	end

	return {
		method = method,
		url = target,
		headers = headers,
		body = b,
		options = options,
		attempt = 0,
		client = self,
	}, nil
end

-- The cookie jar a request uses, if any.
local function jarFor(self: any, options: RequestOptions): types.CookieJar?
	local c = options.cookies
	if c == false then
		return nil
	end
	if cookiesLib.isJar(c) then
		return c :: any
	end
	if c == true or c == nil then
		if self.cookies == nil and c == nil and self._perRequestCookies then
			-- A jar that lives for this one call: cookies set while following redirects
			-- (logins, ...) still work, but nothing is kept between calls.
			return cookiesLib.jar()
		end
		return self.cookies
	end
	return nil
end

-- Sends a prepared request: retries, redirects and cookies. This is the innermost "next".
local function send(self: any, req: Request): (Response?, string?)
	local options = req.options
	local policy = retryPolicy(options.retry)
	local follow = options.followRedirects ~= false
	local maxRedirects = options.maxRedirects or 10
	local jar = jarFor(self, options)
	local redirects: { string } = {}
	local current = req
	local originalHost = req.headers:get("host")

	while true do
		if jar then
			local cookie = jar:header(current.url)
			if cookie then
				current.headers:set("Cookie", cookie)
			else
				current.headers:delete("Cookie")
			end
		end

		local res, err = transport.exchange(current, self._pool)

		-- Retry on network failures and on retryable statuses.
		if policy and current.attempt < (policy.limit or 2) then
			local methods = policy.methods or IDEMPOTENT
			local retriable = table.find(methods, current.method) ~= nil
				and (current.body == nil or current.body.replayable)
			local reason: string? = nil
			if res == nil and retriable and errors.isTransient(err) then
				reason = err
			elseif res and retriable and table.find(policy.statuses or RETRY_STATUSES, res.status) then
				reason = errors.new("status", `{res.status} {res.reason}`)
			end
			if reason then
				current.attempt += 1
				local delay = retryAfter(res) or backoff(policy, current.attempt)
				delay = math.min(delay, policy.maxDelay or 30)
				if res then
					res:close()
				end
				if policy.onRetry then
					policy.onRetry(current.attempt, reason, current)
				end
				task.wait(delay)
				if current.body and (current.body :: any).reopen then
					current.body = (current.body :: any).reopen()
				end
				continue
			end
		end

		if res == nil then
			return nil, err
		end

		if jar then
			local setCookies = res.headers:getAll("set-cookie")
			if #setCookies > 0 then
				jar:store(current.url, setCookies)
			end
		end

		local location = res.headers:get("location")
		if follow and REDIRECTS[res.status] and location then
			if #redirects >= maxRedirects then
				res:close()
				return nil, errors.new("redirect", `more than {maxRedirects} redirects (last: {current.url})`)
			end
			local nextUrl = net.url.resolve(current.url, location)
			if nextUrl == nil then
				res:close()
				return nil, errors.new("redirect", `invalid Location header: {location}`)
			end
			local method: string = current.method
			local keepBody = true
			local isHead = method == "HEAD"
			local isPost = method == "POST"
			if (res.status == 303 and not isHead) or ((res.status == 301 or res.status == 302) and isPost) then
				method, keepBody = "GET", false
			end
			if keepBody and current.body and not current.body.replayable then
				-- The body is gone; hand the redirect itself to the caller.
				res.redirects = redirects
				res.redirected = #redirects > 0
				return res, nil
			end
			res:close()

			local headers = current.headers:clone()
			if headers:get("host") == originalHost then
				headers:delete("Host")
			end
			local nextBody = current.body
			if not keepBody then
				nextBody = nil
				headers:delete("Content-Type")
				headers:delete("Content-Length")
				headers:delete("Transfer-Encoding")
			elseif nextBody and (nextBody :: any).reopen then
				nextBody = (nextBody :: any).reopen()
			end
			-- Credentials don't follow a redirect to another origin.
			if net.url.origin(nextUrl) ~= net.url.origin(current.url) then
				headers:delete("Authorization")
				headers:delete("Proxy-Authorization")
				headers:delete("Cookie")
			end
			table.insert(redirects, nextUrl)
			local nextReq = table.clone(current)
			nextReq.method = method
			nextReq.url = nextUrl
			nextReq.headers = headers
			nextReq.body = nextBody
			current = nextReq
			continue
		end

		res.redirects = redirects
		res.redirected = #redirects > 0
		return res, nil
	end
end

-- Runs the middleware chain and the request; buffers the body unless streaming.
local function perform(self: any, options: RequestOptions): (Response?, string?, Response?)
	local req, err = prepare(self, options)
	if req == nil then
		return nil, err
	end
	local middleware: { Middleware } = self._middleware
	local function run(index: number, r: Request): (Response?, string?)
		local mw = middleware[index]
		if mw == nil then
			return send(self, r)
		end
		return mw(r, function(nextReq: Request?)
			return run(index + 1, nextReq or r)
		end)
	end
	local res, sendErr = run(1, req)
	if res == nil then
		return nil, sendErr
	end
	if not options.stream and res.body == nil and res.socket == nil then
		local ok, bodyErr = (res :: any):_buffer()
		if not ok then
			return nil, bodyErr
		end
	end
	if options.failOnStatus and not res.ok then
		return nil, errors.new("status", `{res.status} {res.reason} ({res.method} {res.url})`), res
	end
	return res, nil
end

--- Sends a request. Accepts `(options)` or `(method, url, options?)`.
---
--- Returns the response, or `nil, err` (and, with `failOnStatus`, the failed response as a
--- third value). HTTP error statuses are not failures unless `failOnStatus` is set.
function Client.request(
	self: any,
	methodOrOptions: string | RequestOptions,
	target: string?,
	options: RequestOptions?
): (Response?, string?, Response?)
	local opts: RequestOptions
	if type(methodOrOptions) == "string" then
		opts = table.clone(options or {})
		opts.method = methodOrOptions
		opts.url = target
	else
		opts = methodOrOptions
	end
	local merged = mergeOptions(self.defaults, opts)
	local total = merged.totalTimeout
	if total then
		local results: { any } = {}
		local ok, timeoutErr = task.timeout(total, function()
			results = table.pack(perform(self, merged))
		end)
		if not ok then
			if timeoutErr == "timed out" then
				return nil, errors.new("timeout", `request took longer than {total}s`)
			end
			return nil, errors.new("aborted", tostring(timeoutErr))
		end
		return results[1], results[2], results[3]
	end
	return perform(self, merged)
end

local function shortcut(method: string)
	return function(self: any, target: string, options: RequestOptions?)
		return Client.request(self, method, target, options)
	end
end

Client.get = shortcut("GET")
Client.head = shortcut("HEAD")
Client.delete = shortcut("DELETE")
Client.options = shortcut("OPTIONS")
Client.post = shortcut("POST")
Client.put = shortcut("PUT")
Client.patch = shortcut("PATCH")

--- Downloads `url` into `file`, streaming it. Returns the response once the file is complete.
--- Non-2xx responses are failures here.
function Client.download(self: any, target: string, file: string, options: RequestOptions?): (Response?, string?)
	local opts = table.clone(options or {})
	opts.stream = true
	local res, err = Client.request(self, "GET", target, opts)
	if res == nil then
		return nil, err
	end
	if not res.ok then
		res:close()
		return nil, errors.new("status", `{res.status} {res.reason} ({res.url})`)
	end
	local _, saveErr = res:save(file)
	if saveErr then
		return nil, saveErr
	end
	return res, nil
end

--- Adds middleware. Middleware added first runs first (outermost).
function Client.use(self: any, middleware: Middleware): Client
	table.insert(self._middleware, middleware)
	return self
end

--- A new client with these options layered over this one's. It shares the connection pool
--- and cookie jar, and starts with a copy of the middleware.
function Client.extend(self: any, options: ClientOptions): Client
	local defaults = table.clone(self.defaults)
	for k, v in options :: { [string]: any } do
		if k ~= "headers" then
			defaults[k] = v
		end
	end
	defaults.headers = headersLib.new(self.defaults.headers):merge(options.headers)
	local child = setmetatable({
		defaults = defaults,
		cookies = if options.cookies == false then nil
			elseif cookiesLib.isJar(options.cookies) then options.cookies
			else self.cookies,
		_pool = self._pool,
		_middleware = table.clone(self._middleware),
		_perRequestCookies = self._perRequestCookies,
	}, Client)
	return child :: any
end

--- Closes the idle connections this client keeps.
function Client.close(self: any)
	self._pool:closeAll()
end

--- Creates a client.
function M.new(options: ClientOptions?): Client
	local defaults: any = table.clone((options or {}) :: any)
	local middleware = defaults.middleware or {}
	defaults.middleware = nil
	local jar: types.CookieJar? = nil
	local perRequest = false
	if cookiesLib.isJar(defaults.cookies) then
		jar = defaults.cookies :: any
	elseif defaults.cookies == "per-request" then
		perRequest = true
		defaults.cookies = nil
	elseif defaults.cookies ~= false then
		jar = cookiesLib.jar()
	end
	local self = setmetatable({
		defaults = defaults,
		cookies = jar,
		_pool = transport.pool({
			maxIdlePerHost = defaults.maxIdlePerHost,
			idleTimeout = defaults.idleTimeout,
		}),
		_middleware = table.clone(middleware),
		_perRequestCookies = perRequest,
	}, Client)
	return self :: any
end

M.VERSION = VERSION
M.USER_AGENT = DEFAULT_USER_AGENT

return M
