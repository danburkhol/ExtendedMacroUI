local ADDON_NAME, ns = ...

-- Macro Builder: a guided side panel that composes a single macro command
-- (/cast or /use, with one optional targeting + one optional modifier
-- conditional) and inserts it as a new line into the macro being edited. It
-- never writes macros itself -- it only appends text to the editor's draft, so
-- the normal dirty/Save flow applies. Not used by Saved Messages.
--
-- The data helpers at the top are pure (no UI): spell/bag enumeration and the
-- command-composition string builder.

local CreateFrame = CreateFrame
local CreateDataProvider = CreateDataProvider
local CreateScrollBoxListLinearView = CreateScrollBoxListLinearView
local ScrollUtil = ScrollUtil
local C_Spell = C_Spell
local C_Item = C_Item
local C_Container = C_Container
local ChatFrameUtil = ChatFrameUtil
local hooksecurefunc = hooksecurefunc
local GetNumSpellTabs = GetNumSpellTabs
local GetSpellTabInfo = GetSpellTabInfo
local GetSpellBookItemInfo = GetSpellBookItemInfo
local GetSpellBookItemName = GetSpellBookItemName
local GetSpellTexture = GetSpellTexture
local IsPassiveSpell = IsPassiveSpell
local sort = table.sort
local concat = table.concat
local strtrim = strtrim

local BOOKTYPE_SPELL = BOOKTYPE_SPELL or "spell"
local BACKPACK = BACKPACK_CONTAINER or 0
local NUM_BAGS = NUM_BAG_SLOTS or 4

local BUILDER_WIDTH, BUILDER_HEIGHT = 380, 560
local ROW_HEIGHT = 20
local QUESTION_MARK_ICON = 134400

local MacroBuilder = {}
ns.MacroBuilder = MacroBuilder

-- "cast" or "use".
MacroBuilder.action = "cast"
MacroBuilder.target = "none"
MacroBuilder.modifier = "none"

local ACTIONS = {
	{ key = "cast", text = "Cast Spell" },
	{ key = "use",  text = "Use Item" },
}

-- Targeting choices. The macro clause uses "@<key>" (except "none").
local TARGETS = {
	{ key = "none",         text = "None",                            desc = "No targeting clause: acts on your current target (or self-casts, depending on the spell)." },
	{ key = "player",       text = "Player (@player)",                desc = "@player: always affects you, whatever you have targeted." },
	{ key = "target",       text = "Target (@target)",                desc = "@target: your current target." },
	{ key = "targettarget", text = "Target's target (@targettarget)", desc = "@targettarget: whatever your target is targeting (e.g. the tank's target)." },
	{ key = "focus",        text = "Focus (@focus)",                  desc = "@focus: your saved focus target (set with /focus)." },
	{ key = "focustarget",  text = "Focus's target (@focustarget)",   desc = "@focustarget: whatever your focus is targeting." },
	{ key = "mouseover",    text = "Mouse-over (@mouseover)",         desc = "@mouseover: the unit your cursor is over (a unit frame or 3D model)." },
	{ key = "pet",          text = "Pet (@pet)",                      desc = "@pet: your pet." },
}

-- Modifier choices mapped to their macro conditional token.
local MODIFIERS = {
	{ key = "none", text = "None",                         desc = "No modifier condition: the command always runs." },
	{ key = "any",  text = "Any modifier",   cond = "mod",       desc = "mod: runs while any of Alt, Ctrl or Shift is held." },
	{ key = "alt",  text = "Alt",            cond = "mod:alt",   desc = "mod:alt: only runs while the Alt key is held." },
	{ key = "ctrl", text = "Ctrl",           cond = "mod:ctrl",  desc = "mod:ctrl: only runs while the Ctrl key is held." },
	{ key = "shift", text = "Shift",         cond = "mod:shift", desc = "mod:shift: only runs while the Shift key is held." },
	{ key = "btn1", text = "Mouse Button 1", cond = "btn:1",     desc = "btn:1: only runs when triggered with mouse button 1 (left)." },
	{ key = "btn2", text = "Mouse Button 2", cond = "btn:2",     desc = "btn:2: only runs when triggered with mouse button 2 (right)." },
	{ key = "btn3", text = "Mouse Button 3", cond = "btn:3",     desc = "btn:3: only runs when triggered with mouse button 3 (middle)." },
	{ key = "btn4", text = "Mouse Button 4", cond = "btn:4",     desc = "btn:4: only runs when triggered with mouse button 4." },
	{ key = "btn5", text = "Mouse Button 5", cond = "btn:5",     desc = "btn:5: only runs when triggered with mouse button 5." },
}

local MOD_COND = {}
for _, m in ipairs(MODIFIERS) do
	MOD_COND[m.key] = m.cond
end

--------------------------------------------------------------------------------
-- Data (pure)
--------------------------------------------------------------------------------

-- Every castable spell the player knows, at its highest rank, as sorted
-- { key = spellID, name, icon, spellID }. De-duplicated by name (a spell line
-- appears once). Skips passives, not-yet-learned and flyout entries.
function MacroBuilder.KnownSpells()
	local list, seen = {}, {}
	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		if offset and numSpells then
			for slot = offset + 1, offset + numSpells do
				local spellType, id = GetSpellBookItemInfo(slot, BOOKTYPE_SPELL)
				if spellType == "SPELL" and not IsPassiveSpell(slot, BOOKTYPE_SPELL) then
					local name = GetSpellBookItemName(slot, BOOKTYPE_SPELL)
					if name and name ~= "" and not seen[name:lower()] then
						seen[name:lower()] = true
						list[#list + 1] = {
							key = id or name,
							name = name,
							icon = GetSpellTexture(slot, BOOKTYPE_SPELL) or QUESTION_MARK_ICON,
							spellID = id,
						}
					end
				end
			end
		end
	end
	sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
	return list
end

-- Extracts the item name from a container item's hyperlink ("[Name]"). The
-- link is always present for an occupied slot, so this avoids item-cache races.
local function NameFromLink(link)
	return link and link:match("%[(.-)%]") or nil
end

-- Every usable item currently in the player's bags, as sorted
-- { key = itemID, name, icon, itemID }. De-duplicated by itemID. Only items
-- with an on-use spell (C_Item.GetItemSpell returns one) are included, so
-- reagents, plain armor and other non-/use items are filtered out.
function MacroBuilder.BagItems()
	local list, seen = {}, {}
	for bag = BACKPACK, NUM_BAGS do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not seen[info.itemID] then
				local name = NameFromLink(info.hyperlink)
				local useSpell = name and C_Item.GetItemSpell(info.itemID)
				if name and useSpell then
					seen[info.itemID] = true
					list[#list + 1] = {
						key = info.itemID,
						name = name,
						icon = info.iconFileID or QUESTION_MARK_ICON,
						itemID = info.itemID,
					}
				end
			end
		end
	end
	sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
	return list
end

-- The localized rank prefix for a spell (e.g. "Rank " from "Rank 6"), or nil if
-- the spell has no rank subtext. Lets us build "(Rank N)" without hardcoding the
-- English word. `identifier` is a spell name or id (GetSpellSubtext accepts
-- either); the result is empty until the spell's data loads.
function MacroBuilder.RankPrefix(identifier)
	if not identifier or identifier == "" or not (C_Spell and C_Spell.GetSpellSubtext) then
		return nil
	end
	local sub = C_Spell.GetSpellSubtext(identifier)
	if not sub or sub == "" then
		return nil
	end
	return sub:match("^(%D+)%d")
end

-- Builds the command string from the current choices. Pure; returns "" when
-- there's no name to act on.
function MacroBuilder.Compose(action, name, target, modifier, rankN, rankPrefix)
	if not name or strtrim(name) == "" then
		return ""
	end
	name = strtrim(name)

	local conds = {}
	if target and target ~= "none" then
		conds[#conds + 1] = "@" .. target
	end
	local modCond = MOD_COND[modifier]
	if modCond then
		conds[#conds + 1] = modCond
	end
	local clause = (#conds > 0) and ("[" .. concat(conds, ",") .. "] ") or ""

	local token = name
	if action == "cast" and rankN and rankPrefix then
		token = name .. "(" .. rankPrefix .. rankN .. ")"
	end

	local verb = (action == "use") and "/use " or "/cast "
	return verb .. clause .. token
end

local TARGET_PHRASE = {
	player = "on yourself",
	target = "on your target",
	targettarget = "on your target's target",
	focus = "on your focus target",
	focustarget = "on your focus's target",
	mouseover = "on the unit under your cursor",
	pet = "on your pet",
}

local MOD_PHRASE = {
	any = "while any modifier is held",
	alt = "while Alt is held",
	ctrl = "while Ctrl is held",
	shift = "while Shift is held",
	btn1 = "when triggered with mouse button 1",
	btn2 = "when triggered with mouse button 2",
	btn3 = "when triggered with mouse button 3",
	btn4 = "when triggered with mouse button 4",
	btn5 = "when triggered with mouse button 5",
}

-- A plain-language description of what the composed command does, e.g.
-- "Uses Healthstone on your focus target." Pure; "" when there's no name.
function MacroBuilder.Describe(action, name, target, modifier, rankN, rankPrefix)
	if not name or strtrim(name) == "" then
		return ""
	end
	name = strtrim(name)

	local token = name
	if action == "cast" and rankN and rankPrefix then
		token = name .. " (" .. rankPrefix .. rankN .. ")"
	end

	local parts = { (action == "use") and ("Uses " .. token) or ("Casts " .. token) }
	if TARGET_PHRASE[target] then
		parts[#parts + 1] = TARGET_PHRASE[target]
	end
	if MOD_PHRASE[modifier] then
		parts[#parts + 1] = MOD_PHRASE[modifier]
	end
	return concat(parts, " ") .. "."
end

--------------------------------------------------------------------------------
-- List
--------------------------------------------------------------------------------

local function InitListButton(button, data)
	if not button.created then
		button.created = true

		button.Selected = button:CreateTexture(nil, "BACKGROUND")
		button.Selected:SetAllPoints()
		button.Selected:SetColorTexture(1, 0.82, 0, 0.16)

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.08)

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(16, 16)
		button.Icon:SetPoint("LEFT", 3, 0)
		ns.TrimIcon(button.Icon)

		button.Name = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		button.Name:SetPoint("LEFT", button.Icon, "RIGHT", 6, 0)
		button.Name:SetPoint("RIGHT", button, "RIGHT", -4, 0)
		button.Name:SetJustifyH("LEFT")
		button.Name:SetWordWrap(false)

		button:SetScript("OnClick", function(self)
			MacroBuilder:SelectEntry(self.data)
		end)
	end

	button.data = data
	button.Icon:SetTexture(data.icon)
	button.Name:SetText(data.name)
	button.Selected:SetShown(data.key == MacroBuilder.selectedKey)
end

-- Rebuilds the list for the current action and search query.
function MacroBuilder:RefreshList()
	if not self.scrollBox then
		return
	end
	local items = (self.action == "use") and MacroBuilder.BagItems() or MacroBuilder.KnownSpells()
	self.allItems = items
	local filtered = ns.MacroData.Filter(items, self.query or "")
	self.scrollBox:SetDataProvider(CreateDataProvider(filtered), true)

	if self.emptyText then
		local noun = (self.action == "use") and "items" or "spells"
		if #items == 0 then
			self.emptyText:SetText(("No %s found."):format(noun))
			self.emptyText:Show()
		elseif #filtered == 0 then
			self.emptyText:SetText(("No %s match your search."):format(noun))
			self.emptyText:Show()
		else
			self.emptyText:Hide()
		end
	end
end

function MacroBuilder:UpdateListSelection()
	if self.scrollBox then
		self.scrollBox:ForEachFrame(function(button)
			button.Selected:SetShown(button.data and button.data.key == self.selectedKey)
		end)
	end
end

--------------------------------------------------------------------------------
-- Selection / preview
--------------------------------------------------------------------------------

function MacroBuilder:SelectEntry(data)
	if not data then
		return
	end
	self.selectedKey = data.key
	-- Clicking the list fills the name box, so that box is always the single,
	-- visible source of truth. Its OnTextChanged refreshes rank/preview.
	self.nameBox:SetText(data.name)
	self:UpdateListSelection()
end

-- The name the command acts on -- always the name box (the list and Shift-click
-- both fill it, for spells and items alike).
function MacroBuilder:EffectiveName()
	return self.nameBox and strtrim(self.nameBox:GetText() or "") or ""
end

function MacroBuilder:CurrentLine()
	return MacroBuilder.Compose(
		self.action,
		self:EffectiveName(),
		self.target,
		self.modifier,
		self.rankN,
		self.rankPrefix
	)
end

function MacroBuilder:UpdatePreview()
	local line = self:CurrentLine()
	if line ~= "" then
		self.preview:SetText(line)
		self.preview:SetTextColor(1, 1, 1)
		self.explain:SetText(MacroBuilder.Describe(
			self.action, self:EffectiveName(), self.target, self.modifier, self.rankN, self.rankPrefix))
		self.insertButton:SetEnabled(true)
	else
		local hint = (self.action == "use")
			and "Pick an item or type its name to build a /use command."
			or "Pick a spell to build a /cast command."
		self.preview:SetText(hint)
		ns.SetMutedText(self.preview)
		self.explain:SetText("")
		self.insertButton:SetEnabled(false)
	end
end

-- Labels the name box for the current action, and shows the rank box only for a
-- /cast whose spell actually has ranks.
function MacroBuilder:UpdateVisibility()
	local isItem = (self.action == "use")
	self.nameLabel:SetText(isItem
		and "Item name (click the list, type, or Shift-click an item)"
		or "Spell name (click the list, type, or Shift-click from your spellbook)")

	local showRank = (not isItem) and self.rankPrefix ~= nil
	self.rankLabel:SetShown(showRank)
	self.rankBox:SetShown(showRank)
	if not showRank then
		self.rankBox:SetText("")
		self.rankN = nil
	end
end

function MacroBuilder:SetAction(key)
	if self.action == key then
		return
	end
	self.action = key
	self.selectedKey = nil
	self.rankPrefix = nil
	self.rankN = nil
	if self.rankBox then self.rankBox:SetText("") end
	if self.nameBox then self.nameBox:SetText("") end
	if self.actionDropdown then self.actionDropdown:GenerateMenu() end
	self:RefreshList()
	self:UpdateVisibility()
	self:UpdatePreview()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function MacroBuilder:Create()
	local frame = ns.CreatePortraitWindow("ExtendedMacroUIMacroBuilder", BUILDER_WIDTH, BUILDER_HEIGHT, "Macro Builder")
	-- Docks to the main window's top-right -- the same slot as the icon picker,
	-- so the two are mutually exclusive (see Open()).
	frame:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 6, 0)
	self.frame = frame

	local inset = frame.Inset

	-- Action dropdown.
	local actionLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	actionLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", 12, -12)
	actionLabel:SetText("What should this command do?")

	local actionDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	actionDropdown:SetWidth(170)
	actionDropdown:SetPoint("TOPLEFT", actionLabel, "BOTTOMLEFT", 0, -6)
	actionDropdown:SetupMenu(function(_, rootDescription)
		for _, a in ipairs(ACTIONS) do
			rootDescription:CreateRadio(a.text,
				function() return MacroBuilder.action == a.key end,
				function() MacroBuilder:SetAction(a.key) end)
		end
	end)
	self.actionDropdown = actionDropdown

	-- Search box over the list.
	local search = CreateFrame("EditBox", nil, inset, "SearchBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", actionDropdown, "BOTTOMLEFT", 2, -10)
	search:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(box)
		MacroBuilder.query = box:GetText()
		MacroBuilder:RefreshList()
	end)
	self.search = search
	ns.RegisterEditBox(search)

	-- Bottom-up block: buttons, preview, conditionals, item-name box.
	local cancel = ns.CreateButton(frame, "Close", 90, 22, function() MacroBuilder:Close() end)
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)

	local insert = ns.CreateButton(frame, "Insert", 90, 22, function() MacroBuilder:Insert() end)
	insert:SetPoint("BOTTOMRIGHT", cancel, "BOTTOMLEFT", -6, 0)
	ns.SetTooltip(insert, "Add this command as a new line in the macro you're editing.")
	self.insertButton = insert

	-- Preview block, built bottom-up: the plain-language explanation sits at the
	-- very bottom, the composed command above it, and the "Preview" label on top.
	local explain = inset:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	explain:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 12, 8)
	explain:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	explain:SetJustifyH("LEFT")
	explain:SetHeight(28)
	self.explain = explain

	local preview = inset:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	preview:SetPoint("BOTTOMLEFT", explain, "TOPLEFT", 0, 6)
	preview:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	preview:SetJustifyH("LEFT")
	preview:SetHeight(24)
	self.preview = preview

	local previewLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	previewLabel:SetPoint("BOTTOMLEFT", preview, "TOPLEFT", 0, 4)
	previewLabel:SetText("Preview")

	-- Rank box (spells with ranks only).
	local rankLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	rankLabel:SetPoint("BOTTOMLEFT", previewLabel, "TOPLEFT", 0, 16)
	rankLabel:SetText("Rank (optional)")
	self.rankLabel = rankLabel

	local rankBox = CreateFrame("EditBox", nil, inset, "InputBoxTemplate")
	rankBox:SetSize(40, 20)
	rankBox:SetPoint("LEFT", rankLabel, "RIGHT", 10, 0)
	rankBox:SetAutoFocus(false)
	rankBox:SetNumeric(true)
	rankBox:SetMaxLetters(3)
	rankBox:SetScript("OnEscapePressed", rankBox.ClearFocus)
	rankBox:HookScript("OnTextChanged", function(box)
		local n = tonumber(box:GetText())
		MacroBuilder.rankN = (n and n > 0) and n or nil
		MacroBuilder:UpdatePreview()
	end)
	self.rankBox = rankBox
	ns.RegisterEditBox(rankBox)

	-- Modifier dropdown.
	local modLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	modLabel:SetPoint("BOTTOMLEFT", rankLabel, "TOPLEFT", 0, 18)
	modLabel:SetText("Modifier")

	local modDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	modDropdown:SetWidth(190)
	modDropdown:SetPoint("LEFT", modLabel, "LEFT", 70, 0)
	modDropdown:SetupMenu(function(_, rootDescription)
		for _, m in ipairs(MODIFIERS) do
			local radio = rootDescription:CreateRadio(m.text,
				function() return MacroBuilder.modifier == m.key end,
				function()
					MacroBuilder.modifier = m.key
					modDropdown:GenerateMenu()
					MacroBuilder:UpdatePreview()
				end)
			if m.desc then
				radio:SetTooltip(function(tooltip)
					GameTooltip_SetTitle(tooltip, m.text)
					GameTooltip_AddNormalLine(tooltip, m.desc)
				end)
			end
		end
	end)
	self.modDropdown = modDropdown

	-- Target dropdown.
	local targetLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	targetLabel:SetPoint("BOTTOMLEFT", modLabel, "TOPLEFT", 0, 36)
	targetLabel:SetText("Target")

	local targetDropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	targetDropdown:SetWidth(190)
	targetDropdown:SetPoint("LEFT", targetLabel, "LEFT", 70, 0)
	targetDropdown:SetupMenu(function(_, rootDescription)
		for _, t in ipairs(TARGETS) do
			local radio = rootDescription:CreateRadio(t.text,
				function() return MacroBuilder.target == t.key end,
				function()
					MacroBuilder.target = t.key
					targetDropdown:GenerateMenu()
					MacroBuilder:UpdatePreview()
				end)
			if t.desc then
				radio:SetTooltip(function(tooltip)
					GameTooltip_SetTitle(tooltip, t.text)
					GameTooltip_AddNormalLine(tooltip, t.desc)
				end)
			end
		end
	end)
	self.targetDropdown = targetDropdown

	-- Name box (spell or item), above the Target row. The list, typing and
	-- Shift-click all fill this one box.
	local nameLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	nameLabel:SetPoint("BOTTOMLEFT", targetLabel, "TOPLEFT", 0, 40)
	nameLabel:SetText("Spell name (click the list, type, or Shift-click from your spellbook)")
	self.nameLabel = nameLabel

	local nameBox = CreateFrame("EditBox", nil, inset, "InputBoxTemplate")
	nameBox:SetHeight(20)
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -4)
	nameBox:SetPoint("RIGHT", inset, "RIGHT", -12, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
	nameBox:HookScript("OnTextChanged", function(editBox)
		-- For a spell, derive the rank prefix from the typed/filled name so the
		-- rank box appears when the spell actually has ranks.
		if MacroBuilder.action ~= "use" then
			MacroBuilder.rankPrefix = MacroBuilder.RankPrefix(strtrim(editBox:GetText() or ""))
		end
		MacroBuilder:UpdateVisibility()
		MacroBuilder:UpdatePreview()
	end)
	self.nameBox = nameBox
	ns.RegisterEditBox(nameBox)

	-- Scrolling list between the search box and the name row.
	local box = CreateFrame("Frame", nil, inset, "InsetFrameTemplate")
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -2, -6)
	box:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 2, -6)
	box:SetPoint("BOTTOM", nameLabel, "TOP", 0, 8)

	local emptyText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("LEFT", box, "LEFT", 14, 0)
	emptyText:SetPoint("RIGHT", box, "RIGHT", -14, 0)
	emptyText:SetJustifyH("CENTER")
	ns.SetMutedText(emptyText)
	emptyText:Hide()
	self.emptyText = emptyText

	local scrollBox = CreateFrame("Frame", nil, box, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4)
	scrollBox:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -22, 4)

	local scrollBar = CreateFrame("EventFrame", nil, box, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(ROW_HEIGHT)
	view:SetElementInitializer("Button", InitListButton)
	view:SetPadding(2, 2, 2, 2, 2)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	self.scrollBox = scrollBox

	-- Keep the list fresh while open as the player learns spells or their bags
	-- change; rebuild only for the list currently shown.
	frame:SetScript("OnShow", function()
		frame:RegisterEvent("SPELLS_CHANGED")
		frame:RegisterEvent("BAG_UPDATE_DELAYED")
	end)
	frame:SetScript("OnHide", function()
		frame:UnregisterEvent("SPELLS_CHANGED")
		frame:UnregisterEvent("BAG_UPDATE_DELAYED")
	end)
	frame:SetScript("OnEvent", function()
		MacroBuilder:RefreshList()
	end)

	frame.CloseButton:SetScript("OnClick", function() MacroBuilder:Close() end)

	-- Shift-clicking a spell (spellbook) or item (bags, etc.) fills the name box
	-- while the builder is open. Both funnel through ChatFrameUtil.InsertLink:
	-- items arrive as an |Hitem:| link, spells as an |Hspell:| link (the plain
	-- "name" path is reserved for Blizzard's own MacroFrameText). A post-hook
	-- taints nothing.
	hooksecurefunc(ChatFrameUtil, "InsertLink", function(text)
		if not (MacroBuilder:IsShown() and type(text) == "string") then
			return
		end
		local name = text:match("%[(.-)%]")
		if not name or name == "" then
			return
		end
		if text:match("|Hitem:") then
			if MacroBuilder.action ~= "use" then
				MacroBuilder:SetAction("use")
			end
			MacroBuilder.nameBox:SetText(name)
		elseif text:match("|Hspell:") then
			if MacroBuilder.action ~= "cast" then
				MacroBuilder:SetAction("cast")
			end
			MacroBuilder.nameBox:SetText(name)
		end
	end)
end

--------------------------------------------------------------------------------
-- Open / close / insert
--------------------------------------------------------------------------------

function MacroBuilder:IsShown()
	return self.frame and self.frame:IsShown()
end

function MacroBuilder:Open()
	if not self.frame then
		return
	end
	-- The icon picker shares the dock slot; only one side panel at a time.
	if ns.IconPicker then
		ns.IconPicker:Close()
	end
	self:RefreshList()
	self:UpdateListSelection()
	self:UpdateVisibility()
	self:UpdatePreview()
	self.frame:Show()
end

function MacroBuilder:Close()
	if self.frame then
		self.frame:Hide()
	end
end

function MacroBuilder:Toggle()
	if self:IsShown() then
		self:Close()
	else
		self:Open()
	end
end

-- Appends the composed line to the macro editor's draft body.
function MacroBuilder:Insert()
	local line = self:CurrentLine()
	if line == "" then
		return
	end
	if ns.Editor then
		ns.Editor:InsertBodyLine(line)
	end
end
