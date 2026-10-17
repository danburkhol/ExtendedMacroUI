local ADDON_NAME, ns = ...

-- Right-pane editor for the Saved Messages tab: a name box, a multi-line
-- content box, and a scrolling checklist of chat outputs (say/yell/party/raid/
-- raid warning/instance/guild/officer plus every joined channel). "Send Now"
-- broadcasts the current draft; Save writes it back to SavedVariables.
--
-- Messages are our own data, not macros, so nothing here is combat-restricted:
-- saving edits a Lua table, and SendChatMessage fires from the button click
-- (a hardware event). No combat lockouts needed.

local CreateFrame = CreateFrame
local CreateDataProvider = CreateDataProvider
local CreateScrollBoxListLinearView = CreateScrollBoxListLinearView
local ScrollUtil = ScrollUtil
local tinsert = tinsert
local tremove = tremove
local strtrim = strtrim

local Messages = ns.Messages

local NAME_MAX = 50
local CONTENT_MAX = 255 -- SendChatMessage sends one line; the game caps at 255.
local CONTENT_WARN = 240
local CONTENT_HEIGHT = 72
local OUTPUT_ROW_HEIGHT = 22

local MessageEditor = {}
ns.MessageEditor = MessageEditor

-- active: whether this editor currently owns the editor pane (the Saved
--   Messages tab is selected). The macro Editor owns it otherwise.
-- id: the message id currently open (nil = nothing selected).
-- draft: { name, content, outputs } pending edits.
MessageEditor.active = false
MessageEditor.id = nil
MessageEditor.draft = nil
MessageEditor.loading = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local NameIsBlank = ns.IsBlank

-- Shallow-copies an outputs array keeping only persisted fields.
local function CopyOutputs(outputs)
	local copy = {}
	if outputs then
		for _, output in ipairs(outputs) do
			local entry = { chatType = output.chatType }
			if output.channel then
				entry.channel = output.channel
			end
			copy[#copy + 1] = entry
		end
	end
	return copy
end

-- Set of output keys, for quick membership and set-equality tests.
local function OutputSet(outputs)
	local set = {}
	if outputs then
		for _, output in ipairs(outputs) do
			set[Messages.OutputKey(output)] = true
		end
	end
	return set
end

--------------------------------------------------------------------------------
-- Dirty / state
--------------------------------------------------------------------------------

function MessageEditor:GetEditingKey()
	return self.id
end

function MessageEditor:IsDirty()
	if not self.draft or not self.id then
		return false
	end
	local saved = Messages.GetById(self.id)
	if not saved then
		return false
	end
	if self.draft.name ~= saved.name or self.draft.content ~= (saved.content or "") then
		return true
	end
	local a, b = OutputSet(self.draft.outputs), OutputSet(saved.outputs)
	for key in pairs(a) do
		if not b[key] then
			return true
		end
	end
	for key in pairs(b) do
		if not a[key] then
			return true
		end
	end
	return false
end

function MessageEditor:HasOutput(output)
	if not self.draft then
		return false
	end
	local key = Messages.OutputKey(output)
	for _, existing in ipairs(self.draft.outputs) do
		if Messages.OutputKey(existing) == key then
			return true
		end
	end
	return false
end

function MessageEditor:ToggleOutput(output, checked)
	if not self.draft then
		return
	end
	local key = Messages.OutputKey(output)
	if checked then
		if not self:HasOutput(output) then
			local entry = { chatType = output.chatType }
			if output.chatType == "CHANNEL" then
				entry.channel = output.channel
			end
			tinsert(self.draft.outputs, entry)
		end
	else
		for i = #self.draft.outputs, 1, -1 do
			if Messages.OutputKey(self.draft.outputs[i]) == key then
				tremove(self.draft.outputs, i)
			end
		end
	end
	self:OnDraftChanged()
end

-- Called after any edit: refresh counters, buttons and the list dirty dot.
function MessageEditor:OnDraftChanged()
	if self.loading then
		return
	end
	self:UpdateCounters()
	self:UpdateButtons()
	if ns.MainFrame then
		ns.MainFrame:UpdateRowStates()
	end
end

function MessageEditor:UpdateCounters()
	local d = self.draft
	local nameLen = d and #d.name or 0
	local contentLen = d and #d.content or 0
	self.nameCount:SetText(("%d/%d"):format(nameLen, NAME_MAX))
	self.contentCount:SetText(("%d/%d Characters Used"):format(contentLen, CONTENT_MAX))
	if contentLen >= CONTENT_WARN then
		self.contentCount:SetTextColor(1, 0.54, 0.41)
	else
		ns.SetMutedText(self.contentCount)
	end
end

-- inCombat is accepted for a common interface with the macro Editor, but
-- messages have no combat restrictions, so it's ignored.
function MessageEditor:UpdateButtons()
	local dirty = self:IsDirty()
	local name = self.draft and strtrim(self.draft.name or "") or ""
	-- Save requires a non-blank, unique name (names address /emu send).
	local nameOk = name ~= "" and not Messages.NameExists(name, self.id)
	self.saveButton:SetEnabled(dirty and nameOk)
	self.cancelButton:SetEnabled(dirty)
	local canSend = self.draft and strtrim(self.draft.content or "") ~= "" and #self.draft.outputs > 0
	self.sendButton:SetEnabled(canSend and true or false)
	self:UpdateSlashHint()
end

-- Shows the /emu send command for this message (to paste into a game macro),
-- or a hint/warning when the name is blank or already taken.
function MessageEditor:UpdateSlashHint()
	if not self.slashHint then
		return
	end
	local d = self.draft
	if not d then
		self.slashHint:SetText("")
		return
	end
	local name = strtrim(d.name or "")
	if name == "" then
		self.slashHint:SetText("Set a name to enable /emu send")
		ns.SetMutedText(self.slashHint)
	elseif Messages.NameExists(name, self.id) then
		self.slashHint:SetText("Name already used by another saved message")
		self.slashHint:SetTextColor(1, 0.3, 0.3)
	else
		self.slashHint:SetText("Macro command:  /emu send " .. name)
		ns.SetMutedText(self.slashHint)
	end
end

--------------------------------------------------------------------------------
-- Outputs list
--------------------------------------------------------------------------------

local function InitOutputRow(button, data)
	if not button.created then
		button.created = true

		local check = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
		check:SetSize(OUTPUT_ROW_HEIGHT, OUTPUT_ROW_HEIGHT)
		check:SetPoint("LEFT", button, "LEFT", 2, 0)
		button.check = check

		local label = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		label:SetPoint("LEFT", check, "RIGHT", 2, 0)
		label:SetPoint("RIGHT", button, "RIGHT", -2, 0)
		label:SetJustifyH("LEFT")
		label:SetWordWrap(false)
		button.label = label

		check:SetScript("OnClick", function(self)
			MessageEditor:ToggleOutput(button.outputData, self:GetChecked())
		end)
	end

	button.outputData = data
	button.label:SetText(data.display or data.channel or data.chatType)
	button.check:SetChecked(MessageEditor:HasOutput(data))
end

-- Rebuilds the output checklist from the fixed targets + current channels +
-- the draft's own channel targets.
function MessageEditor:RefreshOutputs()
	if not self.outputBox then
		return
	end
	local choices = Messages.OutputChoices(self.draft)
	self.outputBox:SetDataProvider(CreateDataProvider(choices), true)
end

--------------------------------------------------------------------------------
-- Load / save / cancel
--------------------------------------------------------------------------------

function MessageEditor:LoadItem(id)
	local saved = id and Messages.GetById(id) or nil

	if not saved then
		self.id = nil
		self.draft = nil
		self.nameBox:ClearFocus()
		self.body.EditBox:ClearFocus()
		self.area:Hide()
		self.prompt:Show()
		return
	end

	self.id = saved.id
	self.draft = {
		name = saved.name,
		content = saved.content or "",
		outputs = CopyOutputs(saved.outputs),
	}

	self.loading = true
	self.nameBox:SetText(saved.name)
	self.body.EditBox:SetText(saved.content or "")
	self.loading = false

	self.prompt:Hide()
	self.area:Show()
	self:RefreshOutputs()
	self:UpdateCounters()
	self:UpdateButtons()
end

-- Returns true if the message was written, false if it couldn't be (blank or
-- duplicate name). The boolean lets the unsaved-changes prompt abort rather
-- than discard edits when a save can't proceed.
function MessageEditor:Save()
	local d = self.draft
	if not d or not self.id or NameIsBlank(d.name) then
		return false
	end
	local name = strtrim(d.name)
	if Messages.NameExists(name, self.id) then
		ns.Print("A saved message named \"" .. name .. "\" already exists.")
		return false
	end
	local saved = Messages.GetById(self.id)
	if not saved then
		return false
	end
	saved.name = name
	saved.content = d.content
	saved.outputs = CopyOutputs(d.outputs)

	if ns.MainFrame then
		ns.MainFrame:SetSelectedKey(self.id)
	end
	self:LoadItem(self.id)
	if ns.MainFrame then
		ns.MainFrame:Refresh()
		-- Macros get a UPDATE_MACROS event that refreshes buttons + the footer;
		-- a message save has no event, so refresh them here.
		ns.MainFrame:UpdateButtons()
	end
	return true
end

function MessageEditor:Cancel()
	if not self.id then
		return
	end
	self:LoadItem(self.id)
	if ns.MainFrame then
		ns.MainFrame:UpdateRowStates()
	end
end

function MessageEditor:FocusName()
	if self.nameBox:IsShown() then
		self.nameBox:SetFocus()
		self.nameBox:HighlightText()
	end
end

-- Hands the editor pane to (or away from) this editor when the Saved Messages
-- tab is selected/deselected. When activated, MainFrame calls LoadItem next.
function MessageEditor:SetActive(active)
	self.active = active
	if not active then
		if self.area then
			self.area:Hide()
		end
		if self.prompt then
			self.prompt:Hide()
		end
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function MessageEditor:Create(parent)
	local area = CreateFrame("Frame", nil, parent)
	area:SetAllPoints(parent)
	self.area = area

	-- Refresh the channel list when it changes while we're visible.
	area:SetScript("OnShow", function(f)
		f:RegisterEvent("CHANNEL_UI_UPDATE")
		f:RegisterEvent("CHANNEL_LEFT")
	end)
	area:SetScript("OnHide", function(f)
		f:UnregisterEvent("CHANNEL_UI_UPDATE")
		f:UnregisterEvent("CHANNEL_LEFT")
	end)
	area:SetScript("OnEvent", function()
		MessageEditor:RefreshOutputs()
	end)

	-- Name label + counter + box.
	local nameLabel = area:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", area, "TOPLEFT", 4, -6)
	nameLabel:SetText("Message Name")

	local nameCount = area:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	nameCount:SetPoint("TOPRIGHT", area, "TOPRIGHT", -6, -6)
	self.nameCount = nameCount

	local nameBox = CreateFrame("EditBox", nil, area, "InputBoxTemplate")
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -6)
	nameBox:SetPoint("RIGHT", area, "RIGHT", -10, 0)
	nameBox:SetHeight(22)
	nameBox:SetAutoFocus(false)
	nameBox:SetMaxLetters(NAME_MAX)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnTextChanged", function(box)
		if MessageEditor.draft then
			MessageEditor.draft.name = box:GetText()
		end
		MessageEditor:OnDraftChanged()
	end)
	self.nameBox = nameBox
	ns.RegisterEditBox(nameBox)

	-- The /emu send command for this message (to paste into a game macro),
	-- doubling as the blank/duplicate-name warning line.
	local slashHint = area:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	slashHint:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 6, -6)
	slashHint:SetPoint("RIGHT", area, "RIGHT", -10, 0)
	slashHint:SetJustifyH("LEFT")
	slashHint:SetWordWrap(false)
	self.slashHint = slashHint

	-- Content label + counter.
	local contentLabel = area:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	contentLabel:SetPoint("TOPLEFT", slashHint, "BOTTOMLEFT", -6, -10)
	contentLabel:SetText("Enter Message Text")

	local contentCount = area:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	contentCount:SetPoint("TOPLEFT", contentLabel, "BOTTOMLEFT", 0, -3)
	contentCount:SetJustifyH("LEFT")
	self.contentCount = contentCount

	-- Content input (scrolling, multi-line), fixed height. Left/right match the
	-- name box and the output checklist (area +10 / -10) so all three line up.
	local body = ns.CreateMultilineInput(area, CONTENT_MAX)
	body:SetPoint("TOPLEFT", contentCount, "BOTTOMLEFT", 0, -6)
	body:SetPoint("RIGHT", area, "RIGHT", -10, 0)
	body:SetHeight(CONTENT_HEIGHT)
	body.EditBox:HookScript("OnTextChanged", function(box)
		if MessageEditor.draft then
			MessageEditor.draft.content = box:GetText()
		end
		MessageEditor:OnDraftChanged()
	end)
	self.body = body
	ns.RegisterEditBox(body.EditBox, body)

	-- Tab cycles focus between the name and content fields.
	nameBox:SetScript("OnTabPressed", function()
		body.EditBox:SetFocus()
	end)
	body.EditBox:SetScript("OnTabPressed", function()
		nameBox:SetFocus()
	end)

	-- "Send to:" label above the output checklist. Aligned with the body's left
	-- so the checklist box (anchored to this label) keeps the shared +10 edge.
	local sendToLabel = area:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	sendToLabel:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -10)
	sendToLabel:SetText("Send to:")

	-- Bottom row: Send Now (left); Save + Cancel (right); the unsaved label on
	-- its own line just above Save/Cancel.
	local sendButton = ns.CreateButton(area, "Send Now", 90, 22, function()
		if MessageEditor.draft then
			ns.Messages.Send(MessageEditor.draft)
		end
	end)
	sendButton:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 6, 4)
	ns.SetTooltip(sendButton, "Broadcast this message now to every checked output.")
	self.sendButton = sendButton

	local cancelButton = ns.CreateButton(area, "Cancel", 78, 22, function() MessageEditor:Cancel() end)
	cancelButton:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -6, 4)
	ns.SetTooltip(cancelButton, "Discard unsaved changes.")
	self.cancelButton = cancelButton

	local saveButton = ns.CreateButton(area, "Save", 78, 22, function() MessageEditor:Save() end)
	saveButton:SetPoint("RIGHT", cancelButton, "LEFT", -6, 0)
	ns.SetTooltip(saveButton, "Save changes to this message.")
	self.saveButton = saveButton

	-- Output checklist, between "Send to:" and the bottom row.
	local box, scrollBox, scrollBar = ns.CreateScrollList(area)
	box:SetPoint("TOPLEFT", sendToLabel, "BOTTOMLEFT", 0, -4)
	box:SetPoint("RIGHT", area, "RIGHT", -10, 0)
	box:SetPoint("BOTTOM", sendButton, "TOP", 0, 8)

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(OUTPUT_ROW_HEIGHT)
	view:SetElementInitializer("Button", InitOutputRow)
	view:SetPadding(2, 2, 2, 2, 2)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	self.outputBox = scrollBox

	-- "No message selected" prompt.
	self.prompt = ns.CreatePrompt(parent, "No message selected",
		"Create a saved message to broadcast to several chat channels at once.")

	area:Hide()
end
