local ADDON_NAME, ns = ...

-- Import/Export wizard: a docked side panel (same slot as the icon picker and
-- macro builder) that walks the player through exporting macros / saved
-- messages to a share string, or importing one. Pages:
--   choose -> (export) select -> result
--          -> (import) paste  -> select -> import + chat report
-- All data work (collect, encode, decode, import) lives in Transfer.lua.

local CreateFrame = CreateFrame
local CreateDataProvider = CreateDataProvider
local GameTooltip = GameTooltip
local InCombatLockdown = InCombatLockdown
local date = date
local geterrorhandler = geterrorhandler
local concat = table.concat

local Transfer = ns.Transfer
local MacroData = ns.MacroData
local Messages = ns.Messages

local WIZARD_WIDTH, WIZARD_HEIGHT = 400, 330
local ROW_HEIGHT = 20
local PREVIEW_HEIGHT = 110

-- The window's height follows the current page (ns.SetInsetContentHeight).
local CHOOSE_INSET_HEIGHT = 240
local TEXT_PAGE_INSET_HEIGHT = 260 -- paste and result pages
-- Select page: fixed space above the list (info, radios, group checks, search),
-- list box padding, and the space below the preview (conflict radios on import).
local SELECT_TOP = 172
local LIST_CHROME = 12
local SELECT_BOTTOM_IMPORT = 54
local SELECT_BOTTOM_EXPORT = 10
local MIN_LIST_ROWS, MAX_LIST_ROWS = 4, 12

local Wizard = ns.RegisterDockPanel({})
ns.TransferWizard = Wizard

Wizard.mode = "export" -- or "import"
Wizard.allMode = true -- true: export/import whole groups; false: picked items
Wizard.conflict = "duplicate" -- or "override"

-- Localized-ish display names for saved message outputs (for the preview).
local OUTPUT_DISPLAY = {}
for _, o in ipairs(Messages.DefaultOutputs()) do
	OUTPUT_DISPLAY[o.chatType] = o.display
end

local Escape = ns.EscapePipes

--------------------------------------------------------------------------------
-- Selection
--------------------------------------------------------------------------------

-- Resets the selection state for a new set of entries (local or payload).
function Wizard:SetEntries(groups)
	self.groups = groups
	self.allKinds = {}
	for _, kind in ipairs(Transfer.KINDS) do
		self.allKinds[kind] = #groups[kind] > 0
	end
	self.picked = {}
	self.allMode = true
	self.pinned = nil
	self.query = ""
	if self.search then
		self.search:SetText("")
	end
end

function Wizard:IsEntrySelected(entry)
	if self.allMode then
		return self.allKinds[entry.kind] and true or false
	end
	return self.picked[entry.key] and true or false
end

-- The entries the current choices select, in kind order.
function Wizard:SelectedEntries()
	local out = {}
	if not self.groups then
		return out
	end
	for _, kind in ipairs(Transfer.KINDS) do
		for _, entry in ipairs(self.groups[kind]) do
			if self:IsEntrySelected(entry) then
				out[#out + 1] = entry
			end
		end
	end
	return out
end

local function HasMacros(entries)
	for _, e in ipairs(entries) do
		if e.kind ~= "message" then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Browser list (section headers + checkbox rows)
--------------------------------------------------------------------------------

local function InitRow(button, data)
	if not button.created then
		button.created = true
		button.Selected = ns.AddRowHighlight(button)

		local check = CreateFrame("CheckButton", nil, button, "UICheckButtonTemplate")
		check:SetSize(ROW_HEIGHT, ROW_HEIGHT)
		check:SetPoint("LEFT", button, "LEFT", 2, 0)
		check:SetScript("OnClick", function(c)
			Wizard:SetPicked(button.data, c:GetChecked())
		end)
		-- Moving onto the checkbox leaves the row, so preview from here too.
		check:SetScript("OnEnter", function() Wizard:ShowPreview(button.data) end)
		check:SetScript("OnLeave", function() Wizard:ShowPreview(Wizard.pinned) end)
		button.Check = check

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(16, 16)
		ns.TrimIcon(button.Icon)

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button.Header = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		button.Header:SetPoint("LEFT", button, "LEFT", 6, 0)
		button.Header:SetPoint("RIGHT", button, "RIGHT", -4, 0)
		button.Header:SetJustifyH("LEFT")

		button:SetScript("OnEnter", function(self)
			if not self.data.header then
				Wizard:ShowPreview(self.data)
			end
		end)
		button:SetScript("OnLeave", function() Wizard:ShowPreview(Wizard.pinned) end)
		button:SetScript("OnClick", function(self)
			if self.data.header then
				return
			end
			-- Clicking a row pins its preview and (when picking) toggles it.
			Wizard.pinned = self.data
			if not Wizard.allMode then
				Wizard:SetPicked(self.data, not Wizard.picked[self.data.key])
			else
				Wizard:UpdateRows()
			end
			Wizard:ShowPreview(self.data)
		end)
	end

	button.data = data
	if data.header then
		button.Header:SetText(data.text)
		button.Header:Show()
		button.Check:Hide()
		button.Icon:Hide()
		button.Name:Hide()
		button.Selected:Hide()
		return
	end

	button.Header:Hide()
	button.Check:Show()
	button.Name:Show()
	button.Name:ClearAllPoints()
	if data.kind == "message" then
		button.Icon:Hide()
		button.Name:SetPoint("LEFT", button.Check, "RIGHT", 2, 0)
	else
		button.Icon:Show()
		button.Icon:SetTexture(data.icon)
		button.Icon:SetPoint("LEFT", button.Check, "RIGHT", 2, 0)
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
	end
	button.Name:SetPoint("RIGHT", button, "RIGHT", -4, 0)
	button.Name:SetText(Escape(data.name))
	button.Check:SetChecked(Wizard:IsEntrySelected(data))
	button.Check:SetEnabled(not Wizard.allMode)
	button.Selected:SetShown(Wizard.pinned ~= nil and Wizard.pinned.key == data.key)
end

-- Rebuilds the list from the entries + search query.
function Wizard:RefreshList()
	if not self.scrollBox or not self.groups then
		return
	end
	local rows = {}
	local hasQuery = MacroData.NormalizeQuery(self.query or "") ~= ""
	for _, kind in ipairs(Transfer.KINDS) do
		local all = self.groups[kind]
		local filtered = MacroData.Filter(all, self.query or "")
		if #all > 0 and (#filtered > 0 or not hasQuery) then
			rows[#rows + 1] = { header = true, kind = kind, text = ("%s (%d)"):format(Transfer.KIND_LABEL[kind], #all) }
			for _, entry in ipairs(filtered) do
				rows[#rows + 1] = entry
			end
		end
	end
	self.scrollBox:SetDataProvider(CreateDataProvider(rows), true)
	if #rows == 0 then
		self.emptyText:SetText(hasQuery and "Nothing matches your search." or "Nothing to show.")
		self.emptyText:Show()
	else
		self.emptyText:Hide()
	end
end

-- Refreshes checkbox/pin state on the visible rows without a rebuild.
function Wizard:UpdateRows()
	if self.scrollBox then
		self.scrollBox:ForEachFrame(function(button)
			if button.data and not button.data.header then
				button.Check:SetChecked(self:IsEntrySelected(button.data))
				button.Check:SetEnabled(not self.allMode)
				button.Selected:SetShown(self.pinned ~= nil and self.pinned.key == button.data.key)
			end
		end)
	end
	self:UpdateSelectControls()
end

function Wizard:SetPicked(entry, picked)
	if not entry or entry.header or self.allMode then
		return
	end
	self.picked[entry.key] = picked and true or nil
	self:UpdateRows()
end

--------------------------------------------------------------------------------
-- Preview
--------------------------------------------------------------------------------

function Wizard:ShowPreview(entry)
	local p = self.preview
	if not p then
		return
	end
	if not entry or entry.header then
		p.Icon:Hide()
		p.Title:SetText("")
		p.Sub:SetText("")
		p.Body:SetText("Hover over or click an item to preview it.")
		ns.SetMutedText(p.Body)
		return
	end
	p.Body:SetTextColor(1, 1, 1)
	p.Title:SetText(Escape(entry.name))
	if entry.kind == "message" then
		p.Icon:Hide()
		local targets = {}
		for _, o in ipairs(entry.outputs or {}) do
			targets[#targets + 1] = (o.chatType == "CHANNEL") and Escape(o.channel)
				or OUTPUT_DISPLAY[o.chatType] or o.chatType
		end
		p.Sub:SetText("Saved message -> " .. (#targets > 0 and concat(targets, ", ") or "no outputs"))
		p.Body:SetText(Escape(entry.content ~= "" and entry.content or "(empty)"))
	else
		p.Icon:SetTexture(entry.icon)
		p.Icon:Show()
		p.Sub:SetText(entry.kind == "character" and "Character macro" or "General macro")
		p.Body:SetText(Escape(entry.body ~= "" and entry.body or "(empty)"))
	end
end

--------------------------------------------------------------------------------
-- Select page controls
--------------------------------------------------------------------------------

function Wizard:SetAllMode(allMode)
	self.allMode = allMode
	self:UpdateRows()
end

-- Radio states, group checkbox labels/enables, conflict radios and the primary
-- button's enabled state.
function Wizard:UpdateSelectControls()
	local page = self.pages and self.pages.select
	if not page or not self.groups then
		return
	end
	page.radioAll:SetChecked(self.allMode)
	page.radioSpecific:SetChecked(not self.allMode)
	for _, kind in ipairs(Transfer.KINDS) do
		local check = page.groupChecks[kind]
		local n = #self.groups[kind]
		check.Text:SetText(("%s (%d)"):format(Transfer.KIND_LABEL[kind], n))
		check:SetChecked(self.allKinds[kind] and n > 0)
		check:SetEnabled(self.allMode and n > 0)
	end
	page.overrideRadio:SetChecked(self.conflict == "override")
	page.duplicateRadio:SetChecked(self.conflict == "duplicate")
	if self.page == "select" then
		self:UpdatePrimary()
	end
end

-- Enables the bottom-right button for the current page, recording why it's
-- disabled (shown in its tooltip).
function Wizard:UpdatePrimary()
	local button = self.primary
	local reason
	if self.page == "select" then
		local entries = self:SelectedEntries()
		if #entries == 0 then
			reason = "Select at least one item."
		elseif self.mode == "import" and InCombatLockdown() and HasMacros(entries) then
			reason = "Can't import macros while in combat."
		end
		button:SetText(self.mode == "import" and ("Import (%d)"):format(#entries) or ("Export (%d)"):format(#entries))
	elseif self.page == "paste" then
		if ns.IsBlank(self.pasteBox.EditBox:GetText()) then
			reason = "Paste an export string first."
		end
	end
	button.disabledReason = reason
	button:SetEnabled(reason == nil)
end

--------------------------------------------------------------------------------
-- Pages / navigation
--------------------------------------------------------------------------------

-- Rows the select list would show unfiltered (headers + entries), so the
-- window is sized to its contents and doesn't jump while searching.
function Wizard:FullRowCount()
	local n = 0
	for _, kind in ipairs(Transfer.KINDS) do
		local count = self.groups and #self.groups[kind] or 0
		if count > 0 then
			n = n + 1 + count
		end
	end
	return n
end

function Wizard:SelectInsetHeight()
	local rows = math.min(math.max(self:FullRowCount(), MIN_LIST_ROWS), MAX_LIST_ROWS)
	local bottom = (self.mode == "import") and SELECT_BOTTOM_IMPORT or SELECT_BOTTOM_EXPORT
	return SELECT_TOP + rows * ROW_HEIGHT + LIST_CHROME + 6 + PREVIEW_HEIGHT + bottom
end

function Wizard:ShowPage(name)
	self.page = name
	for key, page in pairs(self.pages) do
		page:SetShown(key == name)
	end
	local primary, back = self.primary, self.back
	if name == "choose" then
		ns.SetInsetContentHeight(self.frame, CHOOSE_INSET_HEIGHT)
		primary:Hide()
		back:Hide()
	elseif name == "select" then
		ns.SetInsetContentHeight(self.frame, self:SelectInsetHeight())
		primary:Show()
		back:Show()
		local page = self.pages.select
		page.conflict:SetShown(self.mode == "import")
		page.previewBox:ClearAllPoints()
		page.previewBox:SetPoint("LEFT", page, "LEFT", 12, 0)
		page.previewBox:SetPoint("RIGHT", page, "RIGHT", -12, 0)
		page.previewBox:SetHeight(PREVIEW_HEIGHT)
		if self.mode == "import" then
			page.previewBox:SetPoint("BOTTOM", page.conflict, "TOP", 0, 6)
		else
			page.previewBox:SetPoint("BOTTOM", page, "BOTTOM", 0, 10)
		end
		self:RefreshList()
		self:ShowPreview(self.pinned)
		self:UpdateSelectControls()
	elseif name == "paste" then
		ns.SetInsetContentHeight(self.frame, TEXT_PAGE_INSET_HEIGHT)
		primary:Show()
		primary:SetText("Next")
		back:Show()
		self.pasteError:SetText("")
		self:UpdatePrimary()
	elseif name == "result" then
		ns.SetInsetContentHeight(self.frame, TEXT_PAGE_INSET_HEIGHT)
		primary:Show()
		primary:SetText("Done")
		primary.disabledReason = nil
		primary:SetEnabled(true)
		back:Show()
		self.resultBox.EditBox:SetFocus()
		self.resultBox.EditBox:HighlightText()
	end
end

function Wizard:StartExport()
	self.mode = "export"
	self:SetEntries(Transfer.LocalEntries())
	self.pages.select.info:SetText("Choose what to export. The result is a text string you can paste anywhere.")
	self:ShowPage("select")
end

function Wizard:StartImport()
	self.mode = "import"
	self.pasteBox.EditBox:SetText("")
	self:ShowPage("paste")
	self.pasteBox.EditBox:SetFocus()
end

-- Validates the pasted text and moves on to the selection page.
function Wizard:DecodePaste()
	local payload, err = Transfer.Decode(self.pasteBox.EditBox:GetText())
	if not payload then
		self.pasteError:SetText(err)
		return
	end
	self.payload = payload
	self:SetEntries(Transfer.PayloadEntries(payload))

	local from = payload.char or "Unknown"
	if payload.realm then
		from = from .. " - " .. payload.realm
	end
	local info = "From " .. Escape(from)
	if payload.time then
		info = info .. ", " .. date("%Y-%m-%d %H:%M", payload.time)
	end
	if payload.addon then
		info = info .. " (v" .. Escape(payload.addon) .. ")"
	end
	info = info .. "."
	if payload.dropped > 0 then
		info = info .. (" |cffff5555%d invalid item(s) skipped.|r"):format(payload.dropped)
	end
	self.pages.select.info:SetText(info)
	self:ShowPage("select")
end

function Wizard:DoExport()
	local entries = self:SelectedEntries()
	local text, err = Transfer.Encode(Transfer.BuildPayload(entries))
	if not text then
		ns.Print(err)
		geterrorhandler()("Extended Macro UI export failed: " .. tostring(err))
		return
	end
	self.exportText = text
	self.resultBox.EditBox:SetText(text)
	self.resultStats:SetText(("%d item(s), %d characters."):format(#entries, #text))
	self:ShowPage("result")
end

function Wizard:DoImport()
	if (ns.Editor and ns.Editor:IsDirty()) or (ns.MessageEditor and ns.MessageEditor:IsDirty()) then
		ns.Print("Save or cancel your unsaved changes before importing.")
		return
	end
	local entries = self:SelectedEntries()
	local snap = ns.MainFrame:SelectionSnapshot()
	local report = Transfer.Import(entries, self.conflict)
	ns.MainFrame:ReloadAfterImport(snap)

	ns.Print(("Import complete: %d succeeded, %d failed."):format(report.ok, report.failed))
	for _, line in ipairs(report.errors) do
		ns.Print("|cffff5555Failed:|r " .. Escape(line))
	end
	if report.failed > 0 then
		-- Surface failures as a Lua error report (without aborting) so error
		-- catchers like BugSack/BugGrabber record the details.
		geterrorhandler()(("Extended Macro UI import: %d of %d item(s) failed:\n%s"):format(
			report.failed, #entries, concat(report.errors, "\n")))
	end
	self:Close()
end

function Wizard:OnPrimary()
	if self.page == "select" then
		if self.mode == "import" then
			self:DoImport()
		else
			self:DoExport()
		end
	elseif self.page == "paste" then
		self:DecodePaste()
	elseif self.page == "result" then
		self:Close()
	end
end

function Wizard:OnBack()
	if self.page == "result" then
		self:ShowPage("select")
	elseif self.page == "select" and self.mode == "import" then
		self:ShowPage("paste")
	else
		self:ShowPage("choose")
	end
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function CreatePage(parent)
	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints(parent)
	page:Hide()
	return page
end

function Wizard:BuildChoosePage(inset)
	local page = CreatePage(inset)

	local title = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", page, "TOP", 0, -24)
	title:SetText("What would you like to do?")

	local export = ns.CreateButton(page, "Export", 160, 28, function() Wizard:StartExport() end)
	export:SetPoint("TOP", title, "BOTTOM", 0, -30)
	local exportDesc = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	exportDesc:SetPoint("TOP", export, "BOTTOM", 0, -8)
	exportDesc:SetWidth(320)
	exportDesc:SetText("Turn your macros and saved messages into a text string you can share or keep as a backup.")

	local import = ns.CreateButton(page, "Import", 160, 28, function() Wizard:StartImport() end)
	import:SetPoint("TOP", exportDesc, "BOTTOM", 0, -30)
	local importDesc = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	importDesc:SetPoint("TOP", import, "BOTTOM", 0, -8)
	importDesc:SetWidth(320)
	importDesc:SetText("Paste a string exported by Extended Macro UI and choose what to add.")

	return page
end

function Wizard:BuildSelectPage(inset)
	local page = CreatePage(inset)

	local info = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -10)
	info:SetPoint("RIGHT", page, "RIGHT", -12, 0)
	info:SetHeight(26)
	info:SetJustifyH("LEFT")
	info:SetJustifyV("TOP")
	page.info = info

	page.radioAll = ns.CreateRadio(page, "Everything in these groups:", function() Wizard:SetAllMode(true) end)
	page.radioAll:SetPoint("TOPLEFT", page, "TOPLEFT", 14, -42)

	page.groupChecks = {}
	local y = -58
	for _, kind in ipairs(Transfer.KINDS) do
		local check = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
		check:SetSize(22, 22)
		check:SetPoint("TOPLEFT", page, "TOPLEFT", 30, y)
		check.Text:SetFontObject("GameFontHighlightSmall")
		check:SetScript("OnClick", function(c)
			Wizard.allKinds[kind] = c:GetChecked() and true or false
			Wizard:UpdateRows()
		end)
		page.groupChecks[kind] = check
		y = y - 20
	end

	page.radioSpecific = ns.CreateRadio(page, "Only the items I check in the list:", function() Wizard:SetAllMode(false) end)
	page.radioSpecific:SetPoint("TOPLEFT", page, "TOPLEFT", 14, y - 6)

	local search = CreateFrame("EditBox", nil, page, "SearchBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", page.radioSpecific, "BOTTOMLEFT", 6, -6)
	search:SetPoint("RIGHT", page, "RIGHT", -14, 0)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		Wizard.query = box:GetText()
		Wizard:RefreshList()
	end)
	self.search = search
	ns.RegisterEditBox(search)

	-- Conflict policy (import only), pinned to the bottom.
	local conflict = CreateFrame("Frame", nil, page)
	conflict:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 12, 8)
	conflict:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -12, 8)
	conflict:SetHeight(40)
	local conflictLabel = conflict:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	conflictLabel:SetPoint("TOPLEFT", conflict, "TOPLEFT", 2, 0)
	conflictLabel:SetText("If an item with the same name already exists:")
	page.overrideRadio = ns.CreateRadio(conflict, "Overwrite it", function()
		Wizard.conflict = "override"
		Wizard:UpdateSelectControls()
	end)
	page.overrideRadio:SetPoint("TOPLEFT", conflictLabel, "BOTTOMLEFT", 2, -6)
	page.duplicateRadio = ns.CreateRadio(conflict, "Add it as a copy", function()
		Wizard.conflict = "duplicate"
		Wizard:UpdateSelectControls()
	end)
	page.duplicateRadio:SetPoint("LEFT", page.overrideRadio, "RIGHT", 120, 0)
	ns.SetTooltip(page.overrideRadio, "Replace the first macro (in the same tab) or saved message with the same name.")
	ns.SetTooltip(page.duplicateRadio, "Always create a new one. Saved messages get a numbered name (e.g. \"Name 2\").")
	page.conflict = conflict

	-- Preview box (anchored per mode in ShowPage).
	local previewBox = CreateFrame("Frame", nil, page, "InsetFrameTemplate")
	local p = {}
	p.Icon = previewBox:CreateTexture(nil, "ARTWORK")
	p.Icon:SetSize(28, 28)
	p.Icon:SetPoint("TOPLEFT", previewBox, "TOPLEFT", 8, -8)
	ns.TrimIcon(p.Icon)
	p.Title = previewBox:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	p.Title:SetPoint("TOPLEFT", previewBox, "TOPLEFT", 42, -8)
	p.Title:SetPoint("RIGHT", previewBox, "RIGHT", -8, 0)
	p.Title:SetJustifyH("LEFT")
	p.Title:SetWordWrap(false)
	p.Sub = previewBox:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	p.Sub:SetPoint("TOPLEFT", p.Title, "BOTTOMLEFT", 0, -3)
	p.Sub:SetPoint("RIGHT", previewBox, "RIGHT", -8, 0)
	p.Sub:SetJustifyH("LEFT")
	p.Sub:SetWordWrap(false)
	p.Body = previewBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	p.Body:SetPoint("TOPLEFT", previewBox, "TOPLEFT", 8, -42)
	p.Body:SetPoint("BOTTOMRIGHT", previewBox, "BOTTOMRIGHT", -8, 6)
	p.Body:SetJustifyH("LEFT")
	p.Body:SetJustifyV("TOP")
	p.Body:SetNonSpaceWrap(true)
	self.preview = p
	page.previewBox = previewBox

	-- The list fills the space between the search box and the preview.
	local box, scrollBox, scrollBar = ns.CreateScrollList(page, 22)
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -8, -6)
	box:SetPoint("RIGHT", page, "RIGHT", -12, 0)
	box:SetPoint("BOTTOM", previewBox, "TOP", 0, 6)

	self.emptyText = ns.CreateEmptyText(box)

	ns.InitListView(scrollBox, scrollBar, ROW_HEIGHT, InitRow)
	self.scrollBox = scrollBox

	return page
end

function Wizard:BuildPastePage(inset)
	local page = CreatePage(inset)

	local label = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -12)
	label:SetText("Paste an export string below (Ctrl+V):")

	local errorText = page:CreateFontString(nil, "ARTWORK", "GameFontRedSmall")
	errorText:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 12, 10)
	errorText:SetPoint("RIGHT", page, "RIGHT", -12, 0)
	errorText:SetHeight(28)
	errorText:SetJustifyH("LEFT")
	errorText:SetJustifyV("TOP")
	self.pasteError = errorText

	local box = ns.CreateMultilineInput(page, 0)
	box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -10)
	box:SetPoint("RIGHT", page, "RIGHT", -18, 0)
	box:SetPoint("BOTTOM", errorText, "TOP", 0, 8)
	box.EditBox:HookScript("OnTextChanged", function()
		Wizard.pasteError:SetText("")
		Wizard:UpdatePrimary()
	end)
	ns.RegisterEditBox(box.EditBox, box)
	self.pasteBox = box

	return page
end

function Wizard:BuildResultPage(inset)
	local page = CreatePage(inset)

	local label = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -12)
	label:SetText("Press Ctrl+C to copy this text, then share it:")

	local stats = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	stats:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 12, 12)
	ns.SetMutedText(stats)
	self.resultStats = stats

	local box = ns.CreateMultilineInput(page, 0)
	box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 6, -10)
	box:SetPoint("RIGHT", page, "RIGHT", -18, 0)
	box:SetPoint("BOTTOM", stats, "TOP", 0, 10)
	-- Read-only: undo any typing and keep the whole string selected for copying.
	box.EditBox:HookScript("OnTextChanged", function(editBox, userInput)
		if userInput and Wizard.exportText then
			editBox:SetText(Wizard.exportText)
			editBox:HighlightText()
		end
	end)
	box.EditBox:HookScript("OnEditFocusGained", function(editBox)
		editBox:HighlightText()
	end)
	ns.RegisterEditBox(box.EditBox, box)
	self.resultBox = box

	return page
end

function Wizard:Create()
	local frame = ns.CreatePortraitWindow("ExtendedMacroUITransfer", WIZARD_WIDTH, WIZARD_HEIGHT, "Import / Export")
	-- Docks in the same slot as the icon picker and macro builder.
	frame:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 6, 0)
	self.frame = frame

	local inset = frame.Inset
	self.pages = {
		choose = self:BuildChoosePage(inset),
		select = self:BuildSelectPage(inset),
		paste = self:BuildPastePage(inset),
		result = self:BuildResultPage(inset),
	}

	local primary = ns.CreateButton(frame, "Next", 110, 22, function() Wizard:OnPrimary() end)
	primary:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)
	primary:SetMotionScriptsWhileDisabled(true)
	primary:SetScript("OnEnter", function(b)
		if b.disabledReason then
			GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
			GameTooltip:AddLine(b.disabledReason, 1, 0.3, 0.3, true)
			GameTooltip:Show()
		end
	end)
	primary:SetScript("OnLeave", function() GameTooltip:Hide() end)
	self.primary = primary

	local back = ns.CreateButton(frame, "Back", 90, 22, function() Wizard:OnBack() end)
	back:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 6)
	self.back = back

	-- Macros can't be written in combat; keep the Import button's state current.
	frame:SetScript("OnShow", function()
		frame:RegisterEvent("PLAYER_REGEN_DISABLED")
		frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	end)
	frame:SetScript("OnHide", function()
		frame:UnregisterEvent("PLAYER_REGEN_DISABLED")
		frame:UnregisterEvent("PLAYER_REGEN_ENABLED")
	end)
	frame:SetScript("OnEvent", function()
		if Wizard.page == "select" or Wizard.page == "paste" then
			Wizard:UpdatePrimary()
		end
	end)

	frame.CloseButton:SetScript("OnClick", function() Wizard:Close() end)
	self:ShowPage("choose")
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

function Wizard:Open()
	if not self.frame then
		return
	end
	-- One docked side panel at a time.
	ns.CloseDockPanels(self)
	self.payload = nil
	self.exportText = nil
	self:ShowPage("choose")
	self.frame:Show()
end
