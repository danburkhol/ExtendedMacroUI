local ADDON_NAME, ns = ...

-- LibDataBroker launcher + optional minimap button (LibDBIcon).
--
-- One LDB "launcher" object is shown by any LDB display (Titan Panel,
-- ChocolateBar, ...) and by LibDBIcon as a minimap button:
--   Left-click   toggle the Extended Macro UI window
--   Right-click  menu of Saved Messages; picking one sends it through
--                Messages.Send (same anti-spam throttle and channel checks
--                as /emu send). A menu click is a hardware event, which
--                the chat API requires.
-- The libraries are embedded under Libs/ and loaded by the TOC; LibStub keeps
-- only the newest copy across all addons.

local LibStub = LibStub
local MenuUtil = MenuUtil
local GameTooltip_SetTitle = GameTooltip_SetTitle

local Messages = ns.Messages

local BROKER_NAME = "ExtendedMacroUI"
local ICON = "Interface\\MacroFrame\\MacroFrame-Icon"

local Broker = {}
ns.Broker = Broker

-- The Saved Messages menu: one entry per message (A->Z), plus a shortcut to
-- the Saved Messages tab.
local function OpenMessageMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
		rootDescription:CreateTitle("Send a Saved Message")
		local items = Messages.ListItems()
		if #items == 0 then
			local none = rootDescription:CreateButton("No saved messages yet", function() end)
			none:SetEnabled(false)
		end
		for _, item in ipairs(items) do
			local id = item.key
			local button = rootDescription:CreateButton((item.name:gsub("|", "||")), function()
				Messages.Send(Messages.GetById(id))
			end)
			local msg = Messages.GetById(id)
			if not msg or ns.IsBlank(msg.content) or not msg.outputs or #msg.outputs == 0 then
				-- Nothing would go out; show it but don't let it fire.
				button:SetEnabled(false)
			end
		end
		rootDescription:CreateDivider()
		rootDescription:CreateButton("Open Saved Messages", function()
			ns.OpenMain()
			if ns.MainFrame and ns.MainFrame.SelectTab then
				ns.MainFrame:SelectTab("messages")
			end
		end)
	end)
end

local function OnClick(owner, button)
	if button == "RightButton" then
		OpenMessageMenu(owner)
	else
		ns.Toggle()
	end
end

local function OnTooltipShow(tooltip)
	GameTooltip_SetTitle(tooltip, "Extended Macro UI")
	tooltip:AddLine("|cffffd100Left-click|r to open or close the macro window.", 1, 1, 1)
	tooltip:AddLine("|cffffd100Right-click|r to send a saved message.", 1, 1, 1)
end

-- Creates the LDB object and minimap button. Safe if the libraries are
-- missing (does nothing).
function Broker:Initialize()
	local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
	if not ldb then
		return
	end
	self.dataObject = ldb:NewDataObject(BROKER_NAME, {
		type = "launcher",
		label = "Extended Macro UI",
		text = "Extended Macro UI",
		icon = ICON,
		OnClick = OnClick,
		OnTooltipShow = OnTooltipShow,
	})

	local icon = LibStub("LibDBIcon-1.0", true)
	if icon and self.dataObject then
		self.icon = icon
		-- LibDBIcon keeps hide + minimap position in this table.
		icon:Register(BROKER_NAME, self.dataObject, ns.db.minimap)
	end
end

function Broker:IsMinimapShown()
	return not (ns.db.minimap and ns.db.minimap.hide)
end

function Broker:SetMinimapShown(shown)
	ns.db.minimap.hide = not shown
	if not self.icon then
		return
	end
	if shown then
		self.icon:Show(BROKER_NAME)
	else
		self.icon:Hide(BROKER_NAME)
	end
end
