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

local PICKER_WIDTH, PICKER_HEIGHT = 380, 424
local GRID_STRIDE = 8
local CELL_SIZE = 37

local FILTERS = {
	{ key = "all", text = "All Icons" },
	{ key = "spells", text = "Spell Icons" },
	{ key = "items", text = "Item Icons" },
}

local IconPicker = {}
ns.IconPicker = IconPicker

IconPicker.filter = "all"
IconPicker.selectedIcon = nil

--------------------------------------------------------------------------------
-- Icon data
--------------------------------------------------------------------------------

local function IconTypesForFilter(filter)
	if filter == "spells" then
		return { IconDataProviderIconType.Spell }
	elseif filter == "items" then
		return { IconDataProviderIconType.Item }
	end
	return { IconDataProviderIconType.Spell, IconDataProviderIconType.Item }
end

function IconPicker:EnsureProvider()
	if not self.provider then
		self.provider = CreateAndInitFromMixin(IconDataProviderMixin, IconDataProviderExtraType.Spellbook)
	end
	self.provider:SetIconTypes(IconTypesForFilter(self.filter))
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

	local icon = IconPicker.provider:GetIconByIndex(index)
	button.icon = icon
	button.Icon:SetTexture(icon)
	button.Selected:SetShown(icon == IconPicker.selectedIcon)
end

function IconPicker:RefreshGrid()
	self:EnsureProvider()
	local count = self.provider:GetNumIcons()
	self.scrollBox:SetDataProvider(CreateIndexRangeDataProvider(count), ScrollBoxConstants.RetainScrollPosition)
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

	-- "Choose an Icon:" label + filter dropdown, right of the preview.
	local chooseLabel = inset:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	chooseLabel:SetPoint("TOPLEFT", preview, "TOPRIGHT", 18, -2)
	chooseLabel:SetText("Choose an Icon:")

	local dropdown = CreateFrame("DropdownButton", nil, inset, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(150)
	dropdown:SetPoint("TOPLEFT", chooseLabel, "BOTTOMLEFT", 0, -6)
	dropdown:SetupMenu(function(_, rootDescription)
		for _, f in ipairs(FILTERS) do
			rootDescription:CreateRadio(f.text,
				function() return IconPicker.filter == f.key end,
				function() IconPicker:SetFilter(f.key) end)
		end
	end)
	self.dropdown = dropdown

	-- Okay / Cancel, bottom-right inside the frame.
	local cancel = ns.CreateButton(frame, "Cancel", 90, 22, function() IconPicker:Close() end)
	cancel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 6)

	local okay = ns.CreateButton(frame, "Okay", 90, 22, function() IconPicker:Okay() end)
	okay:SetPoint("BOTTOMRIGHT", cancel, "BOTTOMLEFT", -6, 0)

	-- Icon grid. A tighter scrollbar gutter (22) keeps the 8-column grid width.
	local box, scrollBox, scrollBar = ns.CreateScrollList(inset, 22)
	box:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -84)
	box:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -10, -84)
	box:SetPoint("BOTTOM", okay, "TOP", 0, 10)

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

function IconPicker:IsShown()
	return self.frame and self.frame:IsShown()
end

function IconPicker:SetFilter(filter)
	self.filter = filter
	self:RefreshGrid()
	if self.dropdown then
		self.dropdown:GenerateMenu()
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
	-- The macro builder shares the dock slot; only one side panel at a time.
	if ns.MacroBuilder then
		ns.MacroBuilder:Close()
	end
	self.selectedIcon = draft.icon
	self.preview:SetTexture(draft.icon)
	self:RefreshGrid()
	self.frame:Show()
end

function IconPicker:Close()
	if self.frame then
		self.frame:Hide()
	end
end

function IconPicker:Toggle()
	if self:IsShown() then
		self:Close()
	else
		self:Open()
	end
end

function IconPicker:Okay()
	if ns.Editor and self.selectedIcon then
		ns.Editor:SetDraftIcon(self.selectedIcon)
	end
	self:Close()
end
