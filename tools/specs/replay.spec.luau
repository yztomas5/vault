return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local SEEDS = 10
	local WANTED = {
		"start: took a free profile",
		"start: already the holder",
		"start asking: left with the other server",
		"start stealing: took it from another server",
		"start: took it from another server",
		"save",
		"last save",
		"write that changed nothing",
		"message",
	}

	local function describeCommit(commit: any): string
		local function brief(record: any): string
			if type(record) ~= "table" then
				return tostring(record)
			end
			local meta = record.MetaData or {}
			local active, force = meta.ActiveSession, meta.ForceLoadSession
			return string.format(
				"holder %s request %s count %s last %s sent %s pending %s",
				tostring(active and active[2]),
				tostring(force and force[2]),
				tostring(meta.SessionLoadCount),
				tostring(meta.LastUpdate),
				tostring(record.GlobalUpdates and record.GlobalUpdates[1]),
				tostring(record.GlobalUpdates and #record.GlobalUpdates[2])
			)
		end
		return `{commit.key} by {tostring(commit.jobId)} at {commit.at}: [{brief(commit.before)}] -> [{brief(commit.after)}]`
	end

	local function scripted()
		local cluster = api.cluster({ seed = 21 })
		local commits = cluster.trace()
		local function server(name: string)
			local made = cluster.server(name)
			made.store = api.drivers.ProfileStore(made).open("Players", api.soakTemplate())
			return made
		end
		local function start(on: any, key: string)
			on.spawn(function()
				on.store.start(key)
			end)
		end
		local a, b, c, d = server("a"), server("b"), server("c"), server("d")
		start(a, "silent")
		cluster.run(5)
		a.kill()
		cluster.run(700)
		start(b, "silent")
		cluster.run(5)
		cluster.cloud.faults.messageLoss = 1
		start(d, "contended")
		cluster.run(5)
		start(b, "contended")
		cluster.run(40)
		start(c, "contended")
		cluster.run(120)
		return { commits = commits, epoch = cluster.cloud.epoch, placeId = api.placeId }
	end

	local traces: { any }? = nil

	local function recorded(): { any }
		if not traces then
			local list = { scripted() }
			for seed = 1, SEEDS do
				table.insert(list, api.soak("ProfileStore", seed, { trace = true }))
			end
			traces = list
		end
		return traces :: { any }
	end

	local function replay(patches: { [string]: (string) -> string }?)
		local unit = api.cluster().server("unit", { patches = patches })
		local Record = unit.require("ReplicatedStorage.Packages.Vault.Engine.Record")
		local Lock = unit.require("ReplicatedStorage.Packages.Vault.Engine.Lock")
		local Settings = unit.require("ReplicatedStorage.Packages.Vault.Engine.Settings")
		local seen: { [string]: number } = {}
		local unexplained: { string } = {}
		local total = 0
		for _, result in recorded() do
			local context = {
				placeId = result.placeId,
				epoch = result.epoch,
				template = api.soakTemplate(),
				message = api.soakMessage(),
				deadSeconds = Settings.DeadSeconds,
				messageQueue = Settings.MessageQueue,
			}
			for _, commit in result.commits do
				total += 1
				local label = api.explain(Record, Lock, commit, context)
				if label then
					seen[label] = (seen[label] or 0) + 1
				else
					table.insert(unexplained, describeCommit(commit))
				end
			end
		end
		return { seen = seen, unexplained = unexplained, total = total }
	end

	describe("every write ProfileStore made in the random runs", function()
		it("is reproduced by Record and Lock", function()
			local result = replay()
			if #result.unexplained > 0 then
				error(`{#result.unexplained} of {result.total} writes not reproduced, first: {result.unexplained[1]}`, 0)
			end
			expect(result.total).toBeAtLeast(1000)
			for _, label in WANTED do
				if not result.seen[label] then
					error(`the runs never produced: {label}`, 0)
				end
			end
		end)

		it("is not reproduced by a Lock with the wrong rules", function()
			local function swap(from: string, to: string): (string) -> string
				return function(source: string): string
					local out, count = string.gsub(source, string.gsub(from, "%p", "%%%0"), (string.gsub(to, "%%", "%%%%")))
					assert(count > 0, `calibration target not found: {from}`)
					return out
				end
			end
			local wrong = {
				{ module = "Lock", patch = swap("meta.SessionLoadCount = Record.loadCount(record) + 1", "meta.SessionLoadCount = Record.loadCount(record)") },
				{ module = "Lock", patch = swap("intent.now - last > intent.deadSeconds", "intent.now - last > intent.deadSeconds * 2") },
				{ module = "Lock", patch = swap("if Record.isSession(meta.ForceLoadSession, intent.me) then\n\t\t\ttake(meta, intent)", "if false then\n\t\t\ttake(meta, intent)") },
				{ module = "Lock", patch = swap("record.MetaData.LastUpdate = intent.now", "record.MetaData.LastUpdate = intent.now + 5") },
				{ module = "Lock", patch = swap("meta.ForceLoadSession = { intent.me.placeId, intent.me.jobId }", "meta.ForceLoadSession = { intent.me.placeId, intent.me.jobId, intent.sessionId }") },
				{ module = "Record", patch = swap("messages[1] += 1", "messages[1] += 2") },
				{ module = "Record", patch = swap("stored.WasOverwritten = false", "stored.WasOverwritten = nil") },
			}
			for index, case in wrong do
				local result = replay({ [case.module] = case.patch })
				if #result.unexplained == 0 then
					error(`wrong rule {index} in {case.module} still reproduced every write`, 0)
				end
			end
		end)
	end)
end
