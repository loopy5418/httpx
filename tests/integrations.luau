local t = require("./lib")
local httpx = require("../init")

return function()
	t.section("webhook")
	local webhook = httpx.webhook
	local SECRET = "s3cret"

	local app = httpx.app({ logErrors = false })
	local received = {}
	for _, scheme in { "hmac", "github", "stripe", "slack", "standard", "shopify" } do
		app:post(`/hook/{scheme}`, webhook.receiver({ secret = SECRET, scheme = scheme }, function(event)
			table.insert(received, { scheme = scheme, event = event })
		end))
	end
	app:post("/open", webhook.receiver(nil, function(event)
		return { type = event.type, data = event.data }
	end))

	local srv = assert(app:listen({ port = 0, host = "127.0.0.1" }))
	local base = `http://127.0.0.1:{srv.port}`

	t.test("signed webhooks verify with every scheme", function()
		for _, scheme in { "hmac", "github", "stripe", "slack", "standard", "shopify" } do
			local res, err = webhook.new(`{base}/hook/{scheme}`):secret(SECRET, scheme):event("ping"):json({ n = 1 }):send()
			t.ok(res, `{scheme}: {err}`)
			t.eq((res :: any).status, 204, scheme)
		end
		t.eq(#received, 6)
		t.eq(received[1].event.type, "ping")
		t.eq(received[1].event.data.n, 1)
		t.ok(received[1].event.verified, "verified")
	end)

	t.test("bad signatures are refused", function()
		local res, err, failed = webhook.send(`{base}/hook/github`, { n = 1 }, { secret = "wrong", scheme = "github", retry = 0 })
		t.eq(res, nil)
		t.eq(httpx.errorKind(err), "status")
		t.eq((failed :: any).status, 401)
		res, err, failed = webhook.send(`{base}/hook/hmac`, { n = 1 }, { retry = 0 })
		t.eq((failed :: any).status, 401)
	end)

	t.test("unsigned receiver parses JSON and forms", function()
		local res = assert(webhook.send(`{base}/open`, { type = "user.created", id = 7 }))
		local data = assert(res:json())
		t.eq(data.type, "user.created")
		res = assert(webhook.new(`{base}/open`):form({ a = "1" }):send())
		t.eq(assert(res:json()).data.a, "1")
	end)

	t.test("build shows the request without sending", function()
		local prepared = webhook.new("https://example.com/x"):secret("k", "github"):json({ a = 1 }):build()
		t.eq(prepared.method, "POST")
		t.eq(prepared.body, '{"a":1}')
		local found = false
		for _, pair in prepared.headers do
			if pair[1] == "X-Hub-Signature-256" then
				found = string.sub(pair[2], 1, 7) == "sha256="
			end
		end
		t.ok(found, "signature header")
	end)

	t.test("custom hmac scheme with timestamps", function()
		local scheme = webhook.scheme({ header = "X-Sig", algorithm = "sha512", encoding = "base64", prefix = "", timestampHeader = "X-Ts" })
		local body = "payload"
		local headers = scheme.sign(body, "k", { id = "1", timestamp = os.time() })
		t.ok(webhook.verifyRaw(headers, body, "k", scheme), "verifies")
		t.eq((webhook.verifyRaw(headers, body .. "!", "k", scheme)), false)
		local old = scheme.sign(body, "k", { id = "1", timestamp = os.time() - 3600 })
		t.eq((webhook.verifyRaw(old, body, "k", scheme)), false)
	end)

	srv:close()
end
