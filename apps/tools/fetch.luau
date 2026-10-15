--[[
	fetch: a small curl-like HTTP client.
]]

local json = require("@sonata/json")
local fs = require("@sonata/fs")
local path = require("@sonata/path")
local term = require("@sonata/term")
local cli = require("./cli")
local httpx = require("../../lib")

local fetch = {}

fetch.spec = {
	name = "fetch",
	description = "Send an HTTP request and print the response.",
	usage = "<url> [options]",
	options = {
		{ "method", "X", type = "string", value = "<method>", help = "request method (default GET, or POST with a body)" },
		{ "header", "H", type = "list", value = "<name: value>", help = "add a request header" },
		{ "query", "q", type = "list", value = "<name=value>", help = "add a query parameter" },
		{ "data", "d", type = "string", value = "<text|@file|->", help = "raw request body" },
		{ "json", "j", type = "string", value = "<json|@file|->", help = "JSON request body" },
		{ "field", type = "list", value = "<name=value>", help = "URL-encoded form field" },
		{ "form", "F", type = "list", value = "<name=value|name=@file>", help = "multipart form field (or file)" },
		{ "user", "u", type = "string", value = "<user:password>", help = "basic authentication" },
		{ "bearer", type = "string", value = "<token>", help = "bearer token" },
		{ "output", "o", type = "string", value = "<file>", help = "write the body to a file" },
		{ "include", "i", type = "boolean", help = "print the status line and headers" },
		{ "head", "I", type = "boolean", help = "send a HEAD request and print the headers" },
		{ "verbose", "v", type = "boolean", help = "print request and response details to stderr" },
		{ "silent", "s", type = "boolean", help = "no progress or errors" },
		{ "pretty", "P", type = "boolean", help = "pretty-print JSON responses (default on terminals)" },
		{ "raw", type = "boolean", help = "don't decompress or prettify" },
		{ "fail", "f", type = "boolean", help = "exit with status 22 on HTTP errors (4xx/5xx)" },
		{ "no-follow", type = "boolean", help = "don't follow redirects" },
		{ "max-redirects", type = "number", default = 10, help = "most redirects to follow" },
		{ "timeout", "t", type = "number", default = 30, help = "seconds for each wait" },
		{ "retry", type = "number", default = 0, help = "retries on network errors and 429/5xx" },
		{ "insecure", "k", type = "boolean", help = "skip TLS certificate checks" },
		{ "proxy", "x", type = "string", value = "<url>", help = "proxy, e.g. socks5://host:1080" },
		{ "events", type = "boolean", help = "read a server-sent event stream" },
	},
	examples = {
		"https://example.com",
		"https://httpbin.org/post --json '{\"hello\":\"world\"}'",
		"https://api.example.com/items -H 'Accept: application/json' -q page=2",
		"https://example.com/big.zip -o big.zip",
		"https://httpbin.org/post -F name=report -F file=@report.pdf",
	},
}

local function statusColor(status: number): string
	if status >= 500 then
		return "red"
	elseif status >= 400 then
		return "yellow"
	elseif status >= 300 then
		return "cyan"
	end
	return "green"
end

local function printHead(res: any, stream: any)
	stream:writeLine(cli.style(`HTTP/{res.version} {res.status} {res.reason}`, statusColor(res.status), "bold"))
	for name, value in res.headers do
		stream:writeLine(cli.style(name, "cyan") .. ": " .. value)
	end
	stream:writeLine("")
end

function fetch.main(argv: { string }): number?
	local opts, rest = cli.parse(argv, fetch.spec)
	local target = rest[1]
	if target == nil then
		print(cli.help(fetch.spec))
		return 2
	end
	if not string.find(target, "://", 1, true) then
		target = if string.match(target, "^localhost") or string.match(target, "^127%.") or string.match(target, "^%[?::1")
			then "http://" .. target
			else "https://" .. target
	end

	local request: { [string]: any } = {
		headers = cli.headers(opts.header),
		query = cli.pairs(opts.query, "query parameter"),
		timeout = opts.timeout,
		followRedirects = not opts.noFollow,
		maxRedirects = opts.maxRedirects,
		insecure = opts.insecure,
		proxy = opts.proxy,
		decompress = not opts.raw,
		stream = true,
	}
	if #request.query == 0 then
		request.query = nil
	end
	if opts.retry > 0 then
		request.retry = { limit = opts.retry }
	end
	if opts.user then
		local user, password = string.match(opts.user, "^([^:]*):?(.*)$")
		request.auth = { user, password }
	end
	if opts.bearer then
		request.bearer = opts.bearer
	end

	local hasBody = true
	if opts.json then
		local text = cli.readValue(opts.json)
		local ok, err = pcall(json.decode, text)
		if not ok then
			cli.fail(`--json is not valid JSON: {err}`)
		end
		request.body = text
		table.insert(request.headers, { "Content-Type", "application/json" })
	elseif opts.data then
		request.body = cli.readValue(opts.data)
	elseif #opts.field > 0 then
		local form = {}
		for _, pair in cli.pairs(opts.field, "field") do
			table.insert(form, pair)
		end
		request.body = httpx.url.buildQuery(form)
		table.insert(request.headers, { "Content-Type", "application/x-www-form-urlencoded" })
	elseif #opts.form > 0 then
		local parts = {}
		for _, pair in cli.pairs(opts.form, "form field") do
			local name, value = pair[1], pair[2]
			if string.sub(value, 1, 1) == "@" then
				local file = string.sub(value, 2)
				if not fs.isFile(file) then
					cli.fail(`no such file: {file}`)
				end
				table.insert(parts, { name = name, value = fs.readFile(file), filename = path.basename(file) })
			else
				table.insert(parts, { name = name, value = value })
			end
		end
		request.multipart = parts
	else
		hasBody = false
	end

	local method = opts.method or (if opts.head then "HEAD" elseif hasBody then "POST" else "GET")
	request.method = string.upper(method)
	request.url = target

	local stderr = term.stderr
	if opts.verbose then
		local http = httpx.client()
		http:use(function(req, nextFn)
			stderr:writeLine(cli.style(`> {req.method} {req.url}`, "bold"))
			local res, err = nextFn(req)
			-- Printed afterwards: the transport adds Host, Content-Length, ... on the way.
			for name, value in req.headers do
				stderr:writeLine(cli.dim(`> {name}: {value}`))
			end
			stderr:writeLine(cli.dim(">"))
			return res, err
		end)
		request.client = http
	end

	local http = request.client or httpx.request.default
	request.client = nil
	local res, err = http:request(request)
	if res == nil then
		if not opts.silent then
			cli.fail(tostring(err), 1)
		end
		return 1
	end

	if opts.verbose then
		if #res.redirects > 0 then
			for _, url in res.redirects do
				stderr:writeLine(cli.dim(`* redirected to {url}`))
			end
		end
		stderr:writeLine(cli.style(`< HTTP/{res.version} {res.status} {res.reason}`, statusColor(res.status), "bold"))
		for name, value in res.headers do
			stderr:writeLine(cli.dim(`< {name}: {value}`))
		end
		stderr:writeLine(cli.dim(string.format("* %.0f ms to first byte", res.elapsed * 1000)))
		stderr:flush()
	end
	if opts.include or opts.head then
		printHead(res, term.stdout)
	end

	if opts.output then
		local total = tonumber(res.headers:get("content-length"))
		local showProgress = not opts.silent and term.stderr:isTerminal()
		local received = 0
		local temp = opts.output .. ".part"
		fs.writeFile(temp, "")
		while true do
			local chunk, readErr = res:read()
			if readErr then
				pcall(fs.removeFile, temp)
				cli.fail(readErr)
			end
			if chunk == nil then
				break
			end
			fs.appendFile(temp, chunk)
			received += #chunk
			if showProgress then
				local line = if total then string.format("%s / %s (%d%%)", cli.bytes(received), cli.bytes(total), math.floor(received / total * 100)) else cli.bytes(received)
				stderr:write("\r\27[K" .. cli.dim(line)):flush()
			end
		end
		fs.move(temp, opts.output)
		if showProgress then
			stderr:write("\r\27[K"):flush()
		end
		if not opts.silent then
			cli.success(`saved {cli.bytes(received)} to {opts.output}`)
		end
	elseif opts.events then
		for event in res:events() do
			term.stdout:writeLine(cli.style(event.event, "cyan") .. (if event.id then cli.dim(` #{event.id}`) else "") .. " " .. event.data)
			term.stdout:flush()
		end
	elseif opts.fail and res.status >= 400 then
		res:close() -- like curl --fail: no body for errors
	elseif request.method ~= "HEAD" then
		local contentType = res.headers:get("content-type") or ""
		local pretty = not opts.raw and (opts.pretty or cli.isTerminal()) and httpx.core.body.isJson(contentType)
		if pretty then
			local text, readErr = res:text()
			if text == nil then
				cli.fail(readErr or "could not read the body")
			end
			term.stdout:writeLine(cli.prettyJson(text :: string))
		else
			local endedWithNewline = true
			for chunk in res:chunks() do
				term.stdout:write(chunk)
				endedWithNewline = string.sub(chunk, -1) == "\n"
			end
			if res.error then
				cli.fail(res.error)
			end
			if not endedWithNewline and cli.isTerminal() then
				term.stdout:write("\n")
			end
			term.stdout:flush()
		end
	end

	if opts.fail and res.status >= 400 then
		if not opts.silent then
			cli.warn(`{res.status} {res.reason}`)
		end
		return 22
	end
	return 0
end

return fetch
