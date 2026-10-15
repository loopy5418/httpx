local net = require("@sonata/net")
local task = require("@sonata/task")
local t = require("./lib")
local httpx = require("../init")

return function()
	t.section("core")
	local core = httpx.core

	t.test("headers are case-insensitive and multi-valued", function()
		local h = core.headers.new({ ["Content-Type"] = "text/plain" })
		h:add("Set-Cookie", "a=1"):add("set-cookie", "b=2")
		t.eq(h:get("content-type"), "text/plain")
		t.eq(h["CONTENT-TYPE"], "text/plain")
		t.eq(#h:getAll("Set-Cookie"), 2)
		t.eq(h:get("set-cookie"), "a=1\nb=2")
		h:set("set-cookie", "c=3")
		t.eq(h:get("set-cookie"), "c=3")
		h:merge({ ["X-A"] = "1" })
		local names = {}
		for name in h do
			table.insert(names, name)
		end
		t.eq(#names, 3)
		t.eq(h:delete("x-a"):has("X-A"), false)
	end)

	t.test("url helpers", function()
		t.eq(core.url.join("https://api.x.com/v1", "users/1"), "https://api.x.com/v1/users/1")
		t.eq(core.url.join("https://api.x.com/v1/", "/users"), "https://api.x.com/v1/users")
		t.eq(core.url.join("https://a.com", "https://b.com/x"), "https://b.com/x")
		t.eq(core.url.withQuery("https://a.com/s?x=1#f", { q = "a b" }), "https://a.com/s?x=1&q=a%20b#f")
		t.eq(core.url.buildQuery({ a = { 1, 2 }, b = true, c = false }), "a=1&a=2&b=true")
	end)

	t.test("cookie jar domain and path rules", function()
		local jar = httpx.cookieJar()
		jar:store("https://www.example.com/app/page", {
			"a=1; Path=/",
			"b=2",
			"c=3; Domain=example.com; Path=/; Secure",
			"d=4; Domain=evil.com",
			"e=5; Max-Age=0",
		})
		t.eq(jar:header("https://www.example.com/app/x"), "b=2; a=1; c=3")
		t.eq(jar:header("https://www.example.com/other"), "a=1; c=3")
		t.eq(jar:header("http://sub.example.com/"), nil)
		t.eq(jar:header("https://sub.example.com/"), "c=3")
		t.eq(jar:header("https://evil.com/"), nil)
	end)

	t.test("errors carry their kind", function()
		t.eq(httpx.errorKind("timeout: too slow"), "timeout")
		t.eq(httpx.errorKind("whatever"), nil)
		local res, err = httpx.get("http://127.0.0.1:1/")
		t.eq(res, nil)
		t.eq(httpx.errorKind(err), "connect")
		res, err = httpx.get("not a url")
		t.eq(httpx.errorKind(err), "invalid")
	end)

	t.test("sse parser", function()
		local p = httpx.sse.parser()
		local events = p:push("event: a\ndata: 1\r")
		t.eq(#events, 0)
		events = p:push("\ndata: 2\n\n: comment\nid: 9\ndata:x\n\n")
		t.eq(#events, 2)
		t.eq(events[1].event, "a")
		t.eq(events[1].data, "1\n2")
		t.eq(events[2].data, "x")
		t.eq(events[2].id, "9")
	end)

	-- A tiny raw server to exercise client behaviour the httpx server never produces.
	local hits: { [string]: number } = {}
	local listener = assert(net.listen("127.0.0.1", 0))
	local _, port = listener:localAddress()
	task.spawn(function()
		while true do
			local c = listener:accept()
			if not c then
				break
			end
			task.spawn(function()
				while true do
					local data = c:recvUntil("\r\n\r\n")
					if not data then
						break
					end
					local head = net.http.parseRequest(data)
					local mode, len = net.http.bodyLength(head)
					if mode == "length" and len > 0 then
						c:recv(len, true)
					end
					hits[head.path] = (hits[head.path] or 0) + 1
					local n = hits[head.path]
					local function reply(status: number, body: string, extra: { { string } }?)
						local headers = { { "Content-Length", tostring(#body) } }
						for _, h in (extra or {}) :: { { string } } do
							table.insert(headers, h)
						end
						c:send(net.http.formatResponse({ status = status, headers = headers }) .. body)
					end
					if head.path == "/flaky" then
						if n < 3 then
							reply(503, "busy", { { "Retry-After", "0" } })
						else
							reply(200, "finally")
						end
					elseif head.path == "/loop" then
						reply(302, "", { { "Location", "/loop" } })
					elseif head.path == "/slow" then
						task.wait(1)
						reply(200, "late")
					elseif head.path == "/see-other" then
						reply(303, "", { { "Location", "/method" } })
					elseif head.path == "/method" then
						reply(200, head.method .. ":" .. tostring(head.headers["content-length"]))
					elseif head.path == "/missing" then
						reply(404, "nope")
					elseif head.path == "/auth" then
						reply(200, tostring(head.headers.authorization))
					else
						reply(200, "ok")
					end
				end
				c:close()
			end)
		end
	end)
	local base = `http://127.0.0.1:{port}`

	t.test("retries with Retry-After", function()
		local retries = 0
		local res = assert(httpx.get(base .. "/flaky", {
			retry = { limit = 3, delay = 0.01, onRetry = function()
				retries += 1
			end },
		}))
		t.eq(res.status, 200)
		t.eq(res.body, "finally")
		t.eq(retries, 2)
	end)

	t.test("redirect limits", function()
		local res, err = httpx.get(base .. "/loop", { maxRedirects = 3 })
		t.eq(res, nil)
		t.eq(httpx.errorKind(err), "redirect")
	end)

	t.test("303 turns POST into GET", function()
		local res = assert(httpx.post(base .. "/see-other", { body = "data" }))
		t.eq(res.body, "GET:nil")
		t.eq(#res.redirects, 1)
	end)

	t.test("timeouts", function()
		local res, err = httpx.get(base .. "/slow", { timeout = 0.2 })
		t.eq(res, nil)
		t.eq(httpx.errorKind(err), "timeout")
		res, err = httpx.get(base .. "/slow", { totalTimeout = 0.2 })
		t.eq(httpx.errorKind(err), "timeout")
	end)

	t.test("failOnStatus and raiseForStatus", function()
		local res = assert(httpx.get(base .. "/missing"))
		t.eq(res.status, 404)
		t.eq(res.ok, false)
		local failedRes, err, failed = httpx.get(base .. "/missing", { failOnStatus = true })
		t.eq(failedRes, nil)
		t.eq(httpx.errorKind(err), "status")
		t.eq((failed :: any).status, 404)
		local ok, raised = pcall(function()
			res:raiseForStatus()
		end)
		t.eq(ok, false)
		t.contains(tostring(raised), "404")
		t.eq(assert(httpx.get(base .. "/x")):raiseForStatus().status, 200)
		local value, jsonErr = httpx.json(base .. "/missing")
		t.eq(value, nil)
		t.eq(httpx.errorKind(jsonErr), "status")
	end)

	t.test("client middleware and auth", function()
		local client = httpx.client({ baseUrl = base, bearer = "tok" })
		local seen = {}
		client:use(function(req, nextFn)
			table.insert(seen, req.method .. " " .. req.url)
			req.headers:set("x-traced", "1")
			return nextFn(req)
		end)
		local res = assert(client:get("/auth"))
		t.eq(res.body, "Bearer tok")
		t.eq(seen[1], `GET {base}/auth`)
		res = assert(client:get("/auth", { auth = { "u", "p" }, bearer = false :: any }))
		t.eq(res.body, net.http.basicAuth("u", "p"))
		local child = client:extend({ headers = { ["x-child"] = "1" } })
		t.eq(#child._middleware, 1)
	end)

	t.test("download to a file", function()
		local fs = require("@sonata/fs")
		local path = require("@sonata/path")
		local dir = fs.makeTempDir()
		local file = path.join(dir, "out.txt")
		assert(httpx.download(base .. "/whatever", file))
		t.eq(fs.readFile(file), "ok")
		fs.removeDir(dir, true)
	end)

	t.test("callable request category", function()
		t.eq(assert(httpx.request("GET", base .. "/x")).body, "ok")
		t.eq(assert(httpx.request({ url = base .. "/x" })).body, "ok")
	end)

	listener:close()
end
