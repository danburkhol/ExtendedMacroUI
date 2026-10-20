local ADDON_NAME, ns = ...

-- Cache hot globals as locals.
local CreateFrame = CreateFrame
local UIParent = UIParent
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip
local CreateScrollBoxListLinearView = CreateScrollBoxListLinearView
local ScrollUtil = ScrollUtil
local sort = table.sort

local CHAT_PREFIX = "|cffffd100Extended Macro UI:|r "

-- Shared state lives on ns.
ns.frame = nil
ns.db = nil

-- User-facing chat output.
function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. msg)
end

local function HideTooltip()
	GameTooltip:Hide()
end

-- Standard button tooltip. combatSensitive adds the combat reason when the
-- button is disabled during combat.
function ns.SetTooltip(button, title, combatSensitive)
	button:SetMotionScriptsWhileDisabled(true)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if title then
			GameTooltip:AddLine(title, 1, 1, 1, true)
		end
		if combatSensitive and not self:IsEnabled() and InCombatLockdown() then
			GameTooltip:AddLine("Can't change macros while in combat.", 1, 0.3, 0.3, true)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", HideTooltip)
end

--------------------------------------------------------------------------------
-- Shared UI helpers
--------------------------------------------------------------------------------

-- Standard red panel button. Callers add their own SetPoint / tooltip.
function ns.CreateButton(parent, text, width, height, onClick)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, height)
	button:SetText(text)
	if onClick then
		button:SetScript("OnClick", onClick)
	end
	return button
end

-- A hidden, movable-elsewhere portrait window (the main window, icon picker and
-- macro builder all share this chrome). Callers position it, set scripts and
-- add their own contents.
function ns.CreatePortraitWindow(name, width, height, title)
	local frame = CreateFrame("Frame", name, UIParent, "ButtonFrameTemplate")
	frame:SetSize(width, height)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	frame:SetTitle(title)
	frame:SetPortraitToAsset("Interface\\MacroFrame\\MacroFrame-Icon")
	return frame
end

-- Trims the 1px border baked into icon textures so they don't look inset.
function ns.TrimIcon(texture)
	texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	return texture
end

-- The muted parchment color used for secondary/disabled text.
ns.MUTED_COLOR = { 0.72, 0.67, 0.54 }
function ns.SetMutedText(fontString)
	fontString:SetTextColor(ns.MUTED_COLOR[1], ns.MUTED_COLOR[2], ns.MUTED_COLOR[3])
end

-- True for a nil/empty/whitespace-only string. Name boxes use this to gate Save.
function ns.IsBlank(text)
	return not text or strtrim(text) == ""
end

-- Returns `name .. suffix`, trimming the END of `name` when needed so the result
-- fits `maxLen`. Duplicating uses this so a name already at the length limit
-- (e.g. a 16-char macro name) still gets a suffix instead of overflowing.
function ns.NameWithSuffix(name, suffix, maxLen)
	name = name or ""
	suffix = suffix or ""
	if #name + #suffix <= maxLen then
		return name .. suffix
	end
	local keep = maxLen - #suffix
	if keep < 0 then
		keep = 0
	end
	return name:sub(1, keep) .. suffix
end

-- Builds the recessed list container shared by every scrolling list in the
-- addon: an InsetFrame box holding a WowScrollBoxList and a MinimalScrollBar.
-- The caller anchors the returned `box`, builds a view (linear or grid) and
-- calls ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view).
-- `rightInset` is the box-to-scrollBox right gap that leaves room for the
-- scrollbar (defaults to 24; the icon grid passes a tighter value so its fixed
-- column count still fits).
function ns.CreateScrollList(parent, rightInset)
	rightInset = rightInset or 24
	local box = CreateFrame("Frame", nil, parent, "InsetFrameTemplate")

	local scrollBox = CreateFrame("Frame", nil, box, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -4)
	scrollBox:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -rightInset, 4)

	local scrollBar = CreateFrame("EventFrame", nil, box, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 4, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 4, 0)

	return box, scrollBox, scrollBar
end

-- Builds the standard one-column list view (fixed row height, 2px padding) on
-- a CreateScrollList scrollBox/scrollBar pair. `initializer(button, data)`
-- sets up each row. Returns the view.
function ns.InitListView(scrollBox, scrollBar, rowHeight, initializer)
	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(rowHeight)
	view:SetElementInitializer("Button", initializer)
	view:SetPadding(2, 2, 2, 2, 2)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
	return view
end

-- The centered, muted empty-state line shown over a list box. Hidden; the
-- owner sets its text and shows it when the list is empty.
function ns.CreateEmptyText(box)
	local emptyText = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	emptyText:SetPoint("LEFT", box, "LEFT", 14, 0)
	emptyText:SetPoint("RIGHT", box, "RIGHT", -14, 0)
	emptyText:SetJustifyH("CENTER")
	ns.SetMutedText(emptyText)
	emptyText:Hide()
	return emptyText
end

-- ButtonFrameTemplate's Inset sits 60px below the frame's top and 26px above
-- its bottom, so a window sized to its contents is content height + 86.
local INSET_CHROME = 86
function ns.SetInsetContentHeight(frame, height)
	frame:SetHeight(height + INSET_CHROME)
end

-- A small radio button with a white label to its right. Callers anchor it and
-- keep the group's checked state in sync.
function ns.CreateRadio(parent, text, onClick)
	local radio = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
	radio.text:SetFontObject("GameFontHighlightSmall")
	if text then
		radio.text:SetText(text)
	end
	if onClick then
		radio:SetScript("OnClick", onClick)
	end
	return radio
end

-- Gives a Menu element description (e.g. a dropdown radio) a title +
-- description hover tooltip.
function ns.SetMenuTooltip(description, title, text)
	description:SetTooltip(function(tooltip)
		GameTooltip_SetTitle(tooltip, title)
		GameTooltip_AddNormalLine(tooltip, text)
	end)
end

-- Escapes "|" as "||" so user text displays literally instead of being read
-- as color or link codes.
function ns.EscapePipes(text)
	return (tostring(text or ""):gsub("|", "||"))
end

-- Case-insensitive A->Z on .name; equal names fall back to .key (when both
-- have one) so the order is stable.
local function ByName(a, b)
	local an, bn = a.name:lower(), b.name:lower()
	if an == bn and a.key ~= nil and b.key ~= nil and type(a.key) == type(b.key) then
		return a.key < b.key
	end
	return an < bn
end

-- Sorts a list of { name, key?, ... } items A->Z (see ByName). Returns it.
function ns.SortByName(list)
	sort(list, ByName)
	return list
end

-- The default "?" macro icon (INV_Misc_QuestionMark).
ns.QUESTION_MARK_ICON = 134400

--------------------------------------------------------------------------------
-- Docked side panels
--------------------------------------------------------------------------------

-- The icon picker, macro builder and import/export wizard all dock in the same
-- slot right of the main window, so only one is open at a time. Each panel
-- registers here, gets IsShown/Close/Toggle, and implements its own Open
-- (which calls ns.CloseDockPanels(self) first).
local dockPanels = {}

local DockPanelMixin = {}

function DockPanelMixin:IsShown()
	return self.frame and self.frame:IsShown()
end

function DockPanelMixin:Close()
	if self.frame then
		self.frame:Hide()
	end
end

function DockPanelMixin:Toggle()
	if self:IsShown() then
		self:Close()
	else
		self:Open()
	end
end

function ns.RegisterDockPanel(panel)
	Mixin(panel, DockPanelMixin)
	dockPanels[#dockPanels + 1] = panel
	return panel
end

-- Closes every docked panel except `except` (nil closes them all).
function ns.CloseDockPanels(except)
	for _, panel in ipairs(dockPanels) do
		if panel ~= except then
			panel:Close()
		end
	end
end

-- Adds the standard row visuals to a list button: a gold "selected" background
-- (shown by the owner when the row is the selection) and a subtle hover
-- highlight. Returns the Selected texture so the caller can toggle it.
function ns.AddRowHighlight(button)
	local selected = button:CreateTexture(nil, "BACKGROUND")
	selected:SetAllPoints()
	selected:SetColorTexture(1, 0.82, 0, 0.16)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.08)

	return selected
end

-- The centered "nothing selected" placeholder both editor panes show when no
-- item is loaded. Returns the (hidden) prompt frame.
function ns.CreatePrompt(parent, title, hint)
	local prompt = CreateFrame("Frame", nil, parent)
	prompt:SetAllPoints(parent)

	local promptTitle = prompt:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	promptTitle:SetPoint("CENTER", prompt, "CENTER", 0, 20)
	promptTitle:SetText(title)

	local promptHint = prompt:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	promptHint:SetPoint("TOP", promptTitle, "BOTTOM", 0, -8)
	promptHint:SetWidth(240)
	promptHint:SetText(hint)

	prompt:Hide()
	return prompt
end

-- A scrolling multi-line text input (InputScrollFrameTemplate) with the built-in
-- char counter hidden and the editbox width kept in sync with the frame so text
-- wraps correctly. Callers anchor it, set OnTextChanged and RegisterEditBox.
function ns.CreateMultilineInput(parent, maxLetters)
	local body = CreateFrame("ScrollFrame", nil, parent, "InputScrollFrameTemplate")
	body.CharCount:Hide()
	body.EditBox:SetMaxLetters(maxLetters)
	body:HookScript("OnSizeChanged", function(f, width)
		f.EditBox:SetWidth(width - 18)
	end)
	return body
end

local DB_DEFAULTS = {
	position = nil, -- { point, relPoint, x, y } (free-floating mode only)
	takeoverMacro = false, -- /macro opens this window instead of Blizzard's
	lockToPanel = true, -- open as a managed UI panel (like Blizzard's windows)
	messages = {}, -- saved chat messages (outside the macro system; no slots)
	nextMessageId = 1, -- monotonic id source for saved messages
	sendInterval = 15, -- anti-spam: min seconds between any two message sends
	minimap = { hide = false }, -- LibDBIcon state (shown + position)
}

local function CopyDefaults(dst, src)
	for key, value in pairs(src) do
		if dst[key] == nil then
			if type(value) == "table" then
				dst[key] = CopyDefaults({}, value)
			else
				dst[key] = value
			end
		end
	end
	return dst
end

-- Edit boxes register here so that clicking anywhere off them (a button, the
-- frame background, or outside the window) ends text entry, instead of
-- requiring Escape.
ns.editBoxes = {}

-- hitFrame is the region a click must land in to keep focus (defaults to the
-- edit box; pass a scroll frame for multi-line boxes).
function ns.RegisterEditBox(editBox, hitFrame)
	ns.editBoxes[#ns.editBoxes + 1] = { box = editBox, hit = hitFrame or editBox }
end

local focusWatcher = CreateFrame("Frame")
focusWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
focusWatcher:SetScript("OnEvent", function()
	for _, entry in ipairs(ns.editBoxes) do
		if entry.box:HasFocus() and not entry.hit:IsMouseOver() then
			entry.box:ClearFocus()
		end
	end
end)

-- Optional: make /macro open our window instead of Blizzard's. Done by
-- swapping the slash handler (never by tainting MacroFrame). false sentinel
-- records that the original was nil (Blizzard_MacroUI not yet loaded).
local originalMacroSlash
local function ApplyMacroTakeover()
	if not SlashCmdList then
		return
	end
	if ns.db.takeoverMacro then
		if originalMacroSlash == nil then
			originalMacroSlash = SlashCmdList["MACRO"] or false
		end
		SlashCmdList["MACRO"] = function()
			ns.Toggle()
		end
	elseif originalMacroSlash ~= nil then
		SlashCmdList["MACRO"] = originalMacroSlash or nil
		originalMacroSlash = nil
	end
end

-- Opens Blizzard's native macro window via its own slash handler (which
-- handles the load-on-demand), whichever handler currently points at it.
local function OpenNativeMacro()
	local handler = ns.db.takeoverMacro and originalMacroSlash or SlashCmdList["MACRO"]
	if type(handler) == "function" then
		handler("")
		return
	end
	if C_AddOns and C_AddOns.LoadAddOn then
		C_AddOns.LoadAddOn("Blizzard_MacroUI")
	end
	if MacroFrame then
		ShowUIPanel(MacroFrame)
	end
end
ns.OpenNativeMacro = OpenNativeMacro

--------------------------------------------------------------------------------
-- Window layout: locked UI panel (default) vs. free-floating
--------------------------------------------------------------------------------

-- Panel registration mirrors Blizzard's own MacroFrame, so our window joins the
-- managed layout and pushes alongside the character panel, spellbook, etc.
local PANEL_ATTRS = { area = "left", pushable = 1, whileDead = 1 }

-- Add/remove the main frame from UISpecialFrames. Panel-managed frames are
-- closed on Escape by the panel system; UISpecialFrames would raw-Hide them and
-- leave the layout slot stuck, so only free-floating mode registers there.
local function SetSpecialFrame(enabled)
	local name = ns.frame and ns.frame:GetName()
	if not name then
		return
	end
	for i = #UISpecialFrames, 1, -1 do
		if UISpecialFrames[i] == name then
			tremove(UISpecialFrames, i)
		end
	end
	if enabled then
		tinsert(UISpecialFrames, name)
	end
end

-- Applies the current lockToPanel setting to the frame. Out of combat only
-- (it reshuffles panel registration and attributes); the window should be hidden.
function ns.ApplyLayoutMode()
	local frame = ns.frame
	if not frame then
		return
	end
	local name = frame:GetName()
	if ns.db.lockToPanel then
		UIPanelWindows[name] = PANEL_ATTRS
		-- Force the panel manager to re-read the attributes on the next show.
		frame:SetAttribute("UIPanelLayout-defined", false)
		frame:SetMovable(false)
		SetSpecialFrame(false)
	else
		UIPanelWindows[name] = nil
		frame:SetAttribute("UIPanelLayout-defined", false)
		frame:SetMovable(true)
		SetSpecialFrame(true)
	end
	if ns.MainFrame and ns.MainFrame.RestorePosition then
		ns.MainFrame:RestorePosition()
	end
end

-- Opens/closes the window with the mechanism its current mode needs, and
-- remembers which was used so Close matches Open even if the mode changed.
function ns.OpenMain()
	local frame = ns.frame
	if not frame or frame:IsShown() then
		return
	end
	if ns.db.lockToPanel then
		ns.openedAsPanel = true
		-- Blizzard blocks ShowUIPanel in combat (same as the native panel).
		ShowUIPanel(frame)
	else
		ns.openedAsPanel = false
		frame:Show()
	end
end

function ns.CloseMain()
	local frame = ns.frame
	if not frame or not frame:IsShown() then
		return
	end
	if ns.openedAsPanel then
		HideUIPanel(frame)
	else
		frame:Hide()
	end
end

function ns.Toggle()
	local frame = ns.frame
	if not frame then
		return
	end
	if frame:IsShown() then
		ns.CloseMain()
	else
		ns.OpenMain()
	end
end

-- Changes the lock setting and re-applies the layout. Panels can't be moved or
-- shown in combat, so a change made then is deferred to PLAYER_REGEN_ENABLED.
function ns.SetLockToPanel(value)
	value = not not value
	ns.db.lockToPanel = value
	if InCombatLockdown() then
		ns.pendingLayout = true
		ns.Print("Window layout will update when you leave combat.")
		return
	end
	ns.pendingLayout = nil
	local frame = ns.frame
	local wasShown = frame and frame:IsShown()
	if wasShown then
		ns.CloseMain()
	end
	ns.ApplyLayoutMode()
	if wasShown then
		ns.OpenMain()
	end
end

local combatWatcher = CreateFrame("Frame")
combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatcher:SetScript("OnEvent", function()
	if ns.pendingLayout then
		ns.SetLockToPanel(ns.db.lockToPanel)
	end
end)

-- The EMU/Macro buttons switch which window /macro opens and swap windows now.
function ns.SwitchToEMU()
	ns.db.takeoverMacro = true
	ApplyMacroTakeover()
	-- Hiding Blizzard's (possibly protected) frame is only safe out of combat.
	if MacroFrame and MacroFrame:IsShown() and not InCombatLockdown() then
		HideUIPanel(MacroFrame)
	end
	ns.OpenMain()
end

function ns.SwitchToNative()
	ns.db.takeoverMacro = false
	ApplyMacroTakeover()
	ns.CloseMain()
	OpenNativeMacro()
end

-- Adds an "EMU" button to Blizzard's macro window, left of its close button.
local function EnsureNativeButton()
	if ns.nativeButton or not MacroFrame then
		return
	end
	local btn = ns.CreateButton(MacroFrame, "EMU", 44, 20, ns.SwitchToEMU)
	if MacroFrame.CloseButton then
		btn:SetPoint("RIGHT", MacroFrame.CloseButton, "LEFT", 0, 0)
	else
		btn:SetPoint("TOPRIGHT", MacroFrame, "TOPRIGHT", -30, -4)
	end
	ns.SetTooltip(btn, "Switch to Extended Macro UI, and make /macro open it.")
	ns.nativeButton = btn
end
ns.EnsureNativeButton = EnsureNativeButton

-- Options panel, built with the modern Settings API (present on this client).
-- Checkboxes drive lockToPanel and takeoverMacro; both mirror the /emu commands.
local optionsCategory
local function BuildOptions()
	if optionsCategory or not Settings or not Settings.RegisterVerticalLayoutCategory then
		return
	end
	local category = Settings.RegisterVerticalLayoutCategory("Extended Macro UI")

	local function GetLock()
		return ns.db.lockToPanel
	end
	local function SetLock(value)
		ns.SetLockToPanel(value)
	end
	local lockSetting = Settings.RegisterProxySetting(category, "EXTENDEDMACROUI_LOCK_PANEL",
		Settings.VarType.Boolean, "Lock window as a UI panel",
		Settings.Default.True, GetLock, SetLock)

	local lockTooltip = "On (default): the window opens in a fixed position and shares the"
		.. " screen with other panels like the character or spellbook window.\n\n"
		.. "Off: the window floats free and can be dragged anywhere, independent of"
		.. " other panels."
	Settings.CreateCheckbox(category, lockSetting, lockTooltip)

	-- Make /macro open Extended Macro UI instead of Blizzard's window
	-- (equivalent to /emu macro).
	local function GetTakeover()
		return ns.db.takeoverMacro
	end
	local function SetTakeover(value)
		ns.db.takeoverMacro = not not value
		ApplyMacroTakeover()
	end
	local takeoverSetting = Settings.RegisterProxySetting(category, "EXTENDEDMACROUI_TAKEOVER_MACRO",
		Settings.VarType.Boolean, "Use as the default macro window (/macro)",
		Settings.Default.False, GetTakeover, SetTakeover)

	local takeoverTooltip = "On: typing /macro (and the game's Macros button) opens"
		.. " Extended Macro UI instead of Blizzard's macro window.\n\n"
		.. "Off (default): /macro opens Blizzard's macro window."
	Settings.CreateCheckbox(category, takeoverSetting, takeoverTooltip)

	-- Minimap button (LibDBIcon); the broker entry in Titan Panel etc. is
	-- managed by those addons.
	local function GetMinimap()
		return not (ns.db.minimap and ns.db.minimap.hide)
	end
	local function SetMinimap(value)
		if ns.Broker then
			ns.Broker:SetMinimapShown(value)
		else
			ns.db.minimap.hide = not value
		end
	end
	local minimapSetting = Settings.RegisterProxySetting(category, "EXTENDEDMACROUI_MINIMAP",
		Settings.VarType.Boolean, "Show minimap button",
		Settings.Default.True, GetMinimap, SetMinimap)
	local minimapTooltip = "Show the Extended Macro UI button on the minimap."
		.. " Left-click it to open the window; right-click it to send a saved message.\n\n"
		.. "The same launcher is also available to Titan Panel and other data-broker"
		.. " displays, whether or not the minimap button is shown."
	Settings.CreateCheckbox(category, minimapSetting, minimapTooltip)

	-- Anti-spam: the minimum seconds between any two saved-message sends
	-- (slider, so the Settings API clamps it to [MIN, MAX]).
	if Settings.CreateSlider and Settings.CreateSliderOptions then
		local function GetInterval()
			return ns.Messages and ns.Messages.GetInterval() or ns.db.sendInterval
		end
		local function SetInterval(value)
			ns.db.sendInterval = value
		end
		local intervalSetting = Settings.RegisterProxySetting(category, "EXTENDEDMACROUI_SEND_INTERVAL",
			Settings.VarType.Number, "Message send interval (anti-spam)",
			15, GetInterval, SetInterval)

		-- 0.5s steps so the minimum can be 0.5 while whole seconds stay reachable.
		local options = Settings.CreateSliderOptions(0.5, 60, 0.5)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return ("%g sec"):format(value)
		end)

		local intervalTooltip = "The minimum time between sending saved messages. The addon"
			.. " won't send any message (via Send Now or /emu send) again until this many"
			.. " seconds have passed since the last one, to prevent accidental or"
			.. " intentional spam.\n\nDefault: 15 seconds. Minimum: 0.5 seconds."
		Settings.CreateSlider(category, intervalSetting, options, intervalTooltip)
	end

	Settings.RegisterAddOnCategory(category)
	optionsCategory = category
end

-- Opens our Settings panel.
function ns.OpenOptions()
	if optionsCategory and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(optionsCategory:GetID())
	else
		ns.Print("Options are unavailable on this client.")
	end
end

local function Initialize()
	ExtendedMacroUIDB = ExtendedMacroUIDB or {}
	ns.db = CopyDefaults(ExtendedMacroUIDB, DB_DEFAULTS)

	-- Register the slash command first so /emu works even if a frame fails
	-- to build.
	SLASH_EMU1 = "/emu"
	SlashCmdList.EMU = function(msg)
		msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
		if msg == "macro" then
			ns.db.takeoverMacro = not ns.db.takeoverMacro
			ApplyMacroTakeover()
			if ns.db.takeoverMacro then
				ns.Print("/macro now opens Extended Macro UI.")
			else
				ns.Print("/macro restored to the default macro window.")
			end
		elseif msg == "lock" then
			ns.SetLockToPanel(true)
			ns.Print("Window locked to its UI-panel position.")
		elseif msg == "unlock" then
			ns.SetLockToPanel(false)
			ns.Print("Window unlocked; drag it anywhere.")
		elseif msg == "options" or msg == "config" then
			ns.OpenOptions()
		elseif msg == "send" or msg:sub(1, 5) == "send " then
			-- /emu send <message name> broadcasts a saved message to its
			-- checked outputs. Matching is case-insensitive.
			local name = (msg == "send") and "" or msg:sub(6)
			name = name:gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" then
				ns.Print("Usage: /emu send <message name>")
			elseif not ns.Messages.SendByName(name) then
				ns.Print("No saved message named \"" .. name .. "\".")
			end
		elseif msg == "help" then
			ns.Print("/emu - toggle the window.  Also: /emu lock | unlock | options | macro | send <name>")
		else
			ns.Toggle()
		end
	end

	ApplyMacroTakeover()

	ns.MainFrame:Create()

	-- Apply the saved lock/float mode now that the frame exists.
	ns.ApplyLayoutMode()

	-- Build the options panel; isolate it so a failure can't abort init.
	local okOpts, errOpts = pcall(BuildOptions)
	if not okOpts then
		ns.Print("Options panel failed to load: " .. tostring(errOpts))
	end

	-- Isolate the icon picker so a failure there surfaces instead of
	-- silently aborting init.
	local ok, err = pcall(function()
		ns.IconPicker:Create()
	end)
	if not ok then
		ns.Print("Icon picker failed to load: " .. tostring(err))
	end

	-- Same isolation for the macro builder side panel.
	local okBuilder, errBuilder = pcall(function()
		ns.MacroBuilder:Create()
	end)
	if not okBuilder then
		ns.Print("Macro builder failed to load: " .. tostring(errBuilder))
	end

	-- Data broker launcher + minimap button.
	local okBroker, errBroker = pcall(function()
		ns.Broker:Initialize()
	end)
	if not okBroker then
		ns.Print("Minimap/broker button failed to load: " .. tostring(errBroker))
	end

	-- Same isolation for the import/export wizard.
	local okTransfer, errTransfer = pcall(function()
		ns.TransferWizard:Create()
	end)
	if not okTransfer then
		ns.Print("Import/Export wizard failed to load: " .. tostring(errTransfer))
	end

	-- If Blizzard's macro UI is already loaded, add our EMU button now;
	-- otherwise the loader adds it when Blizzard_MacroUI loads.
	EnsureNativeButton()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
	if name == ADDON_NAME then
		Initialize()
	elseif name == "Blizzard_MacroUI" then
		EnsureNativeButton()
	end
end)
