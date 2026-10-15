--[[
	Runs the test suite: sn run --entry tests/run.luau
]]

local process = require("@sonata/process")
local term = require("@sonata/term")
local t = require("./lib")

local suites = {
	require("./core"),
	require("./server"),
	require("./integrations"),
}

for _, suite in suites do
	suite()
end

local r = t.results
print()
if r.failed == 0 then
	print(term.style(`{r.passed} passed`, "green", "bold"))
	process.exit(0)
else
	print(term.style(`{r.failed} failed`, "red", "bold") .. `, {r.passed} passed`)
	process.exit(1)
end
