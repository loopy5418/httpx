--[[
	Argument parsing and terminal output shared by the prebuilt programs.

	Usage lines and examples are written without the program's name: help output starts them
	with the command that actually runs the program ("./build/serve", "httpx serve",
	"sn run --entry apps/serve.luau --", ...), see "cli.program()".

	    local spec = {
	        name = "serve",
	        usage = "[dir] [options]",
	        options = {
	            { "port", "p", type = "number", default = 8080, help = "port to listen on" },
	            { "header", "H", type = "list", help = "extra response header" },
	            { "spa", type = "boolean", help = "serve index.html for unknown paths" },
	        },
	    }
	    local opts, rest = cli.parse(argv, spec)
]]

local process = require("@sonata/process")
local term = require("@sonata/term")
local fs = require("@sonata/fs")
local path = require("@sonata/path")

local cli = {}

export type Option = {
	[number]: string, -- [1] long name, [2] short name
	type: ("string" | "number" | "boolean" | "list")?,
	default: any?,
	help: string?,
	value: string?, -- placeholder shown in help, e.g. "<file>"
}

export type Spec = {
	name: string,
	usage: (string | { string })?, -- after the program name; a list shows alternatives
	description: string?,
	options: { Option }?,
	commands: { { string } }?, -- { name, description }
	examples: { string }?,
}

local HELP: Option = { "help", "h", type = "boolean", help = "show this help" }

local function camel(name: string): string
	return (string.gsub(name, "%-(%a)", string.upper))
end

-- Program names ------------------------------------------------------------------------------

-- Quotes an argument for a shell when it needs it.
local function quote(arg: string): string
	if string.match(arg, "^[%w%./\\_%-=:@,+]+$") then
		return arg
	end
	return "'" .. string.gsub(arg, "'", "'\\''") .. "'"
end

-- The entrypoint the project's manifest names (what "sn run" without --entry starts).
local function manifestEntry(root: string): string
	local ok, text = pcall(fs.readFile, path.join(root, ".sonata", "project.luau"))
	if ok then
		local entry = string.match(text, "entrypoint%s*=%s*[\"']([^\"']+)[\"']")
		if entry then
			return path.normalize(entry)
		end
	end
	return "main.luau"
end

-- Whether "dir" is one of the folders on PATH.
local function onPath(dir: string): boolean
	local okDir, realDir = pcall(fs.realPath, dir)
	if not okDir then
		return false
	end
	for _, entry in path.splitList(process.env.PATH or "") do
		local ok, real = pcall(fs.realPath, entry)
		if ok and real == realDir then
			return true
		end
	end
	return false
end

--- The command that starts this program, as you would type it in a terminal:
---
--- * built with "sn build": the executable's name if it is on PATH ("serve"), otherwise its
---   path from the current folder ("./build/serve");
--- * under "sn run": "sn run --" for the project's entrypoint, or
---   "sn run --entry apps/serve.luau --" for another script (with the project folder when
---   you are outside it).
function cli.base(): string
	local exe = sonata.executable
	if sonata.bundled and exe then
		local name = path.basename(exe)
		if onPath(path.dirname(exe)) then
			return quote((string.gsub(name, "%.[Ee][Xx][Ee]$", "")))
		end
		local rel = path.relative(process.cwd(), exe)
		if #rel > #exe then
			return quote(exe)
		end
		if not string.find(rel, "[/\\]") then
			rel = "." .. path.sep .. rel
		end
		return quote(rel)
	end
	local root = sonata.project.root
	local parts = { "sn", "run" }
	local cwd = process.cwd()
	if not path.isInside(cwd, root) then
		local rel = path.relative(cwd, root)
		table.insert(parts, quote(if #rel > #root then root else rel))
	end
	local entry = path.normalize(path.relative(root, sonata.entry))
	if entry ~= manifestEntry(root) then
		table.insert(parts, "--entry")
		table.insert(parts, quote(path.toPosix(entry)))
	end
	table.insert(parts, "--")
	return table.concat(parts, " ")
end

local programPrefix: string? = nil

--- How to invoke the running program (or tool of the all-in-one program): "cli.base()",
--- plus the tool's name inside the all-in-one program ("./httpx serve").
function cli.program(): string
	if programPrefix == nil then
		programPrefix = cli.base()
	end
	return programPrefix :: string
end

--- Adds a word to the program prefix: the all-in-one program calls it before handing over to
--- a tool, so the tool's help reads "httpx serve [folder]" instead of "serve [folder]".
function cli.enter(name: string)
	programPrefix = cli.program() .. " " .. name
end

--- A command line for the user to run: the program, then "rest".
function cli.command(rest: string?): string
	if rest == nil or rest == "" then
		return cli.program()
	end
	return cli.program() .. " " .. rest
end

-- A hint pointing at the help.
local function seeHelp(): string
	return `(see '{cli.command("--help")}')`
end

--- Help text for a spec.
function cli.help(spec: Spec): string
	local lines = {}
	if spec.description then
		table.insert(lines, spec.description)
		table.insert(lines, "")
	end
	local usage = spec.usage or "[options]"
	local usages: { string } = if type(usage) == "table" then usage else { usage }
	for i, u in usages do
		local label = if i == 1 then term.style("Usage", "bold") else "     "
		table.insert(lines, label .. "  " .. cli.command(u))
	end
	if spec.commands then
		table.insert(lines, "")
		table.insert(lines, term.style("Commands", "bold"))
		local width = 0
		for _, c in spec.commands do
			width = math.max(width, #c[1])
		end
		for _, c in spec.commands do
			table.insert(lines, "  " .. term.style(c[1] .. string.rep(" ", width - #c[1]), "cyan") .. "  " .. c[2])
		end
	end
	local options = table.clone(spec.options or {})
	table.insert(options, HELP)
	table.insert(lines, "")
	table.insert(lines, term.style("Options", "bold"))
	local rows = {}
	local width = 0
	for _, o in options do
		local left = if o[2] then `-{o[2]}, --{o[1]}` else `    --{o[1]}`
		if o.type ~= "boolean" then
			left ..= " " .. (o.value or (if o.type == "number" then "<n>" else "<value>"))
		end
		width = math.max(width, #left)
		local help = o.help or ""
		if o.default ~= nil and o.type ~= "boolean" then
			help ..= term.style(` (default {o.default})`, "dim")
		end
		if o.type == "list" then
			help ..= term.style(" (repeatable)", "dim")
		end
		table.insert(rows, { left, help })
	end
	for _, row in rows do
		table.insert(lines, "  " .. term.style(row[1] .. string.rep(" ", width - #row[1]), "cyan") .. "  " .. row[2])
	end
	if spec.examples then
		table.insert(lines, "")
		table.insert(lines, term.style("Examples", "bold"))
		for _, example in spec.examples do
			table.insert(lines, "  " .. cli.command(example))
		end
	end
	return table.concat(lines, "\n")
end

--- Prints an error and exits with status "code" (default 1).
function cli.fail(message: string, code: number?): never
	term.stderr:writeLine(term.style("error", "red", "bold") .. ": " .. message):flush()
	process.exit(code or 1)
	error("unreachable")
end

function cli.info(message: string)
	term.stderr:writeLine(message):flush()
end

function cli.success(message: string)
	term.stderr:writeLine(term.style("✓ ", "green") .. message):flush()
end

function cli.warn(message: string)
	term.stderr:writeLine(term.style("warning", "yellow", "bold") .. ": " .. message):flush()
end

function cli.dim(text: string): string
	return term.style(text, "dim")
end

function cli.style(text: string, ...: string): string
	return term.style(text, ...)
end

--- Parses arguments. Returns the options (by camelCase name) and the positional arguments.
--- Prints help and exits on -h/--help; exits with a message on bad arguments.
function cli.parse(argv: { string }, spec: Spec): ({ [string]: any }, { string })
	local byLong: { [string]: Option } = {}
	local byShort: { [string]: Option } = {}
	local options = table.clone(spec.options or {})
	table.insert(options, HELP)
	local result: { [string]: any } = {}
	for _, o in options do
		byLong[o[1]] = o
		if o[2] then
			byShort[o[2]] = o
		end
		if o.type == "list" then
			result[camel(o[1])] = {}
		elseif o.default ~= nil then
			result[camel(o[1])] = o.default
		end
	end
	local positionals = {}

	local function set(o: Option, value: string?, flagName: string)
		local key = camel(o[1])
		local kind = o.type or "string"
		if kind == "boolean" then
			result[key] = true
			return
		end
		if value == nil then
			cli.fail(`{flagName} needs a value {seeHelp()}`)
		end
		if kind == "number" then
			local n = tonumber(value)
			if n == nil then
				cli.fail(`{flagName} expects a number, got '{value}'`)
			end
			result[key] = n
		elseif kind == "list" then
			table.insert(result[key], value)
		else
			result[key] = value
		end
	end

	local i = 1
	while i <= #argv do
		local arg = argv[i]
		if arg == "--" then
			for j = i + 1, #argv do
				table.insert(positionals, argv[j])
			end
			break
		end
		local long, inline = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
		if long == nil then
			long = string.match(arg, "^%-%-([%w%-]+)$")
		end
		if long then
			local o = byLong[long]
			if o == nil and string.sub(long, 1, 3) == "no-" and byLong[string.sub(long, 4)] then
				local negated = byLong[string.sub(long, 4)]
				if negated.type == "boolean" then
					result[camel(negated[1])] = false
					i += 1
					continue
				end
			end
			if o == nil then
				cli.fail(`unknown option --{long} {seeHelp()}`)
			end
			assert(o)
			if o.type == "boolean" then
				if inline ~= nil then
					result[camel(o[1])] = inline ~= "false" and inline ~= "0" and inline ~= "no"
				else
					set(o, nil, "--" .. long)
				end
			elseif inline ~= nil then
				set(o, inline, "--" .. long)
			else
				i += 1
				set(o, argv[i], "--" .. long)
			end
		elseif string.match(arg, "^%-%a") then
			-- -p 8080, -p8080, -vs (combined booleans)
			local letters = string.sub(arg, 2)
			local j = 1
			while j <= #letters do
				local letter = string.sub(letters, j, j)
				local o = byShort[letter]
				if o == nil then
					cli.fail(`unknown option -{letter} {seeHelp()}`)
				end
				assert(o)
				if o.type == "boolean" then
					set(o, nil, "-" .. letter)
					j += 1
				else
					local rest = string.sub(letters, j + 1)
					if rest ~= "" then
						set(o, rest, "-" .. letter)
					else
						i += 1
						set(o, argv[i], "-" .. letter)
					end
					break
				end
			end
		else
			table.insert(positionals, arg)
		end
		i += 1
	end

	if result.help then
		print(cli.help(spec))
		process.exit(0)
	end
	return result, positionals
end

--- Parses "Name: value" header arguments into a list of pairs.
function cli.headers(list: { string }): { { string } }
	local out = {}
	for _, h in list do
		local name, value = string.match(h, "^%s*([^:]+):%s*(.*)$")
		if name == nil then
			cli.fail(`invalid header '{h}' (expected "Name: value")`)
		end
		table.insert(out, { string.gsub(name :: string, "%s+$", "") :: string, value :: string })
	end
	return out
end

--- Parses "name=value" arguments into a list of pairs.
function cli.pairs(list: { string }, what: string): { { string } }
	local out = {}
	for _, item in list do
		local name, value = string.match(item, "^([^=]+)=(.*)$")
		if name == nil then
			cli.fail(`invalid {what} '{item}' (expected name=value)`)
		end
		table.insert(out, { name :: string, value :: string })
	end
	return out
end

--- Reads a value that may be "@file" (the file's contents) or "-" / "@-" (standard input).
function cli.readValue(value: string): string
	if value == "-" or value == "@-" then
		return term.stdin:readAll()
	end
	if string.sub(value, 1, 1) == "@" then
		local fs = require("@sonata/fs")
		local file = string.sub(value, 2)
		local ok, data = pcall(fs.readFile, file)
		if not ok then
			cli.fail(`can't read {file}: {data}`)
		end
		return data
	end
	return value
end

--- Asks a question on the terminal. Returns the default for an empty answer.
function cli.ask(question: string, default: string?): string?
	local suffix = if default and default ~= "" then cli.dim(` [{default}]`) else ""
	local answer = term.prompt(term.style("? ", "cyan") .. question .. suffix .. " ")
	if answer == nil then
		return nil
	end
	answer = string.gsub(answer, "^%s+", "")
	answer = string.gsub(answer, "%s+$", "")
	if answer == "" then
		return default
	end
	return answer
end

--- Asks a yes/no question.
function cli.confirm(question: string, default: boolean?): boolean
	local hint = if default then "Y/n" else "y/N"
	local answer = cli.ask(`{question} ({hint})`)
	if answer == nil or answer == "" then
		return default == true
	end
	local lower = string.lower(answer)
	return lower == "y" or lower == "yes"
end

--- Whether standard output is a terminal (so output can be colored or prettified).
function cli.isTerminal(): boolean
	return term.stdout:isTerminal()
end

--- Writes to standard output without a newline.
function cli.write(text: string)
	term.stdout:write(text):flush()
end

--- Pretty-prints JSON text, or returns it unchanged if it isn't JSON.
function cli.prettyJson(text: string): string
	local json = require("@sonata/json")
	local ok, value = pcall(json.decode, text)
	if not ok then
		return text
	end
	return json.encode(value, { indent = 2 })
end

--- Formats a byte count.
function cli.bytes(n: number): string
	if n < 1024 then
		return `{n} B`
	elseif n < 1024 * 1024 then
		return string.format("%.1f KiB", n / 1024)
	elseif n < 1024 * 1024 * 1024 then
		return string.format("%.1f MiB", n / 1024 / 1024)
	end
	return string.format("%.2f GiB", n / 1024 / 1024 / 1024)
end

--- Runs a program's "main(argv)", turning stray errors into a clean message and exit code.
function cli.run(main: (argv: { string }) -> number?, argv: { string })
	local ok, result = xpcall(main, function(err)
		return { message = tostring(err), traceback = debug.traceback(nil, 2) }
	end, argv)
	if not ok then
		local info = result :: any
		term.stderr:writeLine(term.style("error", "red", "bold") .. ": " .. info.message)
		if process.env.HTTPX_DEBUG then
			term.stderr:writeLine(info.traceback)
		end
		term.stderr:flush()
		process.exit(1)
	end
	if type(result) == "number" then
		process.exit(result)
	end
end

return cli
