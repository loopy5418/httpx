--[[
	serve: a static file server for the current folder (or any folder).
]]

local net = require("@sonata/net")
local fs = require("@sonata/fs")
local path = require("@sonata/path")
local task = require("@sonata/task")
local pocket = require("@sonata/pocket")
local process = require("@sonata/process")
local cli = require("./cli")
local httpx = require("../../lib")

local serve = {}

serve.spec = {
	name = "serve",
	description = "Serve a folder's HTML files and assets over HTTP.",
	usage = "[folder] [options]",
	options = {
		{ "port", "p", type = "number", default = 8080, help = "port to listen on (the next free one is used if taken)" },
		{ "host", type = "string", default = "127.0.0.1", value = "<addr>", help = "address to bind; 0.0.0.0 shares on your network" },
		{ "strict-port", type = "boolean", help = "fail instead of trying the next port" },
		{ "spa", type = "boolean", help = "single-page app: serve index.html for unknown paths" },
		{ "no-list", type = "boolean", help = "don't list folders without an index.html" },
		{ "no-clean-urls", type = "boolean", help = "don't serve /about from about.html" },
		{ "dotfiles", type = "boolean", help = "serve files whose names start with '.'" },
		{ "live", "l", type = "boolean", help = "reload the browser when files change" },
		{ "cors", type = "boolean", help = "allow cross-origin requests (Access-Control-Allow-Origin: *)" },
		{ "cache", type = "number", value = "<seconds>", help = "Cache-Control max-age (default: always revalidate)" },
		{ "no-compress", type = "boolean", help = "don't gzip responses" },
		{ "header", "H", type = "list", value = "<name: value>", help = "add a response header" },
		{ "tls-cert", type = "string", value = "<file>", help = "serve HTTPS with this certificate (PEM)" },
		{ "tls-key", type = "string", value = "<file>", help = "the certificate's private key (PEM)" },
		{ "quiet", "q", type = "boolean", help = "don't log requests" },
	},
	examples = {
		"                      # the current folder on http://127.0.0.1:8080",
		"dist --spa --port 3000",
		"site --live           # reload the browser on save",
		". --host 0.0.0.0      # share on your local network",
	},
}

local LIVE_PATH = "/__httpx/live"
local LIVE_SCRIPT = "/__httpx/live.js"

local function networkUrls(scheme: string, port: number): { string }
	local urls = {}
	local ok, interfaces = pcall(net.interfaces)
	if not ok then
		return urls
	end
	for _, iface in interfaces do
		if not iface.internal and iface.family == "ipv4" then
			table.insert(urls, `{scheme}://{iface.address}:{port}`)
		end
	end
	return urls
end

-- Watches "root" and tells live clients to reload (or just restyle, for CSS-only changes).
local function watch(root: string, hub: any)
	task.spawn(function()
		local watcher = fs.watch(root, { recursive = true, interval = 0.2 })
		while true do
			local event = watcher:next()
			if event == nil then
				break
			end
			-- Gather a burst of changes (an editor saving several files) into one reload.
			local changes = { event }
			while true do
				local more = watcher:next(0.15)
				if more == nil then
					break
				end
				table.insert(changes, more)
			end
			local cssOnly = true
			for _, change in changes do
				if path.extname(change.path) ~= ".css" then
					cssOnly = false
				end
			end
			hub:broadcast(if cssOnly then "css" else "reload", if cssOnly then "css" else "reload")
		end
	end)
end

local function injectLiveScript(content: string): string
	local tag = `<script src="{LIVE_SCRIPT}"></script>`
	local injected, count = string.gsub(content, "</[Bb][Oo][Dd][Yy]>", function(close)
		return tag .. close
	end, 1)
	if count == 0 then
		return content .. tag
	end
	return injected
end

function serve.main(argv: { string }): number?
	local opts, rest = cli.parse(argv, serve.spec)
	local root = rest[1] or "."
	if not fs.isDir(root) then
		cli.fail(`not a folder: {root}`)
	end
	root = path.resolve(root)
	if (opts.tlsCert == nil) ~= (opts.tlsKey == nil) then
		cli.fail("--tls-cert and --tls-key go together")
	end

	local app = httpx.app()
	local mw = httpx.middleware
	if not opts.quiet then
		app:use(mw.logger())
	end
	if opts.noCompress ~= true then
		app:use(mw.compress())
	end
	if opts.cors then
		app:use(mw.cors())
	end
	if #opts.header > 0 then
		local extra = cli.headers(opts.header)
		app:use(function(req, res, nextFn)
			for _, pair in extra do
				res:header(pair[1], pair[2])
			end
			nextFn()
		end)
	end

	local staticOptions: { [string]: any } = {
		listing = opts.noList ~= true,
		spa = opts.spa == true,
		extensions = if opts.noCleanUrls then nil else { "html", "htm" },
		dotfiles = if opts.dotfiles then "allow" else "ignore",
		cacheControl = if opts.cache then `public, max-age={math.floor(opts.cache)}` else "no-cache",
	}

	if opts.live then
		local hub = httpx.sse.hub()
		app:sse(LIVE_PATH, function(stream)
			hub:add(stream)
		end, { keepAlive = 20 })
		app:get(LIVE_SCRIPT, function(req, res)
			res:type("js"):header("Cache-Control", "no-store"):send(pocket.read("assets/livereload.js"))
		end)
		staticOptions.transform = function(content: string): string
			return injectLiveScript(content)
		end
		staticOptions.transformMatch = "%.[Hh][Tt][Mm][Ll]?$"
		watch(root, hub)
	end

	app:static("/", root, staticOptions)

	local listenOptions: { [string]: any } = {
		host = opts.host,
		port = opts.port,
		tls = if opts.tlsCert then { cert = opts.tlsCert, key = opts.tlsKey } else nil,
	}
	local srv, err
	for attempt = 0, if opts.strictPort then 0 else 20 do
		listenOptions.port = opts.port + attempt
		srv, err = app:listen(listenOptions)
		if srv or httpx.errorKind(err) == "tls" then
			break
		end
	end
	if srv == nil then
		cli.fail(tostring(err))
	end
	assert(srv)

	local scheme = if srv.secure then "https" else "http"
	local shown = if opts.host == "0.0.0.0" or opts.host == "::" then "localhost" else opts.host
	if string.find(shown, ":", 1, true) then
		shown = `[{shown}]`
	end
	cli.info("")
	cli.info(cli.style("  Serving ", "bold") .. root)
	cli.info("")
	cli.info(`  Local:    {cli.style(`{scheme}://{shown}:{srv.port}`, "cyan", "bold")}`)
	if opts.host == "0.0.0.0" or opts.host == "::" then
		for _, url in networkUrls(scheme, srv.port) do
			cli.info(`  Network:  {cli.style(url, "cyan")}`)
		end
	else
		cli.info(cli.dim("  Network:  use --host 0.0.0.0 to share"))
	end
	if srv.port ~= opts.port then
		cli.warn(`port {opts.port} was taken, using {srv.port}`)
	end
	if opts.live then
		cli.info(cli.dim("  Live reload is on"))
	end
	cli.info(cli.dim("  Press Ctrl+C to stop"))
	cli.info("")

	process.onSignal("interrupt", function()
		cli.info(cli.dim("\nshutting down"))
		srv:close({ graceful = true, timeout = 2 })
		process.exit(0)
	end)
	srv:wait()
	return 0
end

return serve
