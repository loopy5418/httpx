--[[
	A tiny test harness: `t.test(name, fn)`, `t.eq(actual, expected, label?)`, `t.ok(value, label?)`.
]]

local term = require("@sonata/term")

local t = {}

local results = { passed = 0, failed = 0, failures = {} :: { string } }
t.results = results

local function describe(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

function t.eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {describe(expected)}, got {describe(actual)}`, 2)
	end
end

function t.ok(value: any, label: string?)
	if not value then
		error(`{label or "assertion"} failed (got {describe(value)})`, 2)
	end
	return value
end

function t.contains(haystack: string?, needle: string, label: string?)
	if type(haystack) ~= "string" or not string.find(haystack, needle, 1, true) then
		error(`{label or "value"}: expected to contain {describe(needle)}, got {describe(haystack)}`, 2)
	end
end

function t.test(name: string, fn: () -> ())
	local ok, err = xpcall(fn, function(e)
		return tostring(e) .. "\n" .. debug.traceback(nil, 2)
	end)
	if ok then
		results.passed += 1
		print(term.style("  ✓ ", "green") .. name)
	else
		results.failed += 1
		table.insert(results.failures, `{name}: {err}`)
		print(term.style("  ✗ ", "red") .. name)
		print(term.style("    " .. string.gsub(tostring(err), "\n", "\n    "), "dim"))
	end
end

function t.section(name: string)
	print(term.style(name, "bold"))
end

return t
