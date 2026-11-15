--!strict
local Settings = require(script.Parent.Parent.Settings)

local Data = require(script.Parent.Data)

local Receipts = {}

export type Outcome = {
	Decision: Enum.ProductPurchaseDecision,
	Granted: boolean,
	Problem: string?,
}

local function outcome(decision: Enum.ProductPurchaseDecision, granted: boolean, problem: string?): Outcome
	return { Decision = decision, Granted = granted, Problem = problem }
end

local function confirm(player: Player, purchaseId: string): boolean
	local function saved(market: any): boolean
		return type(market.Receipts) == "table" and table.find(market.Receipts, purchaseId) ~= nil
	end
	while Data.loaded(player) do
		if Data.saveConfirmed(player, saved) then
			return true
		end
		task.wait(Settings.SaveRetrySeconds)
	end
	return false
end

function Receipts.settle(player: Player, purchaseId: string, grant: () -> any): Outcome
	local notYet = Enum.ProductPurchaseDecision.NotProcessedYet
	if not Data.loaded(player) then
		return outcome(notYet, false, "inactive profile")
	end
	local granted = false
	if not Data.listed(player, "Receipts", purchaseId) then
		local ok, result = pcall(grant)
		if not ok then
			return outcome(notYet, false, `handler errored: {tostring(result)}`)
		end
		if result ~= true then
			return outcome(notYet, false, `handler returned {tostring(result)}`)
		end
		if not Data.remember(player, "Receipts", purchaseId) then
			return outcome(notYet, true, "ledger write failed")
		end
		granted = true
	end
	if confirm(player, purchaseId) then
		return outcome(Enum.ProductPurchaseDecision.PurchaseGranted, granted)
	end
	return outcome(notYet, granted, "session ended before save")
end

function Receipts.waitFor(check: () -> boolean, timeout: number): boolean
	local spent = 0
	while not check() do
		if spent >= timeout then
			return false
		end
		spent += task.wait(Settings.PollSeconds)
	end
	return true
end

return Receipts
