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
local GetChannelList = GetChannelList
local GetChannelName = GetChannelName
local tinsert = tinsert
local tremove = tremove
local strtrim = strtrim
local sort = table.sort

local Messages = {}
ns.Messages = Messages

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

-- Broadcasts a message's content to each of its checked outputs. Only ever
-- called from a hardware event (a button click or the /emu send command),
-- which is what the chat API's anti-spam restriction requires. A channel
-- that isn't currently joined resolves to id 0 and is skipped.
function Messages.Send(message)
	if not message then
		return
	end
	local text = message.content
	if not text or strtrim(text) == "" then
		return
	end
	if not message.outputs then
		return
	end
	for _, output in ipairs(message.outputs) do
		if output.chatType == "CHANNEL" then
			local id = output.channel and GetChannelName(output.channel) or 0
			if id and id > 0 then
				C_ChatInfo.SendChatMessage(text, "CHANNEL", nil, id)
			end
		else
			C_ChatInfo.SendChatMessage(text, output.chatType)
		end
	end
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
