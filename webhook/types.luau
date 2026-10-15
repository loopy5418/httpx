--[[
	Types of outgoing and incoming webhooks.
]]

local coreTypes = require("../core/types")
local requestTypes = require("../request/types")

export type Headers = coreTypes.Headers
export type HeadersInit = coreTypes.HeadersInit
export type Response = requestTypes.Response
export type RequestOptions = requestTypes.RequestOptions

--- What a signature scheme gets when signing.
export type SignContext = {
	id: string, -- a unique message ID
	timestamp: number, -- Unix seconds
}

--- A way of signing webhooks. httpx ships "hmac", "github", "stripe", "slack", "standard"
--- (Standard Webhooks / Svix) and "shopify"; custom schemes have the same shape.
export type Scheme = {
	name: string,
	-- Returns the headers that carry the signature.
	sign: (body: string, secret: string, context: SignContext) -> { [string]: string },
	-- Checks the signature of a received body.
	verify: (headers: Headers, body: string, secret: string, options: VerifyOptions) -> (boolean, string?),
}

--- A generic HMAC signature, configurable for services not covered by a preset.
export type HmacOptions = {
	header: string?, -- default "X-Signature-256"
	algorithm: string?, -- any @sonata/crypto hash (default "sha256")
	encoding: ("hex" | "base64" | "base64url")?, -- default "hex"
	prefix: string?, -- default "sha256=" (set "" for none)
	timestampHeader: string?, -- also sign "<timestamp>.<body>" and send the timestamp here
}

export type SchemeSpec = string | Scheme | HmacOptions

export type VerifyOptions = {
	tolerance: number?, -- seconds a signed timestamp may be off (default 300; 0 = don't check)
	now: number?, -- current Unix time (for tests)
}

--- Options of `webhook.send` and `webhook.new`.
export type SendOptions = RequestOptions & {
	secret: string?, -- sign the body with this secret
	scheme: SchemeSpec?, -- how to sign (default "hmac")
	event: string?, -- sent in the X-Webhook-Event header
	id: string?, -- message ID (default: a new UUID)
	client: any?, -- an httpx client to send with
}

export type Webhook = {
	url: string,
	method: (self: Webhook, method: string) -> Webhook,
	header: (self: Webhook, name: string, value: string) -> Webhook,
	headers: (self: Webhook, headers: { [string]: string }) -> Webhook,
	query: (self: Webhook, query: { [string]: any }) -> Webhook,
	json: (self: Webhook, value: any) -> Webhook,
	body: (self: Webhook, body: string, contentType: string?) -> Webhook,
	form: (self: Webhook, fields: { [string]: any }) -> Webhook,
	secret: (self: Webhook, secret: string, scheme: SchemeSpec?) -> Webhook,
	event: (self: Webhook, name: string) -> Webhook,
	bearer: (self: Webhook, token: string) -> Webhook,
	retry: (self: Webhook, limit: number) -> Webhook,
	timeout: (self: Webhook, seconds: number) -> Webhook,
	option: (self: Webhook, name: string, value: any) -> Webhook,
	build: (self: Webhook) -> Prepared,
	send: (self: Webhook, payload: any?) -> (Response?, string?, Response?),
	clone: (self: Webhook) -> Webhook,
	[string]: any,
}

--- A webhook ready to go out: what `build()` returns (and what a dry run shows).
export type Prepared = {
	method: string,
	url: string,
	headers: { { string } },
	body: string,
	id: string,
	timestamp: number,
}

--- A webhook received by `webhook.receiver`.
export type Event = {
	type: string?, -- from X-GitHub-Event, X-Webhook-Event, ... or the payload's "type"/"event"
	id: string?, -- from the signature headers or X-Webhook-Id, X-GitHub-Delivery, ...
	data: any, -- the parsed body (JSON or form), or the raw body
	body: string, -- the raw body
	headers: Headers,
	verified: boolean, -- whether a signature was checked
}

export type ReceiverOptions = VerifyOptions & {
	secret: (string | { string })?, -- check signatures with this secret (or any of several)
	scheme: SchemeSpec?, -- default "hmac"
	parse: ("auto" | "json" | "form" | "text")?, -- how to decode the body (default "auto")
}

return {}
