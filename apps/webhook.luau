-- Entry point of the "webhook" program: sn run --entry apps/webhook.luau -- --help
local cli = require("./tools/cli")
cli.run(require("./tools/webhook").main, args)
