--[[
	Builds the prebuilt programs into standalone executables.

	    sn run --entry apps/build.luau                    # every program, into build/
	    sn run --entry apps/build.luau -- serve webhook   # just these
	    sn run --entry apps/build.luau -- --out bin --all-libs

	Any option it doesn't know (--all-libs, --standalone, -O 2, ...) is passed to "sn build".
]]

local process = require("@sonata/process")
local path = require("@sonata/path")
local fs = require("@sonata/fs")
local cli = require("./tools/cli")

local PROGRAMS = { "httpx", "serve", "fetch", "webhook", "ws" }

local function main(argv: { string }): number
	local wanted: { string } = {}
	local passthrough: { string } = {}
	local out = "build"
	local i = 1
	while i <= #argv do
		local arg = argv[i]
		if arg == "--out" or arg == "-o" then
			i += 1
			out = argv[i] or cli.fail("--out needs a folder")
		elseif arg == "--help" or arg == "-h" then
			print("Usage: sn run --entry apps/build.luau -- [programs...] [--out <folder>] [sn build options]")
			print("Programs: " .. table.concat(PROGRAMS, ", "))
			return 0
		elseif table.find(PROGRAMS, arg) then
			table.insert(wanted, arg)
		else
			table.insert(passthrough, arg)
			-- Options with a value: keep the value with them.
			if (arg == "-O" or arg == "-g" or arg == "--optimize" or arg == "--debug-level" or arg == "--runtime" or arg == "-l" or arg == "--libs") and argv[i + 1] then
				i += 1
				table.insert(passthrough, argv[i])
			end
		end
		i += 1
	end
	if #wanted == 0 then
		wanted = PROGRAMS
	end

	-- Under "sn run", the running executable is "sn" itself.
	local sn = process.execPath or "sn"
	if not string.find(path.basename(sn), "sn", 1, true) then
		sn = "sn"
	end
	local root = sonata.project.root
	fs.makeDir(path.join(root, out), true)

	local failed = 0
	for _, name in wanted do
		local output = path.join(out, name)
		cli.info(cli.style("building ", "bold") .. name .. cli.dim(` -> {output}`))
		-- httpx itself is the project's entrypoint (init.luau), which runs the all-in-one program.
		local buildArgs = { "build", "--output", output }
		if name ~= "httpx" then
			table.insert(buildArgs, "--entry")
			table.insert(buildArgs, `apps/{name}.luau`)
		end
		for _, extra in passthrough do
			table.insert(buildArgs, extra)
		end
		local result = process.exec(sn, buildArgs, { cwd = root, stdio = "inherit" })
		if not result.ok then
			failed += 1
			cli.warn(`{name} failed (exit code {result.code})`)
		end
	end
	if failed > 0 then
		return 1
	end
	cli.success(`built {#wanted} program{if #wanted == 1 then "" else "s"} into {out}/`)
	return 0
end

cli.run(main, args)
