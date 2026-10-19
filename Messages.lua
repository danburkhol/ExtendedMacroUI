local ADDON_NAME, ns = ...

-- Saved Messages data layer: storage, chat-output enumeration and sending.
--
-- Messages live entirely in SavedVariables (ExtendedMacroUIDB.messages),
-- outside the game's macro system, so they never consume macro slots. Each is
-- { id, name, content, outputs = { { chatType = "SAY" },
-- { chatType = "CHANNEL", channel = "General" }, ... } }. `id` is a stable
-- monotonic number (unlike macro indices, it never shifts).
--
-- No UI code lives here.

local C_ChatInfo = C_ChatInfo
local C_GuildInfo = C_GuildInfo
local GetChannelList = GetChannelList
local GetChannelName = GetChannelName
local GetTime = GetTime
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local IsInGuild = IsInGuild
local UnitIsGroupLeader = UnitIsGroupLeader
local UnitIsGroupAssistant = UnitIsGroupAssistant
local HOME = LE_PARTY_CATEGORY_HOME
local INSTANCE = LE_PARTY_CATEGORY_INSTANCE
local tinsert = tinsert
local tremove = tremove
local strtrim = strtrim
local sort = table.sort
local ceil = math.ceil

-- Anti-spam default and floor; the EMU settings slider overrides the default
-- (clamped to >= MIN_INTERVAL).
local DEFAULT_INTERVAL = 15
local MIN_INTERVAL = 0.5

-- Matches the message name box's SetMaxLetters; the duplicate suffix is trimmed
-- to fit this so a long name can still be copied.
local NAME_MAX = 50

local Messages = {}
ns.Messages = Messages

-- GetTime() (seconds, monotonic) of the last send, shared across every message
-- so the throttle is global. Session-local, which is all anti-spam needs.
Messages.lastSend = 0

-- Localized label with a readable fallback if the global string is missing.
local function L(global, fallback)
	return (type(global) == "string" and global) or fallback
end

-- The fixed "speak" targets every player has, in display order. `chatType` is
-- the SendChatMessage type; `display` is the localized label shown in the UI.
local DEFAULT_OUTPUTS = {
	{ chatType = "SAY",           display = L(SAY, "Say") },
	{ chatType = "YELL",          display = L(YELL, "Yell") },
	{ chatType = "PARTY",         display = L(PARTY, "Party") },
	{ chatType = "RAID",          display = L(RAID, "Raid") },
	{ chatType = "RAID_WARNING",  display = L(RAID_WARNING, "Raid Warning") },
	{ chatType = "INSTANCE_CHAT", display = L(INSTANCE_CHAT, "Instance") },
	{ chatType = "GUILD",         display = L(GUILD, "Guild") },
	{ chatType = "OFFICER",       display = L(OFFICER, "Officer") },
}

--------------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------------

-- The live message array (never nil once the DB is initialized).
function Messages.All()
	return (ns.db and ns.db.messages) or {}
end

function Messages.GetById(id)
	for _, m in ipairs(Messages.All()) do
		if m.id == id then
			return m
		end
	end
	return nil
end

-- True if another message (other than exceptId) already uses this name,
-- compared case-insensitively and trimmed. Names must be unique so /emu send
-- resolves to exactly one message.
function Messages.NameExists(name, exceptId)
	if not name then
		return false
	end
	local target = strtrim(name):lower()
	if target == "" then
		return false
	end
	for _, m in ipairs(Messages.All()) do
		if m.id ~= exceptId and strtrim(m.name):lower() == target then
			return true
		end
	end
	return false
end

-- Returns `base`, or "base 2"/"base 3"/... — the first name not already taken.
function Messages.UniqueName(base)
	base = strtrim(base or "")
	if base == "" then
		base = "New Message"
	end
	if not Messages.NameExists(base) then
		return base
	end
	local n = 2
	while Messages.NameExists(base .. " " .. n) do
		n = n + 1
	end
	return base .. " " .. n
end

-- Creates, stores and returns a new empty message with a unique name.
function Messages.New(name)
	local db = ns.db
	local id = db.nextMessageId or 1
	db.nextMessageId = id + 1
	local msg = { id = id, name = Messages.UniqueName(name or "New Message"), content = "", outputs = {} }
	tinsert(db.messages, msg)
	return msg
end

-- Creates a copy of message `id` (content + outputs) under a new unique name:
-- the original name plus a " Copy" suffix, trimmed to fit the length limit, then
-- made unique (names drive /emu send). Returns the new message, or nil.
function Messages.Duplicate(id)
	local src = Messages.GetById(id)
	if not src then
		return nil
	end
	local base = ns.NameWithSuffix(src.name, " Copy", NAME_MAX)
	local outputs = {}
	if src.outputs then
		for _, o in ipairs(src.outputs) do
			local entry = { chatType = o.chatType }
			if o.channel then
				entry.channel = o.channel
			end
			outputs[#outputs + 1] = entry
		end
	end
	local db = ns.db
	local newId = db.nextMessageId or 1
	db.nextMessageId = newId + 1
	local msg = { id = newId, name = Messages.UniqueName(base), content = src.content or "", outputs = outputs }
	tinsert(db.messages, msg)
	return msg
end

-- Imports a message entry { name, content, outputs }. `conflict` "override"
-- replaces the content/outputs of the first message with the same name
-- (case-insensitive); otherwise a new message is created under a unique name.
-- Returns true, or false + reason.
function Messages.Import(entry, conflict)
	if not entry or ns.IsBlank(entry.name) then
		return false, "missing name"
	end
	local outputs = {}
	for _, o in ipairs(entry.outputs or {}) do
		local copy = { chatType = o.chatType }
		if o.channel then
			copy.channel = o.channel
		end
		outputs[#outputs + 1] = copy
	end
	if conflict == "override" then
		local existing = Messages.FindByName(entry.name)
		if existing then
			existing.content = entry.content or ""
			existing.outputs = outputs
			return true
		end
	end
	local db = ns.db
	local id = db.nextMessageId or 1
	db.nextMessageId = id + 1
	tinsert(db.messages, {
		id = id,
		name = Messages.UniqueName(entry.name),
		content = entry.content or "",
		outputs = outputs,
	})
	return true
end

function Messages.Delete(id)
	local list = Messages.All()
	for i = #list, 1, -1 do
		if list[i].id == id then
			tremove(list, i)
			return true
		end
	end
	return false
end

-- Fresh A->Z sorted list of lightweight { key, name } items for the UI list.
-- Deliberately not the stored tables, so the list's transient match-highlight
-- data never leaks into SavedVariables.
function Messages.ListItems()
	local items = {}
	for _, m in ipairs(Messages.All()) do
		items[#items + 1] = { key = m.id, name = m.name }
	end
	sort(items, function(a, b)
		local an, bn = a.name:lower(), b.name:lower()
		if an == bn then
			return a.key < b.key
		end
		return an < bn
	end)
	return items
end

-- First message whose name matches `name` case-insensitively (names aren't
-- unique; the first in creation order wins). Used by /emu send.
function Messages.FindByName(name)
	if not name then
		return nil
	end
	local target = strtrim(name):lower()
	if target == "" then
		return nil
	end
	for _, m in ipairs(Messages.All()) do
		if m.name:lower() == target then
			return m
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Outputs (chat destinations)
--------------------------------------------------------------------------------

function Messages.DefaultOutputs()
	return DEFAULT_OUTPUTS
end

-- A stable comparison key for an output descriptor, so a message's outputs can
-- be compared as a set. Channels are distinguished by name.
function Messages.OutputKey(output)
	if output.chatType == "CHANNEL" then
		return "CHANNEL:" .. (output.channel or "")
	end
	return output.chatType
end

-- The player's currently joined global/custom channels as output descriptors.
-- GetChannelList() returns a flat (id, name, disabled) vararg list.
function Messages.ChannelOutputs()
	local out = {}
	local flat = { GetChannelList() }
	for i = 1, #flat, 3 do
		local name = flat[i + 1]
		if type(name) == "string" and name ~= "" then
			out[#out + 1] = { chatType = "CHANNEL", channel = name, display = name }
		end
	end
	return out
end

-- The full checklist shown for a message: fixed speak targets, then joined
-- channels, then any channel the message targets that isn't currently joined
-- (so a saved target still appears and stays checked). De-duplicated by key.
function Messages.OutputChoices(message)
	local choices, seen = {}, {}
	local function add(output)
		local key = Messages.OutputKey(output)
		if not seen[key] then
			seen[key] = true
			choices[#choices + 1] = output
		end
	end
	for _, output in ipairs(DEFAULT_OUTPUTS) do
		add(output)
	end
	for _, output in ipairs(Messages.ChannelOutputs()) do
		add(output)
	end
	if message and message.outputs then
		for _, output in ipairs(message.outputs) do
			if output.chatType == "CHANNEL" then
				add({ chatType = "CHANNEL", channel = output.channel, display = output.channel })
			end
		end
	end
	return choices
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

-- The anti-spam interval in seconds (the min gap between any two sends). Driven
-- by the EMU settings slider; falls back to the default and never drops below
-- the 0.5s minimum.
function Messages.GetInterval()
	local v = ns.db and ns.db.sendInterval
	if type(v) ~= "number" then
		return DEFAULT_INTERVAL
	end
	return v < MIN_INTERVAL and MIN_INTERVAL or v
end

-- Seconds remaining before another send is allowed, or 0 if one is allowed now.
function Messages.ThrottleRemaining()
	local elapsed = GetTime() - (Messages.lastSend or 0)
	local remaining = Messages.GetInterval() - elapsed
	return remaining > 0 and remaining or 0
end

-- True if a fixed chat type can currently receive a message, so we don't fire a
-- doomed send that just floods the player's chat with "You aren't in a party"
-- and similar errors. Mirrors the eligibility the default chat editbox uses
-- (ChatFrameEditBoxMixin:ResetChatType), plus explicit raid-warning and officer
-- permission checks. CHANNEL outputs are gated separately in Send (by whether
-- the channel is currently joined). SAY/YELL and anything else always attempt.
local function CanSendFixed(chatType)
	if chatType == "PARTY" then
		return IsInGroup(HOME)
	elseif chatType == "RAID" then
		return IsInRaid(HOME)
	elseif chatType == "RAID_WARNING" then
		-- Raid warnings need a raid and lead/assist, else "You are not promoted".
		return IsInRaid(HOME) and (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player"))
	elseif chatType == "INSTANCE_CHAT" then
		return IsInGroup(INSTANCE)
	elseif chatType == "GUILD" then
		return IsInGuild()
	elseif chatType == "OFFICER" then
		return IsInGuild() and C_GuildInfo and C_GuildInfo.IsGuildOfficer and C_GuildInfo.IsGuildOfficer() or false
	end
	return true
end

-- Broadcasts a message's content to each of its checked outputs. Only ever
-- called from a hardware event (a button click or the /emu send command),
-- which is what the chat API's anti-spam restriction requires. A channel
-- that isn't currently joined resolves to id 0 and is skipped.
--
-- A global throttle (Messages.GetInterval) blocks a send that comes too soon
-- after the previous one, so no message the addon can send goes out more often
-- than the configured interval. Returns true if the message was sent, false if
-- it was empty/targetless or throttled.
function Messages.Send(message)
	if not message then
		return false
	end
	local text = message.content
	if not text or strtrim(text) == "" then
		return false
	end
	if not message.outputs then
		return false
	end

	local remaining = Messages.ThrottleRemaining()
	if remaining > 0 then
		ns.Print(("Anti-spam: wait %d more second(s) before sending another message."):format(ceil(remaining)))
		return false
	end

	-- Only send to outputs that can currently receive the message: a joined
	-- channel, or a chat type whose precondition is met (CanSendFixed). This
	-- skips doomed sends instead of spamming chat with their error replies.
	local sentAny = false
	for _, output in ipairs(message.outputs) do
		if output.chatType == "CHANNEL" then
			local id = output.channel and GetChannelName(output.channel) or 0
			if id and id > 0 then
				C_ChatInfo.SendChatMessage(text, "CHANNEL", nil, id)
				sentAny = true
			end
		elseif CanSendFixed(output.chatType) then
			C_ChatInfo.SendChatMessage(text, output.chatType)
			sentAny = true
		end
	end

	-- Only start the cooldown once something actually went out, so a message
	-- with no joined channels doesn't silently eat the interval.
	if sentAny then
		Messages.lastSend = GetTime()
	end
	return sentAny
end

-- Sends the saved message named `name` (case-insensitive). Returns true if a
-- message was found. Backs the /emu send slash command.
function Messages.SendByName(name)
	local message = Messages.FindByName(name)
	if not message then
		return false
	end
	Messages.Send(message)
	return true
end
