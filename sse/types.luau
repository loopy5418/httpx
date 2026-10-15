--[[
	Types of server-sent events (text/event-stream).
]]

--- One event.
export type Event = {
	event: string, -- the event type ("message" when the stream didn't name one)
	data: string,
	id: string?, -- the last event ID seen so far
	retry: number?, -- the reconnection delay the server asked for, in milliseconds
}

export type Parser = {
	push: (self: Parser, chunk: string) -> { Event },
	finish: (self: Parser) -> { Event },
	lastEventId: string?,
	retry: number?,
}

--- What `Stream:send` accepts besides the data.
export type SendOptions = {
	event: string?,
	id: (string | number)?,
	retry: number?, -- milliseconds
}

--- The server side: an open event stream on a response.
export type Stream = {
	send: (self: Stream, data: any, options: (string | SendOptions)?) -> boolean,
	comment: (self: Stream, text: string?) -> boolean,
	close: (self: Stream) -> (),
	closed: boolean,
	lastEventId: string?, -- the Last-Event-ID the client reconnected with
	[string]: any,
}

export type StreamOptions = {
	keepAlive: number?, -- seconds between keep-alive comments (default 15, 0 = off)
	retry: number?, -- reconnection delay to suggest to clients, in milliseconds
	headers: { [string]: string }?,
}

--- The client side: a connection to an event stream that reconnects on its own.
export type Source = {
	url: string,
	lastEventId: string?,
	closed: boolean,
	next: (self: Source) -> (Event?, string?),
	events: (self: Source) -> () -> Event?,
	on: (self: Source, event: string, handler: (Event) -> ()) -> Source,
	run: (self: Source) -> (),
	close: (self: Source) -> (),
	[string]: any,
}

export type SourceOptions = {
	headers: { [string]: string }?,
	reconnect: boolean?, -- default true
	retryDelay: number?, -- seconds before reconnecting (default 3; the server may change it)
	maxRetries: number?, -- give up after this many failed reconnects in a row (default unlimited)
	lastEventId: string?,
	client: any?, -- an httpx client to use (default: the shared one)
	[string]: any, -- any other request option
}

return {}
