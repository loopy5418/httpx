--[[
	Webhook signature schemes: how a sender signs a body and how a receiver checks it.

	    local scheme = signatures.get("github")
	    local headers = scheme.sign(body, secret, { id = id, timestamp = os.time() })
	    local ok, err = scheme.verify(req.headers, body, secret, { tolerance = 300 })
]]

local crypto = require("@sonata/crypto")
local types = require("./types")

export type Scheme = types.Scheme
export type SchemeSpec = types.SchemeSpec

local signatures = {}

local function checkTimestamp(value: string?, options: types.VerifyOptions): (number?, string?)
	local ts = tonumber(value)
	if ts == nil then
		return nil, "missing or invalid timestamp"
	end
	local tolerance = if options.tolerance == nil then 300 else options.tolerance
	if tolerance > 0 then
		local now = options.now or os.time()
		if math.abs(now - ts) > tolerance then
			return nil, "timestamp outside the allowed window"
		end
	end
	return ts, nil
end

--- A generic HMAC scheme. Defaults: header X-Signature-256, sha256, hex, prefix "sha256=".
function signatures.hmac(options: types.HmacOptions?): Scheme
	local opts = options or {}
	local header = opts.header or "X-Signature-256"
	local algorithm = opts.algorithm or "sha256"
	local encoding = opts.encoding or "hex"
	local prefix = if opts.prefix == nil then `{algorithm}=` else opts.prefix
	local timestampHeader = opts.timestampHeader

	local function signed(body: string, ts: number?): string
		if timestampHeader and ts then
			return `{ts}.{body}`
		end
		return body
	end

	return {
		name = "hmac",
		sign = function(body, secret, context)
			local out = {}
			out[header] = prefix .. crypto.hmac(algorithm, secret, signed(body, context.timestamp), encoding)
			if timestampHeader then
				out[timestampHeader] = tostring(context.timestamp)
			end
			return out
		end,
		verify = function(headers, body, secret, verifyOptions)
			local received = headers:get(header)
			if received == nil then
				return false, `missing {header} header`
			end
			local ts: number? = nil
			if timestampHeader then
				local err
				ts, err = checkTimestamp(headers:get(timestampHeader), verifyOptions)
				if ts == nil then
					return false, err
				end
			end
			local expected = prefix .. crypto.hmac(algorithm, secret, signed(body, ts), encoding)
			if encoding == "hex" then
				received = string.lower(received)
			end
			if #received == #expected and crypto.equals(received, expected) then
				return true, nil
			end
			return false, "signature mismatch"
		end,
	}
end

--- GitHub: X-Hub-Signature-256: sha256=<hex hmac>.
signatures.github = signatures.hmac({ header = "X-Hub-Signature-256", prefix = "sha256=" })
signatures.github.name = "github"

--- Shopify: X-Shopify-Hmac-Sha256: <base64 hmac>.
signatures.shopify = signatures.hmac({ header = "X-Shopify-Hmac-Sha256", encoding = "base64", prefix = "" })
signatures.shopify.name = "shopify"

--- Stripe: Stripe-Signature: t=<timestamp>,v1=<hex hmac of "t.body">.
signatures.stripe = {
	name = "stripe",
	sign = function(body, secret, context)
		local sig = crypto.hmac("sha256", secret, `{context.timestamp}.{body}`, "hex")
		return { ["Stripe-Signature"] = `t={context.timestamp},v1={sig}` }
	end,
	verify = function(headers, body, secret, options)
		local header = headers:get("stripe-signature")
		if header == nil then
			return false, "missing Stripe-Signature header"
		end
		local ts: string? = nil
		local candidates = {}
		for key, value in string.gmatch(header, "([^,=%s]+)=([^,%s]+)") do
			if key == "t" then
				ts = value
			elseif key == "v1" then
				table.insert(candidates, value)
			end
		end
		local t, err = checkTimestamp(ts, options)
		if t == nil then
			return false, err
		end
		local expected = crypto.hmac("sha256", secret, `{ts}.{body}`, "hex")
		for _, candidate in candidates do
			if #candidate == #expected and crypto.equals(string.lower(candidate), expected) then
				return true, nil
			end
		end
		return false, "signature mismatch"
	end,
} :: Scheme

--- Slack: X-Slack-Request-Timestamp and X-Slack-Signature: v0=<hex hmac of "v0:ts:body">.
signatures.slack = {
	name = "slack",
	sign = function(body, secret, context)
		local sig = crypto.hmac("sha256", secret, `v0:{context.timestamp}:{body}`, "hex")
		return {
			["X-Slack-Request-Timestamp"] = tostring(context.timestamp),
			["X-Slack-Signature"] = `v0={sig}`,
		}
	end,
	verify = function(headers, body, secret, options)
		local tsHeader = headers:get("x-slack-request-timestamp")
		local t, err = checkTimestamp(tsHeader, options)
		if t == nil then
			return false, err
		end
		local received = headers:get("x-slack-signature")
		if received == nil then
			return false, "missing X-Slack-Signature header"
		end
		local expected = "v0=" .. crypto.hmac("sha256", secret, `v0:{tsHeader}:{body}`, "hex")
		if #received == #expected and crypto.equals(received, expected) then
			return true, nil
		end
		return false, "signature mismatch"
	end,
} :: Scheme

-- Standard Webhooks secrets look like "whsec_<base64>"; others are used as they are.
local function standardKey(secret: string): string
	local encoded = string.match(secret, "^whsec_(.+)$")
	if encoded then
		return crypto.decode("base64", encoded) or secret
	end
	return secret
end

--- Standard Webhooks (used by Svix, Clerk, Resend, ...): webhook-id, webhook-timestamp and
--- webhook-signature: v1,<base64 hmac of "id.timestamp.body">.
signatures.standard = {
	name = "standard",
	sign = function(body, secret, context)
		local sig = crypto.hmac("sha256", standardKey(secret), `{context.id}.{context.timestamp}.{body}`, "base64")
		return {
			["webhook-id"] = context.id,
			["webhook-timestamp"] = tostring(context.timestamp),
			["webhook-signature"] = `v1,{sig}`,
		}
	end,
	verify = function(headers, body, secret, options)
		local id = headers:get("webhook-id") or headers:get("svix-id")
		local tsHeader = headers:get("webhook-timestamp") or headers:get("svix-timestamp")
		local sigHeader = headers:get("webhook-signature") or headers:get("svix-signature")
		if id == nil or sigHeader == nil then
			return false, "missing webhook-id or webhook-signature header"
		end
		local t, err = checkTimestamp(tsHeader, options)
		if t == nil then
			return false, err
		end
		local expected = crypto.hmac("sha256", standardKey(secret), `{id}.{tsHeader}.{body}`, "base64")
		for item in string.gmatch(sigHeader, "%S+") do
			local version, sig = string.match(item, "^([^,]+),(.+)$")
			if version == "v1" and sig and #sig == #expected and crypto.equals(sig, expected) then
				return true, nil
			end
		end
		return false, "signature mismatch"
	end,
} :: Scheme

signatures.presets = {
	hmac = signatures.hmac(),
	github = signatures.github,
	stripe = signatures.stripe,
	slack = signatures.slack,
	standard = signatures.standard,
	svix = signatures.standard,
	shopify = signatures.shopify,
}

--- Resolves a scheme from a preset name, a Scheme table or HmacOptions.
function signatures.get(spec: SchemeSpec?): Scheme
	if spec == nil then
		return signatures.presets.hmac
	end
	if type(spec) == "string" then
		local scheme = signatures.presets[string.lower(spec)]
		if scheme == nil then
			local names = {}
			for name in signatures.presets do
				table.insert(names, name)
			end
			table.sort(names)
			error(`unknown signature scheme '{spec}' (known: {table.concat(names, ", ")})`, 2)
		end
		return scheme
	end
	if type((spec :: any).sign) == "function" and type((spec :: any).verify) == "function" then
		return spec :: Scheme
	end
	return signatures.hmac(spec :: types.HmacOptions)
end

return signatures
