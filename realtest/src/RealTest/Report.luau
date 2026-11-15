local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Report = {}

local VALUE_NAME = "VaultRealTestReport"

function Report.new()
	local value = Instance.new("StringValue")
	value.Name = VALUE_NAME
	value.Parent = ReplicatedStorage

	local lines: { string } = {}
	local passed, failed = 0, 0
	local report = {}

	function report.line(text: string)
		table.insert(lines, text)
		print(`[VaultRealTest] {text}`)
		value.Value = table.concat(lines, "\n")
	end

	function report.section(title: string)
		report.line("")
		report.line(`== {title}`)
	end

	function report.check(name: string, ok: boolean, detail: string?): boolean
		if ok then
			passed += 1
		else
			failed += 1
		end
		report.line(`{if ok then "PASS" else "FAIL"}  {name}{if detail then `  ({detail})` else ""}`)
		return ok
	end

	function report.info(text: string)
		report.line(`info  {text}`)
	end

	function report.totals(): (number, number)
		return passed, failed
	end

	function report.lines(): { string }
		return lines
	end

	return report
end

return Report
