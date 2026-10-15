--[[
	The httpx module table. `init.luau` returns it (with the types); it lives in its own file so
	the bundled programs can use it too: when `init.luau` is the entry script, other modules
	can't require it back.
]]

local core = require("./core")
local request = require("./request")
local server = require("./server")
local websocket = require("./websocket")
local sse = require("./sse")
local webhook = require("./webhook")

local httpx = {}

httpx.VERSION = request.VERSION

-- Categories
httpx.core = core
httpx.request = request
httpx.server = server
httpx.websocket = websocket
httpx.sse = sse
httpx.webhook = webhook

-- Client shortcuts (the shared client)
httpx.get = request.get
httpx.head = request.head
httpx.post = request.post
httpx.put = request.put
httpx.patch = request.patch
httpx.delete = request.delete
httpx.options = request.options
httpx.download = request.download
httpx.json = request.json
httpx.text = request.text
httpx.client = request.client

-- Server shortcuts
httpx.app = server.app
httpx.router = server.router
httpx.serve = server.serve
httpx.static = server.static
httpx.middleware = server.middleware
httpx.abort = server.abort

-- Building blocks
httpx.headers = core.headers.new
httpx.cookieJar = core.cookies.jar
httpx.url = core.url
httpx.errorKind = core.errors.kind

return httpx
