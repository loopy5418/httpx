--[[
	Types of the HTTP client.
]]

local coreTypes = require("../core/types")

export type Headers = coreTypes.Headers
export type HeadersInit = coreTypes.HeadersInit
export type Query = coreTypes.Query
export type Body = coreTypes.Body
export type BodyStream = coreTypes.BodyStream
export type MultipartInit = coreTypes.MultipartInit
export type CookieJar = coreTypes.CookieJar
export type Tls = coreTypes.Tls
export type Url = coreTypes.Url

--- When and how failed requests are sent again.
export type RetryOptions = {
	limit: number?, -- how many times to retry (default 2 when a table is given)
	methods: { string }?, -- methods that may be retried (default: the idempotent ones)
	statuses: { number }?, -- statuses that trigger a retry (default 408, 425, 429, 500, 502, 503, 504)
	delay: number?, -- first delay in seconds (default 0.5), doubled on each attempt
	maxDelay: number?, -- longest delay, including Retry-After (default 30)
	onRetry: ((attempt: number, reason: string, request: Request) -> ())?,
}

--- `{ "user", "password" }` or `{ username = "user", password = "password" }`.
export type BasicAuth = { string } | { username: string, password: string }

--- Options of one request. Every field is optional; the ones a client was created with act
--- as defaults.
export type RequestOptions = {
	method: string?, -- default "GET"
	url: string?,
	baseUrl: string?, -- prepended to relative URLs
	query: Query?, -- added to the URL's query string
	headers: HeadersInit?,

	-- The body: at most one of these.
	body: (string | buffer | BodyStream)?,
	json: any?, -- encoded as JSON, Content-Type: application/json
	form: { [string]: any }?, -- application/x-www-form-urlencoded
	multipart: MultipartInit?, -- multipart/form-data
	file: string?, -- the contents of a file, streamed

	auth: BasicAuth?, -- HTTP basic authentication
	bearer: string?, -- Authorization: Bearer <token>
	userAgent: (string | false)?, -- false sends none

	timeout: (number | false)?, -- seconds for each wait: connecting, sending, every read (default 30; false: no limit)
	connectTimeout: number?, -- seconds to connect (default: timeout)
	totalTimeout: number?, -- seconds for the whole request, redirects and retries included
	retry: (number | RetryOptions)?, -- number = retry limit with the default policy
	followRedirects: boolean?, -- default true
	maxRedirects: number?, -- default 10
	failOnStatus: boolean?, -- treat 4xx/5xx as failures: returns nil, "status: ...", response

	stream: boolean?, -- don't read the body up front; use res:read(), res:chunks(), ...
	decompress: boolean?, -- send Accept-Encoding and decode gzip/deflate/zstd (default true)
	maxBodySize: number?, -- most bytes of body accepted
	onProgress: ((received: number, total: number?) -> ())?, -- called as the body arrives

	cookies: (boolean | CookieJar)?, -- a jar to use; false: none (clients have their own jar by default)
	keepAlive: boolean?, -- reuse connections (default true)
	tls: Tls?, -- TLS options for https (see @sonata/net), e.g. { caFile = "ca.pem" }
	insecure: boolean?, -- skip certificate verification (testing only)
	proxy: (string | { [string]: any })?, -- "http://host:3128", "socks5://user:pass@host:1080"
	family: ("any" | "ipv4" | "ipv6")?,
	localAddress: string?,
}

--- A request about to be sent, as middleware sees it. Middleware may change any field.
export type Request = {
	method: string,
	url: string,
	headers: Headers,
	body: Body?,
	options: RequestOptions, -- the merged options
	attempt: number, -- 0 for the first try
	[string]: any,
}

export type Response = {
	status: number,
	reason: string,
	ok: boolean, -- status 200-299
	headers: Headers,
	url: string, -- the final URL, after redirects
	method: string,
	version: string,
	redirected: boolean,
	redirects: { string }, -- every URL redirected to, in order
	elapsed: number, -- seconds until the head arrived
	request: Request,
	body: string?, -- the whole body (nil for streamed responses until read)
	socket: any?, -- the raw socket, after a 101 Switching Protocols or a CONNECT

	text: (self: Response) -> (string?, string?),
	json: (self: Response) -> (any, string?),
	form: (self: Response) -> ({ [string]: string }?, string?),
	header: (self: Response, name: string) -> string?,
	read: (self: Response) -> (string?, string?),
	chunks: (self: Response) -> () -> string?,
	lines: (self: Response) -> () -> string?,
	events: (self: Response) -> () -> any,
	save: (self: Response, file: string) -> (number?, string?),
	close: (self: Response) -> (),
	raiseForStatus: (self: Response) -> Response,
	[string]: any,
}

export type Next = (request: Request) -> (Response?, string?)

--- Middleware wraps every request of a client:
---
---     client:use(function(req, next)
---         req.headers:set("x-request-id", crypto.uuid())
---         local res, err = next(req)
---         return res, err
---     end)
export type Middleware = (request: Request, next: Next) -> (Response?, string?)

export type ClientOptions = RequestOptions & {
	maxIdlePerHost: number?, -- idle connections kept per host (default 8)
	idleTimeout: number?, -- seconds an idle connection is kept (default 30)
	middleware: { Middleware }?,
}

export type Client = {
	defaults: ClientOptions,
	cookies: CookieJar?,
	request: (self: Client, methodOrOptions: string | RequestOptions, url: string?, options: RequestOptions?) -> (Response?, string?, Response?),
	get: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	head: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	delete: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	options: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	post: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	put: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	patch: (self: Client, url: string, options: RequestOptions?) -> (Response?, string?, Response?),
	download: (self: Client, url: string, file: string, options: RequestOptions?) -> (Response?, string?),
	use: (self: Client, middleware: Middleware) -> Client,
	extend: (self: Client, options: ClientOptions) -> Client,
	close: (self: Client) -> (),
	[string]: any,
}

return {}
