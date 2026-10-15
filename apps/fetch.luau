-- Entry point of the "fetch" program: sn run --entry apps/fetch.luau -- --help
local cli = require("./tools/cli")
cli.run(require("./tools/fetch").main, args)
