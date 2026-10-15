--[[
	httpx/webhook: send signed webhooks and receive them safely.

	Send:

	    local webhook = require("@httpx/webhook")
	    assert(webhook.send("https://example.com/hook", { hello = "world" }))

	    webhook.new(url):secret(SECRET, "standard"):event("user.created"):json(user):send()

	Receive (with httpx/server):

	    app:post("/hook", webhook.receiver({ secret = SECRET }, function(event)
	        print(event.type, event.data)
	    end))

	Signature schemes: "hmac" (default, X-Signature-256), "github", "stripe", "slack",
	"standard" (Standard Webhooks / Svix), "shopify", or your own:
	`webhook.scheme({ header = "X-My-Sig", algorithm = "sha512", encoding = "base64" })`.
]]

local types = require("./types")
local builder = require("./builder")
local receiverLib = require("./receiver")
local signatures = require("./signatures")

export type Webhook = types.Webhook
export type SendOptions = types.SendOptions
export type Prepared = types.Prepared
export type Scheme = types.Scheme
export type SchemeSpec = types.SchemeSpec
export type HmacOptions = types.HmacOptions
export type VerifyOptions = types.VerifyOptions
export type Event = types.Event
export type ReceiverOptions = types.ReceiverOptions

local webhook = {}

--- Creates a webhook builder.
webhook.new = builder.new
--- Sends a payload in one call.
webhook.send = builder.send

--- A route handler receiving webhooks: `webhook.receiver(options, function(event, req, res) ... end)`.
webhook.receiver = receiverLib.handler
--- Parses (and verifies) a received request into an event.
webhook.parse = receiverLib.parse
--- Checks the signature of a server request.
webhook.verify = receiverLib.verify
--- Checks a signature against raw headers and body.
webhook.verifyRaw = receiverLib.verifyRaw

--- Builds a custom HMAC scheme.
webhook.scheme = signatures.hmac
--- Looks up a scheme by name.
webhook.signatures = signatures.presets
--- Resolves a scheme spec (name, table or options).
webhook.getScheme = signatures.get

return webhook
