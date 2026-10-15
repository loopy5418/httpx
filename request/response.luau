--[[
	The response of the HTTP client.

	    local res = assert(httpx.get("https://example.com"))
	    print(res.status, res.ok, res.headers["content-type"])
	    print(res.body)                 -- buffered by default
	    local data = res:json()

	With `stream = true` the body is not read up front:

	    local res = assert(httpx.get(url, { stream = true }))
	    for chunk in res:chunks() do ... end
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local fs = require("@sonata/fs")
local types = require("./types")
local errors = require("../core/errors")
local sseParser = require("../sse/parser")

export type Response = types.Response

local Response = {}
Response.__index = Response

local M = {}

export type Internal = {
	status: number,
	reason: string?,
	version: string?,
	headers: types.Headers,
	url: string,
	method: string,
	request: types.Request,
	elapsed: number,
	reader: any?, -- a BodyReader
	release: ((reusable: boolean) -> ())?, -- gives the connection back (or closes it)
	socket: any?,
}

function M.new(init: Internal): Response
	local self = setmetatable({
		status = init.status,
		reason = init.reason or net.http.statusText(init.status) or "",
		ok = init.status >= 200 and init.status < 300,
		headers = init.headers,
		url = init.url,
		method = init.method,
		version = init.version or "1.1",
		redirected = false,
		redirects = {},
		elapsed = init.elapsed,
		request = init.request,
		body = nil,
		socket = init.socket,
		_reader = init.reader,
		_release = init.release,
		_error = nil,
		_bufferedRead = false,
	}, Response)
	if init.reader == nil then
		self.body = ""
	end
	return self :: any
end

-- Called once the body has been read completely or abandoned.
function Response._finish(self: any, reusable: boolean)
	local release = self._release
	if release then
		self._release = nil
		release(reusable)
	end
end

--- Reads the whole body now (used for non-streamed responses). Returns `true` or `nil, err`.
function Response._buffer(self: any): (boolean?, string?)
	if self.body ~= nil then
		return true, nil
	end
	local reader = self._reader
	local data, err = reader:readAll()
	if data == nil then
		self._error = err
		self:_finish(false)
		return nil, err
	end
	self.body = data
	self:_finish(reader:isDone())
	return true, nil
end

--- The next piece of the body, or `nil` at the end (or `nil, err`). For a buffered response
--- the first call returns the whole body.
function Response.read(self: any): (string?, string?)
	if self.body ~= nil then
		if self._bufferedRead then
			return nil, nil
		end
		self._bufferedRead = true
		if self.body == "" then
			return nil, nil
		end
		return self.body, nil
	end
	local reader = self._reader
	if reader == nil then
		return nil, nil
	end
	local chunk, err = reader:read()
	if err then
		self._error = err
		self:_finish(false)
		return nil, err
	end
	if chunk == nil then
		self:_finish(true)
	end
	return chunk, nil
end

--- Iterates over the pieces of the body. A read error ends the loop; it is kept in
--- `res.error` afterwards.
function Response.chunks(self: any): () -> string?
	return function()
		local chunk, err = self:read()
		if err then
			self.error = err
		end
		return chunk
	end
end

--- Iterates over the lines of the body (without "\n" or "\r\n").
function Response.lines(self: any): () -> string?
	local pending = ""
	local finished = false
	return function(): string?
		while true do
			local nl = string.find(pending, "\n", 1, true)
			if nl then
				local line = string.sub(pending, 1, nl - 1)
				pending = string.sub(pending, nl + 1)
				return (string.gsub(line, "\r$", ""))
			end
			if finished then
				if pending ~= "" then
					local line = pending
					pending = ""
					return line
				end
				return nil
			end
			local chunk, err = self:read()
			if err then
				self.error = err
			end
			if chunk == nil then
				finished = true
			else
				pending ..= chunk
			end
		end
	end
end

--- Iterates over server-sent events: `for event in res:events() do print(event.data) end`.
function Response.events(self: any): () -> any
	local p = sseParser.new()
	local queue = {}
	local finished = false
	return function()
		while #queue == 0 do
			if finished then
				return nil
			end
			local chunk, err = self:read()
			if err then
				self.error = err
			end
			if chunk == nil then
				finished = true
				p:finish()
			else
				for _, event in p:push(chunk) do
					table.insert(queue, event)
				end
			end
		end
		return table.remove(queue, 1)
	end
end

--- The whole body as a string (reading it now for a streamed response).
function Response.text(self: any): (string?, string?)
	if self.body == nil then
		local ok, err = self:_buffer()
		if not ok then
			return nil, err
		end
	end
	return self.body, nil
end

--- The body decoded as JSON, or `nil, err` if it isn't valid JSON.
function Response.json(self: any): (any, string?)
	local text, err = self:text()
	if text == nil then
		return nil, err
	end
	local ok, value = pcall(json.decode, text)
	if not ok then
		return nil, errors.new("body", `invalid JSON: {value}`)
	end
	return value, nil
end

--- The body decoded as application/x-www-form-urlencoded.
function Response.form(self: any): ({ [string]: string }?, string?)
	local text, err = self:text()
	if text == nil then
		return nil, err
	end
	local map = net.url.parseQuery(text)
	return map, nil
end

--- A header of the response.
function Response.header(self: any, name: string): string?
	return self.headers:get(name)
end

--- Writes the body to a file, streaming it. Returns the number of bytes written. The file is
--- written to `<file>.part` first and renamed once complete.
function Response.save(self: any, file: string): (number?, string?)
	local temp = file .. ".part"
	local written = 0
	local ok, err = pcall(function()
		fs.writeFile(temp, "")
		while true do
			local chunk, readErr = self:read()
			if readErr then
				error(readErr, 0)
			end
			if chunk == nil then
				break
			end
			fs.appendFile(temp, chunk)
			written += #chunk
		end
		fs.move(temp, file)
	end)
	if not ok then
		pcall(fs.removeFile, temp)
		return nil, if errors.kind(err) then err else errors.new("body", `saving to {file}: {err}`)
	end
	return written, nil
end

--- Stops reading the body and releases the connection. Safe to call more than once.
function Response.close(self: any)
	if self._release then
		local reader = self._reader
		-- A small rest of body is read so the connection can be reused; a big one isn't.
		local reusable = reader ~= nil and (reader:isDone() or reader:drain(64 * 1024))
		self:_finish(reusable)
	end
end

--- Raises an error unless the status is 2xx. Returns the response, so it chains:
---
---     local data = assert(httpx.get(url)):raiseForStatus():json()
function Response.raiseForStatus(self: any): Response
	if not self.ok then
		error(errors.new("status", `{self.status} {self.reason} ({self.method} {self.url})`), 2)
	end
	return self
end

Response.__tostring = function(self)
	return `Response({self.status} {self.reason}, {self.method} {self.url})`
end

M.Response = Response

return M
