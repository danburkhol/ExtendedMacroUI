std = "lua51"
max_line_length = false

-- 211/ADDON_NAME: every file starts with `local ADDON_NAME, ns = ...` by
-- convention (CLAUDE.md); some files don't use the name.
-- 212/self: methods defined with `:` that don't need self.
ignore = { "211/ADDON_NAME", "212/self" }

-- Globals this addon is allowed to create or modify (incl. Blizzard tables
-- we add fields to).
globals = {
	"ExtendedMacroUIDB",
	"SLASH_EMU1",
	"SlashCmdList",
	"UISpecialFrames",
	"UIPanelWindows",
	"StaticPopupDialogs",
}

-- WoW API and UI globals we only read.
read_globals = {
	-- Lua/WoW helpers
	"tinsert",
	"tremove",
	"wipe",
	"strtrim",
	"strsplit",
	"Mixin",
	"CreateFromMixins",
	"CreateAndInitFromMixin",
	"GenerateClosure",
	-- Frames / UI
	"CreateFrame",
	"UIParent",
	"DEFAULT_CHAT_FRAME",
	"PlaySound",
	"SOUNDKIT",
	"GameTooltip",
	"GameFontNormal",
	"GameFontHighlight",
	"NORMAL_FONT_COLOR",
	"RED_FONT_COLOR",
	"ScrollUtil",
	"CreateDataProvider",
	"CreateIndexRangeDataProvider",
	"CreateScrollBoxListLinearView",
	"CreateScrollBoxListGridView",
	"ScrollBoxConstants",
	"PanelTemplates_SetNumTabs",
	"PanelTemplates_SetTab",
	"PanelTemplates_TabResize",
	"PanelTemplates_GetSelectedTab",
	"PanelTemplates_UpdateTabs",
	"StaticPopup_Show",
	"IconDataProviderMixin",
	"IconDataProviderExtraType",
	"IconDataProviderIconType",
	-- Macro API
	"GetNumMacros",
	"GetMacroInfo",
	"CreateMacro",
	"EditMacro",
	"DeleteMacro",
	"PickupMacro",
	"GetMacroIcons",
	"GetMacroItemIcons",
	"C_Macro",
	"MAX_ACCOUNT_MACROS",
	"MAX_CHARACTER_MACROS",
	"MACROFRAME_CHAR_LIMIT",
	-- Combat / state
	"InCombatLockdown",
	"UnitName",
	"C_Timer",
	"GetTime",
	-- Chat / saved messages
	"C_ChatInfo",
	"GetChannelList",
	"GetChannelName",
	-- Send eligibility (group/raid/guild/officer/instance gating)
	"C_GuildInfo",
	"IsInGroup",
	"IsInRaid",
	"IsInGuild",
	"UnitIsGroupLeader",
	"UnitIsGroupAssistant",
	"LE_PARTY_CATEGORY_HOME",
	"LE_PARTY_CATEGORY_INSTANCE",
	"SAY",
	"YELL",
	"PARTY",
	"RAID",
	"RAID_WARNING",
	"INSTANCE_CHAT",
	"GUILD",
	"OFFICER",
	-- Macro builder (spell/item enumeration + composition)
	"GetNumSpellTabs",
	"GetSpellTabInfo",
	"GetSpellBookItemInfo",
	"GetSpellBookItemName",
	"GetSpellTexture",
	"IsPassiveSpell",
	"BOOKTYPE_SPELL",
	"C_Spell",
	"C_Item",
	"C_Container",
	"BACKPACK_CONTAINER",
	"NUM_BAG_SLOTS",
	"hooksecurefunc",
	"ChatFrameUtil",
	"GameTooltip_SetTitle",
	"GameTooltip_AddNormalLine",
	-- Native macro window switching
	"MacroFrame",
	"ShowUIPanel",
	"HideUIPanel",
	"C_AddOns",
	-- Import / export (encoding, metadata, error reporting)
	"C_EncodingUtil",
	"Enum",
	"GetRealmName",
	"GetServerTime",
	"geterrorhandler",
	"date",
	"strlenutf8",
	-- Settings (options panel)
	"Settings",
	"MinimalSliderWithSteppersMixin",
}
