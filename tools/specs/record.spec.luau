return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local Record = api.cluster().server("unit").require("ReplicatedStorage.Packages.Vault.Engine.Record")

	local function regular(): { [string]: any }
		return {
			Data = { Counter = 1 },
			MetaData = { SessionLoadCount = 4, ActiveSession = { 7, "job", "sid" } },
			GlobalUpdates = { 2, { { 2, "hello" } } },
			UserIds = { 12 },
			RobloxMetaData = { Tag = true },
		}
	end

	describe("open", function()
		it("classifies every shape a key can hold", function()
			local onlyMessages = { GlobalUpdates = { 3, { { 3, "m" } } } }
			local cases = {
				{ name = "nothing", stored = nil, kind = "Missing", sent = 0 },
				{ name = "a string", stored = "garbage", kind = "Overwritten", sent = 0 },
				{ name = "a number", stored = 5, kind = "Overwritten", sent = 0 },
				{ name = "a regular profile", stored = regular(), kind = "Existing", sent = 2 },
				{ name = "messages only", stored = onlyMessages, kind = "Missing", sent = 3 },
				{ name = "data without metadata", stored = { Data = {}, GlobalUpdates = { 0, {} } }, kind = "Overwritten", sent = 0 },
				{ name = "metadata without data", stored = { MetaData = {}, GlobalUpdates = { 0, {} } }, kind = "Overwritten", sent = 0 },
				{ name = "no messages table", stored = { Data = {}, MetaData = {} }, kind = "Overwritten", sent = 0 },
				{ name = "an empty table", stored = {}, kind = "Overwritten", sent = 0 },
			}
			for _, case in cases do
				local record, kind = Record.open(case.stored)
				if kind ~= case.kind then
					error(`{case.name}: expected {case.kind}, got {kind}`)
				end
				expect(record.GlobalUpdates[1]).toBe(case.sent)
			end
		end)

		it("keeps a regular profile as the same table and clears the overwritten mark", function()
			local stored = regular()
			stored.WasOverwritten = true
			local record = Record.open(stored)
			expect(record).toBe(stored)
			expect(record.WasOverwritten).toBe(false)
		end)

		it("drops everything but the messages of a profile that only has messages", function()
			local stored = { GlobalUpdates = { 1, { { 1, "m" } } }, WasOverwritten = true }
			local record = Record.open(stored)
			expect(record.GlobalUpdates).toBe(stored.GlobalUpdates)
			expect(record.WasOverwritten).toBe(nil)
		end)
	end)

	describe("close", function()
		it("marks only overwritten records and returns the user ids and metadata", function()
			local record = regular()
			local out, userIds, metadata = Record.close(record, "Existing")
			expect(out).toBe(record)
			expect(userIds).toBe(record.UserIds)
			expect(metadata).toBe(record.RobloxMetaData)
			expect(record.WasOverwritten).toBe(nil)
			expect(Record.close({ GlobalUpdates = { 0, {} } }, "Missing").WasOverwritten).toBe(nil)
			expect(Record.close({ GlobalUpdates = { 0, {} } }, "Overwritten").WasOverwritten).toBe(true)
		end)
	end)

	describe("copy and reconcile", function()
		it("copies deeply", function()
			local source = { A = { B = { 1, 2 } } }
			local copy = Record.copy(source)
			copy.A.B[1] = 9
			expect(source.A.B[1]).toBe(1)
			expect(Record.copy(5)).toBe(5)
		end)

		it("fills what is missing and never replaces what is there", function()
			local target = { Cash = 5, Settings = { Music = false }, Weird = 3, [1] = "kept" }
			local template = { Cash = 0, Gems = 1, Settings = { Music = true, Sfx = true }, Weird = { Deep = 1 }, Bag = { 1, 2 }, [1] = "x", [2] = "y" }
			Record.reconcile(target, template)
			expect(target.Cash).toBe(5)
			expect(target.Gems).toBe(1)
			expect(target.Settings.Music).toBe(false)
			expect(target.Settings.Sfx).toBe(true)
			expect(target.Weird).toBe(3)
			expect(target[1]).toBe("kept")
			expect(target[2]).toBe(nil)
			target.Bag[1] = 9
			expect(template.Bag[1]).toBe(1)
		end)
	end)

	describe("session fields", function()
		it("reads the holder, the session id and the load count", function()
			local record = regular()
			expect(Record.holder(record).placeId).toBe(7)
			expect(Record.holder(record).jobId).toBe("job")
			expect(Record.sessionId(record)).toBe("sid")
			expect(Record.loadCount(record)).toBe(4)
			expect(Record.isSession(record.MetaData.ActiveSession, { placeId = 7, jobId = "job" })).toBe(true)
			expect(Record.isSession(record.MetaData.ActiveSession, { placeId = 8, jobId = "job" })).toBe(false)
			expect(Record.isSession(record.MetaData.ActiveSession, { placeId = 7, jobId = "other" })).toBe(false)
			expect(Record.isSession(nil, { placeId = 7, jobId = "job" })).toBe(false)
			expect(Record.isSession("job", { placeId = 7, jobId = "job" })).toBe(false)
		end)

		it("answers with nothing for a record without a session", function()
			local record = { GlobalUpdates = { 0, {} } }
			expect(Record.holder(record)).toBe(nil)
			expect(Record.sessionId(record)).toBe(nil)
			expect(Record.loadCount(record)).toBe(0)
			expect(Record.sessionId({ MetaData = { ActiveSession = { 1, "old" } } })).toBe(nil)
		end)
	end)

	describe("messages", function()
		it("numbers messages and keeps numbering after old ones are dropped", function()
			local record = { GlobalUpdates = { 0, {} } }
			for index = 1, 5 do
				Record.addMessage(record, { N = index }, 3)
			end
			expect(record.GlobalUpdates[1]).toBe(5)
			expect(#record.GlobalUpdates[2]).toBe(3)
			expect(record.GlobalUpdates[2][1][1]).toBe(3)
			expect(record.GlobalUpdates[2][3][2].N).toBe(5)
		end)

		it("drops only the processed ones", function()
			local record = { GlobalUpdates = { 4, { { 1, "a" }, { 2, "b" }, { 3, "c" }, { 4, "d" } } } }
			Record.dropMessages(record, { [2] = true, [4] = true, [9] = true })
			expect(#record.GlobalUpdates[2]).toBe(2)
			expect(record.GlobalUpdates[2][1][2]).toBe("a")
			expect(record.GlobalUpdates[2][2][2]).toBe("c")
			expect(record.GlobalUpdates[1]).toBe(4)
		end)

		it("reads both the current format and the ProfileService one", function()
			local record = { GlobalUpdates = { 2, { { 1, "new" }, { 2, 5, false, "old" } } } }
			local list = Record.messages(record)
			expect(#list).toBe(2)
			expect(list[1].id).toBe(1)
			expect(list[1].data).toBe("new")
			expect(list[2].id).toBe(2)
			expect(list[2].data).toBe("old")
			expect(#Record.messages({})).toBe(0)
		end)
	end)
end
