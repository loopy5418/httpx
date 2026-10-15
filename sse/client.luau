--[[
	Client side of server-sent events, like the browser's EventSource: connects, parses
	events, and reconnects (with Last-Event-ID) when the connection drops.

	    local source = sse.connect("https://example.com/events")
	    for event in source:events() do
	        print(event.event, event.data)
	    end

	    -- or with handlers
	    source:on("message", function(e) print(e.data) end)
	    source:on("tick", function(e) print("tick", e.data) end)
	    source:run()
]]

local task = require("@sonata/task")
local types = require("./types")
local parserLib = require("./parser")
local errors = require("../core/errors")
local requestLib = require("../request")

export type Source = types.Source
export type SourceOptions = types.SourceOptions
export type Event = types.Event

local Source = {}
Source.__index = Source

local client = {}

-- Request options that are Source options, not request options.
local OWN = { reconnect = true, retryDelay = true, maxRetries = true, lastEventId = true, client = true }

function Source._open(self: any): (boolean, string?, boolean?)
	local opts = self._options
	local headers: { [string]: string } = {}
	if opts.headers then
		for k, v in opts.headers do
			headers[k] = v
		end
	end
	headers["Accept"] = "text/event-stream"
	headers["Cache-Control"] = "no-cache"
	if self.lastEventId then
		headers["Last-Event-ID"] = self.lastEventId
	end
	local requestOptions: { [string]: any } = {}
	for k, v in opts do
		if not OWN[k] and k ~= "headers" then
			requestOptions[k] = v
		end
	end
	requestOptions.headers = headers
	requestOptions.stream = true
	if requestOptions.timeout == nil then
		requestOptions.timeout = false -- streams are quiet for long stretches
	end
	local method = requestOptions.method or "GET"
	local http = opts.client or requestLib.default
	local res, err = http:request(method, self.url, requestOptions)
	if res == nil then
		return false, err, true
	end
	if res.status == 204 then
		res:close()
		return false, errors.new("closed", "the server asked not to reconnect (204)"), false
	end
	if not res.ok then
		res:close()
		return false, errors.new("status", `{res.status} {res.reason}`), false
	end
	local contentType = res.headers:get("content-type") or ""
	if not string.find(string.lower(contentType), "text/event-stream", 1, true) then
		res:close()
		return false, errors.new("protocol", `expected text/event-stream, got '{contentType}'`), false
	end
	self.response = res
	self._parser = parserLib.new()
	self._parser.lastEventId = self.lastEventId
	return true, nil, nil
end

--- The next event, reconnecting as needed. `nil` once the source is closed, or `nil, err`
--- when it gives up.
function Source.next(self: any): (Event?, string?)
	local opts = self._options
	while true do
		if #self._queue > 0 then
			return table.remove(self._queue, 1), nil
		end
		if self.closed then
			return nil, nil
		end
		if self.response == nil then
			local ok, err, retriable = self:_open()
			if not ok then
				self._failures += 1
				local gaveUp = opts.reconnect == false
					or not retriable
					or (opts.maxRetries ~= nil and self._failures > opts.maxRetries)
				if gaveUp then
					self.closed = true
					self.error = err
					return nil, err
				end
				task.wait(self._delay)
				continue
			end
			self._failures = 0
		end
		local chunk, readErr = self.response:read()
		if chunk == nil then
			-- The stream ended (or broke): reconnect after the delay.
			self.response:close()
			self.response = nil
			if opts.reconnect == false then
				self.closed = true
				self.error = readErr
				return nil, readErr
			end
			task.wait(self._delay)
		else
			for _, event in self._parser:push(chunk) do
				table.insert(self._queue, event)
			end
			if self._parser.lastEventId then
				self.lastEventId = self._parser.lastEventId
			end
			if self._parser.retry then
				self._delay = self._parser.retry / 1000
			end
		end
	end
end

--- Iterates over events until the source is closed.
function Source.events(self: any): () -> Event?
	return function()
		return (self:next())
	end
end

--- Adds a handler for an event type ("message" for unnamed events, "*" for all).
function Source.on(self: any, event: string, handler: (Event) -> ()): Source
	local list = self._handlers[event]
	if list == nil then
		list = {}
		self._handlers[event] = list
	end
	table.insert(list, handler)
	return self
end

--- Reads events and calls the handlers until the source is closed. Returns the error that
--- ended it, if any.
function Source.run(self: any): string?
	while true do
		local event, err = self:next()
		if event == nil then
			return err
		end
		for _, key in { event.event, "*" } do
			local list = self._handlers[key]
			if list then
				for _, handler in list do
					local ok, handlerErr = pcall(handler, event)
					if not ok then
						print(`httpx: error in an event handler: {handlerErr}`)
					end
				end
			end
		end
	end
end

--- Starts `run` in a new task and returns the source.
function Source.start(self: any): Source
	task.spawn(function()
		self:run()
	end)
	return self
end

--- Stops listening.
function Source.close(self: any)
	self.closed = true
	if self.response then
		-- Drop the connection: draining an endless stream would never finish.
		self.response:_finish(false)
		self.response = nil
	end
end

--- Creates an event source. Nothing is sent until the first event is asked for.
function client.connect(url: string, options: SourceOptions?): Source
	local opts = options or {}
	return setmetatable({
		url = url,
		lastEventId = opts.lastEventId,
		closed = false,
		response = nil,
		error = nil,
		_options = opts,
		_queue = {},
		_handlers = {},
		_failures = 0,
		_delay = opts.retryDelay or 3,
		_parser = nil,
	}, Source) :: any
end

return client
