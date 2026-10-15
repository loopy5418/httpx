-- Entry point of the "serve" program: sn run --entry apps/serve.luau -- --help
local cli = require("./tools/cli")
cli.run(require("./tools/serve").main, args)
