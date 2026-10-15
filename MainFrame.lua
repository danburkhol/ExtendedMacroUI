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
local StaticPopup_Show = StaticPopup_Show

local MacroData = ns.MacroData

local MAIN_FRAME_NAME = "ExtendedMacroUIFrame"
-- Kept well under 2x Blizzard's 338-wide macro frame; macros are short.
local MAIN_WIDTH, MAIN_HEIGHT = 600, 424
local LEFT_PANE_WIDTH = 200
local ROW_HEIGHT = 24
local SCROLLBAR_WIDTH = 24
local QUESTION_MARK_ICON = 134400

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

StaticPopupDialogs["EXTENDEDMACROUI_UNSAVED"] = {
	text = "You have unsaved changes to this macro.",
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

-- Current tab, the selected actual-index per tab, and the shared search
-- query (one box, persists across tabs).
local state = {
	tab = MacroData.ACCOUNT,
	selected = { account = nil, character = nil },
	query = "",
}
MainFrame.state = state

local HIGHLIGHT_START = "|cffffd100"
local HIGHLIGHT_END = "|r"

-- Returns the macro name with any "|" escaped and matched runs wrapped in
-- gold color codes. `hits` is a list of matched byte positions, or nil.
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

local function IsRowSelected(index)
	return index == state.selected[state.tab]
end

-- One-time region creation + per-bind data update for a list row.
local function InitRow(button, data)
	if not button.created then
		button.created = true

		button.Selected = button:CreateTexture(nil, "BACKGROUND")
		button.Selected:SetAllPoints()
		button.Selected:SetColorTexture(1, 0.82, 0, 0.16)

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.08)

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(18, 18)
		button.Icon:SetPoint("LEFT", 3, 0)
		button.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

		-- Gold dot marking a row with unsaved edits.
		button.Dirty = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		button.Dirty:SetPoint("RIGHT", -6, 0)
		button.Dirty:SetText("|cffffd100\226\128\162|r") -- bullet

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 7, 0)
		button.Name:SetPoint("RIGHT", button.Dirty, "LEFT", -2, 0)
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button:SetScript("OnClick", function(self)
			MainFrame:SelectMacro(self.macroData)
		end)
	end

	button.macroData = data
	button.macroIndex = data.index
	button.Icon:SetTexture(data.icon)
	button.Name:SetText(BuildName(data.name, data.hits))
	button.Selected:SetShown(IsRowSelected(data.index))
	button.Dirty:SetShown(data.index == ns.Editor:GetEditingIndex() and ns.Editor:IsDirty())
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

	frame.Tabs = { self.tab1, self.tab2 }
	PanelTemplates_SetNumTabs(frame, 2)
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
	local deleteButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
	deleteButton:SetSize(64, 22)
	deleteButton:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
	deleteButton:SetText("Delete")
	deleteButton:SetScript("OnClick", function() MainFrame:DeleteSelected() end)
	ns.SetTooltip(deleteButton, "Delete the selected macro.", true)
	self.deleteButton = deleteButton

	local newButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
	newButton:SetSize(64, 22)
	newButton:SetPoint("RIGHT", deleteButton, "LEFT", -4, 0)
	newButton:SetText("New")
	newButton:SetScript("OnClick", function() MainFrame:NewMacro() end)
	ns.SetTooltip(newButton, "Create a new macro in this tab.", true)
	self.newButton = newButton

	-- Footer count label.
	local footer = pane:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 2, 6)
	footer:SetPoint("RIGHT", newButton, "LEFT", -6, 0)
	footer:SetJustifyH("LEFT")
	self.footer = footer

	-- Recessed container for the scrolling list.
	local box = CreateFrame("Frame", nil, pane, "InsetFrameTemplate")
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -4, -6)
	box:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 4, -6)
	box:SetPoint("BOTTOM", deleteButton, "TOP", 0, 6)

	-- Empty-state message, shown over the list when there's nothing to show.
	local emptyText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("LEFT", box, "LEFT", 14, 0)
	emptyText:SetPoint("RIGHT", box, "RIGHT", -14, 0)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetTextColor(0.72, 0.67, 0.54)
	emptyText:Hide()
	self.emptyText = emptyText

	local scrollBox = CreateFrame("Frame", nil, box, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4)
	scrollBox:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -(SCROLLBAR_WIDTH), 4)

	local scrollBar = CreateFrame("EventFrame", nil, box, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", InitRow)
	view:SetPadding(2, 2, 2, 2, 2)

	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	self.scrollBox = scrollBox
end

function MainFrame:Create()
	local frame = CreateFrame("Frame", MAIN_FRAME_NAME, UIParent, "ButtonFrameTemplate")
	frame:SetSize(MAIN_WIDTH, MAIN_HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()

	frame:SetTitle("Create Macros")
	frame:SetPortraitToAsset("Interface\\MacroFrame\\MacroFrame-Icon")

	-- Button to switch back to Blizzard's macro window, left of the close "X".
	local macroButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	macroButton:SetSize(56, 20)
	macroButton:SetText("Macro")
	macroButton:SetPoint("RIGHT", frame.CloseButton, "LEFT", 0, 0)
	macroButton:SetScript("OnClick", ns.SwitchToNative)
	ns.SetTooltip(macroButton, "Switch to the default macro window.")

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
		ns.Editor:LoadMacro(state.selected[state.tab])
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

	return frame
end

function MainFrame:CreateEditorPane(frame)
	local inset = frame.Inset
	local right = CreateFrame("Frame", nil, inset)
	right:SetPoint("TOPLEFT", self.listPane, "TOPRIGHT", 12, -2)
	right:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -10, 8)
	self.editorPane = right
	ns.Editor:Create(right)
end

--------------------------------------------------------------------------------
-- Refresh / selection
--------------------------------------------------------------------------------

function MainFrame:UpdateTabLabels()
	local accUsed, charUsed = MacroData.GetCounts()
	local _, accMax = MacroData.GetRange(MacroData.ACCOUNT)
	local _, charMax = MacroData.GetRange(MacroData.CHARACTER)
	self.tab1:SetText(("General Macros  %d/%d"):format(accUsed, accMax))
	self.tab2:SetText(("Character Specific Macros  %d/%d"):format(charUsed, charMax))
	PanelTemplates_TabResize(self.tab1, 10)
	PanelTemplates_TabResize(self.tab2, 10)
end

function MainFrame:UpdateFooter(shown, total, hasQuery)
	if hasQuery then
		self.footer:SetText(("Showing %d of %d"):format(shown, total))
	else
		local _, max = MacroData.GetRange(state.tab)
		self.footer:SetText(("%d of %d slots used"):format(total, max))
	end
end

function MainFrame:UpdateEmptyState(shown, total, hasQuery)
	if total == 0 then
		self.emptyText:SetText("No macros in this tab yet.")
		self.emptyText:Show()
	elseif shown == 0 and hasQuery then
		local q = (state.query or ""):gsub("|", "||")
		self.emptyText:SetText(("No macros match \"%s\"."):format(q))
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

	local macros = MacroData.GetMacros(state.tab)

	-- Re-resolve the selection against all macros (not the filtered view);
	-- indices may have shifted or been removed.
	local sel = state.selected[state.tab]
	local stillExists = false
	for _, m in ipairs(macros) do
		if m.index == sel then
			stillExists = true
			break
		end
	end
	if not stillExists then
		state.selected[state.tab] = macros[1] and macros[1].index or nil
	end

	local total = #macros
	local filtered = MacroData.Filter(macros, state.query or "")
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
	local editingIndex = ns.Editor:GetEditingIndex()
	local dirty = ns.Editor:IsDirty()
	local selected = state.selected[state.tab]
	self.scrollBox:ForEachFrame(function(button)
		button.Selected:SetShown(button.macroIndex == selected)
		button.Dirty:SetShown(button.macroIndex == editingIndex and dirty)
	end)
end

-- Enables/disables New, Delete, Save, Cancel for the current combat + state.
function MainFrame:UpdateButtons()
	if not self.newButton then
		return
	end
	local inCombat = InCombatLockdown()
	local _, max = MacroData.GetRange(state.tab)
	local used = MacroData.GetUsed(state.tab)
	self.newButton:SetEnabled(not inCombat and used < max)
	self.deleteButton:SetEnabled(not inCombat and state.selected[state.tab] ~= nil)
	ns.Editor:UpdateButtons(inCombat)
end

function MainFrame:SetSelectedIndex(index)
	state.selected[state.tab] = index
end

function MainFrame:DoSelectIndex(index)
	state.selected[state.tab] = index
	ns.Editor:LoadMacro(index)
	self:UpdateRowStates()
	self:UpdateButtons()
end

-- Row click: guard against losing unsaved edits before switching.
function MainFrame:SelectMacro(data)
	local targetIndex = data and data.index or nil
	if targetIndex == ns.Editor:GetEditingIndex() then
		return
	end
	if ns.Editor:IsDirty() then
		self.pending = {
			kind = "select",
			index = targetIndex,
			snap = data and { name = data.name, icon = data.icon, body = data.body } or nil,
		}
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoSelectIndex(targetIndex)
end

-- Selects the first macro in the current filtered view (Enter in search).
function MainFrame:SelectFirstResult()
	local macros = MacroData.GetMacros(state.tab)
	local filtered = MacroData.Filter(macros, state.query or "")
	if filtered[1] then
		self:SelectMacro(filtered[1])
	end
end

function MainFrame:DoSelectTab(tab)
	state.tab = tab
	PanelTemplates_SetTab(self.frame, tab == MacroData.CHARACTER and 2 or 1)
	self:Refresh()
	ns.Editor:LoadMacro(state.selected[state.tab])
	self:UpdateButtons()
end

function MainFrame:SelectTab(tab)
	if state.tab == tab then
		return
	end
	if ns.Editor:IsDirty() then
		self.pending = { kind = "selecttab", tab = tab }
		StaticPopup_Show("EXTENDEDMACROUI_UNSAVED")
		return
	end
	self:DoSelectTab(tab)
end

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

-- Carries out the action that was blocked by an unsaved-changes prompt.
function MainFrame:ResolvePending(action)
	local pending = self.pending
	self.pending = nil
	if not pending then
		return
	end

	if action == "save" then
		ns.Editor:Save()
	end

	if pending.kind == "new" then
		self:DoNewMacro()
	elseif pending.kind == "selecttab" then
		self:DoSelectTab(pending.tab)
	else -- select
		local index = pending.index
		if action == "save" and pending.snap then
			index = MacroData.FindBySnapshot(state.tab, pending.snap) or pending.index
		end
		self:DoSelectIndex(index)
	end
end
