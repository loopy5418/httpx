--[[
	webhook: build and send webhooks, or receive and inspect them.
]]

local json = require("@sonata/json")
local term = require("@sonata/term")
local process = require("@sonata/process")
local cli = require("./cli")
local httpx = require("../../lib")

local webhookTool = {}

local SCHEMES = "hmac, github, stripe, slack, standard, shopify"

local sendOptions = {
	{ "json", "j", type = "string", value = "<json|@file|->", help = "JSON payload" },
	{ "data", "d", type = "string", value = "<text|@file|->", help = "raw payload" },
	{ "field", "f", type = "list", value = "<name=value>", help = "form field (URL-encoded payload)" },
	{ "content-type", type = "string", value = "<type>", help = "Content-Type of a --data payload" },
	{ "method", "X", type = "string", default = "POST", help = "request method" },
	{ "header", "H", type = "list", value = "<name: value>", help = "add a header" },
	{ "secret", "s", type = "string", value = "<secret>", help = "sign the payload (also $WEBHOOK_SECRET)" },
	{ "scheme", type = "string", default = "hmac", value = "<name>", help = `signature scheme: {SCHEMES}` },
	{ "event", "e", type = "string", value = "<name>", help = "event name (X-Webhook-Event header)" },
	{ "bearer", type = "string", value = "<token>", help = "bearer token" },
	{ "retry", type = "number", default = 3, help = "retries on failure" },
	{ "timeout", "t", type = "number", default = 30, help = "seconds for each wait" },
	{ "dry-run", "n", type = "boolean", help = "print the request instead of sending it" },
	{ "verbose", "v", type = "boolean", help = "print the request and the full response" },
}

webhookTool.spec = {
	name = "webhook",
	description = "Build, send and receive webhooks.",
	usage = "<command> [options]",
	commands = {
		{ "send <url>", "send a webhook" },
		{ "build [url]", "build a webhook step by step, preview it, then send it" },
		{ "listen", "receive webhooks and print them (optionally verify and forward)" },
		{ "schemes", "list the signature schemes" },
	},
	options = {},
	examples = {
		"send https://example.com/hook --json '{\"event\":\"ping\"}'",
		"send https://example.com/hook -j @payload.json --secret s3cr3t --scheme github -e push",
		"send https://example.com/hook -f name=Ada -f role=admin --dry-run",
		"listen --port 9000 --secret s3cr3t --scheme stripe",
		"listen --forward http://localhost:3000/hooks",
		"build",
	},
}

local function printPrepared(prepared: any)
	local out = term.stdout
	out:writeLine(cli.style(`{prepared.method} {prepared.url}`, "bold"))
	for _, pair in prepared.headers do
		out:writeLine(cli.style(pair[1], "cyan") .. ": " .. pair[2])
	end
	out:writeLine("")
	if prepared.body ~= "" then
		out:writeLine(cli.prettyJson(prepared.body))
	end
	out:flush()
end

-- Builds a webhook builder from parsed options.
local function builderFrom(url: string, opts: { [string]: any }): any
	local hook = httpx.webhook.new(url):method(opts.method or "POST")
	for _, pair in cli.headers(opts.header or {}) do
		hook:header(pair[1], pair[2])
	end
	if opts.json then
		local text = cli.readValue(opts.json)
		local ok, value = pcall(json.decode, text)
		if not ok then
			cli.fail(`--json is not valid JSON: {value}`)
		end
		hook:body(text, "application/json")
	elseif opts.data then
		local text = cli.readValue(opts.data)
		local contentType = opts.contentType
		if contentType == nil and string.match(text, "^%s*[%[{]") and pcall(json.decode, text) then
			contentType = "application/json"
		end
		hook:body(text, contentType)
	elseif opts.field and #opts.field > 0 then
		local fields = {}
		for _, pair in cli.pairs(opts.field, "field") do
			table.insert(fields, pair)
		end
		hook:body(httpx.url.buildQuery(fields), "application/x-www-form-urlencoded")
	end
	local secret = opts.secret or process.env.WEBHOOK_SECRET
	if secret then
		local ok, err = pcall(httpx.webhook.getScheme, opts.scheme)
		if not ok then
			cli.fail(tostring(err))
		end
		hook:secret(secret, opts.scheme)
	end
	if opts.event then
		hook:event(opts.event)
	end
	if opts.bearer then
		hook:bearer(opts.bearer)
	end
	hook:retry(opts.retry or 3)
	hook:timeout(opts.timeout or 30)
	return hook
end

local function deliver(hook: any, verbose: boolean?): number
	if verbose then
		printPrepared(hook:build())
	end
	local started = os.clock()
	local res, err, failed = hook:send()
	local ms = math.floor((os.clock() - started) * 1000)
	local shown = res or failed
	if shown then
		local color = if shown.ok then "green" else "red"
		cli.info(cli.style(`{shown.status} {shown.reason}`, color, "bold") .. cli.dim(` in {ms} ms`))
		local body = shown:text() or ""
		if verbose then
			for name, value in shown.headers do
				cli.info(cli.style(name, "cyan") .. ": " .. value)
			end
		end
		if body ~= "" then
			term.stdout:writeLine(if verbose then cli.prettyJson(body) else string.sub(body, 1, 2000))
		end
	end
	if res == nil then
		if failed == nil then
			cli.fail(tostring(err))
		end
		return 1
	end
	return 0
end

local function send(argv: { string }): number
	local spec = {
		name = "webhook send",
		usage = "send <url> [options]",
		description = "Send a webhook. Without a payload option, the body is read from standard input when it isn't a terminal.",
		options = sendOptions,
	}
	local opts, rest = cli.parse(argv, spec)
	local url = rest[1] or process.env.WEBHOOK_URL
	if url == nil then
		cli.fail("missing <url> (or set $WEBHOOK_URL)")
	end
	assert(url)
	if opts.json == nil and opts.data == nil and #opts.field == 0 and not term.stdin:isTerminal() then
		opts.data = "-"
	end
	local hook = builderFrom(url, opts)
	if opts.dryRun then
		printPrepared(hook:build())
		return 0
	end
	return deliver(hook, opts.verbose)
end

local function build(argv: { string }): number
	local _, rest = cli.parse(argv, { name = "webhook build", usage = "build [url]", options = {} })
	cli.info(cli.style("Webhook builder", "bold") .. cli.dim(" (Ctrl+D to cancel)"))
	local url = rest[1] or cli.ask("URL", process.env.WEBHOOK_URL)
	if url == nil or url == "" then
		cli.fail("a URL is needed")
	end
	assert(url)
	local opts: { [string]: any } = { header = {} }
	opts.method = string.upper(cli.ask("Method", "POST") or "POST")
	local kind = string.lower(cli.ask("Payload: json, form, text or none", "json") or "json")
	if kind == "json" then
		cli.info(cli.dim("Enter JSON. Finish with an empty line."))
		local lines = {}
		while true do
			local line = term.stdin:readLine()
			if line == nil or line == "" then
				break
			end
			table.insert(lines, line)
		end
		opts.json = if #lines > 0 then table.concat(lines, "\n") else "{}"
	elseif kind == "form" then
		opts.field = {}
		cli.info(cli.dim("Enter fields as name=value. Finish with an empty line."))
		while true do
			local line = cli.ask("field")
			if line == nil or line == "" then
				break
			end
			table.insert(opts.field, line)
		end
	elseif kind == "text" then
		opts.data = cli.ask("Text") or ""
	end
	cli.info(cli.dim("Headers as 'Name: value'. Finish with an empty line."))
	while true do
		local line = cli.ask("header")
		if line == nil or line == "" then
			break
		end
		table.insert(opts.header, line)
	end
	opts.event = cli.ask("Event name (optional)")
	local secret = cli.ask("Signing secret (optional)", process.env.WEBHOOK_SECRET)
	if secret and secret ~= "" then
		opts.secret = secret
		opts.scheme = cli.ask(`Signature scheme ({SCHEMES})`, "hmac")
	end
	local hook = builderFrom(url, opts)
	cli.info("")
	printPrepared(hook:build())
	if not cli.confirm("Send it?", true) then
		cli.info("not sent")
		return 0
	end
	return deliver(hook, false)
end

local function listen(argv: { string }): number?
	local spec = {
		name = "webhook listen",
		usage = "listen [options]",
		description = "Receive webhooks and print them. With --secret, signatures are checked; with --forward, deliveries are relayed.",
		options = {
			{ "port", "p", type = "number", default = 9000, help = "port to listen on" },
			{ "host", type = "string", default = "127.0.0.1", help = "address to bind (0.0.0.0 for all)" },
			{ "path", type = "string", default = "/", help = "only accept webhooks under this path" },
			{ "secret", "s", type = "string", help = "check signatures with this secret (also $WEBHOOK_SECRET)" },
			{ "scheme", type = "string", default = "hmac", help = `signature scheme: {SCHEMES}` },
			{ "forward", type = "string", value = "<url>", help = "relay each delivery to this URL" },
			{ "status", type = "number", default = 200, help = "status to answer with" },
			{ "body", type = "string", help = "body to answer with" },
			{ "headers", type = "boolean", help = "print the request headers" },
			{ "json", type = "boolean", help = "print each delivery as one line of JSON (for piping)" },
		},
	}
	local opts = cli.parse(argv, spec)
	local secret = opts.secret or process.env.WEBHOOK_SECRET
	if secret then
		local ok, err = pcall(httpx.webhook.getScheme, opts.scheme)
		if not ok then
			cli.fail(tostring(err))
		end
	end
	local app = httpx.app({ logErrors = false })
	local count = 0
	app:all(opts.path .. (if string.sub(opts.path, -1) == "/" then "*" else "/*"), function(req, res)
		count += 1
		local body = req:text()
		local verified: boolean? = nil
		local verifyErr: string? = nil
		if secret then
			verified, verifyErr = httpx.webhook.verifyRaw(req.headers, body, secret, opts.scheme)
		end
		if opts.json then
			local headers = {}
			for name, value in req.headers do
				headers[string.lower(name)] = value
			end
			term.stdout:writeLine(json.encode({
				n = count,
				time = os.time(),
				method = req.method,
				path = req.target,
				headers = headers,
				body = body,
				verified = if verified == nil then json.null else verified,
			})):flush()
		else
			local stamp = os.date("%H:%M:%S") :: string
			local line = cli.style(`#{count}`, "bold") .. " " .. cli.dim(stamp) .. " " .. cli.style(req.method, "bold") .. " " .. req.target
			if verified == true then
				line ..= " " .. cli.style("✓ signature", "green")
			elseif verified == false then
				line ..= " " .. cli.style(`✗ signature ({verifyErr})`, "red")
			end
			local event = req.headers:get("x-webhook-event") or req.headers:get("x-github-event")
			if event then
				line ..= " " .. cli.style(event, "magenta")
			end
			term.stdout:writeLine(line)
			if opts.headers then
				for name, value in req.headers do
					term.stdout:writeLine("  " .. cli.style(name, "cyan") .. ": " .. value)
				end
			end
			if body ~= "" then
				local pretty = cli.prettyJson(body)
				term.stdout:writeLine("  " .. string.gsub(pretty, "\n", "\n  "))
			end
			term.stdout:writeLine(""):flush()
		end

		if verified == false then
			return 401, "invalid signature"
		end
		if opts.forward then
			local headers = {}
			for name, value in req.headers do
				local lower = string.lower(name)
				if lower ~= "host" and lower ~= "content-length" and lower ~= "connection" and lower ~= "accept-encoding" then
					table.insert(headers, { name, value })
				end
			end
			local target = httpx.url.join(opts.forward, req.path)
			if req.rawQuery then
				target ..= "?" .. req.rawQuery
			end
			local relayed, err = httpx.request(req.method, target, { headers = headers, body = body, decompress = false })
			if relayed == nil then
				cli.warn(`forwarding failed: {err}`)
				return 502, "forwarding failed"
			end
			cli.info(cli.dim(`  ↳ forwarded: {relayed.status} {relayed.reason}`))
			for name, value in relayed.headers do
				local lower = string.lower(name)
				if lower ~= "content-length" and lower ~= "transfer-encoding" and lower ~= "connection" and lower ~= "content-encoding" then
					res:append(name, value)
				end
			end
			return relayed.status, relayed.body
		end
		return opts.status, opts.body or ""
	end)
	local srv, err = app:listen({ port = opts.port, host = opts.host })
	if srv == nil then
		cli.fail(tostring(err))
	end
	assert(srv)
	cli.info(cli.style("Listening for webhooks on ", "bold") .. cli.style(srv.url .. opts.path, "cyan"))
	if secret then
		cli.info(cli.dim(`Checking {opts.scheme} signatures`))
	end
	if opts.forward then
		cli.info(cli.dim(`Forwarding to {opts.forward}`))
	end
	cli.info(cli.dim("Press Ctrl+C to stop"))
	srv:wait()
	return 0
end

function webhookTool.main(argv: { string }): number?
	local command = argv[1]
	local rest = table.move(argv, 2, #argv, 1, {})
	if command == "send" then
		return send(rest)
	elseif command == "build" then
		return build(rest)
	elseif command == "listen" then
		return listen(rest)
	elseif command == "schemes" then
		local names = {}
		for name in httpx.webhook.signatures do
			table.insert(names, name)
		end
		table.sort(names)
		print(table.concat(names, "\n"))
		return 0
	elseif command == nil or command == "-h" or command == "--help" or command == "help" then
		print(cli.help(webhookTool.spec))
		return if command == nil then 2 else 0
	end
	cli.fail(`unknown command '{command}' (see '{cli.command("--help")}')`)
	return 1
end

return webhookTool
