local ADDON_NAME, ns = ...

local CreateFrame = CreateFrame
local UIParent = UIParent
local PlaySound = PlaySound
local SOUNDKIT = SOUNDKIT
local CreateDataProvider = CreateDataProvider
local CreateScrollBoxListLinearView = CreateScrollBoxListLinearView
local ScrollUtil = ScrollUtil
local PanelTemplates_SetNumTabs = PanelTemplates_SetNumTabs
local PanelTemplates_SetTab = PanelTemplates_SetTab
local PanelTemplates_TabResize = PanelTemplates_TabResize
local InCombatLockdown = InCombatLockdown
local CreateMacro = CreateMacro
local DeleteMacro = DeleteMacro
local GetMacroInfo = GetMacroInfo
local PickupMacro = PickupMacro
local StaticPopup_Show = StaticPopup_Show

local MacroData = ns.MacroData
local Messages = ns.Messages

local MAIN_FRAME_NAME = "ExtendedMacroUIFrame"
-- Sized so the editor pane's body box (~286) matches Blizzard's native macro
-- editor, with the left list pane added alongside it.
local MAIN_WIDTH, MAIN_HEIGHT = 552, 424
local LEFT_PANE_WIDTH = 200
local ROW_HEIGHT = 24
local QUESTION_MARK_ICON = 134400

-- A third tab id alongside MacroData.ACCOUNT / MacroData.CHARACTER.
local MESSAGES = "messages"

local MainFrame = {}
ns.MainFrame = MainFrame

StaticPopupDialogs["EXTENDEDMACROUI_CONFIRM_DELETE"] = {
	text = "Delete macro \"%s\"?",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function() MainFrame:DoDelete() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

StaticPopupDialogs["EXTENDEDMACROUI_CONFIRM_DELETE_MSG"] = {
	text = "Delete saved message \"%s\"?",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function() MainFrame:DoDeleteMessage() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

StaticPopupDialogs["EXTENDEDMACROUI_UNSAVED"] = {
	text = "You have unsaved changes.",
	button1 = "Save",
	button2 = "Cancel",
	button3 = "Discard",
	OnAccept = function() MainFrame:ResolvePending("save") end,
	OnCancel = function() MainFrame.pending = nil end,
	OnAlt = function() MainFrame:ResolvePending("discard") end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- Current tab, the selected key per tab (macro index, or message id), and the
-- shared search query (one box, persists across tabs).
local state = {
	tab = MacroData.ACCOUNT,
	selected = { account = nil, character = nil, messages = nil },
	query = "",
}
MainFrame.state = state

-- Which PanelTemplates tab number each tab id maps to.
local TAB_INDEX = {
	[MacroData.ACCOUNT] = 1,
	[MacroData.CHARACTER] = 2,
	[MESSAGES] = 3,
}

function MainFrame:IsMessages()
	return state.tab == MESSAGES
end

-- The editor that currently owns the right pane.
function MainFrame:ActiveEditor()
	if self:IsMessages() then
		return ns.MessageEditor
	end
	return ns.Editor
end

local HIGHLIGHT_START = "|cffffd100"
local HIGHLIGHT_END = "|r"

-- Returns the name with any "|" escaped and matched runs wrapped in gold color
-- codes. `hits` is a list of matched byte positions, or nil.
local function BuildName(name, hits)
	if not hits or #hits == 0 then
		return (name:gsub("|", "||"))
	end
	local hitset = {}
	for _, h in ipairs(hits) do
		hitset[h] = true
	end
	local out, inHit = {}, false
	for i = 1, #name do
		local isHit = hitset[i]
		if isHit and not inHit then
			out[#out + 1] = HIGHLIGHT_START
			inHit = true
		elseif not isHit and inHit then
			out[#out + 1] = HIGHLIGHT_END
			inHit = false
		end
		local c = name:sub(i, i)
		out[#out + 1] = (c == "|") and "||" or c
	end
	if inHit then
		out[#out + 1] = HIGHLIGHT_END
	end
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

-- A fresh, unfiltered list of { key, name, icon?, index?, body? } for the
-- current tab. Macro items carry index/icon/body for snapshots and editing;
-- message items carry only key (= id) and name (no icon). Items are rebuilt
-- each refresh, so the fuzzy filter's transient .hits never touch stored data.
function MainFrame:CurrentItems()
	if self:IsMessages() then
		return Messages.ListItems()
	end
	local items = {}
	for _, m in ipairs(MacroData.GetMacros(state.tab)) do
		items[#items + 1] = {
			key = m.index,
			name = m.name,
			icon = m.icon,
			index = m.index,
			body = m.body,
		}
	end
	return items
end

--------------------------------------------------------------------------------
-- Position persistence
--------------------------------------------------------------------------------

local function SavePosition(frame)
	local point, _, relPoint, x, y = frame:GetPoint(1)
	if point then
		ns.db.position = { point = point, relPoint = relPoint, x = x, y = y }
	end
end

function MainFrame:RestorePosition()
	local frame = self.frame
	if not frame then
		return
	end
	frame:ClearAllPoints()
	-- In locked mode the panel manager positions the frame on ShowUIPanel;
	-- we only need a valid anchor beforehand.
	if ns.db and ns.db.lockToPanel then
		frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 16, -116)
		return
	end
	local pos = ns.db and ns.db.position
	if pos and type(pos.point) == "string" then
		frame:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

--------------------------------------------------------------------------------
-- List rows
--------------------------------------------------------------------------------

-- The inline-texture glyph for the per-row duplicate button (a red square
-- button in the gear button's style; the tooltip says what it does).
local DUP_GLYPH = "|TInterface\\PaperDollInfoFrame\\Character-Plus:12:12|t"

-- Shows the hover duplicate button while the row (or the button itself) is
-- moused over, and tucks the dirty dot away while it's up so they don't overlap
-- on the right edge.
local function UpdateDupShown(row)
	if not row.Dup then
		return
	end
	local over = row.itemData ~= nil and row:IsMouseOver()
	row.Dup:SetShown(over)
	if row.Dirty then
		local editor = MainFrame:ActiveEditor()
		local dirty = row.itemKey == editor:GetEditingKey() and editor:IsDirty()
		row.Dirty:SetShown(dirty and not over)
	end
end

-- One-time region creation + per-bind data update for a list row. The icon is
-- shown only when the item has one (macros do, messages don't).
local function InitRow(button, data)
	if not button.created then
		button.created = true

		button.Selected = ns.AddRowHighlight(button)

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(18, 18)
		button.Icon:SetPoint("LEFT", 3, 0)
		ns.TrimIcon(button.Icon)

		-- Gold dot marking a row with unsaved edits.
		button.Dirty = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		button.Dirty:SetPoint("RIGHT", -6, 0)
		button.Dirty:SetText("|cffffd100\226\128\162|r") -- bullet

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button:SetScript("OnClick", function(self)
			MainFrame:SelectItem(self.itemData)
		end)

		-- Right-justified duplicate button, shown only on hover.
		local dup = ns.CreateButton(button, DUP_GLYPH, 20, 18)
		dup:SetPoint("RIGHT", button, "RIGHT", -2, 0)
		dup:SetMotionScriptsWhileDisabled(true)
		dup:Hide()
		dup:SetScript("OnClick", function(self)
			MainFrame:DuplicateItem(self:GetParent().itemData)
		end)
		dup:SetScript("OnEnter", function(self)
			MainFrame:ShowDupTooltip(self)
			UpdateDupShown(button)
		end)
		dup:SetScript("OnLeave", function()
			GameTooltip:Hide()
			UpdateDupShown(button)
		end)
		button.Dup = dup

		button:HookScript("OnEnter", function(self) UpdateDupShown(self) end)
		button:HookScript("OnLeave", function(self) UpdateDupShown(self) end)

		-- Drag a macro onto the cursor so it can be dropped on an action bar,
		-- the same way Blizzard's macro frame does (PickupMacro taints nothing;
		-- the secure action button handles the drop). Left-click still selects;
		-- only a click-drag picks up. Message rows have no macro index, so this
		-- is a no-op there.
		button:RegisterForDrag("LeftButton")
		button:SetScript("OnDragStart", function(self)
			local d = self.itemData
			if d and d.index then
				PickupMacro(d.index)
			end
		end)
	end

	button.itemData = data
	button.itemKey = data.key

	button.Name:ClearAllPoints()
	if data.icon then
		button.Icon:Show()
		button.Icon:SetTexture(data.icon)
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 7, 0)
	else
		button.Icon:Hide()
		button.Name:SetPoint("LEFT", button, "LEFT", 8, 0)
	end
	button.Name:SetPoint("RIGHT", button.Dirty, "LEFT", -2, 0)
	button.Name:SetText(BuildName(data.name, data.hits))

	local editor = MainFrame:ActiveEditor()
	button.Selected:SetShown(data.key == state.selected[state.tab])
	button.Dirty:SetShown(data.key == editor:GetEditingKey() and editor:IsDirty())
	button.Dup:SetEnabled(MainFrame:CanDuplicate())
	UpdateDupShown(button)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function MainFrame:CreateTabs(frame)
	local function MakeTab(id, onClick)
		local tab = CreateFrame("Button", nil, frame, "PanelTopTabButtonTemplate")
		tab:SetID(id)
		tab:SetScript("OnClick", onClick)
		return tab
	end

	self.tab1 = MakeTab(1, function() MainFrame:SelectTab(MacroData.ACCOUNT) end)
	self.tab1:SetPoint("TOPLEFT", frame, "TOPLEFT", 58, -26)

	self.tab2 = MakeTab(2, function() MainFrame:SelectTab(MacroData.CHARACTER) end)
	self.tab2:SetPoint("LEFT", self.tab1, "RIGHT", 0, 0)

	self.tab3 = MakeTab(3, function() MainFrame:SelectTab(MESSAGES) end)
	self.tab3:SetPoint("LEFT", self.tab2, "RIGHT", 0, 0)

	frame.Tabs = { self.tab1, self.tab2, self.tab3 }
	PanelTemplates_SetNumTabs(frame, 3)
	PanelTemplates_SetTab(frame, 1)
end

function MainFrame:CreateListPane(frame)
	local inset = frame.Inset

	local pane = CreateFrame("Frame", nil, inset)
	pane:SetPoint("TOPLEFT", inset, "TOPLEFT", 8, -8)
	pane:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 8, 8)
	pane:SetWidth(LEFT_PANE_WIDTH)
	self.listPane = pane

	-- Search box (fuzzy filter) with built-in clear button + magnifier.
	local search = CreateFrame("EditBox", nil, pane, "SearchBoxTemplate")
	search:SetPoint("TOPLEFT", pane, "TOPLEFT", 4, -2)
	search:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -4, -2)
	search:SetHeight(20)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(editBox)
		state.query = editBox:GetText()
		MainFrame:Refresh()
	end)
	-- Enter selects the first result.
	search:HookScript("OnEnterPressed", function()
		MainFrame:SelectFirstResult()
	end)
	self.search = search
	ns.RegisterEditBox(search)

	-- Bottom row: New / Delete buttons on the right, count on the left.
	local deleteButton = ns.CreateButton(pane, "Delete", 64, 22, function() MainFrame:DeleteItem() end)
	deleteButton:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
	ns.SetTooltip(deleteButton, "Delete the selected entry.", true)
	self.deleteButton = deleteButton

	local newButton = ns.CreateButton(pane, "New", 64, 22, function() MainFrame:NewItem() end)
	newButton:SetPoint("RIGHT", deleteButton, "LEFT", -4, 0)
	ns.SetTooltip(newButton, "Create a new entry in this tab.", true)
	self.newButton = newButton

	-- Footer count label.
	local footer = pane:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 2, 6)
	footer:SetPoint("RIGHT", newButton, "LEFT", -6, 0)
	footer:SetJustifyH("LEFT")
	self.footer = footer

	-- Recessed container for the scrolling list.
	local box, scrollBox, scrollBar = ns.CreateScrollList(pane)
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -4, -6)
	box:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 4, -6)
	box:SetPoint("BOTTOM", deleteButton, "TOP", 0, 6)

	-- Empty-state message, shown over the list when there's nothing to show.
	local emptyText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("LEFT", box, "LEFT", 14, 0)
	emptyText:SetPoint("RIGHT", box, "RIGHT", -14, 0)
	emptyText:SetJustifyH("CENTER")
	ns.SetMutedText(emptyText)
	emptyText:Hide()
	self.emptyText = emptyText

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", InitRow)
	view:SetPadding(2, 2, 2, 2, 2)

	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	self.scrollBox = scrollBox
end

function MainFrame:Create()
	local frame = ns.CreatePortraitWindow(MAIN_FRAME_NAME, MAIN_WIDTH, MAIN_HEIGHT, "Create Macros")

	-- Button to switch back to Blizzard's macro window, left of the close "X".
	local macroButton = ns.CreateButton(frame, "Macro", 56, 20, ns.SwitchToNative)
	macroButton:SetPoint("RIGHT", frame.CloseButton, "LEFT", 0, 0)
	ns.SetTooltip(macroButton, "Switch to the default macro window.")

	-- Gear button left of "Macro" that jumps to the addon's settings page. A
	-- standard red panel button (same style as the others) with the gear glyph
	-- Blizzard uses on its own options buttons, via inline atlas markup.
	local optionsButton = ns.CreateButton(frame, "|A:OptionsIcon-Brown:16:16|a", 24, 20, ns.OpenOptions)
	optionsButton:SetPoint("RIGHT", macroButton, "LEFT", -2, 0)
	ns.SetTooltip(optionsButton, "Open Extended Macro UI settings.")
	self.optionsButton = optionsButton

	-- Movability/registration is set per mode by ns.ApplyLayoutMode(); dragging
	-- only does anything in free-floating mode.
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(f)
		if ns.db and ns.db.lockToPanel then
			return
		end
		f:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		SavePosition(f)
	end)

	frame:SetScript("OnShow", function(f)
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
		f:RegisterEvent("UPDATE_MACROS")
		f:RegisterEvent("PLAYER_REGEN_DISABLED")
		f:RegisterEvent("PLAYER_REGEN_ENABLED")
		MainFrame:Refresh()
		MainFrame:ActiveEditor():LoadItem(state.selected[state.tab])
		MainFrame:UpdateButtons()
	end)
	frame:SetScript("OnHide", function(f)
		PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
		f:UnregisterEvent("UPDATE_MACROS")
		f:UnregisterEvent("PLAYER_REGEN_DISABLED")
		f:UnregisterEvent("PLAYER_REGEN_ENABLED")
		ns.Editor:UpdateRun() -- hide the UIParent-parented Run button with us
		if ns.IconPicker then
			ns.IconPicker:Close()
		end
		if ns.MacroBuilder then
			ns.MacroBuilder:Close()
		end
	end)
	frame:SetScript("OnEvent", function(_, event)
		if event == "UPDATE_MACROS" then
			MainFrame:Refresh()
		end
		MainFrame:UpdateButtons()
	end)

	self.frame = frame
	ns.frame = frame

	self:RestorePosition()

	self:CreateTabs(frame)
	self:CreateListPane(frame)
	self:CreateEditorPane(frame)

	-- Shared "unsaved changes" notice for whichever editor is active, in the
	-- window's bottom footer so it never overlaps an editor's text or buttons.
	local dirtyFooter = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	dirtyFooter:SetPoint("BOTTOM", frame, "BOTTOM", 0, 5)
	dirtyFooter:SetText("|cffd9b84aUnsaved changes|r")
	dirtyFooter:Hide()
	self.dirtyFooter = dirtyFooter

	return frame
end

-- Shows the footer "unsaved changes" notice when the active editor is dirty.
function MainFrame:UpdateDirtyIndicator()
	if not self.dirtyFooter then
		return
	end
	self.dirtyFooter:SetShown(self:ActiveEditor():IsDirty())
end

function MainFrame:CreateEditorPane(frame)
	local inset = frame.Inset
	local right = CreateFrame("Frame", nil, inset)
	right:SetPoint("TOPLEFT", self.listPane, "TOPRIGHT", 12, -2)
	right:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -10, 8)
	self.editorPane = right
	-- Both editors share the same pane; only the active tab's editor is shown.
	ns.Editor:Create(right)
	ns.MessageEditor:Create(right)
	ns.MessageEditor:SetActive(false)
end

--------------------------------------------------------------------------------
-- Refresh / selection
--------------------------------------------------------------------------------

function MainFrame:UpdateTabLabels()
	local accUsed, charUsed = MacroData.GetCounts()
	local _, accMax = MacroData.GetRange(MacroData.ACCOUNT)
	local _, charMax = MacroData.GetRange(MacroData.CHARACTER)
	self.tab1:SetText(("General Macros  %d/%d"):format(accUsed, accMax))
	self.tab2:SetText(("Character Macros  %d/%d"):format(charUsed, charMax))
	self.tab3:SetText(("Saved Messages  %d"):format(#Messages.All()))
	PanelTemplates_TabResize(self.tab1, 10)
	PanelTemplates_TabResize(self.tab2, 10)
	PanelTemplates_TabResize(self.tab3, 10)
end

function MainFrame:UpdateFooter(shown, total, hasQuery)
	if hasQuery then
		self.footer:SetText(("Showing %d of %d"):format(shown, total))
	elseif self:IsMessages() then
		if total == 1 then
			self.footer:SetText("1 saved message")
		else
			self.footer:SetText(("%d saved messages"):format(total))
		end
	else
		local _, max = MacroData.GetRange(state.tab)
		self.footer:SetText(("%d of %d slots used"):format(total, max))
	end
end

function MainFrame:UpdateEmptyState(shown, total, hasQuery)
	if total == 0 then
		self.emptyText:SetText(self:IsMessages() and "No saved messages yet." or "No macros in this tab yet.")
		self.emptyText:Show()
	elseif shown == 0 and hasQuery then
		local q = (state.query or ""):gsub("|", "||")
		local noun = self:IsMessages() and "messages" or "macros"
		self.emptyText:SetText(("No %s match \"%s\"."):format(noun, q))
		self.emptyText:Show()
	else
		self.emptyText:Hide()
	end
end

function MainFrame:Refresh()
	-- scrollBox is the last piece built, so this also guards against an
	-- early refresh (e.g. the search box firing OnTextChanged during setup).
	if not self.scrollBox then
		return
	end

	local items = self:CurrentItems()

	-- Re-resolve the selection against all items (not the filtered view);
	-- keys may have shifted or been removed.
	local sel = state.selected[state.tab]
	local stillExists = false
	for _, it in ipairs(items) do
		if it.key == sel then
			stillExists = true
			break
		end
	end
	if not stillExists then
		state.selected[state.tab] = items[1] and items[1].key or nil
	end

	local total = #items
	local filtered = MacroData.Filter(items, state.query or "")
	local shown = #filtered
	local hasQuery = MacroData.NormalizeQuery(state.query or "") ~= ""

	self.scrollBox:SetDataProvider(CreateDataProvider(filtered), true)
	self:UpdateEmptyState(shown, total, hasQuery)
	self:UpdateTabLabels()
	self:UpdateFooter(shown, total, hasQuery)
end

-- Updates the selected highlight and dirty dot on visible rows without a
-- full rebuild.
function MainFrame:UpdateRowStates()
	if not self.scrollBox then
		return
	end
	local editor = self:ActiveEditor()
	local editingKey = editor:GetEditingKey()
	local dirty = editor:IsDirty()
	local selected = state.selected[state.tab]
	local canDup = self:CanDuplicate()
	self.scrollBox:ForEachFrame(function(button)
		button.Selected:SetShown(button.itemKey == selected)
		button.Dirty:SetShown(button.itemKey == editingKey and dirty)
		if button.Dup then
			button.Dup:SetEnabled(canDup)
			UpdateDupShown(button)
		end
	end)
	self:UpdateDirtyIndicator()
end

-- Enables/disables New, Delete and the active editor's buttons for the current
-- combat + selection state. Messages have no combat restrictions.
function MainFrame:UpdateButtons()
	if not self.newButton then
		return
	end
	local inCombat = InCombatLockdown()
	if self:IsMessages() then
		self.newButton:SetEnabled(true)
		self.deleteButton:SetEnabled(state.selected[MESSAGES] ~= nil)
		ns.MessageEditor:UpdateButtons(inCombat)
	else
		local _, max = MacroData.GetRange(state.tab)
		local used = MacroData.GetUsed(state.tab)
		self.newButton:SetEnabled(not inCombat and used < max)
		self.deleteButton:SetEnabled(not inCombat and state.selected[state.tab] ~= nil)
		ns.Editor:UpdateButtons(inCombat)
	end
	self:UpdateDirtyIndicator()
end

-- Whether a new entry can currently be made in this tab (so the per-row
-- duplicate button is enabled). Messages have no slot limit; macros need a free
-- slot and can't be created in combat.
function MainFrame:CanDuplicate()
	if self:IsMessages() then
		return true
	end
	if InCombatLockdown() then
		return false
	end
	local _, max = MacroData.GetRange(state.tab)
	return MacroData.GetUsed(state.tab) < max
end

-- Tooltip for a row's duplicate button, explaining it and, when it's disabled,
-- why (combat, or no free macro slot).
function MainFrame:ShowDupTooltip(dupButton)
	GameTooltip:SetOwner(dupButton, "ANCHOR_RIGHT")
	if self:IsMessages() then
		GameTooltip:AddLine("Duplicate this saved message.", 1, 1, 1, true)
	elseif InCombatLockdown() then
		GameTooltip:AddLine("Can't duplicate macros while in combat.", 1, 0.3, 0.3, true)
	elseif not self:CanDuplicate() then
		GameTooltip:AddLine("No free macro slots in this tab.", 1, 1, 1, true)
		GameTooltip:AddLine("Delete a macro to make space before duplicating.", 1, 0.3, 0.3, true)
	else
		GameTooltip:AddLine("Duplicate this macro.", 1, 1, 1, true)
	end
	GameTooltip:Show()
end

function MainFrame:SetSelectedKey(key)
	state.selected[state.tab] = key
end

function MainFrame:DoSelectKey(key)
	state.selected[state.tab] = key
	self:ActiveEditor():LoadItem(key)
	self:UpdateRowStates()
	self:UpdateButtons()
end

-- Row click: guard against losing unsaved edits before switching.
function MainFrame:SelectItem(data)
	local key = data and data.key or nil
	local editor = self:ActiveEditor()
	if key == editor:GetEditingKey() then
		return
	end
	if editor:IsDirty() then
		self.pending = {
			kind = "select",
			key = key,
			-- Macros reindex on save, so capture a snapshot to re-resolve the
			-- target afterward. Messages have stable ids and need none.
			snap = (not self:IsMessages()) and data
				and { name = data.name, icon = data.icon, body = data.body } or nil,
		}
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoSelectKey(key)
end

-- Selects the first item in the current filtered view (Enter in search).
function MainFrame:SelectFirstResult()
	local filtered = MacroData.Filter(self:CurrentItems(), state.query or "")
	if filtered[1] then
		self:SelectItem(filtered[1])
	end
end

function MainFrame:DoSelectTab(tab)
	local oldEditor = self:ActiveEditor()
	state.tab = tab
	PanelTemplates_SetTab(self.frame, TAB_INDEX[tab])
	self.frame:SetTitle(self:IsMessages() and "Saved Messages" or "Create Macros")

	local newEditor = self:ActiveEditor()
	if oldEditor ~= newEditor then
		oldEditor:SetActive(false)
		newEditor:SetActive(true)
	end

	self:Refresh()
	newEditor:LoadItem(state.selected[state.tab])
	self:UpdateButtons()
end

function MainFrame:SelectTab(tab)
	if state.tab == tab then
		return
	end
	if self:ActiveEditor():IsDirty() then
		self.pending = { kind = "selecttab", tab = tab }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoSelectTab(tab)
end

--------------------------------------------------------------------------------
-- New / Delete (routed to the active tab's kind)
--------------------------------------------------------------------------------

function MainFrame:NewItem()
	if self:IsMessages() then
		self:NewMessage()
	else
		self:NewMacro()
	end
end

function MainFrame:DeleteItem()
	if self:IsMessages() then
		self:DeleteMessage()
	else
		self:DeleteSelected()
	end
end

-- Macros ----------------------------------------------------------------------

function MainFrame:DoNewMacro()
	if InCombatLockdown() then
		return
	end
	local perChar = (state.tab == MacroData.CHARACTER)
	local newIndex = CreateMacro("New Macro", QUESTION_MARK_ICON, "", perChar)
	if not newIndex then
		return
	end
	state.selected[state.tab] = newIndex
	state.query = ""
	self.search:SetText("")
	ns.Editor:LoadMacro(newIndex)
	self:Refresh()
	self:UpdateButtons()
	ns.Editor:FocusName()
	-- New macros open the picker so the player can set a name and icon.
	if ns.IconPicker then
		ns.IconPicker:Open()
	end
end

function MainFrame:NewMacro()
	if InCombatLockdown() then
		return
	end
	local _, max = MacroData.GetRange(state.tab)
	if MacroData.GetUsed(state.tab) >= max then
		return
	end
	if ns.Editor:IsDirty() then
		self.pending = { kind = "new" }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoNewMacro()
end

function MainFrame:DoDelete()
	if InCombatLockdown() then
		return
	end
	local index = state.selected[state.tab]
	if not index then
		return
	end
	DeleteMacro(index)
	state.selected[state.tab] = nil
	self:Refresh()
	ns.Editor:LoadMacro(state.selected[state.tab])
	self:UpdateButtons()
end

function MainFrame:DeleteSelected()
	if InCombatLockdown() then
		return
	end
	local index = state.selected[state.tab]
	if not index then
		return
	end
	local name = GetMacroInfo(index)
	StaticPopup_Show("EXTENDEDMACROUI_CONFIRM_DELETE", name)
end

-- Messages --------------------------------------------------------------------

function MainFrame:DoNewMessage()
	local msg = Messages.New()
	state.selected[MESSAGES] = msg.id
	state.query = ""
	self.search:SetText("")
	self:Refresh()
	ns.MessageEditor:LoadItem(msg.id)
	self:UpdateButtons()
	ns.MessageEditor:FocusName()
end

function MainFrame:NewMessage()
	if ns.MessageEditor:IsDirty() then
		self.pending = { kind = "new" }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoNewMessage()
end

function MainFrame:DoDeleteMessage()
	local id = state.selected[MESSAGES]
	if not id then
		return
	end
	Messages.Delete(id)
	state.selected[MESSAGES] = nil
	self:Refresh()
	ns.MessageEditor:LoadItem(state.selected[MESSAGES])
	self:UpdateButtons()
end

function MainFrame:DeleteMessage()
	local id = state.selected[MESSAGES]
	if not id then
		return
	end
	local msg = Messages.GetById(id)
	StaticPopup_Show("EXTENDEDMACROUI_CONFIRM_DELETE_MSG", msg and msg.name or "")
end

-- Duplicate (routed to the active tab's kind) ---------------------------------

function MainFrame:DuplicateItem(data)
	if not data then
		return
	end
	if self:IsMessages() then
		self:DuplicateMessage(data.key)
	else
		self:DuplicateMacro(data)
	end
end

-- Macros ---
function MainFrame:DoDuplicateMacro(data)
	if InCombatLockdown() or not data then
		return
	end
	local tab = state.tab
	local _, max = MacroData.GetRange(tab)
	if MacroData.GetUsed(tab) >= max then
		return
	end
	-- 16 = the macro name limit; trim the source name so the suffix always fits,
	-- even when the original is already at the limit. CreateMacro both creates
	-- and saves, so the copy is persisted immediately.
	local newName = ns.NameWithSuffix(data.name, " Copy", 16)
	local newIndex = CreateMacro(newName, data.icon or QUESTION_MARK_ICON, data.body or "", tab == MacroData.CHARACTER)
	if not newIndex then
		return
	end
	state.selected[tab] = newIndex
	state.query = ""
	self.search:SetText("")
	self:Refresh()
	ns.Editor:LoadMacro(newIndex)
	self:UpdateButtons()
	ns.Editor:FocusName()
end

function MainFrame:DuplicateMacro(data)
	if InCombatLockdown() then
		return
	end
	local _, max = MacroData.GetRange(state.tab)
	if MacroData.GetUsed(state.tab) >= max then
		return
	end
	-- Opening the copy in the editor would drop unsaved edits on the current
	-- macro, so guard with the same prompt as select/new. The copy is built from
	-- the captured name/icon/body, so a reindex after "save" doesn't matter.
	if ns.Editor:IsDirty() then
		self.pending = { kind = "duplicate", data = { name = data.name, icon = data.icon, body = data.body } }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoDuplicateMacro(data)
end

-- Messages ---
function MainFrame:DoDuplicateMessage(id)
	local msg = Messages.Duplicate(id)
	if not msg then
		return
	end
	state.selected[MESSAGES] = msg.id
	state.query = ""
	self.search:SetText("")
	self:Refresh()
	ns.MessageEditor:LoadItem(msg.id)
	self:UpdateButtons()
	ns.MessageEditor:FocusName()
end

function MainFrame:DuplicateMessage(id)
	if ns.MessageEditor:IsDirty() then
		self.pending = { kind = "duplicate", isMessage = true, key = id }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoDuplicateMessage(id)
end

--------------------------------------------------------------------------------
-- Unsaved-changes resolution
--------------------------------------------------------------------------------

-- Carries out the action that was blocked by an unsaved-changes prompt.
function MainFrame:ResolvePending(action)
	local pending = self.pending
	self.pending = nil
	if not pending then
		return
	end

	if action == "save" then
		-- If the save can't proceed (blank/duplicate name, or combat), keep the
		-- edits and abort rather than discarding them by continuing the action.
		if not self:ActiveEditor():Save() then
			return
		end
	end

	if pending.kind == "new" then
		if self:IsMessages() then
			self:DoNewMessage()
		else
			self:DoNewMacro()
		end
	elseif pending.kind == "selecttab" then
		self:DoSelectTab(pending.tab)
	elseif pending.kind == "duplicate" then
		if pending.isMessage then
			self:DoDuplicateMessage(pending.key)
		else
			self:DoDuplicateMacro(pending.data)
		end
	else -- select
		local key = pending.key
		if action == "save" and pending.snap then
			key = MacroData.FindBySnapshot(state.tab, pending.snap) or pending.key
		end
		self:DoSelectKey(key)
	end
end
