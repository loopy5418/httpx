--[[
	Server side of server-sent events: an open text/event-stream response.

	    app:get("/time", function(req, res)
	        local stream = res:sse()
	        while not stream.closed do
	            stream:send({ now = os.time() }, "tick")
	            task.wait(1)
	        end
	    end)
]]

local task = require("@sonata/task")
local json = require("@sonata/json")
local types = require("./types")

export type Stream = types.Stream
export type StreamOptions = types.StreamOptions

local Stream = {}
Stream.__index = Stream

local stream = {}

local function field(name: string, value: string): string
	-- Values can't contain line breaks: each line becomes its own field.
	local out = {}
	for line in string.gmatch(string.gsub(value, "\r\n?", "\n") .. "\n", "([^\n]*)\n") do
		table.insert(out, `{name}: {line}\n`)
	end
	return table.concat(out)
end

--- Formats one event as text/event-stream.
function stream.format(data: any, options: (string | types.SendOptions)?): string
	local opts: types.SendOptions = if type(options) == "string" then { event = options } else (options or {})
	local parts = {}
	if opts.event then
		table.insert(parts, field("event", opts.event))
	end
	if opts.id ~= nil then
		table.insert(parts, field("id", tostring(opts.id)))
	end
	if opts.retry then
		table.insert(parts, `retry: {math.floor(opts.retry)}\n`)
	end
	local text = if type(data) == "table" then json.encode(data) else tostring(data)
	table.insert(parts, field("data", text))
	table.insert(parts, "\n")
	return table.concat(parts)
end

function Stream._write(self: any, text: string): boolean
	if self.closed then
		return false
	end
	local ok = self._res:write(text)
	if not ok then
		self:_markClosed()
		return false
	end
	return true
end

function Stream._markClosed(self: any)
	if self.closed then
		return
	end
	self.closed = true
	for _, thread in { self._keepAliveTask, self._watchTask } do
		if thread and thread ~= task.running() then
			pcall(task.cancel, thread)
		end
	end
	self._closedEvent:set()
	for _, fn in self._onClose do
		pcall(fn)
	end
end

--- Sends an event. `data` tables are sent as JSON; `options` is the event name or
--- `{ event, id, retry }`. Returns `false` once the client is gone.
function Stream.send(self: any, data: any, options: (string | types.SendOptions)?): boolean
	return self:_write(stream.format(data, options))
end

--- Sends a comment (ignored by clients; keeps proxies from closing an idle stream).
function Stream.comment(self: any, text: string?): boolean
	return self:_write(`: {text or ""}\n\n`)
end

--- Calls `fn` when the stream closes (client gone, or `close()`).
function Stream.onClose(self: any, fn: () -> ()): Stream
	table.insert(self._onClose, fn)
	return self
end

--- Waits until the stream is closed. Lets a handler stay alive while other tasks send.
function Stream.wait(self: any, timeout: number?): boolean
	return self._closedEvent:wait(timeout)
end

--- Ends the stream.
function Stream.close(self: any)
	if self.closed then
		return
	end
	self:_markClosed()
	self._res:finish()
end

--- Opens an event stream on a server response.
function stream.open(req: any, res: any, options: StreamOptions?): Stream
	local opts = options or {}
	res:status(200)
	res:header("Content-Type", "text/event-stream; charset=utf-8")
	res:header("Cache-Control", "no-cache")
	res:header("X-Accel-Buffering", "no") -- tell nginx not to buffer
	if opts.headers then
		for name, value in opts.headers do
			res:header(name, value)
		end
	end
	local self = setmetatable({
		closed = false,
		lastEventId = req.headers:get("last-event-id"),
		request = req,
		_res = res,
		_closedEvent = task.event(),
		_onClose = {},
		_keepAliveTask = nil,
		_watchTask = nil,
	}, Stream)

	-- The stream may stay quiet for a long time: no per-read timeout.
	local sock = res._sock
	sock:setTimeout(nil)

	-- Start the response right away so the client sees the stream open.
	self:_write(if opts.retry then `retry: {math.floor(opts.retry)}\n\n` else ": open\n\n")

	-- Notice when the client goes away: it never sends anything on this connection.
	self._watchTask = task.spawn(function()
		while not self.closed do
			local data, err = sock:recv(1024)
			if data == "" or (data == nil and err ~= "timed out") then
				self:_markClosed()
				break
			end
		end
	end)

	local interval = opts.keepAlive or 15
	if interval > 0 then
		self._keepAliveTask = task.spawn(function()
			while not self.closed do
				task.wait(interval)
				if not self.closed then
					self:comment("keep-alive")
				end
			end
		end)
	end

	-- When the handler returns, the server finishes the response; mark the stream closed.
	res:onFinish(function()
		self:_markClosed()
	end)
	return self :: any
end

return stream
