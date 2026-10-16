local ADDON_NAME, ns = ...

-- Cache hot globals as locals.
local CreateFrame = CreateFrame
local UIParent = UIParent
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip

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

-- A hidden, movable-elsewhere portrait window (our two windows share this
-- chrome). Callers position it, set scripts and add their own contents.
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

local DB_DEFAULTS = {
	position = nil, -- { point, relPoint, x, y } (free-floating mode only)
	takeoverMacro = false, -- /macro opens this window instead of Blizzard's
	lockToPanel = true, -- open as a managed UI panel (like Blizzard's windows)
	messages = {}, -- saved chat messages (outside the macro system; no slots)
	nextMessageId = 1, -- monotonic id source for saved messages
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
