--[[
	The HTTP client, from one-liners to a configured API client.

	    sn run --entry examples/client.luau
]]

local httpx = require("../init")

-- One-liners. Failures return nil, err; assert turns them into errors.
local res = assert(httpx.get("https://example.com"))
print(res.status, res.headers["content-type"], #res.body)

-- JSON in, JSON out
local echoed = assert(httpx.post("https://httpbin.org/post", { json = { hello = "world" } }))
print(assert(echoed:json()).json.hello)

-- Fetch and decode JSON in one call (non-2xx statuses are errors here)
local ip, err = httpx.json("https://httpbin.org/ip")
print(ip and ip.origin or err)

-- A configured client: base URL, default headers, retries, timeouts, middleware
local api = httpx.client({
	baseUrl = "https://httpbin.org",
	headers = { accept = "application/json" },
	timeout = 10,
	retry = { limit = 3, delay = 0.5 },
})

api:use(function(req, nextFn)
	local started = os.clock()
	local response, failure = nextFn(req)
	print(string.format("%s %s -> %s (%.0f ms)", req.method, req.url, response and response.status or failure, (os.clock() - started) * 1000))
	return response, failure
end)

local headers = assert(api:get("/headers", { query = { debug = true } }))
print(assert(headers:json()).headers.Accept)

-- Errors carry their kind
local _, timeoutErr = api:get("/delay/5", { timeout = 1 })
print(timeoutErr, "->", httpx.errorKind(timeoutErr))

-- Streaming a large body
local stream = assert(httpx.get("https://httpbin.org/stream/3", { stream = true }))
for line in stream:lines() do
	print("line:", #line, "bytes")
end
