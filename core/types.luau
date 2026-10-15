--[[
	Types shared by every category of httpx.
]]

export type ErrorKind =
	"connect"
	| "dns"
	| "timeout"
	| "tls"
	| "closed"
	| "protocol"
	| "redirect"
	| "status"
	| "body"
	| "invalid"
	| "aborted"

--- A header value as accepted everywhere: one value, or several for repeated headers.
export type HeaderValue = string | number | { string }

--- Anything httpx accepts where headers are expected.
---
--- * a map: `{ ["content-type"] = "text/plain", accept = { "a", "b" } }`
--- * a list of pairs, kept in order: `{ { "Set-Cookie", "a=1" }, { "Set-Cookie", "b=2" } }`
--- * a `Headers` object
export type HeadersInit = { [string]: HeaderValue } | { { string } } | Headers

--- Case-insensitive, ordered, multi-valued headers. See `core/headers.luau`.
--- Indexing with a name reads the header: `headers["content-type"]`.
export type Headers = {
	get: (self: Headers, name: string) -> string?,
	getAll: (self: Headers, name: string) -> { string },
	has: (self: Headers, name: string) -> boolean,
	set: (self: Headers, name: string, value: HeaderValue) -> Headers,
	add: (self: Headers, name: string, value: HeaderValue) -> Headers,
	setDefault: (self: Headers, name: string, value: HeaderValue) -> Headers,
	delete: (self: Headers, name: string) -> Headers,
	merge: (self: Headers, other: HeadersInit?) -> Headers,
	clone: (self: Headers) -> Headers,
	list: (self: Headers) -> { { string } },
	map: (self: Headers) -> { [string]: string },
	names: (self: Headers) -> { string },
	count: (self: Headers) -> number,
	[string]: any,
}

--- Query parameters: a string, a map (values may be lists, numbers or booleans), or a
--- list of pairs.
export type Query = string | { [string]: any } | { { string } }

--- A parsed URL, as `@sonata/net` returns it.
export type Url = {
	scheme: string?,
	username: string?,
	password: string?,
	host: string?,
	port: number?,
	path: string?,
	query: string?,
	fragment: string?,
}

--- One part of a multipart body.
export type Part = {
	name: string?,
	value: string,
	filename: string?,
	contentType: string?,
	headers: { [string]: string }?,
}

--- A multipart body: a list of parts, or a map of field name to value, where a value is a
--- string, a number, a `Part`, or a `{ file = "path" }` table to upload a file.
export type MultipartInit = { Part } | { [string]: any }

--- A body that is produced piece by piece: called repeatedly, returns `nil` at the end.
export type BodyStream = () -> string?

--- An encoded body, ready to be written to a socket.
export type Body = {
	data: string?, -- the whole body, when it is known up front
	stream: BodyStream?, -- or a producer of chunks
	length: number?, -- the length, when known (always set with `data`)
	contentType: string?, -- the Content-Type that goes with it
	replayable: boolean, -- whether it can be sent again (for redirects and retries)
}

--- Reads an HTTP body from a socket. See `core/io.luau`.
export type BodyReader = {
	read: (self: BodyReader) -> (string?, string?),
	readAll: (self: BodyReader, max: number?) -> (string?, string?),
	drain: (self: BodyReader, max: number?) -> boolean,
	isDone: (self: BodyReader) -> boolean,
	trailers: (self: BodyReader) -> { [string]: string }?,
	received: number, -- bytes of body delivered so far (after decoding)
	length: number?, -- the Content-Length, when given
}

--- A cookie as stored in a `CookieJar`.
export type Cookie = {
	name: string,
	value: string,
	domain: string,
	path: string,
	hostOnly: boolean,
	secure: boolean,
	httpOnly: boolean,
	sameSite: string?,
	expires: number?, -- Unix time; nil for session cookies
	created: number,
	seq: number?, -- creation order, for cookies created in the same second
}

export type CookieJar = {
	store: (self: CookieJar, url: string, setCookie: string | { string }) -> (),
	header: (self: CookieJar, url: string) -> string?,
	get: (self: CookieJar, name: string, url: string?) -> Cookie?,
	set: (self: CookieJar, cookie: { [string]: any }) -> (),
	remove: (self: CookieJar, name: string, domain: string?, path: string?) -> (),
	all: (self: CookieJar) -> { Cookie },
	clear: (self: CookieJar) -> (),
	save: (self: CookieJar, file: string) -> (),
	load: (self: CookieJar, file: string) -> (),
	toJSON: (self: CookieJar) -> string,
	[string]: any,
}

--- TLS settings accepted where `@sonata/net` accepts them: `true`, a `TlsOptions` table or a
--- TLS context.
export type Tls = boolean | { [string]: any } | any

return {}
