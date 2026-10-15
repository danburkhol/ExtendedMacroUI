local ADDON_NAME, ns = ...

-- Cache hot globals as locals.
local CreateFrame = CreateFrame
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

local DB_DEFAULTS = {
	position = nil, -- { point, relPoint, x, y }
	takeoverMacro = false, -- /macro opens this window instead of Blizzard's
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

function ns.Toggle()
	local frame = ns.frame
	if not frame then
		return
	end
	-- The window itself is unprotected (its secure Run button lives on
	-- UIParent), so it can open/close/move in combat.
	if frame:IsShown() then
		frame:Hide()
	else
		frame:Show()
	end
end

-- The EMU/Macro buttons switch which window /macro opens and swap windows now.
function ns.SwitchToEMU()
	ns.db.takeoverMacro = true
	ApplyMacroTakeover()
	-- Hiding Blizzard's (possibly protected) frame is only safe out of combat.
	if MacroFrame and MacroFrame:IsShown() and not InCombatLockdown() then
		HideUIPanel(MacroFrame)
	end
	if ns.frame and not ns.frame:IsShown() then
		ns.frame:Show()
	end
end

function ns.SwitchToNative()
	ns.db.takeoverMacro = false
	ApplyMacroTakeover()
	if ns.frame and ns.frame:IsShown() then
		ns.frame:Hide()
	end
	OpenNativeMacro()
end

-- Adds an "EMU" button to Blizzard's macro window, left of its close button.
local function EnsureNativeButton()
	if ns.nativeButton or not MacroFrame then
		return
	end
	local btn = CreateFrame("Button", nil, MacroFrame, "UIPanelButtonTemplate")
	btn:SetSize(44, 20)
	btn:SetText("EMU")
	if MacroFrame.CloseButton then
		btn:SetPoint("RIGHT", MacroFrame.CloseButton, "LEFT", 0, 0)
	else
		btn:SetPoint("TOPRIGHT", MacroFrame, "TOPRIGHT", -30, -4)
	end
	btn:SetScript("OnClick", ns.SwitchToEMU)
	ns.SetTooltip(btn, "Switch to Extended Macro UI, and make /macro open it.")
	ns.nativeButton = btn
end
ns.EnsureNativeButton = EnsureNativeButton

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
		else
			ns.Toggle()
		end
	end

	ApplyMacroTakeover()

	ns.MainFrame:Create()

	-- Isolate the icon picker so a failure there surfaces instead of
	-- silently aborting init.
	local ok, err = pcall(function()
		ns.IconPicker:Create()
	end)
	if not ok then
		ns.Print("Icon picker failed to load: " .. tostring(err))
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
