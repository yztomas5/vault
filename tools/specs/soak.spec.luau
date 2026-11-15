return function(api)
	local expect, it, describe = api.expect, api.it, api.describe

	local SEEDS = 25
	local CALIBRATION_SEEDS = 5

	for _, driverName in api.drivers.list do
		describe(driverName, function()
			for seed = 1, SEEDS do
				it(`keeps every profile consistent through random joins, crashes and faults, seed {seed}`, function()
					local result = api.soak(driverName, seed)
					if #result.violations > 0 then
						error(result.violations[1], 0)
					end
					if #result.errors > 0 then
						error(result.errors[1], 0)
					end
					if #result.stuck > 0 and not api.drivers.traits[driverName].ghostLocks then
						error(result.stuck[1], 0)
					end
					if #result.unreachable > 0 then
						error(result.unreachable[1], 0)
					end
					if #result.lost > 0 then
						error(result.lost[1], 0)
					end
					if #result.unbalanced > 0 then
						error(result.unbalanced[1], 0)
					end
					expect(result.stats.sessions).toBeAtLeast(20)
					expect(result.stats.increments).toBeAtLeast(50)
					expect(result.stats.crashes + result.stats.closes).toBeAtLeast(5)
					expect(result.stats.hops).toBeAtLeast(5)
					expect(result.stats.gifts).toBeAtLeast(5)
				end)
			end

			it("catches a build that writes over profiles it lost", function()
				local caught = 0
				for seed = 1, CALIBRATION_SEEDS do
					caught += if #api.soak(driverName, seed, { broken = "ownership" }).violations > 0 then 1 else 0
				end
				expect(caught).toBeAtLeast(1)
			end)
		end)
	end
end
