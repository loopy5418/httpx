--[[
	Error values shared by every category.

	httpx follows Sonata's convention: failures caused by the outside world (refused connections,
	timeouts, bad responses, ...) never raise. The call returns `nil, message`, so `assert(...)`
	turns a failure into an error when the program should stop.

	Every message starts with its kind: "timeout: reading the response timed out". Use
	`errors.kind(message)` to branch on it.
]]

local types = require("./types")

export type Kind = types.ErrorKind

local errors = {}

local KINDS: { [string]: boolean } = {
	connect = true, -- the connection could not be opened (refused, unreachable, proxy, ...)
	dns = true, -- the host name could not be resolved
	timeout = true, -- a wait took longer than allowed
	tls = true, -- the TLS handshake or certificate check failed
	closed = true, -- the peer closed the connection early
	protocol = true, -- the peer sent something that isn't valid HTTP / WebSocket
	redirect = true, -- too many redirects, or a redirect that can't be followed
	status = true, -- the response has an error status (only with `failOnStatus`)
	body = true, -- the body is too large, truncated or can't be decoded
	invalid = true, -- the request itself is invalid (bad URL, unsupported scheme, ...)
	aborted = true, -- the operation was cancelled
}

--- Builds an error message of the given kind.
function errors.new(kind: Kind, message: string): string
	return `{kind}: {message}`
end

--- The kind of an error message produced by httpx, or `nil` for other messages.
function errors.kind(message: any): Kind?
	if type(message) ~= "string" then
		return nil
	end
	local kind = string.match(message, "^(%a+): ")
	if kind and KINDS[kind] then
		return kind :: Kind
	end
	return nil
end

--- Turns an error message from `@sonata/net` into an httpx error of the right kind.
function errors.fromNet(message: string?, context: string?): string
	local text = message or "unknown error"
	local lower = string.lower(text)
	local kind: Kind = "connect"
	if string.find(lower, "timed out", 1, true) or string.find(lower, "timeout", 1, true) then
		kind = "timeout"
	elseif
		string.find(lower, "name or service", 1, true)
		or string.find(lower, "resolve", 1, true)
		or string.find(lower, "nodename", 1, true)
		or string.find(lower, "no address", 1, true)
		or string.find(lower, "getaddrinfo", 1, true)
	then
		kind = "dns"
	elseif
		string.find(lower, "tls", 1, true)
		or string.find(lower, "ssl", 1, true)
		or string.find(lower, "certificate", 1, true)
		or string.find(lower, "handshake", 1, true)
	then
		kind = "tls"
	elseif text == "closed" or string.find(lower, "reset", 1, true) or string.find(lower, "broken pipe", 1, true) then
		kind = "closed"
	end
	if context then
		return errors.new(kind, `{context}: {text}`)
	end
	return errors.new(kind, text)
end

--- Whether an error is worth retrying: the request may succeed if sent again.
function errors.isTransient(message: any): boolean
	local kind = errors.kind(message)
	return kind == "connect" or kind == "timeout" or kind == "closed" or kind == "dns"
end

return errors
