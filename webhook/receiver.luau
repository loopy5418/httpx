--[[
	Receiving webhooks: signature checks and a ready-made route handler.

	    app:post("/hooks/github", webhook.receiver({ secret = SECRET, scheme = "github" }, function(event)
	        print(event.type, event.data.repository.full_name)
	        return 204
	    end))

	Or check a signature inside your own handler:

	    local ok, err = webhook.verify(req, SECRET, "stripe")
]]

local net = require("@sonata/net")
local json = require("@sonata/json")
local types = require("./types")
local signatures = require("./signatures")
local headersLib = require("../core/headers")
local bodyLib = require("../core/body")
local httpErrors = require("../server/errors")

export type Event = types.Event
export type ReceiverOptions = types.ReceiverOptions

local receiver = {}

local TYPE_HEADERS = { "x-webhook-event", "x-github-event", "x-gitlab-event", "x-event-type", "x-event-key", "x-shopify-topic" }
local ID_HEADERS = { "x-webhook-id", "webhook-id", "svix-id", "x-github-delivery", "x-request-id" }

--- Checks a body's signature against raw headers. `secret` may be a list (key rotation): any
--- match is accepted.
function receiver.verifyRaw(
	headers: types.HeadersInit,
	body: string,
	secret: string | { string },
	scheme: types.SchemeSpec?,
	options: types.VerifyOptions?
): (boolean, string?)
	local h = headersLib.from(headers)
	local s = signatures.get(scheme)
	local secrets = if type(secret) == "table" then secret else { secret }
	local lastErr: string? = "no secret"
	for _, candidate in secrets do
		local ok, err = s.verify(h, body, candidate, options or {})
		if ok then
			return true, nil
		end
		lastErr = err
	end
	return false, lastErr
end

--- Checks the signature of a server request (reads its body).
function receiver.verify(req: any, secret: string | { string }, scheme: types.SchemeSpec?, options: types.VerifyOptions?): (boolean, string?)
	return receiver.verifyRaw(req.headers, req:text(), secret, scheme, options)
end

local function parseBody(body: string, contentType: string?, mode: string): any
	if mode == "text" or body == "" then
		return body
	end
	local lowerType = string.lower(contentType or "")
	if mode == "json" or (mode == "auto" and (bodyLib.isJson(lowerType) or string.match(body, "^%s*[%[{]"))) then
		local ok, value = pcall(json.decode, body)
		if ok then
			return value
		end
		if mode == "json" then
			httpErrors.abort(400, "invalid JSON payload")
		end
		return body
	end
	if mode == "form" or (mode == "auto" and string.find(lowerType, "x-www-form-urlencoded", 1, true)) then
		local map = net.url.parseQuery(body)
		-- Slack and others put JSON in a "payload" field.
		if mode == "auto" and type(map.payload) == "string" then
			local ok, value = pcall(json.decode, map.payload)
			if ok then
				return value
			end
		end
		return map
	end
	return body
end

--- Turns a received request into an Event (checking its signature when `options.secret` is
--- set). Raises 401 if the signature doesn't check out.
function receiver.parse(req: any, options: ReceiverOptions?): Event
	local opts = options or {}
	local body = req:text()
	local verified = false
	if opts.secret then
		local ok, err = receiver.verifyRaw(req.headers, body, opts.secret, opts.scheme, opts)
		if not ok then
			httpErrors.abort(401, `invalid webhook signature: {err}`)
		end
		verified = true
	end
	local data = parseBody(body, req.headers:get("content-type"), opts.parse or "auto")
	local eventType: string? = nil
	for _, name in TYPE_HEADERS do
		eventType = req.headers:get(name)
		if eventType then
			break
		end
	end
	if eventType == nil and type(data) == "table" then
		local candidate = data.type or data.event
		if type(candidate) == "string" then
			eventType = candidate
		end
	end
	local id: string? = nil
	for _, name in ID_HEADERS do
		id = req.headers:get(name)
		if id then
			break
		end
	end
	return {
		type = eventType,
		id = id,
		data = data,
		body = body,
		headers = req.headers,
		verified = verified,
	}
end

--- A route handler that parses (and verifies) incoming webhooks and calls
--- `handler(event, req, res)`. The handler may answer like any route handler; if it doesn't,
--- the sender gets 204 No Content.
function receiver.handler(options: ReceiverOptions?, handler: (event: Event, req: any, res: any) -> ...any)
	return function(req: any, res: any)
		local event = receiver.parse(req, options)
		local router = require("../server/router") :: any
		router.respondWith(res, handler(event, req, res))
		if not res.sent then
			res:status(204):send()
		end
	end
end

return receiver
