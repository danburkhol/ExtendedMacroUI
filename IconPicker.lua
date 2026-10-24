local ADDON_NAME, ns = ...

local CreateFrame = CreateFrame
local CreateScrollBoxListGridView = CreateScrollBoxListGridView
local CreateIndexRangeDataProvider = CreateIndexRangeDataProvider
local ScrollUtil = ScrollUtil
local ScrollBoxConstants = ScrollBoxConstants
local CreateAndInitFromMixin = CreateAndInitFromMixin
local IconDataProviderMixin = IconDataProviderMixin
local IconDataProviderExtraType = IconDataProviderExtraType
local IconDataProviderIconType = IconDataProviderIconType

local PICKER_WIDTH, PICKER_HEIGHT = 380, 450
local GRID_STRIDE = 8
local CELL_SIZE = 37

-- Dropdown categories. "all" shows everything (via the provider's full range,
-- including icons with no known name); the rest are derived from the texture
-- name and so only cover named icons. "other" is everything named that none of
-- the specific buckets claim.
local CATEGORIES = {
	{ key = "all", text = "All Icons" },
	{ key = "abilities", text = "Abilities" },
	{ key = "spells", text = "Spells" },
	{ key = "items", text = "Items" },
	{ key = "professions", text = "Professions" },
	{ key = "achievements", text = "Achievements" },
	{ key = "other", text = "Other" },
}

local function HasPrefix(name, prefix)
	return name:sub(1, #prefix) == prefix
end

-- name -> boolean predicates for the name-derived categories. "all" has no
-- entry (it bypasses name filtering entirely); see ApplyFilter.
local CATEGORY_PREDICATES = {
	abilities = function(n) return HasPrefix(n, "ability_") end,
	spells = function(n) return HasPrefix(n, "spell_") end,
	items = function(n) return HasPrefix(n, "inv_") or HasPrefix(n, "inv-") end,
	professions = function(n) return HasPrefix(n, "trade_") end,
	-- Matches both "achievement_" and the handful of "achievment_" misspellings.
	achievements = function(n) return HasPrefix(n, "achiev") end,
}
CATEGORY_PREDICATES.other = function(n)
	return not (CATEGORY_PREDICATES.abilities(n)
		or CATEGORY_PREDICATES.spells(n)
		or CATEGORY_PREDICATES.items(n)
		or CATEGORY_PREDICATES.professions(n)
		or CATEGORY_PREDICATES.achievements(n))
end

local IconPicker = ns.RegisterDockPanel({})
ns.IconPicker = IconPicker

IconPicker.category = "all"
IconPicker.selectedIcon = nil
IconPicker.query = ""

--------------------------------------------------------------------------------
-- Icon data
--------------------------------------------------------------------------------

function IconPicker:EnsureProvider()
	if not self.provider then
		self.provider = CreateAndInitFromMixin(IconDataProviderMixin, IconDataProviderExtraType.Spellbook)
		-- Categories are name-based, so the provider always offers every icon.
		self.provider:SetIconTypes({ IconDataProviderIconType.Spell, IconDataProviderIconType.Item })
	end
end

--------------------------------------------------------------------------------
-- Fuzzy search + categories
--------------------------------------------------------------------------------

local IconNames = ns.IconNames

-- The searchable name for an icon: the bundled texture name for a numeric
-- fileDataID (this client returns those from the icon library), or the last
-- path segment for the rare string texture (the "?" default). nil when we have
-- no name -- those icons still appear under "All Icons", just not in search or
-- the name-derived categories.
local function IconName(icon)
	if type(icon) == "number" then
		return IconNames and IconNames[icon]
	elseif type(icon) == "string" then
		local base = icon:match("[^\\]+$")
		return base and base:lower()
	end
	return nil
end

-- Caches a { icon, name } list of every name-bearing icon, so a keystroke or
-- category switch only rescans this array. The provider always exposes every
-- icon, so this index is independent of the category and built just once.
function IconPicker:BuildSearchIndex()
	self:EnsureProvider()
	local list = {}
	for i = 1, self.provider:GetNumIcons() do
		local icon = self.provider:GetIconByIndex(i)
		local name = IconName(icon)
		if name then
			list[#list + 1] = { icon = icon, name = name }
		end
	end
	self.searchIndex = list
end

-- Recomputes self.filtered from the current category and query. nil means
-- "not filtering": the grid then shows the whole provider by index.
function IconPicker:ApplyFilter()
	local nq = ns.MacroData.NormalizeQuery(self.query or "")
	local predicate = CATEGORY_PREDICATES[self.category]
	-- "All Icons" with no search is the only case that shows the full provider
	-- range (so nameless icons still appear); anything else filters by name.
	if not predicate and nq == "" then
		self.filtered = nil
		return
	end
	if not self.searchIndex then
		self:BuildSearchIndex()
	end
	local out = {}
	for _, entry in ipairs(self.searchIndex) do
		local name = entry.name
		if (not predicate or predicate(name))
			and (nq == "" or ns.MacroData.FuzzyMatch(name, nq)) then
			out[#out + 1] = entry.icon
		end
	end
	self.filtered = out
end

-- How many cells the grid should show, and the icon for a given 1-based cell:
-- the filtered results while searching, else the provider's full range.
function IconPicker:GetGridCount()
	if self.filtered then
		return #self.filtered
	end
	return self.provider:GetNumIcons()
end

function IconPicker:GetGridIcon(index)
	if self.filtered then
		return self.filtered[index]
	end
	return self.provider:GetIconByIndex(index)
end

--------------------------------------------------------------------------------
-- Grid
--------------------------------------------------------------------------------

local function InitIconButton(button, index)
	if not button.created then
		button.created = true

		button.Icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon:SetSize(32, 32)
		button.Icon:SetPoint("CENTER")
		ns.TrimIcon(button.Icon)

		button.Selected = button:CreateTexture(nil, "OVERLAY")
		button.Selected:SetSize(CELL_SIZE, CELL_SIZE)
		button.Selected:SetPoint("CENTER")
		button.Selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
		button.Selected:SetBlendMode("ADD")
		button.Selected:Hide()

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints(button.Icon)
		highlight:SetColorTexture(1, 1, 1, 0.2)

		button:SetScript("OnClick", function(self)
			IconPicker:PickIcon(self.icon)
		end)
	end

	local icon = IconPicker:GetGridIcon(index)
	button.icon = icon
	button.Icon:SetTexture(icon)
	button.Selected:SetShown(icon == IconPicker.selectedIcon)
end

function IconPicker:RefreshGrid()
	self:EnsureProvider()
	self:ApplyFilter()
	local count = self:GetGridCount()
	-- A fresh search should start at the top; clearing it keeps your place.
	-- (DiscardScrollPosition is literally `false`, so don't use an and/or here.)
	local retain = ScrollBoxConstants.RetainScrollPosition
	if self.filtered then
		retain = ScrollBoxConstants.DiscardScrollPosition
	end
	self.scrollBox:SetDataProvider(CreateIndexRangeDataProvider(count), retain)

	if self.emptyText then
		if count == 0 and self.filtered then
			if self.query and self.query ~= "" then
				self.emptyText:SetFormattedText("No icons match \"%s\".", self.query)
			else
				self.emptyText:SetText("No icons in this category.")
			end
			self.emptyText:Show()
		else
			self.emptyText:Hide()
		end
	end
end

function IconPicker:UpdateSelectionVisuals()
	self.scrollBox:ForEachFrame(function(button)
		button.Selected:SetShown(button.icon == self.selectedIcon)
	end)
end

function IconPicker:PickIcon(icon)
	self.selectedIcon = icon
	self.preview:SetTexture(icon)
	self:UpdateSelectionVisuals()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function IconPicker:Create()
	local frame = ns.CreatePortraitWindow("ExtendedMacroUIIconPicker", PICKER_WIDTH, PICKER_HEIGHT, "Change Icon")

	-- Dock to the main window's top-right; follows it when it moves.
	frame:SetPoint("TOPLEFT", ns.frame, "TOPRIGHT", 6, 0)
	self.frame = frame

	local inset = frame.Inset

	-- Currently selected preview.
	local previewLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	previewLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", 12, -12)
	previewLabel:SetText("Currently Selected")

	local preview = inset:CreateTexture(nil, "ARTWORK")
	preview:SetSize(40, 40)
	preview:SetPoint("TOPLEFT", previewLabel, "BOTTOMLEFT", 2, -6)
	ns.TrimIcon(preview)
	self.preview = preview

	-- "Choose an Icon:" label + category dropdown, right of the preview.
	local chooseLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	chooseLabel:SetPoint("TOPLEFT", preview, "TOPRIGHT", 18, -2)
	chooseLabel:SetText("Choose an Icon:")

	local dropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(150)
	dropdown:SetPoint("TOPLEFT", chooseLabel, "BOTTOMLEFT", 0, -6)
	dropdown:SetupMenu(function(_, rootDescription)
		for _, c in ipairs(CATEGORIES) do
			rootDescription:CreateRadio(c.text,
				function() return IconPicker.category == c.key end,
				function() IconPicker:SetCategory(c.key) end)
		end
	end)
	self.dropdown = dropdown

	-- Okay / Cancel, bottom-right inside the frame.
	local cancel = ns.CreateButton(frame, "Cancel", 90, 22, function() IconPicker:Close() end)
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)

	local okay = ns.CreateButton(frame, "Okay", 90, 22, function() IconPicker:Okay() end)
	okay:SetPoint("BOTTOMRIGHT", cancel, "BOTTOMLEFT", -6, 0)

	-- Fuzzy search box over the grid; filters icons by texture name.
	local search = CreateFrame("EditBox", nil, inset, "SearchBoxTemplate")
	search:SetPoint("TOPLEFT", inset, "TOPLEFT", 12, -84)
	search:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -12, -84)
	search:SetHeight(20)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(editBox)
		IconPicker:SetQuery(editBox:GetText())
	end)
	-- Enter selects the first matching icon.
	search:HookScript("OnEnterPressed", function()
		IconPicker:SelectFirstResult()
	end)
	self.search = search
	ns.RegisterEditBox(search)

	-- Icon grid. A tighter scrollbar gutter (22) keeps the 8-column grid width.
	local box, scrollBox, scrollBar = ns.CreateScrollList(inset, 22)
	box:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -2, -6)
	box:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 2, -6)
	box:SetPoint("BOTTOM", okay, "TOP", 0, 10)

	-- Shown over the grid when a search matches nothing.
	self.emptyText = ns.CreateEmptyText(box)

	local view = CreateScrollBoxListGridView(GRID_STRIDE, 4, 4, 4, 4, 2, 2)
	view:SetElementSize(CELL_SIZE, CELL_SIZE)
	view:SetElementInitializer("Button", InitIconButton)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	self.scrollBox = scrollBox

	-- Close button hides without applying.
	frame.CloseButton:SetScript("OnClick", function() IconPicker:Close() end)
end

--------------------------------------------------------------------------------
-- Open / close / apply
--------------------------------------------------------------------------------

function IconPicker:SetCategory(category)
	self.category = category
	self:RefreshGrid()
	if self.dropdown then
		self.dropdown:GenerateMenu()
	end
end

function IconPicker:SetQuery(query)
	self.query = query
	self:RefreshGrid()
end

-- Enter in the search box selects the first matching icon.
function IconPicker:SelectFirstResult()
	local icon = self:GetGridIcon(1)
	if icon then
		self:PickIcon(icon)
	end
end

-- Opens the picker seeded from the editor's current draft.
function IconPicker:Open()
	if not self.frame or not ns.Editor then
		return
	end
	local draft = ns.Editor.draft
	if not draft then
		return
	end
	-- One docked side panel at a time.
	ns.CloseDockPanels(self)
	self.selectedIcon = draft.icon
	self.preview:SetTexture(draft.icon)
	-- Start each session with a cleared search.
	self.query = ""
	if self.search then
		self.search:SetText("")
	end
	self:RefreshGrid()
	self.frame:Show()
end

function IconPicker:Okay()
	if ns.Editor and self.selectedIcon then
		ns.Editor:SetDraftIcon(self.selectedIcon)
	end
	self:Close()
end
