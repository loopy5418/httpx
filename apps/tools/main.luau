--[[
	The all-in-one "httpx" program: "httpx <tool> [arguments]". It is what runs when httpx itself
	is the entry script ("sn run", or a program built with plain "sn build").
	Hooray!!
]]

local cli = require("./cli")
local httpx = require("../../lib")

local TOOLS: { { string } } = {
	{ "serve", "serve a folder over HTTP (static files, SPA, live reload)" },
	{ "fetch", "send HTTP requests (curl-like)" },
	{ "webhook", "build, send, receive and inspect webhooks" },
	{ "ws", "WebSocket client and test server" },
	{ "version", "print the versions of httpx and Sonata" },
}

local modules = {
	serve = require("./serve"),
	fetch = require("./fetch"),
	webhook = require("./webhook"),
	ws = require("./ws"),
}

local main = {}

function main.help(): string
	return cli.help({
		name = "httpx",
		description = `httpx {httpx.VERSION}: HTTP tools for Sonata.\nRun {cli.command("<tool> --help")} for a tool's options.`,
		usage = "<tool> [arguments]",
		commands = TOOLS,
		options = {},
		examples = {
			"serve --live",
			"fetch https://example.com -i",
			"webhook listen --port 9000",
		},
	})
end

function main.main(argv: { string }): number?
	local name = argv[1]
	local tool = modules[name or ""]
	if tool then
		cli.enter(name)
		return tool.main(table.move(argv, 2, #argv, 1, {}))
	end
	if name == "version" or name == "--version" or name == "-v" then
		print(`httpx {httpx.VERSION} (sonata {sonata.version}, {sonata.platform})`)
		return 0
	end
	print(main.help())
	if name == nil or name == "help" or name == "-h" or name == "--help" then
		return 0
	end
	cli.fail(`unknown tool '{name}'`)
	return 1
end

return main
