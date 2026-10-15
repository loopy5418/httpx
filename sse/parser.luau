--[[
	An incremental parser for the text/event-stream format (the WHATWG EventSource rules).

	    local p = parser.new()
	    for _, event in p:push("event: ping\ndata: 1\n\n") do
	        print(event.event, event.data) --> ping 1
	    end
]]

local types = require("./types")

export type Event = types.Event

local Parser = {}
Parser.__index = Parser

local parser = {}

function parser.new(): types.Parser
	return setmetatable({
		_buffer = "",
		_data = {},
		_event = nil,
		_id = nil,
		lastEventId = nil,
		retry = nil,
	}, Parser) :: any
end

function Parser._line(self: any, line: string, out: { Event })
	if line == "" then
		-- Blank line: dispatch the event, if it has data.
		if #self._data > 0 then
			table.insert(out, {
				event = self._event or "message",
				data = table.concat(self._data, "\n"),
				id = self.lastEventId,
				retry = self.retry,
			})
		end
		self._data = {}
		self._event = nil
		return
	end
	if string.sub(line, 1, 1) == ":" then
		return -- a comment
	end
	local field, value = string.match(line, "^([^:]*):(.*)$")
	if field == nil then
		field, value = line, ""
	end
	assert(field ~= nil and value ~= nil)
	if string.sub(value, 1, 1) == " " then
		value = string.sub(value, 2)
	end
	if field == "data" then
		table.insert(self._data, value)
	elseif field == "event" then
		self._event = value
	elseif field == "id" then
		if not string.find(value, "\0", 1, true) then
			self.lastEventId = value
		end
	elseif field == "retry" then
		if string.match(value, "^%d+$") then
			self.retry = tonumber(value)
		end
	end
end

--- Feeds a piece of the stream and returns the events it completed.
function Parser.push(self: any, chunk: string): { Event }
	local out: { Event } = {}
	local buffer = self._buffer .. chunk
	local start = 1
	while true do
		local nl = string.find(buffer, "[\r\n]", start)
		if nl == nil then
			break
		end
		local ch = string.sub(buffer, nl, nl)
		if ch == "\r" and nl == #buffer then
			-- A "\r" at the very end may be the first half of "\r\n": wait for more.
			break
		end
		self:_line(string.sub(buffer, start, nl - 1), out)
		if ch == "\r" and string.sub(buffer, nl + 1, nl + 1) == "\n" then
			start = nl + 2
		else
			start = nl + 1
		end
	end
	self._buffer = string.sub(buffer, start)
	return out
end

--- Ends the stream. A last event without a trailing blank line is dropped, as browsers do.
function Parser.finish(self: any): { Event }
	self._buffer = ""
	self._data = {}
	self._event = nil
	return {}
end

return parser
