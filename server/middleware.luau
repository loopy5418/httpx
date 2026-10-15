--[[
	Ready-made middleware.

	    local mw = server.middleware
	    app:use(mw.logger())
	    app:use(mw.cors({ origin = { "https://example.com" }, credentials = true }))
	    app:use(mw.compress())
	    app:use("/admin", mw.basicAuth({ users = { admin = "hunter2" } }))
	    app:use("/api", mw.rateLimit({ window = 60, max = 100 }))
]]

local net = require("@sonata/net")
local crypto = require("@sonata/crypto")
local compress = require("@sonata/compress")
local term = require("@sonata/term")
local types = require("./types")
local httpErrors = require("./errors")

export type Handler = types.Handler

local middleware = {}

-- Logging -------------------------------------------------------------------------------------

export type LoggerOptions = {
	format: ("dev" | "combined" | ((req: any, res: any, ms: number) -> string))?,
	skip: ((req: any, res: any) -> boolean)?,
	write: ((line: string) -> ())?, -- default: stdout
}

local function statusStyle(status: number): string
	if status >= 500 then
		return "red"
	elseif status >= 400 then
		return "yellow"
	elseif status >= 300 then
		return "cyan"
	end
	return "green"
end

--- Logs each request once its response is complete:
--- `GET /users/7 200 3.1ms 512B` ("dev", colored on terminals) or the Apache combined format.
function middleware.logger(options: LoggerOptions?): Handler
	local opts = options or {}
	local format = opts.format or "dev"
	local write = opts.write or function(line: string)
		term.stdout:writeLine(line):flush()
	end
	return function(req: any, res: any, nextFn: any)
		local started = os.clock()
		res:onFinish(function(r: any, s: any)
			if opts.skip and opts.skip(r, s) then
				return
			end
			local ms = (os.clock() - started) * 1000
			local line: string
			if type(format) == "function" then
				line = format(r, s, ms)
			elseif format == "combined" then
				line = string.format(
					'%s - - [%s] "%s %s HTTP/%s" %d %d "%s" "%s"',
					r.ip,
					os.date("!%d/%b/%Y:%H:%M:%S +0000"),
					r.method,
					r.target,
					r.version,
					s.statusCode,
					s.bytesSent,
					r.headers:get("referer") or "-",
					r.headers:get("user-agent") or "-"
				)
			else
				local status = term.style(tostring(s.statusCode), statusStyle(s.statusCode))
				line = string.format(
					"%s %s %s %s %s",
					term.style(r.method, "bold"),
					r.originalPath,
					status,
					term.style(string.format("%.1fms", ms), "dim"),
					term.style(`{s.bytesSent}B`, "dim")
				)
				if s.upgraded then
					line ..= term.style(" (upgraded)", "dim")
				end
			end
			write(line)
		end)
		nextFn()
	end
end

-- CORS ----------------------------------------------------------------------------------------

export type CorsOptions = {
	-- "*" (default), one origin, a list, or a function returning true/false or the origin to allow.
	origin: (string | { string } | ((origin: string, req: any) -> (boolean | string)))?,
	methods: { string }?, -- default GET, HEAD, PUT, PATCH, POST, DELETE
	headers: { string }?, -- allowed request headers (default: whatever the preflight asks for)
	exposeHeaders: { string }?,
	credentials: boolean?,
	maxAge: number?, -- seconds a preflight may be cached
	preflightContinue: boolean?, -- pass preflight requests on instead of answering them
}

--- Cross-origin resource sharing: answers preflight requests and adds the CORS headers.
function middleware.cors(options: CorsOptions?): Handler
	local opts = options or {}
	local methods = table.concat(opts.methods or { "GET", "HEAD", "PUT", "PATCH", "POST", "DELETE" }, ", ")
	return function(req: any, res: any, nextFn: any)
		local origin = req.headers:get("origin")
		local allowed: string? = nil
		local policy = opts.origin or "*"
		if type(policy) == "string" then
			if policy == "*" and opts.credentials and origin then
				allowed = origin -- "*" isn't allowed with credentials: reflect the origin
			else
				allowed = policy
			end
		elseif type(policy) == "table" then
			if origin and table.find(policy, origin) then
				allowed = origin
			end
		elseif type(policy) == "function" and origin then
			local verdict = policy(origin, req)
			if verdict == true then
				allowed = origin
			elseif type(verdict) == "string" then
				allowed = verdict
			end
		end
		if allowed then
			res:header("Access-Control-Allow-Origin", allowed)
			if allowed ~= "*" then
				res:append("Vary", "Origin")
			end
			if opts.credentials then
				res:header("Access-Control-Allow-Credentials", "true")
			end
			if opts.exposeHeaders then
				res:header("Access-Control-Expose-Headers", table.concat(opts.exposeHeaders, ", "))
			end
		end
		local isPreflight = req.method == "OPTIONS" and req.headers:has("access-control-request-method")
		if isPreflight and not opts.preflightContinue then
			if allowed then
				res:header("Access-Control-Allow-Methods", methods)
				local requested = req.headers:get("access-control-request-headers")
				if opts.headers then
					res:header("Access-Control-Allow-Headers", table.concat(opts.headers, ", "))
				elseif requested then
					res:header("Access-Control-Allow-Headers", requested)
					res:append("Vary", "Access-Control-Request-Headers")
				end
				if opts.maxAge then
					res:header("Access-Control-Max-Age", tostring(opts.maxAge))
				end
			end
			res:status(204):send()
			return
		end
		nextFn()
	end
end

-- Compression ---------------------------------------------------------------------------------

export type CompressOptions = {
	threshold: number?, -- smallest body worth compressing, in bytes (default 1024)
	level: (number | string)?, -- compression level (default: the format's default)
	encodings: { string }?, -- in order of preference (default { "zstd", "gzip", "deflate" })
}

-- HTTP content-coding name -> @sonata/compress format
local FORMATS = { gzip = "gzip", deflate = "zlib", zstd = "zstd" }

--- Compresses response bodies (gzip, deflate, or zstd when available) for clients that
--- accept it. Streamed responses (`res:write`) are not compressed.
function middleware.compress(options: CompressOptions?): Handler
	local opts = options or {}
	local available = compress.formats()
	local preferred: { string } = {}
	for _, encoding in opts.encodings or { "zstd", "gzip", "deflate" } do
		local format = FORMATS[encoding]
		if format and table.find(available, format) then
			table.insert(preferred, encoding)
		end
	end
	local function choose(req: any): (string?, string?)
		local header = req.headers:get("accept-encoding")
		if header == nil then
			return nil, nil
		end
		local ok, ranges = pcall(net.http.parseQuality, header)
		if not ok or ranges == nil then
			return nil, nil
		end
		local accepted: { [string]: number } = {}
		for _, range in ranges do
			accepted[string.lower(range.value)] = range.q
		end
		for _, encoding in preferred do
			local q = accepted[encoding] or accepted["*"]
			if q and q > 0 then
				return encoding, FORMATS[encoding]
			end
		end
		return nil, nil
	end
	return function(req: any, res: any, nextFn: any)
		res._compress = { threshold = opts.threshold, level = opts.level, choose = choose }
		nextFn()
	end
end

-- Authentication ------------------------------------------------------------------------------

export type BasicAuthOptions = {
	users: { [string]: string }?, -- user name -> password
	verify: ((user: string, password: string, req: any) -> boolean)?,
	realm: string?,
}

--- HTTP basic authentication. On success the user name is in `req.locals.user`.
function middleware.basicAuth(options: BasicAuthOptions): Handler
	local realm = options.realm or "Restricted"
	local challenge = { ["WWW-Authenticate"] = `Basic realm="{realm}", charset="UTF-8"` }
	return function(req: any, res: any, nextFn: any)
		local header = req.headers:get("authorization")
		if header then
			local ok, user, password = pcall(net.http.parseBasicAuth, header)
			if ok and user then
				local good = false
				if options.verify then
					good = options.verify(user, password or "", req)
				elseif options.users then
					local expected = options.users[user]
					good = expected ~= nil and crypto.equals(expected, password or "")
				end
				if good then
					req.locals.user = user
					nextFn()
					return
				end
			end
		end
		httpErrors.abort(401, "authentication required", challenge)
	end
end

export type BearerAuthOptions = {
	token: (string | { string })?, -- the accepted token(s)
	verify: ((token: string, req: any) -> any)?, -- return a truthy value (stored in req.locals.auth)
}

--- Bearer token authentication (`Authorization: Bearer <token>`).
function middleware.bearerAuth(options: BearerAuthOptions): Handler
	local tokens: { string } = {}
	if type(options.token) == "string" then
		tokens = { options.token }
	elseif type(options.token) == "table" then
		tokens = options.token
	end
	return function(req: any, res: any, nextFn: any)
		local header = req.headers:get("authorization") or ""
		local token = string.match(header, "^[Bb]earer%s+(.+)$")
		if token then
			if options.verify then
				local result = options.verify(token, req)
				if result then
					req.locals.auth = result
					nextFn()
					return
				end
			else
				for _, accepted in tokens do
					if crypto.equals(accepted, token) then
						req.locals.auth = token
						nextFn()
						return
					end
				end
			end
		end
		httpErrors.abort(401, "invalid or missing token", { ["WWW-Authenticate"] = "Bearer" })
	end
end

-- Rate limiting -------------------------------------------------------------------------------

export type RateLimitOptions = {
	window: number?, -- seconds (default 60)
	max: number?, -- requests per window and key (default 60)
	key: ((req: any) -> string)?, -- default: the client's IP
	message: string?,
}

--- A fixed-window rate limiter kept in memory. Answers 429 with Retry-After once the limit is
--- reached, and sends RateLimit-* headers.
function middleware.rateLimit(options: RateLimitOptions?): Handler
	local opts = options or {}
	local window = opts.window or 60
	local max = opts.max or 60
	local buckets: { [string]: { count: number, reset: number } } = {}
	local lastSweep = os.time()
	return function(req: any, res: any, nextFn: any)
		local now = os.time()
		if now - lastSweep > window then
			for k, bucket in buckets do
				if bucket.reset <= now then
					buckets[k] = nil
				end
			end
			lastSweep = now
		end
		local key = if opts.key then opts.key(req) else req.ip
		local bucket = buckets[key]
		if bucket == nil or bucket.reset <= now then
			bucket = { count = 0, reset = now + window }
			buckets[key] = bucket
		end
		bucket.count += 1
		local remaining = math.max(0, max - bucket.count)
		res:header("RateLimit-Limit", tostring(max))
		res:header("RateLimit-Remaining", tostring(remaining))
		res:header("RateLimit-Reset", tostring(bucket.reset - now))
		if bucket.count > max then
			httpErrors.abort(429, opts.message or "too many requests", { ["Retry-After"] = tostring(bucket.reset - now) })
		end
		nextFn()
	end
end

-- Misc ----------------------------------------------------------------------------------------

--- Common security headers. Pass a table to change or remove (`false`) any of them.
function middleware.securityHeaders(overrides: { [string]: string | false }?): Handler
	local headers: { [string]: string | false } = {
		["X-Content-Type-Options"] = "nosniff",
		["X-Frame-Options"] = "SAMEORIGIN",
		["Referrer-Policy"] = "strict-origin-when-cross-origin",
		["Cross-Origin-Opener-Policy"] = "same-origin",
		["X-DNS-Prefetch-Control"] = "off",
	}
	if overrides then
		for k, v in overrides do
			headers[k] = v
		end
	end
	return function(req: any, res: any, nextFn: any)
		for name, value in headers do
			if value then
				res.headers:setDefault(name, value)
			end
		end
		nextFn()
	end
end

--- Gives each request an ID (kept from the incoming header if present), in
--- `req.locals.requestId` and the response header.
function middleware.requestId(header: string?): Handler
	local name = header or "X-Request-Id"
	return function(req: any, res: any, nextFn: any)
		local id = req.headers:get(name) or crypto.uuid(7)
		req.locals.requestId = id
		res:header(name, id)
		nextFn()
	end
end

--- Limits the request body size for the routes below it (the server-wide limit is the
--- `maxBodySize` listen option).
function middleware.bodyLimit(max: number): Handler
	return function(req: any, res: any, nextFn: any)
		local length = tonumber(req.headers:get("content-length"))
		if length and length > max then
			httpErrors.abort(413, "request body too large")
		end
		local reader = req._reader
		if reader and reader._opts then
			local current = reader._opts.maxSize
			if current == nil or max < current then
				reader._opts.maxSize = max
			end
		end
		nextFn()
	end
end

return middleware
