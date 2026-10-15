--[[
	Sending webhooks: one call, or a builder for anything more specific.

	    webhook.send("https://example.com/hooks", { event = "order.paid", id = 42 })

	    webhook.new("https://example.com/hooks")
	        :secret(os.getenv("HOOK_SECRET"), "github")
	        :event("order.paid")
	        :header("X-Tenant", "acme")
	        :json({ id = 42 })
	        :retry(5)
	        :send()
]]

local crypto = require("@sonata/crypto")
local json = require("@sonata/json")
local types = require("./types")
local signatures = require("./signatures")
local requestLib = require("../request")
local urlLib = require("../core/url")
local headersLib = require("../core/headers")

export type Webhook = types.Webhook
export type SendOptions = types.SendOptions
export type Prepared = types.Prepared

local Webhook = {}
Webhook.__index = Webhook

local builder = {}

-- Fields of SendOptions that are not request options.
local OWN = { secret = true, scheme = true, event = true, id = true, client = true, payload = true }

--- Creates a webhook builder for `url`. `options` sets anything up front.
function builder.new(url: string, options: SendOptions?): Webhook
	local opts: { [string]: any } = table.clone(options or {})
	local self = setmetatable({
		url = url,
		_method = opts.method or "POST",
		_headers = headersLib.new(opts.headers),
		_query = opts.query,
		_body = nil :: string?,
		_contentType = nil :: string?,
		_secret = opts.secret,
		_scheme = opts.scheme,
		_event = opts.event,
		_id = opts.id,
		_options = opts,
	}, Webhook)
	if opts.json ~= nil then
		self:json(opts.json)
	elseif opts.form ~= nil then
		self:form(opts.form)
	elseif type(opts.body) == "string" then
		self:body(opts.body)
	end
	if opts.retry == nil then
		opts.retry = { limit = 3, methods = { "POST", "PUT", "PATCH", "DELETE", "GET" } }
	end
	return self :: any
end

function Webhook.method(self: any, method: string): Webhook
	self._method = string.upper(method)
	return self
end

function Webhook.header(self: any, name: string, value: string): Webhook
	self._headers:set(name, value)
	return self
end

function Webhook.headers(self: any, headers: { [string]: string }): Webhook
	self._headers:merge(headers)
	return self
end

function Webhook.query(self: any, query: { [string]: any }): Webhook
	self._query = query
	return self
end

--- Sets a JSON body.
function Webhook.json(self: any, value: any): Webhook
	self._body = json.encode(value)
	self._contentType = "application/json"
	return self
end

--- Sets a raw body.
function Webhook.body(self: any, body: string, contentType: string?): Webhook
	self._body = body
	self._contentType = contentType or "text/plain; charset=utf-8"
	return self
end

--- Sets a form (application/x-www-form-urlencoded) body.
function Webhook.form(self: any, fields: { [string]: any }): Webhook
	self._body = urlLib.buildQuery(fields)
	self._contentType = "application/x-www-form-urlencoded"
	return self
end

--- Signs the body with `secret`, using a scheme ("hmac", "github", "stripe", "slack",
--- "standard", "shopify", or a custom one).
function Webhook.secret(self: any, secret: string, scheme: types.SchemeSpec?): Webhook
	self._secret = secret
	if scheme ~= nil then
		self._scheme = scheme
	end
	return self
end

--- Names the event (sent as X-Webhook-Event).
function Webhook.event(self: any, name: string): Webhook
	self._event = name
	return self
end

function Webhook.bearer(self: any, token: string): Webhook
	self._options.bearer = token
	return self
end

--- How many times to retry a failed delivery (with exponential backoff).
function Webhook.retry(self: any, limit: number): Webhook
	self._options.retry = { limit = limit, methods = { self._method } }
	return self
end

function Webhook.timeout(self: any, seconds: number): Webhook
	self._options.timeout = seconds
	return self
end

--- Sets any other request option (see `RequestOptions`).
function Webhook.option(self: any, name: string, value: any): Webhook
	self._options[name] = value
	return self
end

--- A copy of the builder, to send variations.
function Webhook.clone(self: any): Webhook
	local copy = setmetatable(table.clone(self), Webhook)
	copy._headers = self._headers:clone()
	copy._options = table.clone(self._options)
	return copy :: any
end

--- Everything about the request that would be sent, without sending it.
function Webhook.build(self: any): Prepared
	local body = self._body or ""
	local id = self._id or crypto.uuid()
	local timestamp = os.time()
	local headers = self._headers:clone()
	if self._contentType then
		headers:setDefault("Content-Type", self._contentType)
	end
	if self._event then
		headers:set("X-Webhook-Event", self._event)
	end
	headers:setDefault("X-Webhook-Id", id)
	if self._secret then
		local scheme = signatures.get(self._scheme)
		for name, value in scheme.sign(body, self._secret, { id = id, timestamp = timestamp }) do
			headers:set(name, value)
		end
	end
	return {
		method = self._method,
		url = urlLib.withQuery(self.url, self._query),
		headers = headers:list(),
		body = body,
		id = id,
		timestamp = timestamp,
	}
end

--- Sends the webhook. `payload`, if given, replaces the body (tables as JSON). Any non-2xx
--- answer counts as a failure: returns `nil, err, response`.
function Webhook.send(self: any, payload: any?): (types.Response?, string?, types.Response?)
	if payload ~= nil then
		if type(payload) == "string" then
			self:body(payload, self._contentType)
		else
			self:json(payload)
		end
	end
	local prepared = self:build()
	local options: { [string]: any } = {}
	for k, v in self._options do
		if not OWN[k] and k ~= "json" and k ~= "form" and k ~= "body" and k ~= "multipart" and k ~= "file" then
			options[k] = v
		end
	end
	options.headers = prepared.headers
	options.query = nil
	options.body = prepared.body
	options.failOnStatus = true
	local http = self._options.client or requestLib.default
	return http:request(prepared.method, prepared.url, options)
end

Webhook.__tostring = function(self)
	return `Webhook({self._method} {self.url})`
end

--- Sends `payload` (a table is sent as JSON) to `url` in one call.
function builder.send(url: string, payload: any?, options: SendOptions?): (types.Response?, string?, types.Response?)
	return builder.new(url, options):send(payload)
end

return builder
