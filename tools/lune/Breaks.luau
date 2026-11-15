export type Break = { module: string, patch: (source: string) -> string }

local function swap(module: string, from: string, to: string): Break
	return {
		module = module,
		patch = function(source: string): string
			local out, count = string.gsub(source, string.gsub(from, "%p", "%%%0"), (string.gsub(to, "%%", "%%%%")))
			assert(count > 0, `calibration target not found in {module}: {from}`)
			return out
		end,
	}
end

local Breaks = {}

Breaks.list = {
	ProfileStore = {
		ownership = swap(
			"ProfileStore",
			"session_owns_profile = IsThisSession(active_session) and session_load_count == profile.load_index",
			"session_owns_profile = true"
		),
		shutdown = swap("ProfileStore", 'SaveProfileAsync(profile, true, nil, "Shutdown")', "local _ = profile"),
		deadLimit = swap("ProfileStore", "local ASSUME_DEAD = 630", "local ASSUME_DEAD = 63000"),
		lastSave = swap("ProfileStore", "local repeat_save_flag = true", "local repeat_save_flag = false"),
	},
	Engine = {
		ownership = swap("Lock", "if not Lock.owns(record, intent.me, intent.loadIndex) then", "if false then"),
		shutdown = swap("Shutdown", 'Saver.save(context, session, true, "Shutdown")', "local _ = session"),
		deadLimit = swap("Settings", "DeadSeconds = 630", "DeadSeconds = 63000"),
		lastSave = swap("Saver", "if not ending then\n\t\t\tbreak", "if true then\n\t\t\tbreak"),
	},
} :: { [string]: { [string]: Break } }

function Breaks.patches(driverName: string, name: string?): { [string]: (source: string) -> string }?
	if not name then
		return nil
	end
	local found = Breaks.list[driverName][name]
	return { [found.module] = found.patch }
end

return Breaks
