local fs = require("@lune/fs")
local process = require("@lune/process")

local PROJECT = "test.project.json"
local WORK_DIR = "C:/Temp/vault-tests/" .. (process.env.VAULT_TAG or "main")
local PLACE = WORK_DIR .. "/test.rbxl"
local REAL_PROJECT = "realtest/realtest.project.json"
local REAL_PLACE = WORK_DIR .. "/realtest.rbxl"

fs.writeDir(WORK_DIR)
local build = process.exec("rojo", { "build", PROJECT, "-o", PLACE })
if not build.ok then
	print("rojo build failed:\n" .. build.stdout .. build.stderr)
	process.exit(1)
end

local real = process.exec("rojo", { "build", REAL_PROJECT, "-o", REAL_PLACE })
if not real.ok then
	print("rojo build of the real test place failed:\n" .. real.stdout .. real.stderr)
	process.exit(1)
end

local args = { "run", "tools/specs/run.luau", PLACE }
if process.args[1] then
	table.insert(args, process.args[1])
end
local result = process.exec("lune", args, { stdio = "inherit" })
process.exit(if result.ok then 0 else 1)
