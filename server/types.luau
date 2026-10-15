--[[
	Types of the HTTP server.
]]

local coreTypes = require("../core/types")

export type Headers = coreTypes.Headers
export type HeadersInit = coreTypes.HeadersInit
export type Part = coreTypes.Part

--- An incoming request.
export type Request = {
	method: string, -- "GET", "POST", ...
	path: string, -- the path, relative to where the current router is mounted
	originalPath: string, -- the full path, as received
	baseUrl: string, -- the prefix the current router is mounted at ("" at the top)
	target: string, -- the raw request target: "/a/b?x=1"
	rawQuery: string?, -- "x=1"
	query: { [string]: string }, -- decoded query parameters (first value of each)
	queryList: { { string } }, -- every query parameter, in order
	params: { [string]: string }, -- route parameters: "/users/:id" -> params.id
	headers: Headers,
	version: string, -- "1.1"
	ip: string, -- the client's address (X-Forwarded-For with trustProxy)
	port: number, -- the client's port
	host: string, -- the Host header, without port
	protocol: string, -- "http" or "https"
	secure: boolean,
	url: string, -- the full URL: "https://example.com/a?x=1"
	cookies: { [string]: string }, -- parsed Cookie header
	body: string, -- the whole body, read on first access
	locals: { [string]: any }, -- free space for middleware to pass data along
	app: any,
	socket: any, -- the raw connection

	header: (self: Request, name: string) -> string?,
	text: (self: Request) -> string,
	json: (self: Request) -> any,
	form: (self: Request) -> { [string]: string },
	multipart: (self: Request) -> ({ Part }, { [string]: Part }),
	read: (self: Request) -> string?,
	chunks: (self: Request) -> () -> string?,
	accepts: (self: Request, ...string) -> string?,
	is: (self: Request, contentType: string) -> boolean,
	isWebSocket: (self: Request) -> boolean,
	[string]: any,
}

--- Options of `res:cookie`.
export type CookieOptions = {
	maxAge: number?, -- seconds
	expires: number?, -- Unix time
	domain: string?,
	path: string?, -- default "/"
	secure: boolean?,
	httpOnly: boolean?, -- default true
	sameSite: ("Strict" | "Lax" | "None")?,
	partitioned: boolean?,
}

--- The response being built. Setters return the response, so they chain:
---
---     res:status(201):header("Location", "/items/7"):json(item)
export type Response = {
	statusCode: number,
	headers: Headers,
	sent: boolean, -- the head has been sent
	finished: boolean, -- the response is complete
	request: Request,

	status: (self: Response, code: number) -> Response,
	header: (self: Response, name: string, value: any) -> Response,
	set: (self: Response, name: string, value: any) -> Response,
	get: (self: Response, name: string) -> string?,
	type: (self: Response, contentType: string) -> Response,
	cookie: (self: Response, name: string, value: string, options: CookieOptions?) -> Response,
	clearCookie: (self: Response, name: string, options: CookieOptions?) -> Response,

	send: (self: Response, body: any?) -> boolean,
	json: (self: Response, value: any, status: number?) -> boolean,
	text: (self: Response, text: string, status: number?) -> boolean,
	html: (self: Response, html: string, status: number?) -> boolean,
	redirect: (self: Response, location: string, status: number?) -> boolean,
	file: (self: Response, path: string, options: { [string]: any }?) -> boolean,
	error: (self: Response, status: number, message: string?) -> boolean,

	write: (self: Response, chunk: string) -> (boolean, string?),
	finish: (self: Response, chunk: string?) -> boolean,
	sse: (self: Response, options: { [string]: any }?) -> any,
	[string]: any,
}

--- Called with no argument to go on to the next matching handler, or with an error to skip
--- to the error handler.
export type Next = (err: any?) -> ()

--- Route handlers and middleware share one shape. A handler may answer with `res`, or
--- return a value:
---
--- * a string: sent as text/html when it looks like HTML, text/plain otherwise
--- * a table: sent as JSON
--- * a number: the status; a second value is the body
export type Handler = (req: Request, res: Response, next: Next) -> ...any

export type ErrorHandler = (err: any, req: Request, res: Response) -> ()

--- Options of `listen`.
export type ListenOptions = {
	port: number?, -- default 8080; 0 picks a free port
	host: string?, -- default all interfaces; "127.0.0.1" for local only
	unix: string?, -- listen on a Unix socket instead
	tls: ({ cert: string?, key: string?, certPem: string?, keyPem: string?, [string]: any } | any)?,
	backlog: number?,
	reusePort: boolean?,
	family: ("any" | "ipv4" | "ipv6")?,
	timeout: number?, -- seconds for each read or write (default 30)
	keepAliveTimeout: number?, -- seconds an idle connection is kept open (default 5)
	maxHeadSize: number?, -- default 64 KiB
	maxHeaders: number?, -- default 100
	maxBodySize: number?, -- default 10 MiB
	maxConnections: number?, -- default unlimited
	trustProxy: boolean?, -- honor X-Forwarded-For/-Proto/-Host
	serverHeader: (string | false)?, -- the Server header (default none)
	onListen: ((server: Server) -> ())?,
}

--- A running server.
export type Server = {
	host: string,
	port: number,
	url: string, -- "http://localhost:8080"
	closed: boolean,
	connections: (self: Server) -> number,
	close: (self: Server, options: { graceful: boolean?, timeout: number? }?) -> (),
	wait: (self: Server) -> (),
	[string]: any,
}

--- Options of the static file handler.
export type StaticOptions = {
	index: ({ string } | string | false)?, -- default { "index.html", "index.htm" }
	extensions: { string }?, -- tried for extension-less paths: { "html" } serves /about from about.html
	listing: boolean?, -- list directories without an index (default false)
	dotfiles: ("ignore" | "allow" | "deny")?, -- default "ignore" (404)
	spa: (string | boolean)?, -- serve this file (true: index.html) for unknown paths
	maxAge: number?, -- Cache-Control max-age in seconds (default 0)
	immutable: boolean?,
	cacheControl: (string | false)?, -- full Cache-Control value, overrides maxAge
	etag: boolean?, -- default true
	lastModified: boolean?, -- default true
	ranges: boolean?, -- byte ranges (default true)
	fallthrough: boolean?, -- call next() when nothing is found (default true)
	redirect: boolean?, -- redirect directories to a trailing slash (default true)
	headers: ((res: Response, path: string, stat: any) -> ())?,
	transform: ((content: string, path: string, req: Request) -> string)?, -- e.g. inject a script into HTML
	transformMatch: string?, -- only transform files whose path matches this Lua pattern ("%.html?$")
	-- Where files come from: a folder (the default), or functions, e.g. to serve
	-- assets packed with @sonata/pocket.
	read: ((path: string) -> string?)?,
	stat: ((path: string) -> { kind: string, size: number, modified: number }?)?,
	list: ((path: string) -> { string }?)?,
}

export type Router = {
	use: (self: Router, ...any) -> Router,
	get: (self: Router, path: string, ...Handler) -> Router,
	post: (self: Router, path: string, ...Handler) -> Router,
	put: (self: Router, path: string, ...Handler) -> Router,
	patch: (self: Router, path: string, ...Handler) -> Router,
	delete: (self: Router, path: string, ...Handler) -> Router,
	head: (self: Router, path: string, ...Handler) -> Router,
	options: (self: Router, path: string, ...Handler) -> Router,
	all: (self: Router, path: string, ...Handler) -> Router,
	route: (self: Router, method: string | { string }, path: string, ...Handler) -> Router,
	mount: (self: Router, prefix: string, router: Router) -> Router,
	group: (self: Router, prefix: string, build: (router: Router) -> ()) -> Router,
	static: (self: Router, prefix: string, root: string, options: StaticOptions?) -> Router,
	ws: (self: Router, path: string, handler: (ws: any, req: Request) -> (), options: { [string]: any }?) -> Router,
	sse: (self: Router, path: string, handler: (stream: any, req: Request) -> (), options: { [string]: any }?) -> Router,
	handle: (self: Router, req: Request, res: Response, done: Next) -> (),
	[string]: any,
}

export type AppOptions = ListenOptions & {
	logErrors: boolean?, -- print unhandled errors with their traceback (default true)
	exposeErrors: boolean?, -- send error messages of 500s to clients (default false)
}

export type App = Router & {
	locals: { [string]: any },
	options: AppOptions,
	listen: (self: App, port: (number | ListenOptions)?, host: string?) -> (Server?, string?),
	onError: (self: App, handler: ErrorHandler) -> App,
	notFound: (self: App, handler: Handler) -> App,
	dispatch: (self: App, req: Request, res: Response) -> (),
}

return {}
