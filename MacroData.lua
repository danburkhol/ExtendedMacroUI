local ADDON_NAME, ns = ...

-- Pure data layer: wraps the macro API, sorting and (later) fuzzy matching.
-- No UI code lives here.

local GetNumMacros = GetNumMacros
local GetMacroInfo = GetMacroInfo
local sort = table.sort

local MacroData = {}
ns.MacroData = MacroData

-- Tab identifiers used across the addon.
MacroData.ACCOUNT = "account"
MacroData.CHARACTER = "character"

-- The WoW Forever (Camelot) client never defines MAX_ACCOUNT_MACROS /
-- MAX_CHARACTER_MACROS -- they stay nil even after Blizzard_MacroUI loads --
-- so every range/slot calculation below would compare against nil and throw.
-- These are that client's real caps, read off its default macro window; the
-- account cap doubles as the character tab's index offset (character macros
-- start at MAX_ACCOUNT_MACROS + 1). Used only as a fallback, and only on
-- Camelot, so any client that exposes the real globals keeps using them.
local CAMELOT_ACCOUNT_MAX = 120
local CAMELOT_CHARACTER_MAX = 30

-- The slot maximums for this client, preferring the live globals and falling
-- back to the Camelot constants when they're absent.
local function Maximums()
	local accountMax, characterMax = MAX_ACCOUNT_MACROS, MAX_CHARACTER_MACROS
	if ns.IS_CAMELOT then
		accountMax = accountMax or CAMELOT_ACCOUNT_MAX
		characterMax = characterMax or CAMELOT_CHARACTER_MAX
	end
	return accountMax, characterMax
end

-- Base index offset and slot maximum for a tab. The maximums come from the
-- game's globals (never hardcode them) except on clients that don't define
-- them at all; see Maximums().
function MacroData.GetRange(tab)
	local accountMax, characterMax = Maximums()
	if tab == MacroData.CHARACTER then
		return accountMax, characterMax
	end
	return 0, accountMax
end

-- numAccount, numCharacter
function MacroData.GetCounts()
	return GetNumMacros()
end

-- How many macros currently exist in a tab.
function MacroData.GetUsed(tab)
	local numAccount, numCharacter = GetNumMacros()
	if tab == MacroData.CHARACTER then
		return numCharacter
	end
	return numAccount
end

-- Case-insensitive A->Z sort; break ties by actual index so order is stable.
local function ByName(a, b)
	local an, bn = a.name:lower(), b.name:lower()
	if an == bn then
		return a.index < b.index
	end
	return an < bn
end
MacroData.ByName = ByName

-- Iterates every existing macro in `tab` (raw slot order), calling
-- fn(actualIndex, name, icon, body). `index` is the actual API index
-- (base + slot). If fn returns a non-nil value, iteration stops and that
-- value is returned; otherwise returns nil. Empty slots are skipped.
local function ForEachMacro(tab, fn)
	local base = MacroData.GetRange(tab)
	local used = MacroData.GetUsed(tab)
	for slot = 1, used do
		local actualIndex = base + slot
		local name, icon, body = GetMacroInfo(actualIndex)
		if name then
			local result = fn(actualIndex, name, icon, body)
			if result ~= nil then
				return result
			end
		end
	end
end

-- Returns an A->Z sorted array of { index, name, icon, body } for the tab.
-- Indices shift after any create/edit/delete, so re-read this list on
-- UPDATE_MACROS rather than caching indices.
function MacroData.GetMacros(tab)
	local list = {}
	ForEachMacro(tab, function(index, name, icon, body)
		list[#list + 1] = { index = index, name = name, icon = icon, body = body }
	end)
	sort(list, ByName)
	return list
end

-- Finds the actual index of the first macro in `tab` matching a snapshot
-- { name, icon, body }. Used to re-resolve a target after a save shifts
-- indices, since macros have no stable id. Returns nil if not found.
function MacroData.FindBySnapshot(tab, snap)
	if not snap then
		return nil
	end
	return ForEachMacro(tab, function(index, name, icon, body)
		if name == snap.name and icon == snap.icon and body == snap.body then
			return index
		end
	end)
end

-- Lowercase and strip all whitespace, so "h pot" and "hpot" behave the same.
function MacroData.NormalizeQuery(query)
	return (query:lower():gsub("%s", ""))
end

-- Case-insensitive subsequence match. `nq` must already be normalized.
-- Returns an array of 1-based byte positions in `name` that were matched,
-- or nil if the whole query could not be matched in order.
local function FuzzyMatch(name, nq)
	local lname = name:lower()
	local qlen = #nq
	if qlen == 0 then
		return nil
	end
	local hits = {}
	local qi = 1
	for i = 1, #lname do
		if lname:sub(i, i) == nq:sub(qi, qi) then
			hits[#hits + 1] = i
			qi = qi + 1
			if qi > qlen then
				break
			end
		end
	end
	if qi > qlen then
		return hits
	end
	return nil
end
MacroData.FuzzyMatch = FuzzyMatch

-- Filters a macro list (from GetMacros) by query. With an empty query the
-- original list is returned unchanged. Otherwise returns a new array of the
-- matching entries, each tagged with `.hits` (match positions) for highlight.
function MacroData.Filter(list, query)
	local nq = MacroData.NormalizeQuery(query)
	if nq == "" then
		return list
	end
	local out = {}
	for _, m in ipairs(list) do
		local hits = FuzzyMatch(m.name, nq)
		if hits then
			m.hits = hits
			out[#out + 1] = m
		end
	end
	return out
end
