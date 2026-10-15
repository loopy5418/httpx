--[[
	Types of WebSocket connections.
]]

local coreTypes = require("../core/types")

export type Headers = coreTypes.Headers
export type HeadersInit = coreTypes.HeadersInit

--- "text" or "binary".
export type MessageKind = "text" | "binary"

export type State = "open" | "closing" | "closed"

--- Options shared by both ends.
export type ConnectionOptions = {
	maxMessageSize: number?, -- largest message accepted, in bytes (default 16 MiB)
	pingInterval: number?, -- send a ping this often, in seconds (default: never)
	pingTimeout: number?, -- close if no pong arrives this long after a ping (default 20)
	autoPong: boolean?, -- answer pings automatically (default true)
	closeTimeout: number?, -- seconds to wait for the peer's close frame (default 5)
}

--- Options of `websocket.connect` (client).
export type ConnectOptions = ConnectionOptions & {
	headers: HeadersInit?,
	protocols: (string | { string })?, -- subprotocols to offer
	origin: string?,
	query: { [string]: any }?,
	timeout: number?, -- seconds for connecting and the handshake (default 30)
	tls: any?,
	insecure: boolean?,
	proxy: (string | { [string]: any })?,
	bearer: string?,
	cookies: any?, -- a CookieJar to send cookies from
}

--- Options of `websocket.accept` and `app:ws` (server).
export type AcceptOptions = ConnectionOptions & {
	-- Subprotocols this server speaks, in order of preference, or a function picking one of
	-- those the client offered.
	protocols: ({ string } | ((offered: { string }, req: any) -> string?))?,
	headers: { [string]: string }?, -- extra headers for the 101 response
	-- Called before upgrading; return false (or a status code) to refuse.
	verify: ((req: any) -> (boolean | number))?,
}

export type WebSocket = {
	state: State,
	closed: boolean,
	closeCode: number?,
	closeReason: string?,
	protocol: string?, -- the agreed subprotocol
	isClient: boolean,
	url: string?, -- client side: the URL connected to
	request: any?, -- server side: the upgrade request
	headers: Headers?, -- client side: the handshake response headers
	locals: { [string]: any },

	send: (self: WebSocket, data: any, kind: MessageKind?) -> (boolean, string?),
	sendText: (self: WebSocket, text: string) -> (boolean, string?),
	sendBinary: (self: WebSocket, data: string | buffer) -> (boolean, string?),
	sendJson: (self: WebSocket, value: any) -> (boolean, string?),
	ping: (self: WebSocket, payload: string?) -> (boolean, string?),
	pong: (self: WebSocket, payload: string?) -> (boolean, string?),
	recv: (self: WebSocket, timeout: number?) -> (string?, MessageKind | string | nil),
	recvJson: (self: WebSocket, timeout: number?) -> (any, string?),
	messages: (self: WebSocket) -> () -> (string?, MessageKind?),
	on: (self: WebSocket, event: string, handler: (...any) -> ()) -> WebSocket,
	run: (self: WebSocket) -> (),
	start: (self: WebSocket) -> WebSocket,
	wait: (self: WebSocket, timeout: number?) -> boolean,
	close: (self: WebSocket, code: number?, reason: string?) -> (),
	[string]: any,
}

return {}
