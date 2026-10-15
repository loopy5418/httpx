--[[
	HTTP errors raised inside handlers. The app turns them into responses:

	    app:get("/admin", function(req, res)
	        if not req.locals.user then
	            server.abort(401, "log in first")
	        end
	        ...
	    end)
]]

local net = require("@sonata/net")

export type HttpError = {
	status: number,
	message: string,
	headers: { [string]: string }?,
	expose: boolean, -- whether the message may be shown to the client (true below 500)
	cause: any?,
}

local HttpError = {}
HttpError.__index = HttpError
HttpError.__tostring = function(self)
	return `HttpError {self.status}: {self.message}`
end

local M = {}

--- Creates an HTTP error. `message` defaults to the status text.
function M.new(status: number, message: string?, headers: { [string]: string }?): HttpError
	return setmetatable({
		status = status,
		message = message or net.http.statusText(status) or "Error",
		headers = headers,
		expose = status < 500,
	}, HttpError) :: any
end

--- Whether a value is an HTTP error.
function M.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == HttpError
end

--- Raises an HTTP error, ending the handler. The app answers with that status.
function M.abort(status: number, message: string?, headers: { [string]: string }?): never
	error(M.new(status, message, headers), 0)
end

return M
