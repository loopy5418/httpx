# httpx

HTTP for [Sonata](https://sonata.5418.org) 1.0.1, built on [`@sonata/net`](https://sonata.5418.org/docs/api/module/net/).

`@sonata/net` provides sockets, TLS and the HTTP/WebSocket wire formats, but no client or server. httpx builds those on top of it: an HTTP client, an HTTP server with routing, WebSockets, server-sent events and signed webhooks. It also ships prebuilt command-line programs you can bundle into standalone executables.

```luau
local httpx = require("@httpx")

local res = assert(httpx.get("https://example.com"))
print(res.status, res.body)

local app = httpx.app()
app:get("/hello/:name", function(req) return { hello = req.params.name } end)
assert(app:listen(8080))
```

- [Install](#install)
- [Categories](#categories)
- [Errors](#errors)
- [request: the HTTP client](#request-the-http-client)
- [server: the HTTP server](#server-the-http-server)
- [websocket](#websocket)
- [sse: server-sent events](#sse-server-sent-events)
- [webhook](#webhook)
- [core](#core)
- [Prebuilt programs](#prebuilt-programs)
- [Development](#development)

## Install

```sh
sn pkg add github.com/loopy5418/httpx
```

```luau
local httpx = require("@httpx")              -- everything
local server = require("@httpx/server")      -- or one category
```

httpx uses these built-in libraries: `net`, `task`, `json`, `compress`, `fs`, `path`, `crypto`, `term`, `process` and `pocket`. Its manifest declares them, so Sonata adds them to your build automatically.

## Categories

Each category is a folder holding its own `types.luau` and implementation, and each one can be required on its own.

| Folder | What it does |
| --- | --- |
| `request/` | HTTP client: one-liners, configurable clients, retries, redirects, cookies, streaming, downloads, middleware |
| `server/` | HTTP/1.1 server: apps, routers, middleware, static files, TLS, error handling |
| `websocket/` | WebSocket client and server connections, broadcast hubs |
| `sse/` | Server-sent events: server streams, an auto-reconnecting client, a parser |
| `webhook/` | Sending signed webhooks, and receiving and verifying them (GitHub, Stripe, Slack, Standard Webhooks, Shopify, custom HMAC) |
| `core/` | Shared building blocks: `Headers`, URLs, bodies, the cookie jar, socket I/O, error kinds, hubs |
| `apps/` | The prebuilt programs (`serve`, `fetch`, `webhook`, `ws`, and the all-in-one `httpx`) |

Everything is layered. The simple calls are built from the lower-level pieces, and those pieces are exported too, so you can drop down a level when you need more control. For example, `httpx.get` uses a `Client`, which uses `request.transport`, which uses `@sonata/net` sockets.

## Errors

httpx follows Sonata's own convention: failures caused by the outside world don't raise. The call returns `nil, err`. Wrap a call in `assert` when a failure should stop the program.

```luau
local res, err = httpx.get("https://example.invalid")
if res == nil then
    print(err)                    --> "dns: connecting to example.invalid:443: Name or service not known"
    print(httpx.errorKind(err))   --> "dns"
end
```

Every error message starts with its kind: `connect`, `dns`, `timeout`, `tls`, `closed`, `protocol`, `redirect`, `status`, `body`, `invalid` or `aborted`.

HTTP error statuses (404, 500, ...) are normal responses. To treat them as failures, check `res.ok`, call `res:raiseForStatus()`, or pass `failOnStatus = true`. With `failOnStatus`, a failed call returns `nil, err, response`.

Misusing the API (wrong argument types, and so on) raises an error, as Sonata's libraries do.

## request: the HTTP client

```luau
-- One-liners using the shared client
local res = assert(httpx.get("https://api.example.com/items", { query = { page = 2 } }))
local created = assert(httpx.post(url, { json = { name = "Ada" } }))
local data = assert(httpx.json("https://api.example.com/me", { bearer = token }))   -- non-2xx is an error
local html = assert(httpx.text("https://example.com"))
assert(httpx.download("https://example.com/big.iso", "big.iso", {
    onProgress = function(received, total) ... end,
}))

-- The category is callable as well
httpx.request("PUT", url, { form = { a = 1 } })
httpx.request({ method = "DELETE", url = url })
```

The response:

| Field / method | |
| --- | --- |
| `status`, `reason`, `ok` | `ok` is true for 2xx |
| `headers` | `Headers` object: `res.headers["content-type"]`, `res.headers:getAll("set-cookie")` |
| `body` | the whole body (buffered by default) |
| `url`, `redirected`, `redirects` | the final URL and the chain of redirects |
| `elapsed` | seconds until the response head arrived |
| `res:json()`, `res:text()`, `res:form()` | decoded body, or `nil, err` |
| `res:read()`, `res:chunks()`, `res:lines()`, `res:events()` | streaming access (with `stream = true`) |
| `res:save(path)` | stream the body to a file |
| `res:raiseForStatus()` | raises unless 2xx; returns the response, so it chains |
| `res:close()` | stop reading and release the connection |

### Request options

| Option | Default | |
| --- | --- | --- |
| `query` | | map, list of pairs, or string; added to the URL |
| `headers` | | map, list of pairs, or `Headers` |
| `body` / `json` / `form` / `multipart` / `file` | | the body: raw string or stream function, JSON, URL-encoded form, multipart (`{ field = "x", upload = { file = "a.png" } }`), or a file on disk (streamed) |
| `auth` / `bearer` | | basic auth `{ "user", "pass" }`, or a bearer token |
| `timeout` | `30` | seconds for each wait (`false` for none) |
| `connectTimeout`, `totalTimeout` | | the connect step only / the whole call, including retries |
| `retry` | none | a number, or `{ limit, methods, statuses, delay, maxDelay, onRetry }`; honors `Retry-After` |
| `followRedirects`, `maxRedirects` | `true`, `10` | 303 → GET; credentials dropped across origins |
| `failOnStatus` | `false` | treat 4xx/5xx as failures |
| `stream` | `false` | don't buffer the body |
| `decompress` | `true` | gzip, deflate and zstd |
| `maxBodySize`, `onProgress` | | |
| `cookies` | | a jar, or `false` |
| `keepAlive` | `true` | connection pooling per origin |
| `tls`, `insecure`, `proxy`, `family`, `localAddress` | | passed through to `net.connect` (`proxy = "socks5://..."`, `tls = { caFile = ... }`) |

### Clients

```luau
local api = httpx.client({
    baseUrl = "https://api.example.com/v1",
    headers = { accept = "application/json" },
    bearer = token,
    retry = 3,
    timeout = 10,
})

-- Middleware wraps every request: auth refresh, logging, tracing, caching, ...
api:use(function(req, next)
    req.headers:set("X-Request-Id", crypto.uuid())
    local res, err = next(req)
    if res and res.status == 401 then
        req.headers:set("Authorization", "Bearer " .. refresh())
        res, err = next(req)
    end
    return res, err
end)

local users = assert(api:get("users", { query = { active = true } })):json()
local admin = api:extend({ headers = { ["X-Admin"] = "1" } })   -- shares the pool and cookies
```

Each client has its own cookie jar (`client.cookies`; save and load it with `jar:save(file)` and `jar:load(file)`). The shared client used by `httpx.get` and friends keeps no cookies between calls; each call gets a jar that lasts only for that call, so cookies set during redirects still work.

## server: the HTTP server

```luau
local app = httpx.app()
local mw = httpx.middleware

app:use(mw.logger())
app:use(mw.compress())
app:use("/api", mw.cors({ origin = { "https://example.com" }, credentials = true }))

app:get("/", function() return "<h1>Hi</h1>" end)                     -- strings: text or HTML
app:get("/users/:id(%d+)", function(req) return { id = req.params.id } end)  -- tables: JSON
app:post("/users", function(req, res)
    local user = req:json()                                 -- 400 if invalid
    res:status(201):json(user)
end)
app:delete("/users/:id", function() return 204 end)         -- numbers: status (+ optional body, headers)
app:get("/files/*path", function(req) return req.params.path end)

app:group("/admin", function(admin)
    admin:use(mw.basicAuth({ users = { root = "hunter2" } }))
    admin:get("/stats", function() return { uptime = os.clock() } end)
end)

app:static("/", "public", { extensions = { "html" }, spa = true })

app:onError(function(err, req, res)
    res:json({ error = tostring(err) }, if httpx.server.isError(err) then err.status else 500)
end)

local srv = assert(app:listen({ port = 8080 }))
print("listening on", srv.url)
```

- **Handlers** receive `(req, res, next)`. They can answer with `res`, or return a string, a table, or `status[, body[, headers]]`. Call `httpx.abort(status, message)` anywhere to answer with an error.
- **Routing**: `:param`, `:param(luaPattern)`, `*rest`; `get/post/put/patch/delete/head/options/all/route`; `use`, `mount`, `group`. HEAD and OPTIONS are handled automatically, along with 404 and 405 (with an `Allow` header).
- **Request**: `method`, `path`, `params`, `query`, `headers`, `cookies`, `ip`, `body` (read on first access), `req:json()`, `req:form()`, `req:multipart()`, `req:chunks()` (streaming uploads), `req:accepts(...)`, `req:is(...)`, and `locals` for passing data between middleware.
- **Response**: `status`, `header`, `type`, `cookie`, `clearCookie`, `send`, `json`, `text`, `html`, `redirect`, `file` (with ETag, ranges and 304s), `write`/`finish` (chunked streaming), `sse()`, and `onFinish(fn)`.
- **Middleware**: `logger`, `cors`, `compress`, `basicAuth`, `bearerAuth`, `rateLimit`, `securityHeaders`, `requestId`, `bodyLimit`, `static`.
- **Listen options**: `port`, `host`, `unix`, `tls = { cert, key }`, `timeout`, `keepAliveTimeout`, `maxBodySize`, `maxHeadSize`, `maxConnections`, `trustProxy`, `serverHeader`. `srv:close({ graceful = true })` and `srv:wait()` stop and wait.
- **Going lower**: `httpx.server.listen(handler, options)` serves a plain `function(req, res)`. `httpx.server.serveConnection(sock, app)` serves a socket you accepted yourself.

Static files can also come from assets packed into the program:

```luau
local pocket = require("@sonata/pocket")
app:static("/", "www", { read = function(p) return pocket.tryRead(p) end })
```

## websocket

```luau
-- Client
local ws = assert(httpx.websocket.connect("wss://example.com/socket", { protocols = { "chat" } }))
ws:send("hello")
ws:sendJson({ type = "join" })
for message, kind in ws:messages() do print(kind, message) end
print("closed:", ws.closeCode, ws.closeReason)

-- Server
local room = httpx.websocket.hub()
app:ws("/chat", function(ws, req)
    room:add(ws)
    for message in ws:messages() do
        room:broadcastExcept(ws, message)
    end
end, { protocols = { "chat" }, pingInterval = 30 })
```

Connections answer pings, reassemble fragmented messages, validate UTF-8 and enforce `maxMessageSize`. They also support event handlers (`ws:on("message", fn)`, then `ws:start()`), heartbeats (`pingInterval`), and `websocket.wrap(sock)` for sockets you upgraded yourself.

## sse: server-sent events

```luau
-- Server
local feed = httpx.sse.hub()
app:sse("/events", function(stream, req) feed:add(stream) end)   -- stays open until the client leaves
feed:broadcast({ price = 42 }, "update")

app:get("/countdown", function(req, res)
    local stream = res:sse()
    for i = 3, 1, -1 do stream:send(i); task.wait(1) end
    stream:close()
end)

-- Client: reconnects with Last-Event-ID
for event in httpx.sse.connect("https://example.com/events"):events() do
    print(event.event, event.data)
end
```

## webhook

```luau
-- Send (retried 3 times by default; non-2xx answers are failures)
assert(httpx.webhook.send("https://example.com/hook", { event = "order.paid", id = 42 }))

httpx.webhook.new("https://example.com/hook")
    :secret(SECRET, "standard")        -- hmac | github | stripe | slack | standard | shopify | custom
    :event("order.paid")
    :header("X-Tenant", "acme")
    :json({ id = 42 })
    :send()

-- Receive and verify
app:post("/hooks/github", httpx.webhook.receiver({ secret = SECRET, scheme = "github" }, function(event)
    print(event.type, event.data.repository.full_name)
end))

-- Custom HMAC schemes
local scheme = httpx.webhook.scheme({ header = "X-Sig", algorithm = "sha512", encoding = "base64", prefix = "" })
```

## core

`httpx.headers(init)` creates case-insensitive, ordered, multi-valued headers. `httpx.cookieJar()` creates a cookie jar, and `httpx.url` has the URL helpers (`join`, `withQuery`, `buildQuery`, ...). `httpx.core.body` encodes bodies, and `httpx.core.io` reads and writes HTTP messages on raw sockets, which is useful when implementing another protocol on top of HTTP.

## Prebuilt programs

| Program | |
| --- | --- |
| `serve` | serves a folder (the current one by default): directory listings, clean URLs, SPA mode, live reload, CORS, gzip, HTTPS |
| `fetch` | a curl-like client: `-X -H -d --json -F -o -i -v --retry --events ...` |
| `webhook` | `send` (signed, retried, `--dry-run`), `build` (interactive), `listen` (inspect, verify, `--forward`), `schemes` |
| `ws` | interactive WebSocket client, `-x` one-shot messages, `--serve` echo or broadcast server |
| `httpx` | all of the above in one program: `httpx serve`, `httpx webhook send ...` |

httpx's entrypoint (`init.luau`) is both the library and the `httpx` program. Required with `require("@httpx")`, it returns the module. Run directly, it starts the all-in-one program, which prints its help when given no arguments:

```sh
sn run                                   # help
sn run -- serve . --live                 # a tool of the all-in-one program
sn run --entry apps/serve.luau -- . --live   # a single program
```

Build standalone executables into `build/`:

```sh
sn build                                                # build/httpx, the all-in-one program
sn run --entry apps/build.luau                          # every program
sn run --entry apps/build.luau -- serve webhook         # some of them
sn run --entry apps/build.luau -- --all-libs --out bin  # extra options go to `sn build`
```

Help and error messages show the command that actually runs the program: `sn run -- serve` or `sn run --entry apps/serve.luau --` under `sn run`, and for a built program its path from the current folder (`./build/serve`), or just its name when it is on your `PATH`.

`--all-libs` uses the prebuilt Sonata runtime, which makes builds fast. Without it, `sn build` compiles a runtime tailored to the libraries in `build.libraries`, which is smaller but slow the first time.

Examples:

```sh
cd my-site && serve --spa --port 3000
fetch https://httpbin.org/post --json '{"a":1}' -v
webhook listen --port 9000 --secret "$SECRET" --scheme github --forward http://localhost:3000/hooks
webhook build
```

The `webhook` program reads `$WEBHOOK_URL` and `$WEBHOOK_SECRET`. Set `HTTPX_DEBUG=1` to print stack traces.

## Development

```sh
sn run --entry tests/run.luau        # the test suite (local servers only, no internet)
sn run --entry examples/server.luau  # examples: server, chat, client
```

The editor setting `luau-lsp.require.useOriginalRequireByStringSemantics` (in `.vscode/settings.json`) makes luau-lsp resolve `./` in `init.luau` files the way Sonata does: relative to the file's own folder.
