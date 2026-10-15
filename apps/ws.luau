-- Entry point of the "ws" program: sn run --entry apps/ws.luau -- --help
local cli = require("./tools/cli")
cli.run(require("./tools/ws").main, args)
