local ADDON_NAME, ns = ...

-- Import/export data layer: collects macros and saved messages into a payload,
-- encodes it as a shareable string, decodes + validates one, and applies an
-- import. No UI code lives here (TransferWizard.lua owns the window).
--
-- String format: "!EMU:<v>!" .. Base64(Deflate(CBOR(payload))) -- the same
-- serialize/compress/encode pipeline Blizzard uses for its own share strings
-- (Blizzard_CooldownViewer). The prefix makes a string recognizable and carries
-- the format version before anything is decoded.
--
-- Payload (v1):
--   { v = 1, addon = "<TOC version>", char = "Name", realm = "Realm",
--     time = <server epoch seconds>,
--     general   = { { name, icon, body }, ... },
--     character = { { name, icon, body }, ... },
--     messages  = { { name, content, outputs = { { chatType, channel? } } } } }
--
-- "Entries" are the flat records the wizard lists and selects:
--   { kind = "general"|"character"|"message", key, name, icon?, body?,
--     content?, outputs? }

local C_EncodingUtil = C_EncodingUtil
local C_AddOns = C_AddOns
local Enum = Enum
local CreateMacro = CreateMacro
local EditMacro = EditMacro
local GetRealmName = GetRealmName
local GetServerTime = GetServerTime
local InCombatLockdown = InCombatLockdown
local UnitName = UnitName
local strlenutf8 = strlenutf8
local strtrim = strtrim

local MacroData = ns.MacroData
local Messages = ns.Messages

local Transfer = {}
ns.Transfer = Transfer

Transfer.VERSION = 1
local PREFIX_PATTERN = "^!EMU:(%d+)!(.+)$"

-- Limits enforced on import, matching the editors' own limits.
local MACRO_NAME_MAX = 16
local MACRO_BODY_MAX = 255
local MESSAGE_NAME_MAX = 50
local MESSAGE_CONTENT_MAX = 255
local QUESTION_MARK_ICON = ns.QUESTION_MARK_ICON

-- The chat types a saved message output may use (besides CHANNEL).
local VALID_CHAT_TYPES = {}
for _, o in ipairs(Messages.DefaultOutputs()) do
	VALID_CHAT_TYPES[o.chatType] = true
end

Transfer.KINDS = { "general", "character", "message" }
Transfer.KIND_LABEL = {
	general = "General Macros",
	character = "Character Macros",
	message = "Saved Messages",
}
-- Which MacroData tab a macro kind lives in.
local KIND_TAB = {
	general = MacroData.ACCOUNT,
	character = MacroData.CHARACTER,
}

--------------------------------------------------------------------------------
-- Collecting (local data -> entries)
--------------------------------------------------------------------------------

local CopyOutputs = Messages.CopyOutputs

-- The player's own macros and messages as entries, grouped by kind and sorted
-- A->Z. Keys are unique across kinds so a selection set can mix them.
function Transfer.LocalEntries()
	local groups = { general = {}, character = {}, message = {} }
	for kind, tab in pairs(KIND_TAB) do
		for _, m in ipairs(MacroData.GetMacros(tab)) do
			local list = groups[kind]
			list[#list + 1] = {
				kind = kind,
				key = kind .. ":" .. m.index,
				name = m.name,
				icon = m.icon,
				body = m.body or "",
			}
		end
	end
	for _, item in ipairs(Messages.ListItems()) do
		local m = Messages.GetById(item.key)
		if m then
			local list = groups.message
			list[#list + 1] = {
				kind = "message",
				key = "message:" .. m.id,
				name = m.name,
				content = m.content or "",
				outputs = CopyOutputs(m.outputs),
			}
		end
	end
	return groups
end

-- Builds a payload table from a list of entries (any kinds, any order).
function Transfer.BuildPayload(entries)
	local version = C_AddOns and C_AddOns.GetAddOnMetadata
		and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or nil
	local payload = {
		v = Transfer.VERSION,
		addon = version,
		char = UnitName("player"),
		realm = GetRealmName(),
		time = GetServerTime(),
		general = {},
		character = {},
		messages = {},
	}
	for _, e in ipairs(entries) do
		if e.kind == "message" then
			payload.messages[#payload.messages + 1] = {
				name = e.name,
				content = e.content,
				outputs = CopyOutputs(e.outputs),
			}
		elseif KIND_TAB[e.kind] then
			local list = payload[e.kind]
			list[#list + 1] = { name = e.name, icon = e.icon, body = e.body }
		end
	end
	return payload
end

--------------------------------------------------------------------------------
-- Encoding / decoding
--------------------------------------------------------------------------------

-- Payload table -> share string. Returns string, or nil + error.
function Transfer.Encode(payload)
	if not C_EncodingUtil then
		return nil, "This client has no encoding support (C_EncodingUtil)."
	end
	local ok, result = pcall(function()
		local serialized = C_EncodingUtil.SerializeCBOR(payload)
		local compressed = C_EncodingUtil.CompressString(serialized, Enum.CompressionMethod.Deflate)
		return C_EncodingUtil.EncodeBase64(compressed)
	end)
	if not ok or type(result) ~= "string" then
		return nil, "Couldn't encode the export: " .. tostring(result)
	end
	return ("!EMU:%d!%s"):format(Transfer.VERSION, result)
end

-- Upgraders from older payload versions to the current one, keyed by the old
-- version: UPGRADES[n](payload) returns a version n+1 payload. Empty for v1.
local UPGRADES = {}

local function ValidName(name, max)
	if type(name) ~= "string" then
		return nil
	end
	name = strtrim(name)
	if name == "" or strlenutf8(name) > max then
		return nil
	end
	return name
end

local function SanitizeMacro(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local name = ValidName(raw.name, MACRO_NAME_MAX)
	local body = raw.body
	if body == nil then
		body = ""
	end
	if not name or type(body) ~= "string" or #body > MACRO_BODY_MAX then
		return nil
	end
	local icon = raw.icon
	if type(icon) ~= "number" and type(icon) ~= "string" then
		icon = QUESTION_MARK_ICON
	end
	return { name = name, icon = icon, body = body }
end

local function SanitizeMessage(raw)
	if type(raw) ~= "table" then
		return nil
	end
	local name = ValidName(raw.name, MESSAGE_NAME_MAX)
	local content = raw.content
	if content == nil then
		content = ""
	end
	if not name or type(content) ~= "string" or #content > MESSAGE_CONTENT_MAX then
		return nil
	end
	local outputs = {}
	if type(raw.outputs) == "table" then
		for _, o in ipairs(raw.outputs) do
			if type(o) == "table" then
				if o.chatType == "CHANNEL" and type(o.channel) == "string" and o.channel ~= "" then
					outputs[#outputs + 1] = { chatType = "CHANNEL", channel = o.channel }
				elseif VALID_CHAT_TYPES[o.chatType] then
					outputs[#outputs + 1] = { chatType = o.chatType }
				end
			end
		end
	end
	return { name = name, content = content, outputs = outputs }
end

-- Share string -> sanitized payload, or nil + a user-facing error. Invalid
-- individual entries are dropped and counted in payload.dropped.
function Transfer.Decode(text)
	if type(text) ~= "string" then
		return nil, "Nothing to import."
	end
	text = text:gsub("%s+", "")
	local version, data = text:match(PREFIX_PATTERN)
	version = tonumber(version)
	if not version then
		return nil, "Not a valid Extended Macro UI export."
	end
	if version > Transfer.VERSION then
		return nil, "This export was made by a newer version of Extended Macro UI. Update the addon to import it."
	end
	if not C_EncodingUtil then
		return nil, "This client has no decoding support (C_EncodingUtil)."
	end

	local ok, payload = pcall(function()
		local compressed = C_EncodingUtil.DecodeBase64(data)
		local serialized = C_EncodingUtil.DecompressString(compressed, Enum.CompressionMethod.Deflate)
		return C_EncodingUtil.DeserializeCBOR(serialized)
	end)
	if not ok or type(payload) ~= "table" then
		return nil, "Not a valid Extended Macro UI export (it may be incomplete or damaged)."
	end

	local v = tonumber(payload.v) or version
	while v < Transfer.VERSION do
		local upgrade = UPGRADES[v]
		if not upgrade then
			return nil, ("Unsupported export version %d."):format(v)
		end
		payload = upgrade(payload)
		v = v + 1
	end

	local clean = {
		v = Transfer.VERSION,
		addon = type(payload.addon) == "string" and payload.addon or nil,
		char = type(payload.char) == "string" and payload.char or nil,
		realm = type(payload.realm) == "string" and payload.realm or nil,
		time = type(payload.time) == "number" and payload.time or nil,
		general = {},
		character = {},
		messages = {},
		dropped = 0,
	}
	for _, section in ipairs({ "general", "character" }) do
		if type(payload[section]) == "table" then
			for _, raw in ipairs(payload[section]) do
				local m = SanitizeMacro(raw)
				if m then
					clean[section][#clean[section] + 1] = m
				else
					clean.dropped = clean.dropped + 1
				end
			end
		end
	end
	if type(payload.messages) == "table" then
		for _, raw in ipairs(payload.messages) do
			local m = SanitizeMessage(raw)
			if m then
				clean.messages[#clean.messages + 1] = m
			else
				clean.dropped = clean.dropped + 1
			end
		end
	end
	return clean
end

-- A decoded payload's contents as entries grouped by kind (A->Z), the same
-- shape as Transfer.LocalEntries so the wizard's browser handles both.
function Transfer.PayloadEntries(payload)
	local groups = { general = {}, character = {}, message = {} }
	for _, kind in ipairs({ "general", "character" }) do
		for i, m in ipairs(payload[kind]) do
			local list = groups[kind]
			list[#list + 1] = {
				kind = kind,
				key = ("%s:%04d"):format(kind, i),
				name = m.name,
				icon = m.icon,
				body = m.body,
			}
		end
		ns.SortByName(groups[kind])
	end
	for i, m in ipairs(payload.messages) do
		local list = groups.message
		list[#list + 1] = {
			kind = "message",
			key = ("message:%04d"):format(i),
			name = m.name,
			content = m.content,
			outputs = m.outputs,
		}
	end
	ns.SortByName(groups.message)
	return groups
end

--------------------------------------------------------------------------------
-- Importing
--------------------------------------------------------------------------------

-- Actual index of the first macro in `tab` whose name matches (trimmed,
-- case-insensitive), or nil. Re-scanned per entry since indices shift.
local function FindMacroByName(tab, name)
	local target = strtrim(name):lower()
	for _, m in ipairs(MacroData.GetMacros(tab)) do
		if strtrim(m.name):lower() == target then
			return m.index
		end
	end
	return nil
end

local function ImportMacro(entry, conflict)
	local tab = KIND_TAB[entry.kind]
	if InCombatLockdown() then
		return false, "can't change macros in combat"
	end
	if conflict == "override" then
		local index = FindMacroByName(tab, entry.name)
		if index then
			local ok, err = pcall(EditMacro, index, entry.name, entry.icon, entry.body)
			if not ok then
				return false, tostring(err)
			end
			return true
		end
	end
	local _, max = MacroData.GetRange(tab)
	if MacroData.GetUsed(tab) >= max then
		return false, "no free " .. (entry.kind == "character" and "character" or "general") .. " macro slot"
	end
	local ok, result = pcall(CreateMacro, entry.name, entry.icon, entry.body, entry.kind == "character")
	if not ok then
		return false, tostring(result)
	end
	if not result then
		return false, "the game refused to create it"
	end
	return true
end

-- Imports the given entries with `conflict` = "override" or "duplicate".
-- Returns { ok = n, failed = n, errors = { "Kind \"name\": reason", ... } }.
function Transfer.Import(entries, conflict)
	local report = { ok = 0, failed = 0, errors = {} }
	for _, e in ipairs(entries) do
		local ok, err
		if e.kind == "message" then
			ok, err = Messages.Import(e, conflict)
		elseif KIND_TAB[e.kind] then
			ok, err = ImportMacro(e, conflict)
		else
			ok, err = false, "unknown entry type"
		end
		if ok then
			report.ok = report.ok + 1
		else
			report.failed = report.failed + 1
			report.errors[#report.errors + 1] = ("%s \"%s\": %s"):format(
				Transfer.KIND_LABEL[e.kind] or tostring(e.kind), tostring(e.name), tostring(err or "unknown error"))
		end
	end
	return report
end
