local ADDON_NAME, ns = ...

local CreateFrame = CreateFrame
local GetMacroInfo = GetMacroInfo
local EditMacro = EditMacro
local InCombatLockdown = InCombatLockdown

local NAME_MAX = 16
local BODY_MAX = 255
local BODY_WARN = 240

local Editor = {}
ns.Editor = Editor

-- index: the actual macro index currently open (nil = nothing selected).
-- draft: { name, icon, body } pending edits.
-- active: whether this editor currently owns the editor pane (a macro tab is
--   selected). Starts true since a macro tab is the default.
Editor.index = nil
Editor.draft = nil
Editor.loading = false
Editor.active = true

local NameIsBlank = ns.IsBlank

--------------------------------------------------------------------------------
-- Dirty / state
--------------------------------------------------------------------------------

function Editor:GetEditingIndex()
	return self.index
end

-- Common editor interface shared with the message editor (MainFrame drives
-- both through these): the selection key here is the macro index.
function Editor:GetEditingKey()
	return self.index
end

function Editor:LoadItem(key)
	return self:LoadMacro(key)
end

-- Hands the editor pane to (or away from) this editor as macro/message tabs are
-- selected. When inactive it hides its contents and its secure Run button so
-- the message editor can take over cleanly.
function Editor:SetActive(active)
	self.active = active
	if not active then
		self.editArea:Hide()
		self.prompt:Hide()
		if ns.IconPicker then
			ns.IconPicker:Close()
		end
		if ns.MacroBuilder then
			ns.MacroBuilder:Close()
		end
		self:UpdateRun()
	end
end

function Editor:IsDirty()
	if not self.draft or not self.index then
		return false
	end
	local name, icon, body = GetMacroInfo(self.index)
	if not name then
		return false
	end
	local d = self.draft
	return d.name ~= name or d.icon ~= icon or d.body ~= body
end

-- Live name editing: the name box's own OnTextChanged drives this.
function Editor:OnNameTyped(text)
	if not self.draft then
		return
	end
	self.draft.name = text
	self:OnDraftChanged()
end

-- Applies a picked icon to the draft (not saved until Save).
function Editor:SetDraftIcon(icon)
	if not self.draft then
		return
	end
	self.draft.icon = icon
	self.icon:SetTexture(icon)
	self:OnDraftChanged()
end

-- Called after any name/body edit: refresh counters, buttons and list dot.
function Editor:OnDraftChanged()
	if self.loading then
		return
	end
	self:UpdateCounters()
	self:UpdateButtons(InCombatLockdown())
	if ns.MainFrame then
		ns.MainFrame:UpdateRowStates()
	end
end

function Editor:UpdateCounters()
	local d = self.draft
	local nameLen = d and #d.name or 0
	local bodyLen = d and #d.body or 0
	self.nameCount:SetText(("%d/%d"):format(nameLen, NAME_MAX))
	self.bodyCount:SetText(("%d/%d Characters Used"):format(bodyLen, BODY_MAX))
	if bodyLen >= BODY_WARN then
		self.bodyCount:SetTextColor(1, 0.54, 0.41)
	else
		ns.SetMutedText(self.bodyCount)
	end
end

-- Pushes the current draft body onto the secure Run button. SetAttribute is
-- blocked in combat, so this only runs out of combat; it re-runs on
-- PLAYER_REGEN_ENABLED (via UpdateButtons) to pick up combat-time edits.
function Editor:SyncRun()
	if not self.run or InCombatLockdown() then
		return
	end
	if self.runNeedsSetup then
		self.run:SetAttribute("type", "macro")
		self.run:RegisterForClicks("AnyUp", "AnyDown")
		self.runNeedsSetup = false
	end
	local d = self.draft
	self.run:SetAttribute("macrotext", (d and d.body) or "")
	self.run:SetEnabled(d ~= nil and self.index ~= nil)
	-- Keep the UIParent-parented button on the window's own layer so it never
	-- floats above unrelated frames (e.g. TradeSkillMaster). SetFrameStrata
	-- resets level, so set strata first. Out-of-combat only (guarded above).
	if ns.frame then
		self.run:SetFrameStrata(ns.frame:GetFrameStrata())
		self.run:SetFrameLevel(ns.frame:GetFrameLevel() + 20)
	end
end

-- Shows/hides and syncs the (UIParent-parented) Run button to match the
-- window. Show/Hide/SetAttribute are blocked on a secure frame in combat, so
-- in combat we only use SetAlpha + Disable (both allowed); the real state is
-- reconciled on PLAYER_REGEN_ENABLED.
function Editor:UpdateRun()
	if not self.run then
		return
	end
	local shouldShow = self.active and ns.frame and ns.frame:IsShown() and self.index ~= nil
	if InCombatLockdown() then
		self.run:SetAlpha(shouldShow and 1 or 0)
		self.run:Disable()
	else
		self.run:SetShown(shouldShow)
		self.run:SetAlpha(1)
		if shouldShow then
			self:SyncRun()
		end
	end
end

function Editor:UpdateButtons(inCombat)
	local dirty = self:IsDirty()
	local nameOk = self.draft and not NameIsBlank(self.draft.name)
	self.saveButton:SetEnabled(dirty and nameOk and not inCombat)
	self.cancelButton:SetEnabled(dirty) -- revert is local; allowed in combat
	self:UpdateRun()
end

--------------------------------------------------------------------------------
-- Load / save / cancel
--------------------------------------------------------------------------------

function Editor:LoadMacro(index)
	local name, icon, body
	if index then
		name, icon, body = GetMacroInfo(index)
	end

	if not name then
		self.index = nil
		self.draft = nil
		self.body.EditBox:ClearFocus()
		self.editArea:Hide()
		self.prompt:Show()
		if ns.IconPicker then
			ns.IconPicker:Close()
		end
		if ns.MacroBuilder then
			ns.MacroBuilder:Close()
		end
		return
	end

	self.index = index
	self.draft = { name = name, icon = icon, body = body }

	self.loading = true
	self.icon:SetTexture(icon)
	self.nameBox:SetText(name)
	self.body.EditBox:SetText(body)
	self.loading = false

	self.prompt:Hide()
	self.editArea:Show()
	self:UpdateCounters()
	self:UpdateButtons(InCombatLockdown())

	-- Keep an open picker in sync with the newly loaded macro.
	if ns.IconPicker and ns.IconPicker:IsShown() then
		ns.IconPicker:Open()
	end
end

-- Returns true if the macro was written, false otherwise (blank name or in
-- combat), so the unsaved-changes prompt can abort instead of discarding edits.
function Editor:Save()
	if InCombatLockdown() then
		return false
	end
	local d = self.draft
	if not d or not self.index or NameIsBlank(d.name) then
		return false
	end

	local newIndex = EditMacro(self.index, d.name, d.icon, d.body)
	self.index = newIndex
	if ns.MainFrame then
		ns.MainFrame:SetSelectedKey(newIndex)
	end
	self:LoadMacro(newIndex)
	if ns.MainFrame then
		ns.MainFrame:Refresh()
	end
	return true
end

function Editor:Cancel()
	if not self.index then
		return
	end
	self:LoadMacro(self.index)
	if ns.MainFrame then
		ns.MainFrame:UpdateRowStates()
	end
end

-- Appends a command as a new line to the draft body (used by the Macro
-- Builder). Setting the edit box text fires its OnTextChanged, which updates
-- the draft, dirty state and the list dot. Refuses if it would exceed the
-- 255-char macro limit, rather than silently truncating.
function Editor:InsertBodyLine(line)
	if not self.draft then
		ns.Print("Select or create a macro first.")
		return
	end
	local body = self.draft.body or ""
	if body ~= "" and body:sub(-1) ~= "\n" then
		body = body .. "\n"
	end
	local newBody = body .. line
	if #newBody > BODY_MAX then
		ns.Print("That line won't fit -- the macro is near the 255-character limit.")
		return
	end
	self.body.EditBox:SetText(newBody)
	self.body.EditBox:SetCursorPosition(#newBody)
end

function Editor:FocusName()
	if self.nameBox:IsShown() then
		self.nameBox:SetFocus()
		self.nameBox:HighlightText()
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function Editor:Create(parent)
	local area = CreateFrame("Frame", nil, parent)
	area:SetAllPoints(parent)
	self.editArea = area

	-- Icon preview.
	local icon = area:CreateTexture(nil, "ARTWORK")
	icon:SetSize(58, 58)
	icon:SetPoint("TOPLEFT", area, "TOPLEFT", 4, -4)
	ns.TrimIcon(icon)
	self.icon = icon

	-- Name label + counter.
	local nameLabel = area:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
	nameLabel:SetText("Macro Name")

	local nameCount = area:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	nameCount:SetPoint("TOPRIGHT", area, "TOPRIGHT", -6, -4)
	self.nameCount = nameCount

	local nameBox = CreateFrame("EditBox", nil, area, "InputBoxTemplate")
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -6)
	nameBox:SetPoint("RIGHT", area, "RIGHT", -10, 0)
	nameBox:SetHeight(22)
	nameBox:SetAutoFocus(false)
	nameBox:SetMaxLetters(NAME_MAX)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:SetScript("OnTextChanged", function(box)
		Editor:OnNameTyped(box:GetText())
	end)
	self.nameBox = nameBox
	ns.RegisterEditBox(nameBox)

	-- Change Name/Icon button toggles the icon picker. Anchored to the pane's
	-- left edge (not under the indented name box) so the two buttons fit the
	-- narrow editor pane without overflowing.
	local changeButton = ns.CreateButton(area, "Change Icon", 128, 22, function()
		if ns.IconPicker then
			ns.IconPicker:Toggle()
		end
	end)
	changeButton:SetPoint("TOPLEFT", area, "TOPLEFT", 4, -68)
	ns.SetTooltip(changeButton, "Pick an icon for this macro.")
	self.changeButton = changeButton

	-- Macro Builder button (right of Change Icon) toggles the builder side panel.
	local builderButton = ns.CreateButton(area, "Macro Builder", 128, 22, function()
		if ns.MacroBuilder then
			ns.MacroBuilder:Toggle()
		end
	end)
	builderButton:SetPoint("LEFT", changeButton, "RIGHT", 6, 0)
	ns.SetTooltip(builderButton, "Build a /cast or /use command and insert it into this macro.")
	self.builderButton = builderButton

	-- Body label + counter. The counter sits on its own line under the label
	-- so the narrower editor pane has room for it.
	local bodyLabel = area:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	bodyLabel:SetPoint("TOPLEFT", area, "TOPLEFT", 4, -92)
	bodyLabel:SetText("Enter Macro Commands")

	local bodyCount = area:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	bodyCount:SetPoint("TOPLEFT", bodyLabel, "BOTTOMLEFT", 0, -3)
	bodyCount:SetJustifyH("LEFT")
	self.bodyCount = bodyCount

	-- Bottom row: Run (left), Save + Cancel (right). The unsaved-changes notice
	-- lives in the shared window footer (MainFrame), not here.
	-- Run is a SecureActionButton. It is parented to UIParent (NOT the window)
	-- and only anchored over the window's Run slot, so the window itself stays
	-- unprotected and can open/close/move in combat. Its own visibility is
	-- managed with combat-safe ops in UpdateRun().
	local run = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate, UIPanelButtonTemplate")
	-- Strata/level are synced to the window in SyncRun; start on its layer.
	if ns.frame then
		run:SetFrameStrata(ns.frame:GetFrameStrata())
	end
	run:SetSize(86, 22)
	run:SetPoint("BOTTOMLEFT", area, "BOTTOMLEFT", 6, 4)
	run:SetText("Run Macro")
	run:SetMotionScriptsWhileDisabled(true)
	run:Hide()
	-- type/clicks are secure setup; skip if we loaded in combat and let the
	-- first out-of-combat SyncRun apply it.
	if InCombatLockdown() then
		self.runNeedsSetup = true
	else
		run:SetAttribute("type", "macro")
		run:RegisterForClicks("AnyUp", "AnyDown")
	end
	ns.SetTooltip(run, "Run this macro now, even if it isn't saved.", true)
	self.run = run

	local cancelButton = ns.CreateButton(area, "Cancel", 78, 22, function() Editor:Cancel() end)
	cancelButton:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", -6, 4)
	ns.SetTooltip(cancelButton, "Discard unsaved changes.")
	self.cancelButton = cancelButton

	local saveButton = ns.CreateButton(area, "Save", 78, 22, function() Editor:Save() end)
	saveButton:SetPoint("RIGHT", cancelButton, "LEFT", -6, 0)
	ns.SetTooltip(saveButton, "Save changes to this macro.", true)
	self.saveButton = saveButton

	-- Body input (scrolling, multi-line) between the counter and the bottom row.
	local body = ns.CreateMultilineInput(area, BODY_MAX)
	body:SetPoint("TOPLEFT", bodyCount, "BOTTOMLEFT", 6, -6)
	body:SetPoint("RIGHT", area, "RIGHT", -16, 0)
	body:SetPoint("BOTTOM", cancelButton, "TOP", 0, 6)
	body.EditBox:HookScript("OnTextChanged", function(box)
		if Editor.draft then
			Editor.draft.body = box:GetText()
		end
		Editor:OnDraftChanged()
	end)
	self.body = body
	ns.RegisterEditBox(body.EditBox, body)

	-- Tab cycles focus between the name and body fields.
	nameBox:SetScript("OnTabPressed", function()
		body.EditBox:SetFocus()
	end)
	body.EditBox:SetScript("OnTabPressed", function()
		nameBox:SetFocus()
	end)

	-- "No macro selected" prompt.
	self.prompt = ns.CreatePrompt(parent, "No macro selected",
		"Pick a macro from the list, or create a new one to start editing.")

	area:Hide()
end
