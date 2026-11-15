return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local server = api.cluster().server("unit")
	local Record = server.require("ReplicatedStorage.Packages.Vault.Engine.Record")
	local Lock = server.require("ReplicatedStorage.Packages.Vault.Engine.Lock")

	local NOW = 100000
	local DEAD = 630
	local ME = { placeId = 1, jobId = "A" }
	local MINE = { 1, "A", "mine" }
	local THEIRS = { 1, "B", "theirs" }

	local function existing(meta: { [string]: any }?): { [string]: any }
		local fields = meta or {}
		return {
			Data = { Counter = 3 },
			MetaData = {
				ProfileCreateTime = 5,
				SessionLoadCount = fields.count or 2,
				ActiveSession = fields.active,
				ForceLoadSession = fields.force,
				LastUpdate = fields.last,
				MetaTags = {},
			},
			GlobalUpdates = { 0, {} },
		}
	end

	local function start(stored: any, overrides: { [string]: any }?): ({ [string]: any }, string)
		local record, kind = Record.open(stored)
		local intent = {
			me = ME,
			sessionId = "mine",
			now = NOW,
			template = { Counter = 0, Bag = {} },
			ask = false,
			steal = false,
			cancelled = false,
			deadSeconds = DEAD,
		}
		for key, value in overrides or {} do
			intent[key] = value
		end
		Lock.start(record, kind, intent)
		return record, Lock.verdict(record, ME)
	end

	describe("start", function()
		it("decides every case of an existing profile", function()
			local recent = NOW - 10
			local cases = {
				{ name = "free", meta = {}, verdict = "Owned", holder = "A", count = 3, last = NOW },
				{ name = "free with a stale request", meta = { force = { 1, "C" } }, verdict = "Owned", holder = "A", count = 3, last = NOW },
				{ name = "already mine", meta = { active = { 1, "A", "old" }, force = { 1, "C" }, last = recent }, verdict = "Owned", holder = "A", count = 3, last = NOW, session = "old" },
				{ name = "theirs, not asking", meta = { active = THEIRS, last = recent }, verdict = "Refused", holder = "B", count = 2, last = recent },
				{ name = "theirs, asking", meta = { active = THEIRS, last = recent }, intent = { ask = true }, verdict = "Waiting", holder = "B", count = 2, last = recent, force = "A" },
				{ name = "theirs, asking over another request", meta = { active = THEIRS, last = recent, force = { 1, "C" } }, intent = { ask = true }, verdict = "Waiting", holder = "B", count = 2, last = recent, force = "A" },
				{ name = "theirs, silent past the limit", meta = { active = THEIRS, last = NOW - DEAD - 1 }, verdict = "Owned", holder = "A", count = 3, last = NOW },
				{ name = "theirs, silent exactly the limit", meta = { active = THEIRS, last = NOW - DEAD }, intent = { ask = true }, verdict = "Waiting", holder = "B", count = 2, last = NOW - DEAD, force = "A" },
				{ name = "theirs, never updated", meta = { active = THEIRS }, intent = { ask = true }, verdict = "Waiting", holder = "B", count = 2, force = "A" },
				{ name = "steal with my request standing", meta = { active = THEIRS, last = recent, force = { 1, "A" } }, intent = { steal = true }, verdict = "Owned", holder = "A", count = 3, last = NOW },
				{ name = "steal after another server asked", meta = { active = THEIRS, last = recent, force = { 1, "C" } }, intent = { steal = true }, verdict = "Refused", holder = "B", count = 2, last = recent, force = "C" },
				{ name = "steal with no request", meta = { active = THEIRS, last = recent }, intent = { steal = true, ask = true }, verdict = "Refused", holder = "B", count = 2, last = recent },
				{ name = "same job in another place", meta = { active = { 2, "A", "x" }, last = recent }, intent = { ask = true }, verdict = "Waiting", holder = "A", place = 2, count = 2, last = recent, force = "A" },
				{ name = "cancelled on a free profile", meta = {}, intent = { cancelled = true }, verdict = "Free", count = 2 },
				{ name = "cancelled on theirs", meta = { active = THEIRS, last = recent }, intent = { cancelled = true, ask = true }, verdict = "Refused", holder = "B", count = 2, last = recent },
				{ name = "a broken session tag", meta = { active = "broken", last = recent }, intent = { ask = true }, verdict = "Free", count = 2, last = recent },
			}
			for _, case in cases do
				local record, verdict = start(existing(case.meta), case.intent)
				local meta = record.MetaData
				local holder = Record.holder(record)
				local function check(what: string, got: any, wanted: any)
					if got ~= wanted then
						error(`{case.name}: {what} expected {tostring(wanted)}, got {tostring(got)}`)
					end
				end
				check("verdict", verdict, case.verdict)
				check("holder", if holder then holder.jobId else nil, case.holder)
				check("place", if holder then holder.placeId else nil, if case.holder then case.place or 1 else nil)
				check("load count", meta.SessionLoadCount, case.count)
				check("last update", meta.LastUpdate, case.last)
				check("request", if type(meta.ForceLoadSession) == "table" then meta.ForceLoadSession[2] else nil, case.force)
				if case.holder == "A" and (case.place or 1) == 1 then
					check("session id", Record.sessionId(record), case.session or "mine")
				end
				check("data", record.Data.Counter, 3)
			end
		end)

		it("creates a profile from a copy of the template", function()
			local template = { Counter = 0, Bag = {} }
			local record, verdict = start(nil, { template = template })
			expect(verdict).toBe("Owned")
			expect(record.Data.Counter).toBe(0)
			expect(record.Data.Bag ~= template.Bag).toBe(true)
			expect(record.MetaData.ProfileCreateTime).toBe(NOW)
			expect(record.MetaData.SessionLoadCount).toBe(1)
			expect(record.MetaData.LastUpdate).toBe(NOW)
			expect(Record.sessionId(record)).toBe("mine")
			expect(record.GlobalUpdates[1]).toBe(0)
		end)

		it("creates the profile without a lock when the load was cancelled", function()
			local record, verdict = start(nil, { cancelled = true })
			expect(verdict).toBe("Free")
			expect(record.Data.Counter).toBe(0)
			expect(record.MetaData.SessionLoadCount).toBe(0)
			expect(record.MetaData.ActiveSession).toBe(nil)
			expect(record.MetaData.LastUpdate).toBe(nil)
		end)

		it("keeps messages that were waiting for a profile that did not exist yet", function()
			local record, verdict = start({ GlobalUpdates = { 2, { { 2, "gift" } } } })
			expect(verdict).toBe("Owned")
			expect(record.GlobalUpdates[1]).toBe(2)
			expect(record.GlobalUpdates[2][1][2]).toBe("gift")
		end)

		it("starts over a corrupted key and marks it on close", function()
			local record, kind = Record.open("garbage")
			Lock.start(record, kind, {
				me = ME,
				sessionId = "mine",
				now = NOW,
				template = { Counter = 0 },
				ask = true,
				steal = false,
				cancelled = false,
				deadSeconds = DEAD,
			})
			Record.close(record, kind)
			expect(record.WasOverwritten).toBe(true)
			expect(Lock.verdict(record, ME)).toBe("Owned")
		end)
	end)

	describe("save", function()
		local function intent(overrides: { [string]: any }?): { [string]: any }
			local out = {
				me = ME,
				loadIndex = 2,
				now = NOW,
				ending = false,
				data = { Counter = 9 },
				userIds = { 55 },
				robloxMetaData = { Tag = 1 },
				processed = {},
			}
			for key, value in overrides or {} do
				out[key] = value
			end
			return out
		end

		it("writes the data and keeps the lock", function()
			local record = existing({ active = MINE, last = 5, force = { 1, "C" } })
			record.GlobalUpdates = { 3, { { 1, "a" }, { 2, "b" }, { 3, "c" } } }
			local wanted = intent({ processed = { [2] = true } })
			expect(Lock.save(record, wanted)).toBe(true)
			expect(record.Data).toBe(wanted.data)
			expect(record.UserIds).toBe(wanted.userIds)
			expect(record.RobloxMetaData).toBe(wanted.robloxMetaData)
			expect(record.MetaData.LastUpdate).toBe(NOW)
			expect(Record.holder(record).jobId).toBe("A")
			expect(record.MetaData.ForceLoadSession[2]).toBe("C")
			expect(#record.GlobalUpdates[2]).toBe(2)
			expect(record.GlobalUpdates[2][2][2]).toBe("c")
		end)

		it("frees the lock on the last save", function()
			local record = existing({ active = MINE, force = { 1, "C" } })
			expect(Lock.save(record, intent({ ending = true }))).toBe(true)
			expect(record.MetaData.ActiveSession).toBe(nil)
			expect(record.MetaData.ForceLoadSession[2]).toBe("C")
			expect(record.Data.Counter).toBe(9)
		end)

		it("changes nothing when this session does not own the profile", function()
			local cases = {
				{ name = "theirs", record = existing({ active = THEIRS, last = 5 }) },
				{ name = "free", record = existing({ last = 5 }) },
				{ name = "reloaded since", record = existing({ active = MINE, last = 5, count = 3 }) },
				{ name = "another place", record = existing({ active = { 2, "A", "mine" }, last = 5 }) },
				{ name = "messages only", record = { GlobalUpdates = { 1, { { 1, "m" } } } } },
			}
			for _, case in cases do
				local before = Record.copy(case.record)
				local saved = Lock.save(case.record, intent({ ending = true, processed = { [1] = true } }))
				if saved or not api.cloud.same(before, case.record) then
					error(`{case.name}: a session that does not own the profile changed it`)
				end
			end
		end)
	end)

	describe("after a write", function()
		it("tells ownership by server and load count", function()
			expect(Lock.owns(existing({ active = MINE }), ME, 2)).toBe(true)
			expect(Lock.owns(existing({ active = MINE }), ME, 1)).toBe(false)
			expect(Lock.owns(existing({ active = THEIRS }), ME, 2)).toBe(false)
			expect(Lock.owns(existing({}), ME, 2)).toBe(false)
			expect(Lock.owns({ GlobalUpdates = { 0, {} } }, ME, 2)).toBe(false)
		end)

		it("sees a release request only from another server", function()
			expect(Lock.releaseAsked(existing({ active = MINE, force = { 1, "B" } }), ME)).toBe(true)
			expect(Lock.releaseAsked(existing({ active = MINE, force = { 1, "A" } }), ME)).toBe(false)
			expect(Lock.releaseAsked(existing({ active = MINE }), ME)).toBe(false)
			expect(Lock.releaseAsked({ GlobalUpdates = { 0, {} } }, ME)).toBe(false)
		end)
	end)
end
