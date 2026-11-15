local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local PROJECT = "test.project.json"
local TOOLS = "tools"
local REAL_TEST = "realtest/src"
local REAL_PROJECT = "realtest/realtest.project.json"
local LINT_DIR = "C:/Temp/vault-syntax"
local LINT_TREE = LINT_DIR .. "/tree"
local CALIBRATION_FILE = "__calibration_broken.luau"

local failures = 0

local function pass(message: string)
	print(`  ok    {message}`)
end

local function failCheck(message: string)
	failures += 1
	print(`  FAIL  {message}`)
end

local function walk(dir: string, visit: (string) -> ())
	for _, name in fs.readDir(dir) do
		local path = `{dir}/{name}`
		if fs.isDir(path) then
			walk(path, visit)
		else
			visit(path)
		end
	end
end

local function collectPaths(node: any, into: { string })
	if type(node) ~= "table" then
		return
	end
	for key, value in node do
		if key == "$path" and type(value) == "string" then
			table.insert(into, value)
		elseif type(value) == "table" then
			collectPaths(value, into)
		end
	end
end

local function sourceRoots(): { string }
	local paths = {}
	collectPaths(serde.decode("json", fs.readFile(PROJECT)).tree, paths)
	local roots = {}
	for _, path in paths do
		if fs.isDir(path) or path:match("%.luau$") then
			table.insert(roots, path)
		end
	end
	table.insert(roots, TOOLS)
	table.insert(roots, REAL_TEST)
	table.sort(roots)
	return roots
end

local function walkSources(visit: (string) -> ())
	for _, root in sourceRoots() do
		if fs.isDir(root) then
			walk(root, visit)
		else
			visit(root)
		end
	end
end

local function checkEncoding()
	print("[1/4] Encoding (BOM breaks modules in Studio)")
	local bad = {}
	walkSources(function(path)
		if path:match("%.luau$") and fs.readFile(path):sub(1, 3) == "\239\187\191" then
			table.insert(bad, path)
		end
	end)
	if #bad == 0 then
		pass("no UTF-8 BOM in the sources")
	else
		failCheck(`BOM found in: {table.concat(bad, ", ")}`)
	end
end

local function checkRojoBuild()
	print("[2/4] rojo build")
	fs.writeDir(LINT_DIR)
	local result = process.exec("rojo", { "build", PROJECT, "-o", `{LINT_DIR}/build.rbxl` })
	local real = process.exec("rojo", { "build", REAL_PROJECT, "-o", `{LINT_DIR}/realtest.rbxl` })
	if result.ok and real.ok then
		pass("both project trees build (note: rojo build does not parse Luau)")
	else
		failCheck("rojo build failed:\n" .. result.stdout .. result.stderr .. real.stdout .. real.stderr)
	end
end

local function copySources(files: { string })
	walkSources(function(path)
		if not path:match("%.luau$") then
			return
		end
		local target = `{LINT_TREE}/{path}`
		fs.writeDir(target:match("^(.*)/[^/]+$") :: string)
		fs.writeFile(target, fs.readFile(path))
		table.insert(files, target)
	end)
end

local function checkSyntax()
	print("[3/4] Luau syntax (luau-lsp, accent-free copy)")
	if fs.isDir(LINT_TREE) then
		fs.removeDir(LINT_TREE)
	end
	local files = {}
	copySources(files)
	local deepest = LINT_TREE
	for _, file in files do
		local dir = file:match("^(.*)/[^/]+$")
		if select(2, dir:gsub("/", "")) > select(2, deepest:gsub("/", "")) then
			deepest = dir
		end
	end
	fs.writeFile(`{deepest}/{CALIBRATION_FILE}`, "local x = \nreturn x +\n")
	table.insert(files, CALIBRATION_FILE)

	local result = process.exec("luau-lsp", { "analyze", "--platform=standard", LINT_TREE })
	local output = result.stdout .. result.stderr

	local calibrated = false
	local errors = {}
	for line in output:gmatch("[^\r\n]+") do
		if line:find("SyntaxError") then
			if line:find(CALIBRATION_FILE, 1, true) then
				calibrated = true
			else
				table.insert(errors, line)
			end
		end
	end

	if not calibrated then
		failCheck("luau-lsp did not report the deliberately broken calibration file: the syntax check is not trustworthy")
		return
	end
	if #errors == 0 then
		pass(`{#files - 1} files parsed, zero syntax errors (calibration file correctly rejected)`)
	else
		failCheck(`{#errors} syntax error(s):\n    ` .. table.concat(errors, "\n    "))
	end
end

local function checkTests()
	print("[4/4] Specs (simulated servers, no Studio)")
	if not fs.isFile(`{LINT_DIR}/build.rbxl`) then
		failCheck("no build to test: the rojo build step failed")
		return
	end
	local result = process.exec("lune", { "run", "tools/specs/run.luau", `{LINT_DIR}/build.rbxl` })
	local summary = result.stdout:match("tests: [^\n]+") or "no summary"
	if result.ok then
		pass(summary)
	else
		failCheck(summary .. "\n" .. result.stdout)
	end
end

checkEncoding()
checkRojoBuild()
checkSyntax()
checkTests()

if failures > 0 then
	print(`\n{failures} check(s) failed`)
	process.exit(1)
end
print("\nall checks passed")
