--[[
	httpx/sse: server-sent events, both ends.

	Server:

	    local feed = sse.hub()
	    app:sse("/events", function(stream, req)
	        feed:add(stream)              -- stays open until the client leaves
	    end)
	    feed:broadcast({ price = 42 }, "update")

	Client:

	    for event in sse.connect("http://localhost:8080/events"):events() do
	        print(event.event, event.data)
	    end
]]

local types = require("./types")
local parser = require("./parser")
local stream = require("./stream")
local client = require("./client")
local hub = require("../core/hub")

export type Event = types.Event
export type Parser = types.Parser
export type SendOptions = types.SendOptions
export type Stream = types.Stream
export type StreamOptions = types.StreamOptions
export type Source = types.Source
export type SourceOptions = types.SourceOptions

local sse = {}

--- Connects to an event stream (client side). See `sse/client.luau`.
sse.connect = client.connect

--- Opens an event stream on a server response: `sse.open(req, res)` (same as `res:sse()`).
sse.open = stream.open

--- Formats one event as text/event-stream.
sse.format = stream.format

--- An incremental text/event-stream parser.
sse.parser = parser.new

--- A set of streams to broadcast to: `hub:broadcast(data, eventOrOptions)`.
sse.hub = hub.new

return sse
