local ADDON_NAME = ...

-- Forever/modern clients removed the global GetItemInfo in favour of C_Item.GetItemInfo (same
-- return signature). Bind a local so every GetItemInfo(...) call in this file works on both.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
-- Item-count feature: GetItemCount(id[, includeBank]) and the C_Container reads (globals were
-- moved under C_Item / C_Container on modern clients; fall back to the old globals if present).
local GetItemCount = GetItemCount or (C_Item and C_Item.GetItemCount)
local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or _G.GetContainerNumSlots
local GetContainerItemID = (C_Container and C_Container.GetContainerItemID) or _G.GetContainerItemID
local GetContainerItemInfo = (C_Container and C_Container.GetContainerItemInfo) or _G.GetContainerItemInfo
local QUEST_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local GEM_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Gem) or 3
local RECIPE_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9

-- Item class id via GetItemInfoInstant (instant/cached, no async wait). nil if unavailable.
local function getItemClassID(itemID)
    if not (itemID and GetItemInfoInstant) then return nil end
    local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
    return classID
end

local function isQuestItem(itemID)
    return getItemClassID(itemID) == QUEST_ITEM_CLASS
end

-- classID + subclassID (recipe/consumable subclass tells patterns vs enchants vs schematics, etc.)
local function getItemClassInfo(itemID)
    if not (itemID and GetItemInfoInstant) then return nil, nil end
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemID)
    return classID, subclassID
end

-- Recipe subclass ids (stable across clients). Consumable class id.
local RECIPE_SUB_LEATHERWORKING, RECIPE_SUB_TAILORING = 1, 2
local RECIPE_SUB_ENGINEERING = 3
local RECIPE_SUB_ENCHANTING = 8
local CONSUMABLE_ITEM_CLASS = 0
local CONSUMABLE_SUB_SCROLL = 4   -- confirmed on this client: "Scroll of X" = class 0, subclass 4

-- Classic gems are NOT the retail Gem class (3) here -- they're Trade Goods (class 7, subclass
-- "Other") mixed in with non-gems, so a class check can't isolate them. Use a curated id set of
-- the vanilla drop/prospect gems instead (extend as needed).
local GEM_ITEM_IDS = {
    [774] = true,   -- Malachite
    [818] = true,   -- Tigerseye
    [1206] = true,  -- Moss Agate
    [1210] = true,  -- Shadowgem
    [1529] = true,  -- Jade
    [1705] = true,  -- Lesser Moonstone
    [3864] = true,  -- Citrine
    [7909] = true,  -- Aquamarine
    [7910] = true,  -- Star Ruby
    [11754] = true, -- Black Diamond
    [11382] = true, -- Blood of the Mountain
    [12361] = true, -- Blue Sapphire
    [12364] = true, -- Huge Emerald
    [12363] = true, -- Arcane Crystal
    [12799] = true, -- Large Opal
    [12800] = true, -- Azerothian Diamond
}

-- Collapsible "various X" groups: label + rendering order. Everything not caught here that is
-- quality>=3 is "notable" (shown individually) and white/grey is "commons" (main drops).
local GROUP_META = {
    gems       = { label = "Gems" },
    patterns   = { label = "Various patterns" },
    schematics = { label = "Various schematics" },
    enchants   = { label = "Various enchants" },
    recipes    = { label = "Various recipes" },
    scrolls    = { label = "Various scrolls" },
    greens     = { label = "Various greens" },
}
local GROUP_ORDER = { "gems", "patterns", "schematics", "enchants", "recipes", "scrolls", "greens" }

-- Which bucket a drop belongs to: "quest" | "notable" | one of the GROUP_ORDER keys | "commons".
local function groupKeyForDrop(drop)
    local itemID = drop.itemID
    local quality = drop.quality or 0
    local classID, subclassID = getItemClassInfo(itemID)

    if classID == QUEST_ITEM_CLASS then return "quest" end
    if quality >= 3 then return "notable" end            -- blue/epic: always individual
    if GEM_ITEM_IDS[itemID] or classID == GEM_ITEM_CLASS then return "gems" end
    if classID == RECIPE_ITEM_CLASS then
        if subclassID == RECIPE_SUB_LEATHERWORKING or subclassID == RECIPE_SUB_TAILORING then return "patterns" end
        if subclassID == RECIPE_SUB_ENGINEERING then return "schematics" end
        if subclassID == RECIPE_SUB_ENCHANTING then return "enchants" end
        return "recipes"
    end
    if classID == CONSUMABLE_ITEM_CLASS and subclassID == CONSUMABLE_SUB_SCROLL then return "scrolls" end
    if quality == 2 then return "greens" end
    return "commons"
end

-- Effective display for a collapsible group. Shift (held) reveals everything (even hidden);
-- otherwise per-group mode drives it, with the global expandAllVarious forcing expand.
local function groupDisplayMode(key)
    if IsShiftKeyDown() then return "expand" end
    local modes = DropChanceTooltipDB and DropChanceTooltipDB.variousMode
    local m = (modes and modes[key]) or "collapse"
    if m == "hidden" then return "hidden" end
    if m == "expand" or (DropChanceTooltipDB and DropChanceTooltipDB.expandAllVarious) then return "expand" end
    return "collapse"
end

-- Active quest objective texts (lowercased). Used to show a quest-item drop only while the player is
-- on a quest that needs it. Rebuilt lazily; marked dirty on QUEST_LOG_UPDATE.
local activeQuestObjectives = {}
local questObjectivesDirty = true

local function refreshActiveQuestObjectives()
    questObjectivesDirty = false
    wipe(activeQuestObjectives)
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo and C_QuestLog.GetQuestObjectives) then
        return
    end
    local num = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, num do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID then
            local objectives = C_QuestLog.GetQuestObjectives(info.questID)
            if objectives then
                for _, obj in ipairs(objectives) do
                    if obj and obj.text and obj.text ~= "" then
                        activeQuestObjectives[obj.text:lower()] = true
                    end
                end
            end
        end
    end
end

-- Record a Forever-specific gap (item/npc we could show nothing for) for later targeted scraping.
-- Stores an enriched record (name/zone/level/count/dates) rather than a bare flag so a clean logout
-- preserves a self-contained, human-readable evidence log in SavedVariables -- no need to export
-- before quitting. (WoW writes SavedVariables to disk on clean logout/reload; there is no API to
-- force a mid-session flush, so the copyable /dct gaps export string is the crash-proof channel.)
local function recordGap(kind, id, name, meta)
    if not id then return end
    local gaps = DropChanceTooltipDB and DropChanceTooltipDB.gaps
    if not (gaps and gaps[kind]) then return end
    local rec = gaps[kind][id]
    if type(rec) ~= "table" then rec = {} end   -- upgrade legacy `true` entries in place
    gaps[kind][id] = rec
    rec.count = (rec.count or 0) + 1
    if name and name ~= "" and name ~= "?" then rec.name = name end
    if meta then
        if meta.zone and meta.zone ~= "" then rec.zone = meta.zone end
        if meta.level and meta.level > 0 then rec.level = meta.level end
    end
    local stamp = date and date("%Y-%m-%d") or nil
    rec.first = rec.first or stamp
    rec.last = stamp or rec.last
    DropChanceTooltipDB.gapsDirty = true       -- un-exported since last /dct gaps export
end

-- True if a quest-item drop matches an objective of a quest the player is currently on. Objective
-- text looks like "Darksoul Shackle: 0/5", so we test whether it contains the item's name.
local function isQuestDropRelevant(drop)
    if questObjectivesDirty then refreshActiveQuestObjectives() end
    local name = drop.name
    if not name or name == "" then return false end
    name = name:lower()
    for objText in pairs(activeQuestObjectives) do
        if objText:find(name, 1, true) then return true end
    end
    return false
end

-- Source->items reverse index for MOB tooltips. LootDBLua is item->sources only, so we observe
-- its global LootDB_AddChunk (called as each chunk lazily loads / preloads) and derive
-- npcSourceID -> { [itemID] = chance }. Only sourceType 0 (creatures/NPCs) is indexed. This never
-- modifies LootDBLua. Assumes LootDBLua's type-0 sourceID == the game's npcID (verify in-game).
local mobDropIndex = {}
local mobIndexHooked = false

local function indexChunk(quality, chunk, data)
    if type(data) ~= "table" then return end
    for itemID, triplets in pairs(data) do
        if type(triplets) == "table" then
            for i = 1, #triplets - 2, 3 do
                local sType, sID, chance = triplets[i], triplets[i + 1], triplets[i + 2]
                if sType == 0 and sID and chance then
                    local bucket = mobDropIndex[sID]
                    if not bucket then
                        bucket = {}
                        mobDropIndex[sID] = bucket
                    end
                    if not bucket[itemID] or chance > bucket[itemID] then
                        bucket[itemID] = chance
                    end
                end
            end
        end
    end
end

local function installMobDropIndex()
    if mobIndexHooked or type(LootDB_AddChunk) ~= "function" then
        return
    end
    mobIndexHooked = true
    hooksecurefunc("LootDB_AddChunk", indexChunk)

    -- Merge our harvested Questie quest-drop data (fills quest-only drops LootDBLua omits, e.g.
    -- Darksoul Shackle 3157 <- Moonrage Darksoul 1782). Percent -> chance (ten-thousandths). Only
    -- seed where LootDBLua has nothing yet; LootDBLua's own data (loaded via the hook) then wins
    -- for anything it covers.
    if type(DropChanceTooltip_QuestieDrops) == "table" then
        for itemID, npcs in pairs(DropChanceTooltip_QuestieDrops) do
            for npcID, pct in pairs(npcs) do
                local bucket = mobDropIndex[npcID]
                if not bucket then
                    bucket = {}
                    mobDropIndex[npcID] = bucket
                end
                if bucket[itemID] == nil then
                    bucket[itemID] = pct * 100
                end
            end
        end
    end

    -- Ensure the whole DB loads so the index fills (also auto-starts on PLAYER_ENTERING_WORLD).
    if LootDBLua and LootDBLua.StartPreload then
        LootDBLua.StartPreload()
    end
end

local DropChanceTooltip = CreateFrame("Frame")
-- Register defensively: RegisterEvent throws on an event name this (Forever) client doesn't know,
-- and an unguarded throw here would abort the entire addon load (no slash commands, no tooltips).
-- pcall so a missing event just quietly disables its own feature.
local function dctRegisterEvent(event)
    pcall(DropChanceTooltip.RegisterEvent, DropChanceTooltip, event)
end
dctRegisterEvent("ADDON_LOADED")
dctRegisterEvent("MODIFIER_STATE_CHANGED")
dctRegisterEvent("QUEST_LOG_UPDATE")
dctRegisterEvent("PLAYER_CAMPING")           -- logout timer started
dctRegisterEvent("PLAYER_QUITING")           -- quit timer started
dctRegisterEvent("ZONE_CHANGED_NEW_AREA")    -- throttled reminder while roaming
dctRegisterEvent("PLAYER_ENTERING_WORLD")    -- initial inventory snapshot
dctRegisterEvent("PLAYER_LOGOUT")            -- reliable final snapshot before SavedVariables flush
dctRegisterEvent("BAG_UPDATE_DELAYED")       -- bags changed -> re-snapshot carried
dctRegisterEvent("BANKFRAME_OPENED")         -- bank readable -> snapshot bank
dctRegisterEvent("BANKFRAME_CLOSED")
dctRegisterEvent("PLAYERBANKSLOTS_CHANGED")  -- bank contents changed while open
dctRegisterEvent("PLAYERBANKBAGSLOTS_CHANGED")

local debugEnabled = false
local modernHooksInstalled = false
local settingsCategoryID
local settingsCategory

local defaultSettings = {
    enabled = true, -- master on/off for the tooltip additions (toggle via /dct or the keybind)
    enableItemRarityFilter = true,
    enableMobRarityFilter = true,
    -- How many drop sources to list per item, scaled by the ITEM's rarity: the rarer the item,
    -- the more sources are worth knowing (few mobs drop a blue; everything drops grey junk, so a
    -- grey shows the fewest). Unshifted shows this many; Shift expands up to sourceExpandedCap.
    sourceCountByRarity = {
        [0] = 3,  -- Poor (grey)
        [1] = 4,  -- Common (white)
        [2] = 6,  -- Uncommon (green)
        [3] = 10, -- Rare (blue)
        [4] = 15, -- Epic
        [5] = 20, -- Legendary
        [6] = 20, -- Artifact
        [7] = 20, -- Heirloom
    },
    sourceCountDefault = 5,   -- used when the item's quality is unknown
    sourceExpandedCap = 30,   -- max rows shown while Shift is held
    -- Mob tooltip: how many regular (non-quest) drops to list. Quest items are always shown in
    -- full in their own section above these. Rare/epic are ordered first, so the cap keeps them.
    mobDropCount = 10,        -- unshifted
    mobDropExpandedCap = 25,  -- Shift held
    -- Mob tooltip: hide drops below this % by default (blue/epic and quest items are always shown
    -- regardless; Shift ignores the floor and reveals everything).
    minDropChancePercent = 1.0,
    -- Quest items: by default only show them on a mob when they match an objective of a quest you're
    -- currently on. Override to always show them regardless.
    alwaysShowQuestItems = false,
    -- Quest items below this % are phantom noise (there is never a real quest drop under ~1%), so we
    -- drop them from the Quest Items section regardless of the on-quest filter. Shift reveals them.
    minQuestChancePercent = 1.0,
    -- Per-group display for the collapsible "various X" categories: "collapse" | "expand" | "hidden".
    variousMode = {
        gems = "collapse", patterns = "collapse", schematics = "collapse",
        enchants = "collapse", recipes = "collapse", scrolls = "collapse", greens = "collapse",
    },
    expandAllVarious = false,  -- persistent "always expand every various group"
    -- Item tooltip: show how many of the item you (and your other characters) own. Self counts are
    -- live (GetItemCount); alt counts come from per-character bag/bank snapshots in SavedVariables.
    -- Four independent toggles; Shift breaks the alt total down per character.
    showSelfBags = true,
    showSelfBank = true,
    showAltsBags = true,
    showAltsBank = true,
    -- Collapsed line shows just the grand total ("You have  54"); consolidated appends the split
    -- ("You have  54 (34 bags, 20 bank)"). Shift always expands to the full per-character breakdown.
    countConsolidated = false,
    -- Only meaningful with countConsolidated: fold ALL characters into the collapsed total additively
    -- (label becomes "Total"). Ignored/locked when countConsolidated is off.
    countIncludeAlts = false,
    -- Materials (cloth/leather/herb/ore) show an aggregated source summary instead of a per-NPC list.
    enableMaterialAggregation = true,
    -- A mob must drop a material at least this % of kills to count toward its level range/bands (below
    -- = incidental side-drop, ignored). Tune live with /dct matmin. Leather has no drop data -> always counts.
    materialMinPercent = 15,
    -- Only generic trash defines a material's range: keep mobs whose level is a RANGE (minLevel<maxLevel);
    -- drop named/unique mobs (a fixed single level) and elites/rares (rank>0). Best for limited items
    -- like textiles. Toggle with /dct mattrash.
    materialTrashOnly = true,
    -- Profession skill-requirement display (gather nodes, skinnable beasts/corpses). Independent per
    -- profession: `enabled` off hides it entirely; on shows it when you own the profession;
    -- `showWithoutProfession` also shows it when you don't (the "override"). Defaults have the override
    -- ON so the info is visible while testing even without the profession -- flip to false to ship the
    -- own-it-to-see-it gating. Structured as one row per profession for the future settings menu.
    professions = {
        mining    = { enabled = true, showWithoutProfession = true },
        herbalism = { enabled = true, showWithoutProfession = true },
        skinning  = { enabled = true, showWithoutProfession = true },
    },
    -- Options window: use the bundled Expressway font (EllesmereUI look) vs the default game font.
    useExpresswayFont = true,
    showItemByRarity = {
        [0] = true, -- Poor
        [1] = true, -- Common
        [2] = true, -- Uncommon
        [3] = true, -- Rare
        [4] = true, -- Epic
        [5] = true, -- Legendary
        [6] = true, -- Artifact
        [7] = true, -- Heirloom
    },
    showMobByRarity = {
        [0] = true, -- Poor
        [1] = true, -- Common
        [2] = true, -- Uncommon
        [3] = true, -- Rare
        [4] = true, -- Epic
        [5] = true, -- Legendary
        [6] = true, -- Artifact
        [7] = true, -- Heirloom
    },
}

-- Rarity rows shown in the options panel (Poor..Epic). Legendary/Artifact/Heirloom omitted for now.
local rarityOrder = { 0, 1, 2, 3, 4 }

local rarityLabels = {
    [0] = ITEM_QUALITY0_DESC or "Poor",
    [1] = ITEM_QUALITY1_DESC or "Common",
    [2] = ITEM_QUALITY2_DESC or "Uncommon",
    [3] = ITEM_QUALITY3_DESC or "Rare",
    [4] = ITEM_QUALITY4_DESC or "Epic",
    [5] = ITEM_QUALITY5_DESC or "Legendary",
    [6] = ITEM_QUALITY6_DESC or "Artifact",
    [7] = ITEM_QUALITY7_DESC or "Heirloom",
}


local function ensureSettings()
    if type(DropChanceTooltipDB) ~= "table" then
        DropChanceTooltipDB = {}
    end

    -- Master on/off defaults to ON when unset. Only an explicit toggle-off turns it false.
    if DropChanceTooltipDB.enabled == nil then
        DropChanceTooltipDB.enabled = defaultSettings.enabled
    end

    -- "Various X" group display modes (per category), default collapse.
    if type(DropChanceTooltipDB.variousMode) ~= "table" then
        DropChanceTooltipDB.variousMode = {}
    end
    for key in pairs(defaultSettings.variousMode) do
        if DropChanceTooltipDB.variousMode[key] == nil then
            DropChanceTooltipDB.variousMode[key] = defaultSettings.variousMode[key]
        end
    end
    if DropChanceTooltipDB.expandAllVarious == nil then
        DropChanceTooltipDB.expandAllVarious = defaultSettings.expandAllVarious
    end
    if DropChanceTooltipDB.minDropChancePercent == nil then
        DropChanceTooltipDB.minDropChancePercent = defaultSettings.minDropChancePercent
    end
    if DropChanceTooltipDB.alwaysShowQuestItems == nil then
        DropChanceTooltipDB.alwaysShowQuestItems = defaultSettings.alwaysShowQuestItems
    end
    if DropChanceTooltipDB.minQuestChancePercent == nil then
        DropChanceTooltipDB.minQuestChancePercent = defaultSettings.minQuestChancePercent
    end
    if DropChanceTooltipDB.enableMaterialAggregation == nil then
        DropChanceTooltipDB.enableMaterialAggregation = defaultSettings.enableMaterialAggregation
    end
    if DropChanceTooltipDB.materialMinPercent == nil then
        DropChanceTooltipDB.materialMinPercent = defaultSettings.materialMinPercent
    end
    if DropChanceTooltipDB.materialTrashOnly == nil then
        DropChanceTooltipDB.materialTrashOnly = defaultSettings.materialTrashOnly
    end
    if type(DropChanceTooltipDB.professions) ~= "table" then
        DropChanceTooltipDB.professions = {}
    end
    for profKey, profDefault in pairs(defaultSettings.professions) do
        local p = DropChanceTooltipDB.professions[profKey]
        if type(p) ~= "table" then
            p = {}
            DropChanceTooltipDB.professions[profKey] = p
        end
        if p.enabled == nil then p.enabled = profDefault.enabled end
        if p.showWithoutProfession == nil then p.showWithoutProfession = profDefault.showWithoutProfession end
    end
    if DropChanceTooltipDB.useExpresswayFont == nil then
        DropChanceTooltipDB.useExpresswayFont = defaultSettings.useExpresswayFont
    end
    for _, key in ipairs({ "showSelfBags", "showSelfBank", "showAltsBags", "showAltsBank", "countConsolidated", "countIncludeAlts" }) do
        if DropChanceTooltipDB[key] == nil then
            DropChanceTooltipDB[key] = defaultSettings[key]
        end
    end
    if type(DropChanceTooltipDB.inventory) ~= "table" then
        DropChanceTooltipDB.inventory = {}  -- [guid] = {name,realm,class,faction,bags={},bank={},updated}
    end
    -- The old name-realm keying collided same-first-name characters; wipe once and re-capture by GUID.
    if DropChanceTooltipDB.inventoryKeyScheme ~= "guid" then
        DropChanceTooltipDB.inventory = {}
        DropChanceTooltipDB.inventoryKeyScheme = "guid"
    end
    -- Evidence log of Forever-specific gaps found through play: items/npcs we tried to show but
    -- had NO data for in any source. Exported via /dct gaps to seed the targeted Wowhead scrape.
    if type(DropChanceTooltipDB.gaps) ~= "table" then
        DropChanceTooltipDB.gaps = { items = {}, npcs = {} }
    end
    DropChanceTooltipDB.gaps.items = DropChanceTooltipDB.gaps.items or {}
    DropChanceTooltipDB.gaps.npcs = DropChanceTooltipDB.gaps.npcs or {}

    if type(DropChanceTooltipDB.showItemByRarity) ~= "table" then
        DropChanceTooltipDB.showItemByRarity = {}
    end

    if type(DropChanceTooltipDB.showMobByRarity) ~= "table" then
        DropChanceTooltipDB.showMobByRarity = {}
    end

    if DropChanceTooltipDB.enableItemRarityFilter == nil then
        DropChanceTooltipDB.enableItemRarityFilter = defaultSettings.enableItemRarityFilter
    end

    if DropChanceTooltipDB.enableMobRarityFilter == nil then
        DropChanceTooltipDB.enableMobRarityFilter = defaultSettings.enableMobRarityFilter
    end

    if type(DropChanceTooltipDB.showByRarity) == "table" then
        for i = 1, #rarityOrder do
            local rarity = rarityOrder[i]
            if DropChanceTooltipDB.showItemByRarity[rarity] == nil and DropChanceTooltipDB.showByRarity[rarity] ~= nil then
                DropChanceTooltipDB.showItemByRarity[rarity] = DropChanceTooltipDB.showByRarity[rarity]
            end
            if DropChanceTooltipDB.showMobByRarity[rarity] == nil and DropChanceTooltipDB.showByRarity[rarity] ~= nil then
                DropChanceTooltipDB.showMobByRarity[rarity] = DropChanceTooltipDB.showByRarity[rarity]
            end
        end
        DropChanceTooltipDB.showByRarity = nil
    end

    if type(DropChanceTooltipDB.disableByRarity) == "table" then
        for i = 1, #rarityOrder do
            local rarity = rarityOrder[i]
            if DropChanceTooltipDB.showItemByRarity[rarity] == nil and DropChanceTooltipDB.disableByRarity[rarity] ~= nil then
                DropChanceTooltipDB.showItemByRarity[rarity] = not DropChanceTooltipDB.disableByRarity[rarity]
            end
            if DropChanceTooltipDB.showMobByRarity[rarity] == nil and DropChanceTooltipDB.disableByRarity[rarity] ~= nil then
                DropChanceTooltipDB.showMobByRarity[rarity] = not DropChanceTooltipDB.disableByRarity[rarity]
            end
        end
        DropChanceTooltipDB.disableByRarity = nil
    end

    for i = 1, #rarityOrder do
        local rarity = rarityOrder[i]
        if DropChanceTooltipDB.showItemByRarity[rarity] == nil then
            DropChanceTooltipDB.showItemByRarity[rarity] = defaultSettings.showItemByRarity[rarity]
        end
        if DropChanceTooltipDB.showMobByRarity[rarity] == nil then
            DropChanceTooltipDB.showMobByRarity[rarity] = defaultSettings.showMobByRarity[rarity]
        end
    end
end

local function isItemRarityHidden(quality)
    ensureSettings()
    if DropChanceTooltipDB.enableItemRarityFilter == false then
        return false
    end
    return quality ~= nil and DropChanceTooltipDB.showItemByRarity[quality] == false
end

local function isMobRarityShown(quality)
    ensureSettings()
    if DropChanceTooltipDB.enableMobRarityFilter == false then
        return true
    end
    if quality == nil then
        return true
    end
    return DropChanceTooltipDB.showMobByRarity[quality] == true
end

local function debugPrint(message)
    if not debugEnabled then
        return
    end

    local line = string.format("|cff66ccffDCT|r %s", tostring(message or ""))
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(line)
    elseif print then
        print(line)
    end
end

local function setCheckButtonLabel(checkButton, text)
    if not checkButton then
        return
    end

    if checkButton.Text and checkButton.Text.SetText then
        checkButton.Text:SetText(text)
        return
    end

    if checkButton.text and checkButton.text.SetText then
        checkButton.text:SetText(text)
        return
    end

    if not checkButton.Label then
        checkButton.Label = checkButton:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        checkButton.Label:SetPoint("LEFT", checkButton, "RIGHT", 2, 1)
    end
    checkButton.Label:SetText(text)
end

local function packArgs(...)
    return {
        n = select("#", ...),
        ...
    }
end

local function unpackArgs(t)
    if not t then
        return
    end
    return unpack(t, 1, t.n or #t)
end

local getItemQualityByID

local function getItemIDFromLink(link)
    if not link then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function formatChance(chance)
    local percent = (chance or 0) / 100
    if percent >= 1 then
        return string.format("%.2f%%", percent)
    end
    return string.format("%.3f%%", percent)
end

local sourceTypeLabels = {
    ["npc"] = "NPC",
    ["object"] = "Object",
    ["item"] = "Item",
    ["quest"] = "Quest",
    ["zone"] = "Zone",
    ["vendor"] = "Vendor",
    ["fishing"] = "Fishing",
    ["pickpocket"] = "Pickpocket",
    ["disenchant"] = "Disenchant",
    [1] = "NPC",
    [2] = "Object",
    [3] = "Item",
    [4] = "Quest",
    [5] = "Zone",
    [6] = "Vendor",
}

local numericSourceTypeMap = {
    [1] = "npc",
    [2] = "object",
    [3] = "item",
    [4] = "quest",
    [5] = "zone",
    [6] = "vendor",
}

local resolvedSourceNames = {}

local function safeCall(func, ...)
    if type(func) ~= "function" then
        return nil
    end

    local ok, value = pcall(func, ...)
    if not ok then
        return nil
    end

    return value
end

local function getCachedSourceName(sourceType, sourceID)
    if not sourceType or not sourceID then
        return nil
    end

    local cacheKey = string.format("%s:%d", tostring(sourceType), sourceID)
    if resolvedSourceNames[cacheKey] ~= nil then
        return resolvedSourceNames[cacheKey]
    end

    local resolvedName
    local normalizedType = sourceType
    if type(normalizedType) == "number" then
        normalizedType = numericSourceTypeMap[normalizedType]
    end
    normalizedType = tostring(normalizedType):lower()

    if type(LootDBLua) == "table" and type(LootDBLua.GetSourceName) == "function" then
        resolvedName = safeCall(LootDBLua.GetSourceName, sourceID, normalizedType)
        if (not resolvedName or resolvedName == "") and sourceType ~= normalizedType then
            resolvedName = safeCall(LootDBLua.GetSourceName, sourceID, sourceType)
        end
        if not resolvedName or resolvedName == "" then
            resolvedName = safeCall(LootDBLua.GetSourceName, sourceID)
        end
    end

    if not resolvedName and (normalizedType == "npc" or normalizedType == "vendor" or normalizedType == "pickpocket") then
        if C_CreatureInfo and C_CreatureInfo.GetCreatureName then
            resolvedName = safeCall(C_CreatureInfo.GetCreatureName, sourceID)
        end
    elseif not resolvedName and normalizedType == "item" then
        resolvedName = safeCall(GetItemInfo, sourceID)
    elseif not resolvedName and normalizedType == "quest" then
        if C_QuestLog and C_QuestLog.GetTitleForQuestID then
            resolvedName = safeCall(C_QuestLog.GetTitleForQuestID, sourceID)
        end
    elseif not resolvedName and normalizedType == "zone" then
        if C_Map and C_Map.GetMapInfo then
            local mapInfo = safeCall(C_Map.GetMapInfo, sourceID)
            if type(mapInfo) == "table" then
                resolvedName = mapInfo.name
            end
        end
    end

    if type(resolvedName) == "string" and resolvedName ~= "" then
        resolvedSourceNames[cacheKey] = resolvedName
        return resolvedName
    end

    resolvedSourceNames[cacheKey] = false
    return nil
end

local function getSourceName(source)
    if not source then
        return nil
    end

    if source.sourceName and source.sourceName ~= "" then
        return tostring(source.sourceName)
    end

    if source.name and source.name ~= "" then
        return tostring(source.name)
    end

    if source.sourceID then
        local resolvedName = getCachedSourceName(source.sourceType, source.sourceID)
        if resolvedName then
            return resolvedName
        end
    end

    return nil
end

local function getSourceLabel(source)
    if not source then
        return "Unknown"
    end

    local sourceName = getSourceName(source)
    if sourceName then
        return sourceName
    end

    if source.sourceID then
        return tostring(source.sourceID)
    end

    return sourceTypeLabels[source.sourceType] or tostring(source.sourceType or "Unknown")
end


local function stripNumericSuffix(label)
    if type(label) ~= "string" then
        return label
    end

    local stripped = label:match("^(.-)%s*%(%d+%)$")
    return stripped or label
end

local difficultyIDLabels = {
    [3] = "10m",
    [4] = "25m",
    [5] = "10m H",
    [6] = "25m H",
    [9] = "40m",
    [14] = "N",
    [15] = "H",
    [16] = "M",
    [17] = "LFR",
}

local function getDifficultyTag(source)
    if type(source) ~= "table" then
        return nil
    end

    local explicitSize = tonumber(source.raidSize or source.instanceSize or source.size or source.playerCount)
    local difficultyID = tonumber(source.difficultyID or source.difficultyId or source.mapDifficultyID)

    if explicitSize and explicitSize > 0 then
        local sizeLabel = string.format("%dm", explicitSize)
        if source.heroic == true or source.isHeroic == true then
            return string.format("%s H", sizeLabel)
        end
        return sizeLabel
    end

    if difficultyID and difficultyIDLabels[difficultyID] then
        return difficultyIDLabels[difficultyID]
    end

    local rawDifficulty = source.difficultyName or source.difficulty
    if type(rawDifficulty) == "string" then
        local lowered = rawDifficulty:lower()
        local size = lowered:match("(%d+)%s*man") or lowered:match("(%d+)m")
        if size then
            if lowered:find("heroic", 1, true) then
                return string.format("%sm H", size)
            end
            return string.format("%sm", size)
        end
        if lowered:find("heroic", 1, true) then
            return "H"
        end
    elseif type(rawDifficulty) == "number" and difficultyIDLabels[rawDifficulty] then
        return difficultyIDLabels[rawDifficulty]
    end

    if source.heroic == true or source.isHeroic == true then
        return "H"
    end

    return nil
end

local function assignDisplaySourceLabels(sources)
    local counts = {}
    local indicesByBaseLabel = {}
    local displayLabelCounts = {}

    for i = 1, #sources do
        local source = sources[i]
        local baseLabel = stripNumericSuffix(getSourceLabel(source))
        source._baseLabel = baseLabel
        counts[baseLabel] = (counts[baseLabel] or 0) + 1
    end

    for i = 1, #sources do
        local source = sources[i]
        local baseLabel = source._baseLabel
        source._baseLabel = nil

        if counts[baseLabel] and counts[baseLabel] > 1 then
            local currentIndex = (indicesByBaseLabel[baseLabel] or 0) + 1
            indicesByBaseLabel[baseLabel] = currentIndex
            local difficultyTag = getDifficultyTag(source)
            if difficultyTag then
                source.displayLabel = string.format("%s (%s)", baseLabel, difficultyTag)
            else
                source.displayLabel = string.format("%s (%d)", baseLabel, currentIndex)
            end

            displayLabelCounts[source.displayLabel] = (displayLabelCounts[source.displayLabel] or 0) + 1
            if displayLabelCounts[source.displayLabel] > 1 then
                source.displayLabel = string.format("%s (%d)", source.displayLabel, currentIndex)
            end
        else
            source.displayLabel = baseLabel
        end
    end
end
local function getLootDBProvider()
    if type(LootDBLua) == "table" then
        return LootDBLua
    end

    return nil
end

local function normalizeSource(raw)
    local chance = tonumber(raw.chance or raw.dropChance or raw.percent or raw[3])
    local sourceType = raw.sourceType or raw.type or raw[1]
    local sourceID = tonumber(raw.sourceID or raw.id or raw[2])
    local sourceName = raw.sourceName or raw.name or raw.label or raw[4]

    if not chance then
        return nil
    end

    return {
        chance = chance,
        chancePercent = tonumber(raw.chancePercent),
        sourceType = sourceType,
        sourceID = sourceID,
        sourceName = sourceName,
        name = sourceName,
        difficulty = raw.difficulty,
        difficultyName = raw.difficultyName,
        difficultyID = raw.difficultyID or raw.difficultyId,
        mapDifficultyID = raw.mapDifficultyID,
        raidSize = raw.raidSize or raw.raid_size,
        instanceSize = raw.instanceSize,
        size = raw.size,
        playerCount = raw.playerCount,
        heroic = raw.heroic,
        isHeroic = raw.isHeroic,
    }
end

local function normalizeSources(rawSources)
    if type(rawSources) ~= "table" then
        return nil
    end

    local sources = {}
    for key, value in pairs(rawSources) do
        local raw = value
        if type(value) ~= "table" and type(key) == "table" then
            raw = key
        end

        if type(raw) == "table" then
            local source = normalizeSource(raw)
            if source then
                table.insert(sources, source)
            end
        end
    end

    if #sources == 0 then
        return nil
    end

    table.sort(sources, function(a, b)
        return (a.chance or 0) > (b.chance or 0)
    end)

    assignDisplaySourceLabels(sources)

    return sources
end


local function formatDebugArgs(args)
    if type(args) ~= "table" then
        return ""
    end

    local formatted = {}
    for i = 1, #args do
        formatted[i] = tostring(args[i])
    end

    return table.concat(formatted, ", ")
end

local function callSourceGetter(provider, itemID)
    if provider.GetSourcesForItem then
        local quality = provider.GetItemQuality and provider.GetItemQuality(itemID) or nil
        debugPrint(string.format("Item lookup: trying GetSourcesForItem(%d, %s)", itemID, tostring(quality)))
        local result = provider.GetSourcesForItem(itemID, quality)
        if result then
            debugPrint("Item lookup: GetSourcesForItem returned data")
            return result
        end
    end

    if provider.GetItemSources then
        debugPrint(string.format("Item lookup: trying GetItemSources(%d)", itemID))
        local result = provider.GetItemSources(itemID)
        if result then
            debugPrint("Item lookup: GetItemSources returned data")
            return result
        end
    end

    if provider.GetDropsForItem then
        debugPrint(string.format("Item lookup: trying GetDropsForItem(%d)", itemID))
        local result = provider.GetDropsForItem(itemID)
        if result then
            debugPrint("Item lookup: GetDropsForItem returned data")
            return result
        end
    end

    debugPrint(string.format("Item lookup: no source table found for itemID %d", itemID))
    return nil
end

local function callMobDropGetter(provider, npcID)
    local candidates = {
        { name = "GetDropsForSource", args = { npcID, "npc" } },
        { name = "GetDropsForSource", args = { "npc", npcID } },
        { name = "GetDropsForSource", args = { npcID, 1 } },
        { name = "GetDropsForSource", args = { 1, npcID } },
        { name = "GetSourceDrops", args = { "npc", npcID } },
        { name = "GetSourceDrops", args = { npcID, "npc" } },
        { name = "GetSourceDrops", args = { 1, npcID } },
        { name = "GetLootForSource", args = { "npc", npcID } },
        { name = "GetLootForSource", args = { npcID, "npc" } },
        { name = "GetLootForSource", args = { 1, npcID } },
        { name = "GetDropsForNPC", args = { npcID } },
        { name = "GetNPCDrops", args = { npcID } },
        { name = "GetDropsBySource", args = { "npc", npcID } },
        { name = "GetDropsBySource", args = { npcID, "npc" } },
        { name = "GetDropsBySource", args = { 1, npcID } },
    }

    for i = 1, #candidates do
        local candidate = candidates[i]
        local method = provider[candidate.name]
        if type(method) == "function" then
            debugPrint(string.format("Mob lookup: trying %s(%s)", candidate.name, formatDebugArgs(candidate.args)))
            local result = method(unpack(candidate.args))
            if result then
                debugPrint(string.format("Mob lookup: %s returned data for npcID %d", candidate.name, npcID))
                return result
            end
        end
    end

    debugPrint(string.format("Mob lookup: no drop table found for npcID %d", npcID))
    return nil
end

local function callObjectDropGetter(provider, objectID)
    local candidates = {
        { name = "GetDropsForSource", args = { objectID, "object" } },
        { name = "GetDropsForSource", args = { "object", objectID } },
        { name = "GetDropsForSource", args = { objectID, 2 } },
        { name = "GetDropsForSource", args = { 2, objectID } },
        { name = "GetSourceDrops", args = { "object", objectID } },
        { name = "GetSourceDrops", args = { objectID, "object" } },
        { name = "GetSourceDrops", args = { 2, objectID } },
        { name = "GetLootForSource", args = { "object", objectID } },
        { name = "GetLootForSource", args = { objectID, "object" } },
        { name = "GetLootForSource", args = { 2, objectID } },
        { name = "GetDropsForObject", args = { objectID } },
        { name = "GetObjectDrops", args = { objectID } },
        { name = "GetDropsBySource", args = { "object", objectID } },
        { name = "GetDropsBySource", args = { objectID, "object" } },
        { name = "GetDropsBySource", args = { 2, objectID } },
    }

    for i = 1, #candidates do
        local candidate = candidates[i]
        local method = provider[candidate.name]
        if type(method) == "function" then
            local result = method(unpack(candidate.args))
            if result then
                return result
            end
        end
    end

    return nil
end

local function getSources(itemID)
    local provider = getLootDBProvider()
    if not provider then
        debugPrint("No LootDB provider found")
        return nil
    end

    local rawSources = callSourceGetter(provider, itemID)
    if not rawSources then
        debugPrint(string.format("No sources found for itemID %d", itemID))
        return nil
    end

    return normalizeSources(rawSources)
end

local function normalizeMobDrop(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local itemID = tonumber(raw.itemID or raw.id or raw[1])
    local chance = tonumber(raw.chance or raw.dropChance or raw.percent or raw[2])

    if not itemID then
        return nil
    end

    local quality = tonumber(raw.quality or raw.rarity)
    if quality == nil then
        quality = getItemQualityByID(itemID)
    end

    local name, link
    if raw.link then
        link = raw.link
        name = GetItemInfo(link)
    else
        name, link = GetItemInfo(itemID)
    end

    -- Fallback for items not in the local cache (GetItemInfo returns nil), e.g. quest-only drops
    -- harvested from Questie. Also warm the cache so a later hover gets the real (colored) link.
    name = raw.name or name
    if not name and DropChanceTooltip_QuestieItemNames then
        name = DropChanceTooltip_QuestieItemNames[itemID]
    end
    if not link and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end

    return {
        itemID = itemID,
        chance = chance,
        quality = quality,
        name = name,
        link = link,
    }
end

local function normalizeMobDropFromPair(key, value)
    local itemID = tonumber(key)
    if not itemID then
        return nil
    end

    local chance = tonumber(value)
    if type(value) == "table" then
        chance = tonumber(value.chance or value.dropChance or value.percent or value[1])
    end

    return normalizeMobDrop({
        itemID = itemID,
        chance = chance,
    })
end

local function normalizeMobDrops(rawDrops)
    if type(rawDrops) ~= "table" then
        return nil
    end

    local drops = {}
    for key, value in pairs(rawDrops) do
        local raw
        if type(value) ~= "table" and type(key) == "table" then
            raw = key
        elseif type(value) == "table" then
            raw = value
        else
            raw = normalizeMobDropFromPair(key, value)
        end

        local drop = raw
        if type(raw) == "table" and raw.itemID == nil then
            drop = normalizeMobDrop(raw)
        end

        if drop and isMobRarityShown(drop.quality) then
            table.insert(drops, drop)
        end
    end

    if #drops == 0 then
        return nil
    end

    table.sort(drops, function(a, b)
        local aChance = tonumber(a.chance) or -1
        local bChance = tonumber(b.chance) or -1
        if aChance == bChance then
            return (a.itemID or 0) < (b.itemID or 0)
        end
        return aChance > bChance
    end)

    return drops
end

local function getMobDrops(npcID)
    -- Primary: our source->items reverse index (built from LootDBLua chunk data). The index is a
    -- map { [itemID] = chance }, which normalizeMobDrops accepts directly (key=itemID, value=chance).
    local indexed = mobDropIndex[npcID]
    if indexed and next(indexed) then
        local drops = normalizeMobDrops(indexed)
        debugPrint(string.format("Mob lookup: index gave %d drops for npcID %d", drops and #drops or 0, npcID))
        if drops then return drops end
    end

    -- Fallback: if a future LootDBLua ever exposes a source->items method, use it.
    local provider = getLootDBProvider()
    if provider then
        local rawDrops = callMobDropGetter(provider, npcID)
        if rawDrops then
            return normalizeMobDrops(rawDrops)
        end
    end

    debugPrint(string.format("Mob lookup: no drops for npcID %d (index size=%d)", npcID, mobDropIndex[npcID] and 1 or 0))
    return nil
end

local function getObjectDrops(objectID)
    local provider = getLootDBProvider()
    if not provider then
        return nil
    end

    local rawDrops = callObjectDropGetter(provider, objectID)
    if not rawDrops then
        return nil
    end

    return normalizeMobDrops(rawDrops)
end

local function normalizeSourceIDLookupResult(result)
    if type(result) == "number" then
        return tonumber(result)
    end

    if type(result) == "string" then
        return tonumber(result)
    end

    if type(result) ~= "table" then
        return nil
    end

    if result.id ~= nil then
        return tonumber(result.id)
    end

    if result.sourceID ~= nil then
        return tonumber(result.sourceID)
    end

    if result.npcID ~= nil then
        return tonumber(result.npcID)
    end

    if result.objectID ~= nil then
        return tonumber(result.objectID)
    end

    for _, value in pairs(result) do
        local asNumber = tonumber(value)
        if asNumber then
            return asNumber
        end
    end

    return nil
end

local function getSourceIDByName(sourceType, sourceName)
    if not sourceName or sourceName == "" then
        return nil
    end

    local provider = getLootDBProvider()
    if not provider then
        return nil
    end

    local numericType = sourceType == "object" and 2 or 1
    local candidates = {
        { name = "GetSourceIDByName", args = { sourceType, sourceName } },
        { name = "GetSourceIDByName", args = { sourceName, sourceType } },
        { name = "GetSourceIDByName", args = { numericType, sourceName } },
        { name = "GetSourceIDByName", args = { sourceName, numericType } },
        { name = "GetSourceIdByName", args = { sourceType, sourceName } },
        { name = "GetSourceIdByName", args = { sourceName, sourceType } },
        { name = "LookupSourceIDByName", args = { sourceType, sourceName } },
        { name = "LookupSourceIDByName", args = { sourceName, sourceType } },
        { name = "LookupSourceByName", args = { sourceType, sourceName } },
        { name = "LookupSourceByName", args = { sourceName, sourceType } },
    }

    if sourceType == "npc" then
        table.insert(candidates, { name = "GetNPCIDByName", args = { sourceName } })
        table.insert(candidates, { name = "GetNpcIDByName", args = { sourceName } })
        table.insert(candidates, { name = "LookupNPCIDByName", args = { sourceName } })
        table.insert(candidates, { name = "LookupNpcIDByName", args = { sourceName } })
        table.insert(candidates, { name = "LookupNPCByName", args = { sourceName } })
    else
        table.insert(candidates, { name = "GetObjectIDByName", args = { sourceName } })
        table.insert(candidates, { name = "GetObjectIdByName", args = { sourceName } })
        table.insert(candidates, { name = "LookupObjectIDByName", args = { sourceName } })
        table.insert(candidates, { name = "LookupObjectByName", args = { sourceName } })
    end

    for i = 1, #candidates do
        local candidate = candidates[i]
        local method = provider[candidate.name]
        if type(method) == "function" then
            debugPrint(string.format("Name lookup: trying %s(%s, %s)", candidate.name, tostring(candidate.args[1]), tostring(candidate.args[2])))
            local result = method(unpack(candidate.args))
            local sourceID = normalizeSourceIDLookupResult(result)
            if sourceID then
                debugPrint(string.format("Name lookup: %s resolved %s '%s' -> %d", candidate.name, sourceType, sourceName, sourceID))
                return sourceID
            end
        end
    end

    debugPrint(string.format("Name lookup: failed to resolve %s '%s'", sourceType, sourceName))
    return nil
end

local function calculateAverageChance(sources)
    if not sources or #sources == 0 then
        return nil
    end

    local total = 0
    for i = 1, #sources do
        total = total + (sources[i].chance or 0)
    end

    return total / #sources
end

local function getItemIDFromTooltip(tooltip)
    -- Modern clients (TooltipDataProcessor): the item id is handed to us via the post-call data
    -- and stashed on the tooltip. GetItem() is deprecated/absent there, so prefer the data id.
    if tooltip and tooltip.__dctData and tooltip.__dctData.id then
        return tonumber(tooltip.__dctData.id)
    end

    if not tooltip or not tooltip.GetItem then
        return nil
    end

    local _, link = tooltip:GetItem()
    if not link then
        return nil
    end

    return getItemIDFromLink(link)
end

getItemQualityByID = function(itemID)
    local provider = getLootDBProvider()
    if provider and provider.GetItemQuality then
        local quality = tonumber(provider.GetItemQuality(itemID))
        if quality then
            return quality
        end
    end

    local _, _, quality = GetItemInfo(itemID)
    return tonumber(quality)
end

local function getItemQualityFromTooltip(tooltip, itemID)
    if tooltip and tooltip.GetItem then
        local _, link = tooltip:GetItem()
        if link then
            local _, _, quality = GetItemInfo(link)
            if quality ~= nil then
                return tonumber(quality)
            end
        end
    end

    if itemID then
        return getItemQualityByID(itemID)
    end

    return nil
end

local function buildSignature(itemID, expanded, quality)
    return table.concat({
        tostring(itemID or 0),
        expanded and "1" or "0",
        tostring(quality or -1),
    }, ":")
end

-- How many sources to show for an item of the given quality. Rarer item => more rows.
-- Shift held => expand up to sourceExpandedCap. Always clamped to the number available.
local function getVisibleSourceCount(quality, expanded, total)
    local byRarity = (DropChanceTooltipDB and DropChanceTooltipDB.sourceCountByRarity)
        or defaultSettings.sourceCountByRarity
    local base = (quality ~= nil and byRarity[quality])
        or (DropChanceTooltipDB and DropChanceTooltipDB.sourceCountDefault)
        or defaultSettings.sourceCountDefault
    if expanded then
        local cap = (DropChanceTooltipDB and DropChanceTooltipDB.sourceExpandedCap)
            or defaultSettings.sourceExpandedCap
        return math.min(total, math.max(base, cap))
    end
    return math.min(total, base)
end

-- ------------------------------------------------------------------------------------------------
-- Item-count across your characters (shown on the item tooltip). Self counts are live via
-- GetItemCount; other characters' counts come from bag/bank snapshots we record into account-wide
-- SavedVariables as you play (and open the bank on) each one.
-- ------------------------------------------------------------------------------------------------
-- Key by GUID: UnitName returns only the FIRST name on this client, so same-first-name characters on
-- one realm ("Jec" the Druid vs "Jec" the Shaman) collide and overwrite each other. GUID is unique.
local function charKey()
    local guid = UnitGUID and UnitGUID("player")
    if guid then return guid end
    local name = UnitName and UnitName("player")   -- fallback if GUID unavailable
    if not name then return nil end
    return name .. "-" .. ((GetRealmName and GetRealmName()) or "")
end

-- Sum stack counts across a list of container ids -> { [itemID] = count }, totalSlots. totalSlots==0
-- means the containers aren't readable right now (bags not loaded / torn down at logout) -- callers
-- MUST NOT overwrite a stored snapshot with an empty result in that case.
local function scanContainers(bagList)
    local counts, totalSlots = {}, 0
    if not GetContainerNumSlots then return counts, 0 end
    for _, bag in ipairs(bagList) do
        local slots = GetContainerNumSlots(bag) or 0
        totalSlots = totalSlots + slots
        for slot = 1, slots do
            local id = GetContainerItemID and GetContainerItemID(bag, slot)
            local stack = 1
            local info = GetContainerItemInfo and GetContainerItemInfo(bag, slot)
            if type(info) == "table" then
                id = id or info.itemID
                stack = info.stackCount or 1
            end
            if id then counts[id] = (counts[id] or 0) + stack end
        end
    end
    return counts, totalSlots
end

local CARRIED_BAGS = { 0 }  -- backpack + carried bags (0..NUM_BAG_SLOTS)
do
    for i = 1, (NUM_BAG_SLOTS or 4) do CARRIED_BAGS[#CARRIED_BAGS + 1] = i end
end

local function bankContainers()
    local list = { BANK_CONTAINER or -1 }
    if REAGENTBANK_CONTAINER then list[#list + 1] = REAGENTBANK_CONTAINER end
    local base = NUM_BAG_SLOTS or 4
    for i = 1, (NUM_BANKBAGSLOTS or 6) do list[#list + 1] = base + i end
    return list
end

local _bankIsOpen = false

local function currentCharSnapshot()
    local key = charKey()
    if not key then return nil end
    ensureSettings()
    local inv = DropChanceTooltipDB.inventory
    local snap = inv[key]
    if type(snap) ~= "table" then
        snap = {}
        inv[key] = snap
    end
    -- This client returns the LAST name in UnitName's 2nd value (normally the realm slot), so the full
    -- character name is "First Last" (e.g. Jec Lock). Join them for the display name. (Must NOT wrap the
    -- call in parens/`and` -- that truncates the 2nd return value.)
    local first, last
    if UnitName then first, last = UnitName("player") end
    if first then
        snap.name = (last and last ~= "") and (first .. " " .. last) or first
    end
    snap.realm = (GetRealmName and GetRealmName()) or snap.realm
    snap.class = (UnitClass and select(2, UnitClass("player"))) or snap.class
    snap.faction = (UnitFactionGroup and UnitFactionGroup("player")) or snap.faction
    snap.updated = (date and date("%Y-%m-%d")) or snap.updated
    return snap
end

local function snapshotBags()
    local counts, slots = scanContainers(CARRIED_BAGS)
    if slots == 0 then return end   -- bags not readable (early login / logout teardown): don't wipe
    local snap = currentCharSnapshot()
    if snap then snap.bags = counts end
end

-- Only scan the bank while it is OPEN -- closed bank containers report 0 slots, which would wipe the
-- stored snapshot to empty.
local function snapshotBank()
    if not _bankIsOpen then return end
    local counts, slots = scanContainers(bankContainers())
    if slots == 0 then return end
    local snap = currentCharSnapshot()
    if snap then snap.bank = counts end
end

local function classColorHex(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c and c.colorStr then return c.colorStr end
    if c then return string.format("ff%02x%02x%02x", (c.r or 1) * 255, (c.g or 1) * 255, (c.b or 1) * 255) end
    return "ffffffff"
end

-- Class-colored character label (full "First Last" name); the current character adds "(You)".
local function charLabel(name, classFile, isYou)
    local colored = string.format("|c%s%s|r", classColorHex(classFile), name or "?")
    if isYou then colored = colored .. " |cff9d9d9d(You)|r" end
    return colored
end

local function addOwnedCountsToTooltip(tooltip)
    if not tooltip then return end
    ensureSettings()
    local db = DropChanceTooltipDB
    if db.enabled == false then return end
    if not (db.showSelfBags or db.showSelfBank or db.showAltsBags or db.showAltsBank) then return end
    local itemID = getItemIDFromTooltip(tooltip)
    if not itemID then return end

    local expanded = IsShiftKeyDown()
    local sig = string.format("cnt:%d:%s:%s%s%s%s:%s%s", itemID, expanded and "1" or "0",
        db.showSelfBags and "1" or "0", db.showSelfBank and "1" or "0",
        db.showAltsBags and "1" or "0", db.showAltsBank and "1" or "0",
        db.countConsolidated and "1" or "0", db.countIncludeAlts and "1" or "0")
    if tooltip.__dctCountSig == sig then return end
    tooltip.__dctCountSig = sig

    -- self (live): GetItemCount(id) = bags only; GetItemCount(id, true) = bags + bank.
    local selfBags = (GetItemCount and GetItemCount(itemID)) or 0
    local selfTotal = (GetItemCount and GetItemCount(itemID, true)) or selfBags
    local selfBank = math.max(selfTotal - selfBags, 0)

    -- other characters (snapshots).
    local curKey = charKey()
    local alts = {}  -- { name, class, bags, bank }
    for key, snap in pairs(db.inventory or {}) do
        if key ~= curKey and type(snap) == "table" then
            local b = (snap.bags and snap.bags[itemID]) or 0
            local k = (snap.bank and snap.bank[itemID]) or 0
            if b > 0 or k > 0 then
                alts[#alts + 1] = { name = snap.name or key, class = snap.class, bags = b, bank = k }
            end
        end
    end
    table.sort(alts, function(a, b) return (a.bags + a.bank) > (b.bags + b.bank) end)

    local altBagsSum, altBankSum = 0, 0
    for _, a in ipairs(alts) do
        altBagsSum, altBankSum = altBagsSum + a.bags, altBankSum + a.bank
    end

    -- Included totals honoring the four toggles. bags = carried, bank = stored.
    local bagsPortion = (db.showSelfBags and selfBags or 0) + (db.showAltsBags and altBagsSum or 0)
    local bankPortion = (db.showSelfBank and selfBank or 0) + (db.showAltsBank and altBankSum or 0)
    local grand = bagsPortion + bankPortion
    if grand <= 0 then return end

    tooltip:AddLine(" ")

    if not expanded then
        -- Hover: consolidated shows YOUR bags/bank as distinct "source of truth" figures; with
        -- include-alts, alts fold in as ONE lumped number and the label becomes "Total":
        --   "You have 12 (10 bags, 2 bank)"  ->  "Total 64 (10 bags, 2 bank, 52 alts)".
        local withAlts = db.countConsolidated and db.countIncludeAlts
        local sBags = db.showSelfBags and selfBags or 0
        local sBank = db.showSelfBank and selfBank or 0
        local altsLump = withAlts and ((db.showAltsBags and altBagsSum or 0) + (db.showAltsBank and altBankSum or 0)) or 0
        local value = tostring(sBags + sBank + altsLump)
        if db.countConsolidated then
            local parts = {}
            if sBags > 0 then parts[#parts + 1] = sBags .. " bags" end
            if sBank > 0 then parts[#parts + 1] = sBank .. " bank" end
            if altsLump > 0 then parts[#parts + 1] = altsLump .. " alts" end
            if #parts > 0 then value = value .. " (" .. table.concat(parts, ", ") .. ")" end
        end
        tooltip:AddDoubleLine(withAlts and "Total" or "You have", value, 1, 0.82, 0, 1, 1, 1)
        return
    end

    -- Shift: grand total up top, then a per-character bags breakdown, then a bank breakdown.
    tooltip:AddDoubleLine("Total", tostring(grand), 1, 0.82, 0, 1, 1, 1)

    local pfirst, plast
    if UnitName then pfirst, plast = UnitName("player") end
    local playerName = pfirst and ((plast and plast ~= "") and (pfirst .. " " .. plast) or pfirst) or "You"
    local playerClass = UnitClass and select(2, UnitClass("player")) or nil
    local youLabel = charLabel(playerName, playerClass, true)

    local bagRows = {}
    if db.showSelfBags and selfBags > 0 then bagRows[#bagRows + 1] = { label = youLabel, value = selfBags } end
    if db.showAltsBags then
        for _, a in ipairs(alts) do
            if a.bags > 0 then bagRows[#bagRows + 1] = { label = charLabel(a.name, a.class), value = a.bags } end
        end
    end
    if #bagRows > 0 then
        tooltip:AddLine("Bags", 1, 0.82, 0)
        for _, r in ipairs(bagRows) do
            tooltip:AddDoubleLine("  " .. r.label, tostring(r.value), 1, 1, 1, 1, 1, 1)
        end
    end

    local bankRows = {}
    if db.showSelfBank and selfBank > 0 then bankRows[#bankRows + 1] = { label = youLabel, value = selfBank } end
    if db.showAltsBank then
        for _, a in ipairs(alts) do
            if a.bank > 0 then bankRows[#bankRows + 1] = { label = charLabel(a.name, a.class), value = a.bank } end
        end
    end
    if #bankRows > 0 then
        if #bagRows > 0 then tooltip:AddLine(" ") end
        tooltip:AddLine("Bank", 1, 0.82, 0)
        for _, r in ipairs(bankRows) do
            tooltip:AddDoubleLine("  " .. r.label, tostring(r.value), 1, 1, 1, 1, 1, 1)
        end
    end
end

-- ------------------------------------------------------------------------------------------------
-- Material aggregation. For gathered/farmed materials, a per-NPC source list is noise ("linen drops
-- from 200 humanoids"). Instead summarize: cloth -> "Humanoids 7-13", leather -> "Skinning . Beasts
-- 21-36", herbs/ore -> "Herbalism 50" + top zones. All data is bundled (GatherNodes/MobLevels/
-- SkinningSources); classic gathering/cloth sources are unchanged on Forever.
-- ------------------------------------------------------------------------------------------------
local CLOTH_ITEMS = {  -- humanoid trash cloth (Felcloth/Mooncloth/etc excluded -- not generic trash)
    [2589] = true,  -- Linen Cloth
    [2592] = true,  -- Wool Cloth
    [4306] = true,  -- Silk Cloth
    [4338] = true,  -- Mageweave Cloth
    [14047] = true, -- Runecloth
}

-- ore ITEM name -> gathering NODE name(s) (item and node names differ: "Copper Ore" <- "Copper Vein").
local ORE_ITEM_TO_NODES = {
    ["Copper Ore"] = { "Copper Vein" },
    ["Tin Ore"] = { "Tin Vein" },
    ["Silver Ore"] = { "Silver Vein", "Ooze Covered Silver Vein" },
    ["Gold Ore"] = { "Gold Vein", "Ooze Covered Gold Vein" },
    ["Iron Ore"] = { "Iron Deposit", "Ooze Covered Iron Deposit" },
    ["Mithril Ore"] = { "Mithril Deposit", "Ooze Covered Mithril Deposit" },
    ["Truesilver Ore"] = { "Truesilver Deposit", "Ooze Covered Truesilver Deposit" },
    ["Thorium Ore"] = { "Small Thorium Vein", "Rich Thorium Vein", "Ooze Covered Thorium Vein" },
    ["Dark Iron Ore"] = { "Dark Iron Deposit" },
}

-- Required gathering skill per node (classic). Missing -> line shows the profession without a number.
local HERB_SKILL = {
    ["Peacebloom"]=1, ["Silverleaf"]=1, ["Earthroot"]=15, ["Mageroyal"]=50, ["Briarthorn"]=70,
    ["Stranglekelp"]=85, ["Bruiseweed"]=100, ["Wild Steelbloom"]=115, ["Grave Moss"]=120,
    ["Kingsblood"]=125, ["Liferoot"]=150, ["Fadeleaf"]=160, ["Goldthorn"]=170,
    ["Khadgar's Whisker"]=185, ["Wintersbite"]=195, ["Firebloom"]=205, ["Purple Lotus"]=210,
    ["Arthas' Tears"]=220, ["Sungrass"]=230, ["Blindweed"]=235, ["Ghost Mushroom"]=245,
    ["Gromsblood"]=250, ["Golden Sansam"]=260, ["Dreamfoil"]=270, ["Mountain Silversage"]=280,
    ["Plaguebloom"]=285, ["Icecap"]=290, ["Black Lotus"]=300,
}
local ORE_SKILL = {
    ["Copper Vein"]=1, ["Tin Vein"]=65, ["Silver Vein"]=75, ["Gold Vein"]=115, ["Iron Deposit"]=125,
    ["Mithril Deposit"]=175, ["Truesilver Deposit"]=230, ["Small Thorium Vein"]=245,
    ["Rich Thorium Vein"]=275, ["Dark Iron Deposit"]=230,
    ["Ooze Covered Silver Vein"]=75, ["Ooze Covered Gold Vein"]=115, ["Ooze Covered Iron Deposit"]=125,
    ["Ooze Covered Mithril Deposit"]=175, ["Ooze Covered Truesilver Deposit"]=230,
    ["Ooze Covered Thorium Vein"]=245,
}

-- Classic zone level ranges (small fixed table; keys match the GatherNodes zone names). Cities omitted.
local ZONE_LEVELS = {
    ["Durotar"]={1,10}, ["Mulgore"]={1,10}, ["Elwynn Forest"]={1,10}, ["Dun Morogh"]={1,10},
    ["Tirisfal Glades"]={1,10}, ["Teldrassil"]={1,10},
    ["The Barrens"]={10,25}, ["Silverpine Forest"]={10,20}, ["Westfall"]={10,20}, ["Loch Modan"]={10,20},
    ["Darkshore"]={10,20}, ["Redridge Mountains"]={15,25}, ["Stonetalon Mountains"]={15,27},
    ["Duskwood"]={18,30}, ["Ashenvale"]={18,30}, ["Hillsbrad Foothills"]={20,30}, ["Wetlands"]={20,30},
    ["Thousand Needles"]={25,35}, ["Arathi Highlands"]={30,40}, ["Desolace"]={30,40},
    ["Alterac Mountains"]={30,40}, ["Stranglethorn Vale"]={30,45}, ["Dustwallow Marsh"]={35,45},
    ["Badlands"]={35,45}, ["Swamp of Sorrows"]={35,45}, ["The Hinterlands"]={40,50}, ["Tanaris"]={40,50},
    ["Feralas"]={40,50}, ["Azshara"]={45,55}, ["Searing Gorge"]={45,50}, ["Blasted Lands"]={45,55},
    ["Un'Goro Crater"]={48,55}, ["Felwood"]={48,55}, ["Western Plaguelands"]={51,58},
    ["Burning Steppes"]={50,58}, ["Deadwind Pass"]={55,60}, ["Eastern Plaguelands"]={53,60},
    ["Winterspring"]={53,60}, ["Silithus"]={55,60},
}

-- Creature source entries {npcID, pct?} that drop an item, from LootDBLua (pct = drop chance %).
local function creatureSourceEntries(itemID)
    local sources = getSources(itemID)
    local entries = {}
    if sources then
        for _, s in ipairs(sources) do
            if s.sourceID and (s.sourceType == 0 or s.sourceType == nil) then
                local pct = s.chancePercent or (s.chance and s.chance / 100) or nil
                entries[#entries + 1] = { npcID = s.sourceID, pct = pct }
            end
        end
    end
    return entries
end

-- A normal mob's loot table can't give a specific tradeable material >= this % of kills; values at/above
-- are small-sample noise (e.g. wowhead 3/3 = 100%) and are excluded from the range/bands.
local MATERIAL_PCT_CEILING = 90
local MATERIAL_BAND_TARGET = 5  -- aim for this many level bands on Shift-expand (cloth/leather)

-- Pick a friendly band width that yields ~MATERIAL_BAND_TARGET bands across [lo,hi]. Bands are ANCHORED
-- at lo (not 0) and the last band is capped at hi, so a 5-30 span reads 5-10/10-15/.../25-30.
local function chooseBandWidth(lo, hi)
    local span = math.max((hi or lo or 1) - (lo or 0), 1)
    local best, bestScore
    for _, w in ipairs({ 5, 10, 15, 20, 25, 50 }) do   -- ascending: smaller width wins ties (finer)
        local n = math.ceil(span / w)                   -- bands anchored at lo covering [lo,hi]
        local score = math.abs(n - MATERIAL_BAND_TARGET)
        if not bestScore or score < bestScore then
            best, bestScore = w, score
        end
    end
    return best or 10
end

-- Reduce creature sources to an honest picture: NORMAL mobs only (rank 0 -- no rares/elites/bosses),
-- with the low-% tail trimmed. Returns overall lo/hi level, adaptive bands -> {minpct,maxpct,count},
-- and the band width used.
local function analyzeCreatureSources(entries)
    local lv = DropChanceTooltip_MobLevels
    if not lv then return nil end

    -- Only mobs that drop it at a MEANINGFUL rate define the range/bands. Incidental low-% droppers
    -- (a mob whose Linen is a rare side-drop) and small-sample ~100% noise are both excluded, so the
    -- range reflects where you'd actually farm it. Sources with no drop data (leather) always count.
    local floor = (DropChanceTooltipDB and DropChanceTooltipDB.materialMinPercent) or defaultSettings.materialMinPercent
    local trashOnly = not (DropChanceTooltipDB and DropChanceTooltipDB.materialTrashOnly == false)
    local lo, hi, kept = nil, nil, {}
    for _, e in ipairs(entries) do
        local ml = lv[e.npcID]
        -- generic trash = rank 0 AND a level RANGE (minLevel<maxLevel); named/unique mobs are fixed-level.
        local isTrash = ml and (ml[3] or 0) == 0 and ((not trashOnly) or ((ml[1] or 0) > 0 and (ml[2] or 0) > ml[1]))
        if isTrash then
            local pct = e.pct
            if (pct == nil) or (pct >= floor and pct < MATERIAL_PCT_CEILING) then
                local mn, mx = ml[1] or 0, ml[2] or 0
                kept[#kept + 1] = { lo = mn, hi = mx, lvl = (mx > 0 and mx) or mn, pct = pct }
                if mn > 0 then lo = lo and math.min(lo, mn) or mn end
                if mx > 0 then hi = hi and math.max(hi, mx) or mx end
            end
        end
    end
    if #kept == 0 then return nil end

    local base = lo or 1
    local width = chooseBandWidth(base, hi)
    local maxIdx = math.max(math.ceil(((hi or base) - base) / width) - 1, 0)  -- fold the top mob in
    local bands = {}
    for _, r in ipairs(kept) do
        local lvl = (r.lvl > 0 and r.lvl) or base
        local idx = math.min(math.max(math.floor((lvl - base) / width), 0), maxIdx)  -- anchored at min
        local bstart = base + idx * width
        local b = bands[bstart] or { count = 0 }
        b.count = b.count + 1
        if r.pct then
            b.minpct = b.minpct and math.min(b.minpct, r.pct) or r.pct
            b.maxpct = b.maxpct and math.max(b.maxpct, r.pct) or r.pct
        end
        bands[bstart] = b
    end
    return lo, hi, bands, width
end

-- Returns an aggregation descriptor for a material item, or nil to fall through to the normal list.
local function getMaterialAggregation(itemID)
    if not (DropChanceTooltipDB and DropChanceTooltipDB.enableMaterialAggregation) then return nil end
    local name = GetItemInfo and GetItemInfo(itemID)
    local gn = DropChanceTooltip_GatherNodes

    if name and gn and gn.herb and gn.herb[name] then
        return { kind = "herb", prof = "Herbalism", skill = HERB_SKILL[name], zones = gn.herb[name] }
    end
    if name and gn and gn.ore and ORE_ITEM_TO_NODES[name] then
        local zones, skill = {}, nil
        for _, node in ipairs(ORE_ITEM_TO_NODES[name]) do
            local z = gn.ore[node]
            if z then for zone, c in pairs(z) do zones[zone] = (zones[zone] or 0) + c end end
            local s = ORE_SKILL[node]
            if s and (not skill or s < skill) then skill = s end
        end
        if next(zones) then return { kind = "ore", prof = "Mining", skill = skill, zones = zones } end
    end
    local mb = DropChanceTooltip_MiningBars
    if name and mb and mb[name] then
        local rec = mb[name]
        return { kind = "minebar", prof = "Mining", skill = rec.skill, reagents = rec.reagents }
    end
    local ms = DropChanceTooltip_MiningStone
    if name and ms and ms[name] then
        local rec = ms[name]
        return { kind = "minestone", prof = "Mining", min = rec.min, max = rec.max, ores = rec.ores }
    end
    local ar = DropChanceTooltip_AlchemyRecipes
    if name and ar and ar[name] then
        local rec = ar[name]
        return { kind = "alchemy", prof = "Alchemy", skill = rec.skill, reagents = rec.reagents }
    end
    -- generic crafted items (Tailoring, Engineering, ...): item name -> { prof, skill, reagents }
    local cr = DropChanceTooltip_CraftRecipes
    if name and cr and cr[name] then
        local rec = cr[name]
        return { kind = "craft", prof = rec.prof, skill = rec.skill, reagents = rec.reagents }
    end
    if CLOTH_ITEMS[itemID] then
        return { kind = "cloth", label = "Humanoids", entries = creatureSourceEntries(itemID) }
    end
    local slv = DropChanceTooltip_SkinningLevels
    if slv and slv[itemID] then
        local r = slv[itemID]
        return { kind = "leatherrange", label = "Beasts", prof = "Skinning", min = r[1] or r.min, max = r[2] or r.max }
    end
    local sk = DropChanceTooltip_SkinningSources
    if sk and sk[itemID] then
        local entries = {}
        for _, npcID in ipairs(sk[itemID]) do entries[#entries + 1] = { npcID = npcID } end
        return { kind = "leather", label = "Beasts", prof = "Skinning", entries = entries }
    end
    return nil
end

-- One level, colored by its difficulty vs the player (green..red).
local function colorLevel(level)
    local dc = level and GetQuestDifficultyColor and GetQuestDifficultyColor(level)
    if not dc then return tostring(level or "?") end
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor((dc.r or 1) * 255), math.floor((dc.g or 1) * 255), math.floor((dc.b or 1) * 255), tostring(level))
end

-- "lo-hi" with the min and max EACH colored by their own difficulty, so a wide band (e.g. 11-23)
-- reads green at the low end and red at the high end instead of one flat color.
local function diffRange(lo, hi)
    if lo and hi and lo ~= hi then
        return colorLevel(lo) .. "-" .. colorLevel(hi)
    end
    return colorLevel(hi or lo)
end

-- Zones whose level range OVERLAPS [lo,hi], sorted by zone level. Used to suggest where to farm a
-- creature-sourced material (leather beasts): GatherMate has no beast data, but a zone's level ~= the
-- level of the beasts in it, so level-matched zones are a good "where to skin this" proxy.
local function zonesForLevelRange(lo, hi)
    if not (lo and hi) then return {} end
    local out = {}
    for zone, lv in pairs(ZONE_LEVELS) do
        if lv[1] <= hi and lv[2] >= lo then
            out[#out + 1] = { zone = zone, lo = lv[1], hi = lv[2] }
        end
    end
    table.sort(out, function(a, b) return a.lo < b.lo or (a.lo == b.lo and a.hi < b.hi) end)
    return out
end

local function renderMaterialAggregation(tooltip, agg, expanded)
    tooltip:AddLine(" ")
    if agg.kind == "alchemy" or agg.kind == "minebar" or agg.kind == "craft" then
        local label = (agg.kind == "minebar") and "Smelted" or "Crafted"
        tooltip:AddDoubleLine(label, agg.skill and (agg.prof .. " " .. agg.skill) or (agg.prof or "Crafted"), 1, 0.82, 0, 1, 1, 1)
        if expanded and agg.reagents and #agg.reagents > 0 then
            for _, r in ipairs(agg.reagents) do
                tooltip:AddDoubleLine("  " .. tostring(r.name or r[1]), "x" .. tostring(r.count or r[2] or 1), 1, 1, 1, 0.8, 0.8, 0.8)
            end
        end
        return
    end
    if agg.kind == "leatherrange" then
        tooltip:AddDoubleLine(agg.prof or "Skinning", agg.label .. " " .. diffRange(agg.min, agg.max), 1, 0.82, 0, 1, 1, 1)
        if expanded then
            -- Where to skin it: zones whose level matches the beast range (level-based, not exact).
            local zones = zonesForLevelRange(agg.min, agg.max)
            local cap = math.min(6, #zones)
            for i = 1, cap do
                local z = zones[i]
                tooltip:AddDoubleLine("  " .. z.zone, diffRange(z.lo, z.hi), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if #zones > cap then
                tooltip:AddLine("  +" .. (#zones - cap) .. " more zones", 0.5, 0.5, 0.5)
            end
        end
        return
    end
    if agg.kind == "minestone" then
        local rng = (agg.min and agg.max and agg.min ~= agg.max) and (agg.min .. "-" .. agg.max)
            or tostring(agg.min or agg.max or "?")
        tooltip:AddDoubleLine("Mined", "Mining " .. rng, 1, 0.82, 0, 1, 1, 1)
        if expanded and agg.ores and #agg.ores > 0 then
            for _, o in ipairs(agg.ores) do
                tooltip:AddLine("  " .. tostring(o), 0.8, 0.8, 0.8)
            end
        end
        return
    end
    if agg.kind == "herb" or agg.kind == "ore" then
        local right = agg.skill and (agg.prof .. " " .. agg.skill) or agg.prof
        tooltip:AddDoubleLine("Gathered", right, 1, 0.82, 0, 1, 1, 1)
        local zlist = {}
        for zone, c in pairs(agg.zones) do zlist[#zlist + 1] = { zone, c } end
        table.sort(zlist, function(a, b) return a[2] > b[2] end)
        if expanded then
            -- Shift: densest 6 zones, each with its level range right-aligned and colored by
            -- difficulty vs the player's level. No node counts (not informative).
            local cap = math.min(6, #zlist)
            for i = 1, cap do
                local zone = zlist[i][1]
                local lvl = ZONE_LEVELS[zone]
                if lvl then
                    tooltip:AddDoubleLine("  " .. zone, diffRange(lvl[1], lvl[2]), 0.8, 0.8, 0.8, 1, 1, 1)
                else
                    tooltip:AddLine("  " .. zone, 0.8, 0.8, 0.8)
                end
            end
            if #zlist > cap then
                tooltip:AddLine("  +" .. (#zlist - cap) .. " more zones", 0.5, 0.5, 0.5)
            end
        else
            -- Collapsed: top 3 zone names on one line; the Shift hint on the line below (narrower).
            local top = {}
            for i = 1, math.min(3, #zlist) do top[#top + 1] = zlist[i][1] end
            tooltip:AddLine("  " .. table.concat(top, ", "), 0.8, 0.8, 0.8)
            if #zlist > 3 then
                tooltip:AddLine("  (+" .. (#zlist - 3) .. " «Shift»)", 0.5, 0.5, 0.5)
            end
        end
        return
    end

    -- cloth / leather: normal-mob type + level range (rares/elites and the low-% tail excluded)
    local lo, hi, bands, width = analyzeCreatureSources(agg.entries)
    local rangeText = (lo and hi) and (agg.label .. " " .. diffRange(lo, hi)) or agg.label
    tooltip:AddDoubleLine(agg.prof or "Source", rangeText, 1, 0.82, 0, 1, 1, 1)
    if expanded and bands and next(bands) then
        local starts = {}
        for b in pairs(bands) do starts[#starts + 1] = b end
        table.sort(starts)
        for _, b in ipairs(starts) do
            local band = bands[b]
            local right
            if band.minpct then
                right = (band.minpct == band.maxpct) and string.format("%.0f%%", band.maxpct)
                    or string.format("%.0f-%.0f%%", band.minpct, band.maxpct)
            else
                right = band.count .. (band.count == 1 and " mob" or " mobs")
            end
            local btop = math.min(b + width, hi or (b + width))   -- never overshoot the real max
            tooltip:AddDoubleLine("  " .. diffRange(b, btop), right, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    end
end

local function addDropDataToTooltip(tooltip)
    if not tooltip then
        return
    end

    if DropChanceTooltipDB and DropChanceTooltipDB.enabled == false then
        return
    end

    local itemID = getItemIDFromTooltip(tooltip)
    if not itemID then
        return
    end

    local quality = getItemQualityFromTooltip(tooltip, itemID)
    if isItemRarityHidden(quality) then
        debugPrint(string.format("addItem %d: rarity hidden (q=%s)", itemID, tostring(quality)))
        return
    end

    local expanded = IsShiftKeyDown()
    local signature = buildSignature(itemID, expanded, quality)
    if tooltip.__dctSignature == signature then
        debugPrint(string.format("addItem %d: signature match -> SKIP (dedupe)", itemID))
        return
    end

    -- Materials (cloth/leather/herb/ore) show an aggregated summary instead of a per-NPC list.
    local agg = getMaterialAggregation(itemID)
    if agg then
        tooltip.__dctSignature = signature
        renderMaterialAggregation(tooltip, agg, expanded)
        return
    end

    local sources = getSources(itemID)
    if not sources or #sources == 0 then
        debugPrint(string.format("addItem %d: no sources", itemID))
        tooltip.__dctSignature = signature
        -- Record as a Forever-specific gap only if NO source has it (LootDBLua, Questie, or Wowhead).
        if (not LootDBLua) or LootDBLua.IsLoaded == nil or LootDBLua.IsLoaded() then
            local known = (DropChanceTooltip_QuestieDrops and DropChanceTooltip_QuestieDrops[itemID])
                or (DropChanceTooltip_WowheadDrops and DropChanceTooltip_WowheadDrops[itemID])
            if not known then
                local nm = (GetItemInfo and GetItemInfo(itemID))
                    or (DropChanceTooltip_QuestieItemNames and DropChanceTooltip_QuestieItemNames[itemID])
                recordGap("items", itemID, nm)
            end
        end
        return
    end

    tooltip.__dctSignature = signature
    debugPrint(string.format("addItem %d: ADDING %d sources", itemID, #sources))

    tooltip:AddLine(" ")

    if #sources == 1 then
        local source = sources[1]
        tooltip:AddDoubleLine("Drop Chance", formatChance(source.chance), 1, 1, 1, 0.2, 1, 0.2)
        tooltip:AddLine(string.format("Dropped by: %s", getSourceLabel(source)), 0.70, 0.70, 0.70)
        return
    end

    -- Highest drop chance first, then show a rarity-scaled top-N (the useful farm targets)
    -- rather than every source. Shift expands the list.
    table.sort(sources, function(a, b) return (a.chance or 0) > (b.chance or 0) end)

    local visible = getVisibleSourceCount(quality, expanded, #sources)
    tooltip:AddDoubleLine("Drop Chance", string.format("top %d of %d", visible, #sources), 1, 1, 1, 0.2, 1, 0.2)

    for i = 1, visible do
        local source = sources[i]
        tooltip:AddDoubleLine(
            source.displayLabel or getSourceLabel(source),
            formatChance(source.chance),
            1, 1, 1,
            0.2, 1, 0.2
        )
    end

    if #sources > visible then
        if expanded then
            tooltip:AddLine(string.format("+ %d more sources", #sources - visible), 0.6, 0.6, 0.6)
        else
            tooltip:AddLine(string.format("+ %d more |cff9f9f9f«|r|cff7f7f7fShift to expand|r|cff9f9f9f»|r", #sources - visible), 0.6, 0.6, 0.6)
        end
    end
end

local function getNPCIDFromTooltip(tooltip)
    local guid

    -- Modern clients hand us the unit guid via the post-call data. GetUnit() is deprecated/absent
    -- there, so prefer the data guid, then fall back to GetUnit and the mouseover/target guids.
    if tooltip and tooltip.__dctData and tooltip.__dctData.guid then
        guid = tooltip.__dctData.guid
    end

    if not guid and tooltip and tooltip.GetUnit then
        local first, second = tooltip:GetUnit()
        local unit

        if type(first) == "string" and UnitExists and UnitExists(first) then
            unit = first
        elseif type(second) == "string" and UnitExists and UnitExists(second) then
            unit = second
        else
            unit = second or first
        end

        guid = unit and UnitGUID(unit) or nil
    end

    if not guid and UnitGUID then
        guid = UnitGUID("mouseover") or UnitGUID("target")
    end

    if not guid then
        return nil
    end

    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then
        return nil
    end

    return tonumber(npcID)
end

local function getItemDisplayText(drop)
    if drop.link and drop.link ~= "" then
        return drop.link
    end

    if drop.name and drop.name ~= "" then
        return drop.name
    end

    return string.format("item:%d", drop.itemID or 0)
end

local function addMobDropDataToTooltip(tooltip)
    if not tooltip then
        return
    end

    if DropChanceTooltipDB and DropChanceTooltipDB.enabled == false then
        return
    end

    -- Open-world only. Instance boss loot tables carry 15+ relevant items and would be noise;
    -- instances can be handled separately later.
    if IsInInstance and IsInInstance() then
        return
    end

    local npcID = getNPCIDFromTooltip(tooltip)
    if not npcID then
        return
    end

    local signature = string.format("mob:%d:%s", npcID, IsShiftKeyDown() and "1" or "0")
    if tooltip.__dctMobSignature == signature then
        return
    end

    local drops = getMobDrops(npcID)
    if not drops or #drops == 0 then
        -- Only cache "no drops" once the reverse index is fully built; otherwise a hover during
        -- preload would stick as empty and never retry. Leave uncached while chunks are pending.
        local stats = LootDBLua and LootDBLua.GetStats and LootDBLua.GetStats()
        local ready = stats and (stats.pendingChunkCount or 0) == 0 and (stats.queuedChunkCount or 0) == 0
        if ready then
            tooltip.__dctMobSignature = signature
            -- open-world mob with no data anywhere: Forever-specific candidate. Grab name/zone/level
            -- from the mouseover unit so the persisted record is human-readable later.
            local mobName = (UnitExists and UnitExists("mouseover") and UnitName("mouseover")) or nil
            local lvl = (UnitExists and UnitExists("mouseover") and UnitLevel and UnitLevel("mouseover")) or nil
            local meta = {
                zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()),
                level = lvl,
            }
            recordGap("npcs", npcID, mobName, meta)
        end
        return
    end
    tooltip.__dctMobSignature = signature

    local expanded = IsShiftKeyDown()

    -- Bucket every drop. quest -> own section; notable (blue/epic) + commons (white/grey) show
    -- individually; everything else falls into a collapsible "various X" group (gems, patterns,
    -- schematics, enchants, recipes, scrolls, greens) whose display is per-group configurable.
    -- Minimum-chance floor (percent). It applies ONLY to the individually-listed main "commons" so
    -- they don't fill with junk. The "various X" groups deliberately hold the low-% stuff (that is why
    -- they are collapsible) and are governed by their per-group show/hide instead. Quest + notable are
    -- always kept. Shift ignores the floor.
    local minPct = (DropChanceTooltipDB and DropChanceTooltipDB.minDropChancePercent) or defaultSettings.minDropChancePercent
    local minChanceRaw = (tonumber(minPct) or 0) * 100  -- chance is in ten-thousandths; percent = chance/100

    local buckets = { quest = {}, notable = {}, commons = {} }
    for _, key in ipairs(GROUP_ORDER) do buckets[key] = {} end
    for _, drop in ipairs(drops) do
        local key = groupKeyForDrop(drop)
        if key == "commons" and not expanded and (drop.chance or 0) < minChanceRaw then
            -- pruned by the % floor (commons only)
        else
            local list = buckets[key] or buckets.commons
            list[#list + 1] = drop
        end
    end

    local byChance = function(a, b) return (a.chance or 0) > (b.chance or 0) end
    for _, list in pairs(buckets) do table.sort(list, byChance) end
    table.sort(buckets.notable, function(a, b)
        local qa, qb = a.quality or 0, b.quality or 0
        if qa ~= qb then return qa > qb end
        return (a.chance or 0) > (b.chance or 0)
    end)

    local function sumChance(list)
        local s = 0
        for _, d in ipairs(list) do s = s + (d.chance or 0) end
        return math.min(s, 10000)
    end
    local function chanceText(chance)
        return chance and formatChance(chance) or "--"
    end

    tooltip:AddLine(" ")

    -- Quest items (own section). By default only shown when the drop matches an objective of a quest
    -- the player is currently on; the alwaysShowQuestItems override (or Shift) shows them regardless.
    if #buckets.quest > 0 then
        local alwaysShow = expanded
            or (DropChanceTooltipDB and DropChanceTooltipDB.alwaysShowQuestItems)
        -- Phantom-noise floor for quest items (separate from the commons floor + the on-quest filter):
        -- real quest drops are never sub-~1%, so prune those unless Shift is held.
        local minQuestPct = (DropChanceTooltipDB and DropChanceTooltipDB.minQuestChancePercent)
            or defaultSettings.minQuestChancePercent
        local minQuestRaw = (tonumber(minQuestPct) or 0) * 100  -- chance is ten-thousandths
        local questShown = {}
        for _, drop in ipairs(buckets.quest) do
            local passesFloor = expanded or (drop.chance or 0) >= minQuestRaw
            if passesFloor and (alwaysShow or isQuestDropRelevant(drop)) then
                questShown[#questShown + 1] = drop
            end
        end
        if #questShown > 0 then
            tooltip:AddLine("Quest Items:", 1, 0.82, 0)
            for _, drop in ipairs(questShown) do
                tooltip:AddDoubleLine(getItemDisplayText(drop), chanceText(drop.chance), 1, 1, 1, 0.2, 1, 0.2)
            end
            tooltip:AddLine(" ") -- visual break between Quest Items and Drops
        end
    end

    tooltip:AddLine("Drops:", 0.80, 0.80, 0.80)

    -- Notable (blue/epic) -- always, first, colored by the item link
    for _, drop in ipairs(buckets.notable) do
        tooltip:AddDoubleLine(getItemDisplayText(drop), chanceText(drop.chance), 1, 1, 1, 0.2, 1, 0.2)
    end

    -- Main common drops -- top-N by chance (Shift raises the cap)
    local commons = buckets.commons
    local cap = expanded
        and ((DropChanceTooltipDB and DropChanceTooltipDB.mobDropExpandedCap) or defaultSettings.mobDropExpandedCap)
        or ((DropChanceTooltipDB and DropChanceTooltipDB.mobDropCount) or defaultSettings.mobDropCount)
    local shownCommons = math.min(#commons, cap)
    for i = 1, shownCommons do
        tooltip:AddDoubleLine(getItemDisplayText(commons[i]), chanceText(commons[i].chance), 1, 1, 1, 0.2, 1, 0.2)
    end
    if #commons > shownCommons then
        tooltip:AddLine(string.format("+ %d more common drops%s", #commons - shownCommons,
            expanded and "" or " |cff9f9f9f«|r|cff7f7f7fShift|r|cff9f9f9f»|r"), 0.6, 0.6, 0.6)
    end

    -- Collapsible "various X" groups, each per-group configurable (collapse / expand / hidden).
    for _, key in ipairs(GROUP_ORDER) do
        local list = buckets[key]
        if list and #list > 0 then
            local mode = groupDisplayMode(key)
            if mode == "expand" then
                for _, drop in ipairs(list) do
                    tooltip:AddDoubleLine(getItemDisplayText(drop), chanceText(drop.chance), 1, 1, 1, 0.2, 1, 0.2)
                end
            elseif mode == "collapse" then
                local label
                if key == "gems" and #list <= 4 then
                    local names = {}
                    for _, d in ipairs(list) do names[#names + 1] = d.name or ("item:" .. tostring(d.itemID)) end
                    label = "Gems: " .. table.concat(names, ", ")
                else
                    label = string.format("%s (%d)", GROUP_META[key].label, #list)
                end
                tooltip:AddDoubleLine(label,
                    "~" .. chanceText(sumChance(list)) .. " |cff9f9f9f«|r|cff7f7f7fShift|r|cff9f9f9f»|r",
                    0.1, 1, 0.1, 0.1, 1, 0.1)
            end
            -- "hidden": render nothing
        end
    end

    tooltip:AddLine(" ") -- visual break after our drops block
end

-- ---------------------------------------------------------------------------------------------
-- Profession skill requirements: gather nodes (Mining/Herbalism) + skinnable beasts (Skinning).
-- ---------------------------------------------------------------------------------------------

-- Player's current skill in a profession by localized name (e.g. "Mining"). Returns have, skill, max.
-- Uses the retail-engine global GetProfessions/GetProfessionInfo (confirmed on this client;
-- C_TradeSkillUI.GetProfessions and the old GetSkillLineInfo are both absent). Read live per tooltip
-- (cheap: <=6 calls) so a skill-up shows immediately without cache invalidation.
local function getProfSkill(profName)
    if type(GetProfessions) ~= "function" or type(GetProfessionInfo) ~= "function" then
        return false
    end
    local profs = { GetProfessions() }  -- prof1, prof2, archaeology, fishing, cooking, firstAid
    for _, idx in pairs(profs) do
        if idx then
            local n, _, skill, maxSkill = GetProfessionInfo(idx)
            if n == profName then
                return true, skill, maxSkill
            end
        end
    end
    return false
end

-- Per-profession gate. key = "mining"|"herbalism"|"skinning"; profName = its localized name.
-- Returns shown, skill (skill is nil when shown only via the showWithoutProfession override).
local function professionShown(key, profName)
    ensureSettings()
    local p = DropChanceTooltipDB.professions and DropChanceTooltipDB.professions[key]
    if not p or not p.enabled then
        return false
    end
    local have, skill = getProfSkill(profName)
    if have then
        return true, skill
    end
    if p.showWithoutProfession then
        return true, nil
    end
    return false
end

-- Classic gathering difficulty color for a requirement R vs the player's skill S. Ramp:
-- red (can't) -> orange -> yellow -> green -> grey (trivial at R+100). No skill at all (missing the
-- profession, or below the requirement) means you can't gather/skin it -> red.
local function gatherColor(req, skill)
    if not req then return 0.8, 0.8, 0.8 end             -- unknown requirement -> neutral
    if not skill or skill <= 0 then return 1.0, 0.1, 0.1 end  -- don't have the skill -> can't -> red
    if skill < req then return 1.0, 0.1, 0.1 end         -- impossible
    local d = skill - req
    if d >= 100 then return 0.5, 0.5, 0.5 end            -- trivial (grey)
    if d >= 50  then return 0.25, 0.75, 0.25 end         -- easy (green)
    if d >= 25  then return 1.0, 1.0, 0.0 end            -- medium (yellow)
    return 1.0, 0.5, 0.0                                 -- hard (orange)
end

local function colorText(text, r, g, b)
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), tostring(text))
end

-- Required skinning skill for a beast of the given level (classic convention: level x 5).
local function skinningRequirement(level)
    if not level or level < 1 then return nil end
    return level * 5
end

-- First left FontString whose text contains `needle` (plain match); returns FontString, text.
local function findTooltipLine(tooltip, needle)
    local name = tooltip and tooltip.GetName and tooltip:GetName()
    if not name then return nil end
    for i = 1, tooltip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if text and text:find(needle, 1, true) then
            return fs, text
        end
    end
    return nil
end

-- On this client some tooltip text and unit GUIDs are "secret" values (e.g. inside instances):
-- indexing a table with one or converting one to a string throws. Bail whenever a value is secret
-- (gather nodes / skinnable beasts don't exist in those contexts anyway).
local issecretvalue = issecretvalue or function() return false end

-- Object(4) tooltip: Mining/Herbalism gather nodes. Detected by node name (nodes carry no id).
-- Injects the required skill into the game's "Requires Mining/Herbalism" line as a difficulty-colored
-- "(N)"; adds the line if the game didn't render one. Node names match ORE_SKILL (vein names) and
-- HERB_SKILL (herb names) directly. The signature guard also blocks re-entrancy from tooltip:Show().
local function addGatherNodeInfoToTooltip(tooltip)
    if not tooltip then return end
    if DropChanceTooltipDB and DropChanceTooltipDB.enabled == false then return end
    local nameFS = tooltip.GetName and _G[tooltip:GetName() .. "TextLeft1"]
    local nodeName = nameFS and nameFS:GetText()
    if not nodeName or issecretvalue(nodeName) then return end

    local key, profName, req, needle
    if ORE_SKILL[nodeName] then
        key, profName, req, needle = "mining", "Mining", ORE_SKILL[nodeName], "Mining"
    elseif HERB_SKILL[nodeName] then
        key, profName, req, needle = "herbalism", "Herbalism", HERB_SKILL[nodeName], "Herbalism"
    else
        return
    end

    local sig = string.format("node:%s:%d", nodeName, req)
    if tooltip.__dctNodeSig == sig then return end
    tooltip.__dctNodeSig = sig

    local shown, skill = professionShown(key, profName)
    if not shown then return end

    -- Recolor the WHOLE requirement line (not just the number) to the difficulty color, overriding
    -- the game's default line color. SetTextColor applies to the entire FontString.
    local r, g, b = gatherColor(req, skill)
    local fs, text = findTooltipLine(tooltip, needle)
    if fs then
        fs:SetText(text .. " (" .. req .. ")")
        fs:SetTextColor(r, g, b)
    else
        tooltip:AddLine("Requires " .. profName .. " (" .. req .. ")", r, g, b)
    end
    tooltip:Show()  -- re-layout after editing/adding a line
end

-- Unit(2) tooltip for beasts: skinning. On this client a dead skinnable beast stays a valid mouseover
-- and the game adds a "Skinnable" line (its presence == actually skinnable). Dead -> inject the
-- required skill into that line (task 2). Living Beast -> add a bottom "Skinnable N" line (task 3).
-- Requirement = level x 5, colored by the gather ramp vs current Skinning. Called after the drop
-- section so the living-beast line sits at the bottom.
local function addSkinningInfoToTooltip(tooltip)
    if not tooltip then return end
    if DropChanceTooltipDB and DropChanceTooltipDB.enabled == false then return end

    local unit = (UnitExists and UnitExists("mouseover")) and "mouseover" or nil
    if not unit then return end
    -- Only real NPC creatures are skinnable. Guard on a Creature GUID so we never inject onto a
    -- PLAYER (a shapeshifted druid -- self or others -- reports UnitCreatureType "Beast") or a pet.
    local guid = UnitGUID and UnitGUID(unit)
    if not guid or issecretvalue(guid) then return end   -- secret GUID (e.g. in instances): bail
    if (strsplit("-", guid)) ~= "Creature" then return end
    if not (UnitCreatureType and UnitCreatureType(unit) == "Beast") then return end

    local level = UnitLevel and UnitLevel(unit)
    local req = skinningRequirement(level)
    local isDead = UnitIsDead and UnitIsDead(unit) and true or false

    local sig = string.format("skin:%s:%s:%s",
        tostring(UnitGUID and UnitGUID(unit)), tostring(req), isDead and "d" or "a")
    if tooltip.__dctSkinSig == sig then return end
    tooltip.__dctSkinSig = sig

    local shown, skill = professionShown("skinning", "Skinning")
    if not shown then return end

    -- Recolor the whole "Skinnable" line to the difficulty color (the game paints it green by
    -- default); no skinning skill -> red via gatherColor.
    local r, g, b = gatherColor(req, skill)
    local reqNum = req and tostring(req) or "??"

    if isDead then
        local fs, text = findTooltipLine(tooltip, "Skinnable")
        if fs then
            fs:SetText(text .. " " .. reqNum)
            fs:SetTextColor(r, g, b)
            tooltip:Show()
        end
    else
        tooltip:AddLine("Skinnable " .. reqNum, r, g, b)
        tooltip:Show()
    end
end

local function getTooltipTitleText(tooltip)
    if not tooltip or not tooltip.GetName then
        return nil
    end

    local name = tooltip:GetName()
    if not name then
        return nil
    end

    local titleRegion = _G[name .. "TextLeft1"]
    if not titleRegion or not titleRegion.GetText then
        return nil
    end

    local text = titleRegion:GetText()
    if text and text ~= "" then
        return text
    end

    return nil
end

local function addDropsByNameLookupToTooltip(tooltip)
    if not tooltip then
        return
    end

    if DropChanceTooltipDB and DropChanceTooltipDB.enabled == false then
        return
    end

    if getItemIDFromTooltip(tooltip) then
        return
    end

    if getNPCIDFromTooltip(tooltip) then
        return
    end

    local sourceName = getTooltipTitleText(tooltip)
    if not sourceName then
        debugPrint("Name lookup hover: tooltip has no title text")
        return
    end

    debugPrint(string.format("Name lookup hover: checking '%s'", sourceName))

    local sourceType
    local sourceID
    local drops

    sourceID = getSourceIDByName("npc", sourceName)
    if sourceID then
        drops = getMobDrops(sourceID)
        sourceType = "mob"
    end

    if (not drops or #drops == 0) then
        sourceID = getSourceIDByName("object", sourceName)
        if sourceID then
            drops = getObjectDrops(sourceID)
            sourceType = "object"
        end
    end

    if not sourceID or not drops or #drops == 0 then
        debugPrint(string.format("Name lookup hover: no drops found for '%s'", sourceName))
        return
    end

    debugPrint(string.format("Name lookup hover: resolved %s %d with %d drops", sourceType, sourceID, #drops))

    local signature = string.format("%s:%d", sourceType, sourceID)
    if tooltip.__dctMobSignature == signature then
        return
    end

    tooltip.__dctMobSignature = signature
    tooltip:AddLine(" ")
    tooltip:AddLine("Drops:", 0.80, 0.80, 0.80)

    local maxDrops = math.min(#drops, 15)
    for i = 1, maxDrops do
        local drop = drops[i]
        local chanceLabel = drop.chance and formatChance(drop.chance) or "--"
        tooltip:AddDoubleLine(getItemDisplayText(drop), chanceLabel, 1, 1, 1, 0.2, 1, 0.2)
    end

    if #drops > maxDrops then
        tooltip:AddLine(string.format("and %d more drops", #drops - maxDrops), 0.70, 0.70, 0.70)
    end
end

local function clearTooltipState(tooltip)
    if not tooltip then
        return
    end

    if tooltip.__dctSignature or tooltip.__dctMobSignature or tooltip.__dctCountSig then
        debugPrint("clearTooltipState: reset signatures")
    end
    tooltip.__dctSignature = nil
    tooltip.__dctMobSignature = nil
    tooltip.__dctCountSig = nil
    tooltip.__dctNodeSig = nil
    tooltip.__dctSkinSig = nil
end

local function captureOrigin(tooltip, methodName, ...)
    if not tooltip then
        return
    end

    tooltip.__dctOriginMethod = methodName
    tooltip.__dctOriginArgs = packArgs(...)
    tooltip.__dctLastShiftState = IsShiftKeyDown() and 1 or 0
end

local function rerenderTooltip(tooltip)
    if not tooltip or not tooltip:IsShown() then
        return
    end

    local shiftState = IsShiftKeyDown() and 1 or 0
    if tooltip.__dctLastShiftState == shiftState then
        return
    end

    local hasItem = tooltip.GetItem and getItemIDFromTooltip(tooltip)
    if not hasItem then
        return
    end

    local methodName = tooltip.__dctOriginMethod
    local args = tooltip.__dctOriginArgs

    if not methodName or not args or not tooltip[methodName] then
        return
    end

    tooltip.__dctSignature = nil
    tooltip.__dctCountSig = nil
    tooltip.__dctLastShiftState = shiftState
    if tooltip == ItemRefTooltip and methodName == "SetHyperlink" then
        tooltip.__dctLastShiftState = shiftState
        tooltip.__dctSignature = nil
        tooltip:ClearLines()
        tooltip:SetHyperlink(unpackArgs(args))
        return
    end

    tooltip[methodName](tooltip, unpackArgs(args))
end

local function attachTooltip(tooltip)
    if not tooltip or tooltip.__dctAttached then
        return
    end

    tooltip.__dctAttached = true

    local hasModernProcessor = TooltipDataProcessor and type(TooltipDataProcessor.AddTooltipPostCall) == "function"

    if tooltip.HookScript then
        -- Legacy OnTooltipSet* scripts were removed on modern clients (10.0.2+); on those the
        -- global TooltipDataProcessor post-calls (installed in installTooltipHooks) do the work.
        -- Only wire the legacy per-tooltip scripts when there is no modern processor.
        if not hasModernProcessor then
            tooltip:HookScript("OnTooltipSetItem", function(t)
                addDropDataToTooltip(t)
                addOwnedCountsToTooltip(t)
            end)

            tooltip:HookScript("OnTooltipSetUnit", function(t)
                addMobDropDataToTooltip(t)
            end)

            tooltip:HookScript("OnTooltipSetSpell", function(t)
                addDropsByNameLookupToTooltip(t)
            end)

            tooltip:HookScript("OnTooltipSetQuest", function(t)
                addDropsByNameLookupToTooltip(t)
            end)

            tooltip:HookScript("OnTooltipSetAchievement", function(t)
                addDropsByNameLookupToTooltip(t)
            end)
        end

        -- OnHide / OnTooltipCleared still fire on all clients; use them to reset our per-render state.
        if tooltip:HasScript("OnHide") then
            tooltip:HookScript("OnHide", function(t)
                clearTooltipState(t)
            end)
        end

        if tooltip:HasScript("OnTooltipCleared") then
            tooltip:HookScript("OnTooltipCleared", function(t)
                clearTooltipState(t)
            end)
        end
    end
end

local function installOriginHooks(tooltip)
    if not tooltip then
        return
    end

    local methods = {
        "SetAction",
        "SetBagItem",
        "SetHyperlink",
        "SetInboxItem",
        "SetInventoryItem",
        "SetLootItem",
        "SetLootRollItem",
        "SetMerchantItem",
        "SetQuestItem",
        "SetQuestLogItem",
        "SetTradeTargetItem",
        "SetAuctionItem",
        "SetCraftItem",
        "SetTradeSkillItem",
        "SetRecipeReagentItem",
        "SetRecipeResultItem",
        "SetGuildBankItem",
    }

    local hooked = 0
    for i = 1, #methods do
        local methodName = methods[i]
        if tooltip[methodName] then
            hooksecurefunc(tooltip, methodName, function(self, ...)
                captureOrigin(self, methodName, ...)
            end)
            hooked = hooked + 1
        end
    end

    debugPrint(string.format("Hooked %d origin method(s) for %s", hooked, tostring(tooltip:GetName() or "tooltip")))
end

local function installTooltipHooks()
    attachTooltip(GameTooltip)
    attachTooltip(ItemRefTooltip)

    installOriginHooks(GameTooltip)
    installOriginHooks(ItemRefTooltip)

    -- Modern clients (Dragonflight+/Forever): tooltip content is populated through
    -- TooltipDataProcessor, and the old OnTooltipSet* scripts no longer fire. Register global
    -- post-calls once; they run for every tooltip. The `data` carries the item id / unit guid,
    -- which we stash on the tooltip so getItemIDFromTooltip/getNPCIDFromTooltip can read it.
    if TooltipDataProcessor and type(TooltipDataProcessor.AddTooltipPostCall) == "function"
        and Enum and Enum.TooltipDataType then

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            tooltip.__dctData = data
            addDropDataToTooltip(tooltip)
            addOwnedCountsToTooltip(tooltip)
        end)

        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
            tooltip.__dctData = data
            addMobDropDataToTooltip(tooltip)
            addSkinningInfoToTooltip(tooltip)
        end)

        -- Gather nodes (mining/herb) come through the Object tooltip; they carry no numeric id, so
        -- addGatherNodeInfoToTooltip keys off the node name.
        if Enum.TooltipDataType.Object then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Object, function(tooltip, data)
                tooltip.__dctData = data
                addGatherNodeInfoToTooltip(tooltip)
            end)
        end

        modernHooksInstalled = true
        debugPrint("Tooltip hooks installed (modern TooltipDataProcessor)")
    else
        debugPrint("Tooltip hooks installed (legacy OnTooltipSet*)")
    end
end

local function printDebugStatus()
    local provider = getLootDBProvider()
    local providerName = "none"
    if provider == LootDBLua then
        providerName = "LootDBLua"
    end

    debugPrint(string.format("Debug mode is ON (%s)", tostring(ADDON_NAME)))
    debugPrint(string.format("Provider detected: %s", providerName))

    if GameTooltip and GameTooltip.GetItem then
        local _, link = GameTooltip:GetItem()
        if link then
            local itemID = getItemIDFromLink(link)
            debugPrint(string.format("Current GameTooltip item link: %s", tostring(link)))
            if itemID then
                local sources = getSources(itemID)
                debugPrint(string.format("Current GameTooltip itemID %d sources: %d", itemID, sources and #sources or 0))
            end
        else
            debugPrint("GameTooltip has no current item")
        end
    end
end


-- ============================================================================================
-- Options window -- EllesmereUI-style: left-nav sections + right content with tabs. Fully
-- self-contained (the Expressway font is bundled under media/fonts, no EllesmereUI dependency).
-- ============================================================================================

local UI = { W = 760, H = 560, SIDEBAR_W = 172, HEADER_H = 56, TABBAR_H = 30, PAD = 18, ROW_H = 30 }
local ACCENT = { 0.40, 0.80, 1.00 }   -- DCT blue (66ccff)
local FONT_DEFAULT = "Fonts\\FRIZQT__.TTF"
local FONT_EXPRESSWAY = "Interface\\AddOns\\DropChanceTooltip\\media\\fonts\\Expressway.ttf"

local optionsFrame
local fontRegistry = {}      -- { {fs=, size=, flags=}, ... } for live font swaps
local pageCache = {}         -- ["section::tab"] = wrapper frame
local sectionButtons = {}
local tabPool = {}
local tabButtons = {}
local sectionByKey = {}
local activeSection, activeTab, activeRefreshers, doSelectSection

-- ---- font helpers ---------------------------------------------------------------------------
local function fontFile()
    ensureSettings()
    if DropChanceTooltipDB.useExpresswayFont then return FONT_EXPRESSWAY end
    return FONT_DEFAULT
end

local function applyFont(fs, size, flags)
    fs:SetFont(fontFile(), size, flags or "")
    if not fs:GetFont() then fs:SetFont(FONT_DEFAULT, size, flags or "") end
end

local function refreshAllFonts()
    for _, e in ipairs(fontRegistry) do applyFont(e.fs, e.size, e.flags) end
end

-- ---- primitives -----------------------------------------------------------------------------
local function SolidTex(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function MakeFont(parent, size, r, g, b, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fontRegistry[#fontRegistry + 1] = { fs = fs, size = size, flags = flags }
    applyFont(fs, size, flags)
    fs:SetTextColor(r or 0.9, g or 0.9, b or 0.9, 1)
    return fs
end

local function MakeBorder(parent, r, g, b, a)
    r, g, b, a = r or 0, g or 0, b or 0, a or 1
    local top = SolidTex(parent, "BORDER", r, g, b, a); top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
    local bot = SolidTex(parent, "BORDER", r, g, b, a); bot:SetPoint("BOTTOMLEFT"); bot:SetPoint("BOTTOMRIGHT"); bot:SetHeight(1)
    local lft = SolidTex(parent, "BORDER", r, g, b, a); lft:SetPoint("TOPLEFT"); lft:SetPoint("BOTTOMLEFT"); lft:SetWidth(1)
    local rgt = SolidTex(parent, "BORDER", r, g, b, a); rgt:SetPoint("TOPRIGHT"); rgt:SetPoint("BOTTOMRIGHT"); rgt:SetWidth(1)
end

-- Reflect a settings change immediately: drop cached tooltip state so the next hover re-renders.
local function reflect()
    clearTooltipState(GameTooltip)
    clearTooltipState(ItemRefTooltip)
    if GameTooltip and GameTooltip.IsShown and GameTooltip:IsShown() then GameTooltip:Hide() end
end

-- ---- widget factory (each returns its height; pages walk a y-cursor downward) ---------------
local function makeSection(parent, text, y)
    parent._rows = 0
    local fs = MakeFont(parent, 11, 0.5, 0.5, 0.56)
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.PAD, y - 4)
    fs:SetText(string.upper(text))
    local line = SolidTex(parent, "ARTWORK", 1, 1, 1, 0.08)
    line:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3)
    line:SetPoint("RIGHT", parent, "RIGHT", -UI.PAD, 0)
    line:SetHeight(1)
    return 26
end

local function makeToggle(parent, text, y, get, set, tooltip, layout)
    local rowIndex, x, wdt, ref
    if layout then
        rowIndex = layout.rowIndex or 0
        x = layout.x or UI.PAD
        wdt = layout.w
        ref = layout.ref
    else
        rowIndex = parent._rows or 0
        parent._rows = rowIndex + 1
        x = UI.PAD
    end
    local row = CreateFrame("Button", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if wdt then row:SetWidth(wdt) else row:SetPoint("RIGHT", parent, "RIGHT", -UI.PAD, 0) end
    row:SetHeight(UI.ROW_H)
    local bg = SolidTex(row, "BACKGROUND", 1, 1, 1, (rowIndex % 2 == 0) and 0.03 or 0.06)
    bg:SetAllPoints(row)

    local label = MakeFont(row, 13, 0.88, 0.88, 0.9)
    label:SetPoint("LEFT", 8, 0)
    label:SetText(text)

    local track = CreateFrame("Frame", nil, row)
    track:SetSize(38, 16)
    track:SetPoint("RIGHT", -8, 0)
    local trackTex = SolidTex(track, "ARTWORK", 0.28, 0.28, 0.32, 1)
    trackTex:SetAllPoints(track)
    local knob = track:CreateTexture(nil, "OVERLAY")
    knob:SetSize(12, 12)
    knob:SetColorTexture(0.9, 0.9, 0.9, 1)

    local ON_X, OFF_X = 24, 2
    local cur = get() and ON_X or OFF_X
    local dest = cur
    local enabled = true
    local function place() knob:ClearAllPoints(); knob:SetPoint("LEFT", track, "LEFT", cur, 0) end
    local function applyVisual()
        if enabled then
            local on = (dest == ON_X)
            label:SetTextColor(0.88, 0.88, 0.9)
            trackTex:SetColorTexture(on and ACCENT[1] or 0.28, on and ACCENT[2] or 0.28, on and ACCENT[3] or 0.32, on and 0.9 or 1)
            knob:SetAlpha(1)
        else
            label:SetTextColor(0.42, 0.42, 0.45)
            trackTex:SetColorTexture(0.2, 0.2, 0.22, 1)
            knob:SetAlpha(0.35)
        end
    end
    local function setEnabled(on)
        enabled = on and true or false
        row:EnableMouse(enabled)
        applyVisual()
    end
    place(); applyVisual()

    row:SetScript("OnUpdate", function(self, dt)
        if cur ~= dest then
            cur = cur + (dest - cur) * math.min(1, (dt or 0) * 14)
            if math.abs(dest - cur) < 0.5 then cur = dest end
            place()
        end
    end)
    row:SetScript("OnClick", function()
        if not enabled then return end
        local on = not (dest == ON_X)
        set(on and true or false)
        dest = on and ON_X or OFF_X
        applyVisual()
    end)
    if tooltip then
        row:SetScript("OnEnter", function()
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    if ref then ref.frame = row; ref.setEnabled = setEnabled end
    if activeRefreshers then
        activeRefreshers[#activeRefreshers + 1] = function()
            local on = get() and true or false
            dest = on and ON_X or OFF_X; cur = dest; place(); applyVisual()
        end
    end
    return UI.ROW_H
end

local function makeSlider(parent, text, y, minV, maxV, step, get, set, fmt)
    local H = 40
    local c = CreateFrame("Frame", nil, parent)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.PAD, y)
    c:SetPoint("RIGHT", parent, "RIGHT", -UI.PAD, 0)
    c:SetHeight(H)
    local label = MakeFont(c, 13, 0.88, 0.88, 0.9); label:SetPoint("TOPLEFT", 8, -2); label:SetText(text)
    local valfs = MakeFont(c, 13, ACCENT[1], ACCENT[2], ACCENT[3]); valfs:SetPoint("TOPRIGHT", -8, -2)

    local track = CreateFrame("Frame", nil, c)
    track:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
    track:SetPoint("RIGHT", c, "RIGHT", -10, 0)
    track:SetHeight(5)
    track:EnableMouse(true)
    local tbg = SolidTex(track, "ARTWORK", 0.24, 0.24, 0.28, 1); tbg:SetAllPoints(track)
    local fill = SolidTex(track, "OVERLAY", ACCENT[1], ACCENT[2], ACCENT[3], 0.85)
    fill:SetPoint("TOPLEFT"); fill:SetPoint("BOTTOMLEFT"); fill:SetWidth(1)
    local thumb = CreateFrame("Button", nil, track); thumb:SetSize(12, 12)
    local thtex = SolidTex(thumb, "OVERLAY", 0.92, 0.92, 0.92, 1); thtex:SetAllPoints(thumb)

    local function clamp(v)
        v = math.max(minV, math.min(maxV, v))
        if step and step > 0 then v = math.floor((v - minV) / step + 0.5) * step + minV end
        return v
    end
    local value = clamp(get() or minV)
    local function layout()
        local w = track:GetWidth() or 1
        local frac = (maxV > minV) and (value - minV) / (maxV - minV) or 0
        thumb:ClearAllPoints(); thumb:SetPoint("CENTER", track, "LEFT", frac * w, 0)
        fill:SetWidth(math.max(1, frac * w))
        valfs:SetText(fmt and fmt(value) or tostring(value))
    end
    local function fromCursor()
        local x = GetCursorPosition() / (track:GetEffectiveScale() or 1)
        local left = track:GetLeft() or 0
        local w = track:GetWidth() or 1
        return clamp(minV + ((x - left) / w) * (maxV - minV))
    end
    local dragging = false
    thumb:SetScript("OnMouseDown", function() dragging = true end)
    thumb:SetScript("OnMouseUp", function() dragging = false; value = fromCursor(); layout(); set(value) end)
    thumb:SetScript("OnUpdate", function() if dragging then value = fromCursor(); layout(); set(value) end end)
    track:SetScript("OnMouseDown", function() value = fromCursor(); layout(); set(value) end)
    track:SetScript("OnSizeChanged", layout)
    if activeRefreshers then
        activeRefreshers[#activeRefreshers + 1] = function() value = clamp(get() or minV); layout() end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0, layout) end
    return H
end

local function makeButton(parent, text, y, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", UI.PAD, y)
    b:SetSize(220, 26)
    local bg = SolidTex(b, "ARTWORK", 0.16, 0.16, 0.19, 1); bg:SetAllPoints(b)
    MakeBorder(b, 0, 0, 0, 0.8)
    local fs = MakeFont(b, 13, 0.9, 0.9, 0.9); fs:SetPoint("CENTER"); fs:SetText(text)
    b:SetScript("OnEnter", function() bg:SetColorTexture(ACCENT[1] * 0.35, ACCENT[2] * 0.35, ACCENT[3] * 0.35, 1) end)
    b:SetScript("OnLeave", function() bg:SetColorTexture(0.16, 0.16, 0.19, 1) end)
    b:SetScript("OnClick", onClick)
    return 34
end

local function resetAll()
    if type(DropChanceTooltipDB) == "table" then
        for k in pairs(DropChanceTooltipDB) do DropChanceTooltipDB[k] = nil end
    end
    ensureSettings()
    refreshAllFonts()
    reflect()
    if doSelectSection and activeSection then doSelectSection(activeSection) end
end

-- Lay a list of simple {text,get,set} toggles into two columns; returns the new y-cursor.
local function twoColumn(parent, y, items)
    local W0 = parent:GetWidth()
    if not W0 or W0 < 50 then W0 = UI.W - UI.SIDEBAR_W - 20 end
    local gap = 12
    local colW = (W0 - UI.PAD * 2 - gap) / 2
    local rightX = UI.PAD + colW + gap
    local ri = 0
    local i = 1
    while i <= #items do
        local a = items[i]
        makeToggle(parent, a.text, y, a.get, a.set, a.tooltip, { x = UI.PAD, w = colW, rowIndex = ri, ref = a.ref })
        local b = items[i + 1]
        if b then makeToggle(parent, b.text, y, b.get, b.set, b.tooltip, { x = rightX, w = colW, rowIndex = ri, ref = b.ref }) end
        y = y - UI.ROW_H
        ri = ri + 1
        i = i + 2
    end
    return y
end

-- ---- page builders (build(tab, wrapper) -> total height) ------------------------------------
local function buildGeneral(_, w)
    local y = -UI.PAD
    y = y - makeSection(w, "Drop tooltips", y)
    y = y - makeToggle(w, "Enable drop tooltips", y,
        function() return DropChanceTooltipDB.enabled ~= false end,
        function(v) DropChanceTooltip_Toggle(v and true or false) end,
        "Master on/off for all DropChanceTooltip additions.")
    y = y - makeSection(w, "Material aggregation", y)
    y = y - makeToggle(w, "Aggregate material sources", y,
        function() return DropChanceTooltipDB.enableMaterialAggregation end,
        function(v) DropChanceTooltipDB.enableMaterialAggregation = v; reflect() end,
        "Show a summarized source (level range / zones / recipe) for materials instead of every NPC.")
    y = y - makeToggle(w, "Use trash mobs only for level ranges", y,
        function() return DropChanceTooltipDB.materialTrashOnly end,
        function(v) DropChanceTooltipDB.materialTrashOnly = v; reflect() end)
    y = y - makeSlider(w, "Minimum drop % to count toward a range", y, 0, 100, 1,
        function() return DropChanceTooltipDB.materialMinPercent end,
        function(v) DropChanceTooltipDB.materialMinPercent = v; reflect() end,
        function(v) return string.format("%d%%", v) end)
    y = y - makeSection(w, "Appearance", y)
    y = y - makeToggle(w, "Use Expressway font (EllesmereUI look)", y,
        function() return DropChanceTooltipDB.useExpresswayFont end,
        function(v) DropChanceTooltipDB.useExpresswayFont = v; refreshAllFonts() end)
    return -y + UI.PAD
end

local function buildItem(tab, w)
    local y = -UI.PAD
    if tab == "Rarity" then
        y = y - makeSection(w, "Item rarity filter", y)
        y = y - makeToggle(w, "Enable rarity filter", y,
            function() return DropChanceTooltipDB.enableItemRarityFilter end,
            function(v) DropChanceTooltipDB.enableItemRarityFilter = v; reflect() end)
        local items = {}
        for _, r in ipairs(rarityOrder) do
            local rr = r
            items[#items + 1] = {
                text = rarityLabels[rr] or ("Rarity " .. rr),
                get = function() return DropChanceTooltipDB.showItemByRarity[rr] == true end,
                set = function(v) DropChanceTooltipDB.showItemByRarity[rr] = v; reflect() end,
            }
        end
        y = twoColumn(w, y, items)
    elseif tab == "Sources" then
        y = y - makeSection(w, "Sources shown per item", y)
        y = y - makeSlider(w, "Default count", y, 1, 30, 1,
            function() return DropChanceTooltipDB.sourceCountDefault end,
            function(v) DropChanceTooltipDB.sourceCountDefault = v; reflect() end,
            function(v) return string.format("%d", v) end)
        y = y - makeSlider(w, "Expanded cap (Shift held)", y, 1, 60, 1,
            function() return DropChanceTooltipDB.sourceExpandedCap end,
            function(v) DropChanceTooltipDB.sourceExpandedCap = v; reflect() end,
            function(v) return string.format("%d", v) end)
    else -- Owned Counts
        y = y - makeSection(w, "Owned counts", y)
        local consRef, incRef = {}, {}
        y = twoColumn(w, y, {
            { text = "Your bags",  get = function() return DropChanceTooltipDB.showSelfBags end,
              set = function(v) DropChanceTooltipDB.showSelfBags = v; reflect() end },
            { text = "Your bank",  get = function() return DropChanceTooltipDB.showSelfBank end,
              set = function(v) DropChanceTooltipDB.showSelfBank = v; reflect() end },
            { text = "Alts' bags", get = function() return DropChanceTooltipDB.showAltsBags end,
              set = function(v) DropChanceTooltipDB.showAltsBags = v; reflect() end },
            { text = "Alts' bank", get = function() return DropChanceTooltipDB.showAltsBank end,
              set = function(v) DropChanceTooltipDB.showAltsBank = v; reflect() end },
            { text = "Consolidated total", ref = consRef, get = function() return DropChanceTooltipDB.countConsolidated end,
              set = function(v) DropChanceTooltipDB.countConsolidated = v; reflect(); if incRef.setEnabled then incRef.setEnabled(v) end end },
            { text = "Include alts in total", ref = incRef, get = function() return DropChanceTooltipDB.countIncludeAlts end,
              set = function(v) DropChanceTooltipDB.countIncludeAlts = v; reflect() end },
        })
        local function syncInc() if incRef.setEnabled then incRef.setEnabled(DropChanceTooltipDB.countConsolidated == true) end end
        syncInc()
        if activeRefreshers then activeRefreshers[#activeRefreshers + 1] = syncInc end
    end
    return -y + UI.PAD
end

local function buildMob(tab, w)
    local y = -UI.PAD
    if tab == "Rarity" then
        y = y - makeSection(w, "Mob rarity filter", y)
        y = y - makeToggle(w, "Enable rarity filter", y,
            function() return DropChanceTooltipDB.enableMobRarityFilter end,
            function(v) DropChanceTooltipDB.enableMobRarityFilter = v; reflect() end)
        local items = {}
        for _, r in ipairs(rarityOrder) do
            local rr = r
            items[#items + 1] = {
                text = rarityLabels[rr] or ("Rarity " .. rr),
                get = function() return DropChanceTooltipDB.showMobByRarity[rr] == true end,
                set = function(v) DropChanceTooltipDB.showMobByRarity[rr] = v; reflect() end,
            }
        end
        y = twoColumn(w, y, items)
    elseif tab == "Groups" then
        y = y - makeSection(w, "Collapsible groups", y)
        y = y - makeToggle(w, "Expand all groups", y,
            function() return DropChanceTooltipDB.expandAllVarious end,
            function(v) DropChanceTooltipDB.expandAllVarious = v; reflect() end)
        local W0 = w:GetWidth()
        if not W0 or W0 < 50 then W0 = UI.W - UI.SIDEBAR_W - 20 end
        local gap = 12
        local colW = (W0 - UI.PAD * 2 - gap) / 2
        local rightX = UI.PAD + colW + gap
        local ri = 0
        for _, key in ipairs(GROUP_ORDER) do
            local gk = key
            local short = GROUP_META[gk].label:gsub("^Various ", "")
            local expandRef = {}
            local function syncExpand()
                if expandRef.setEnabled then
                    expandRef.setEnabled((DropChanceTooltipDB.variousMode[gk] or "collapse") ~= "hidden")
                end
            end
            makeToggle(w, "Show " .. short, y,
                function() return (DropChanceTooltipDB.variousMode[gk] or "collapse") ~= "hidden" end,
                function(v)
                    if not v then
                        DropChanceTooltipDB.variousMode[gk] = "hidden"
                    elseif DropChanceTooltipDB.variousMode[gk] == "hidden" then
                        DropChanceTooltipDB.variousMode[gk] = "collapse"
                    end
                    reflect()
                    syncExpand()
                end, nil, { x = UI.PAD, w = colW, rowIndex = ri })
            makeToggle(w, "Expand", y,
                function() return DropChanceTooltipDB.variousMode[gk] == "expand" end,
                function(v)
                    if DropChanceTooltipDB.variousMode[gk] ~= "hidden" then
                        DropChanceTooltipDB.variousMode[gk] = v and "expand" or "collapse"
                    end
                    reflect()
                end, nil, { x = rightX, w = colW, rowIndex = ri, ref = expandRef })
            syncExpand()
            if activeRefreshers then activeRefreshers[#activeRefreshers + 1] = syncExpand end
            y = y - UI.ROW_H
            ri = ri + 1
        end
    elseif tab == "Quest" then
        y = y - makeSection(w, "Quest items", y)
        y = y - makeToggle(w, "Always show quest items", y,
            function() return DropChanceTooltipDB.alwaysShowQuestItems end,
            function(v) DropChanceTooltipDB.alwaysShowQuestItems = v; reflect() end)
        y = y - makeSlider(w, "Minimum quest drop %", y, 0, 5, 0.25,
            function() return DropChanceTooltipDB.minQuestChancePercent end,
            function(v) DropChanceTooltipDB.minQuestChancePercent = v; reflect() end,
            function(v) return string.format("%.2f%%", v) end)
    else -- Thresholds
        y = y - makeSection(w, "Drop thresholds", y)
        y = y - makeSlider(w, "Minimum drop %", y, 0, 5, 0.25,
            function() return DropChanceTooltipDB.minDropChancePercent end,
            function(v) DropChanceTooltipDB.minDropChancePercent = v; reflect() end,
            function(v) return string.format("%.2f%%", v) end)
        y = y - makeSlider(w, "Drops shown", y, 1, 25, 1,
            function() return DropChanceTooltipDB.mobDropCount end,
            function(v) DropChanceTooltipDB.mobDropCount = v; reflect() end,
            function(v) return string.format("%d", v) end)
        y = y - makeSlider(w, "Expanded cap (Shift held)", y, 1, 50, 1,
            function() return DropChanceTooltipDB.mobDropExpandedCap end,
            function(v) DropChanceTooltipDB.mobDropExpandedCap = v; reflect() end,
            function(v) return string.format("%d", v) end)
    end
    return -y + UI.PAD
end

local function buildProfessions(tab, w)
    local map = { Mining = "mining", Herbalism = "herbalism", Skinning = "skinning" }
    local key = map[tab] or "mining"
    local y = -UI.PAD
    y = y - makeSection(w, tab, y)
    y = y - makeToggle(w, "Show " .. tab .. " requirements", y,
        function() return DropChanceTooltipDB.professions[key].enabled end,
        function(v)
            DropChanceTooltipDB.professions[key].enabled = v
            if GameTooltip then GameTooltip.__dctNodeSig = nil; GameTooltip.__dctSkinSig = nil end
        end,
        "Show " .. tab .. " skill requirements on gather nodes / beasts.")
    y = y - makeToggle(w, "Show even without the profession", y,
        function() return DropChanceTooltipDB.professions[key].showWithoutProfession end,
        function(v)
            DropChanceTooltipDB.professions[key].showWithoutProfession = v
            if GameTooltip then GameTooltip.__dctNodeSig = nil; GameTooltip.__dctSkinSig = nil end
        end,
        "Show the requirement even on characters that lack " .. tab .. ".")
    return -y + UI.PAD
end

local function buildAdvanced(_, w)
    local y = -UI.PAD
    y = y - makeSection(w, "Data & diagnostics", y)
    y = y - makeButton(w, "Export data gaps", y, function() SlashCmdList.DROPCHANCETOOLTIP("gaps export") end)
    y = y - makeButton(w, "Run diagnostics", y, function() SlashCmdList.DROPCHANCETOOLTIP("diag") end)
    y = y - makeButton(w, "Character name probe", y, function() SlashCmdList.DROPCHANCETOOLTIP("whoami") end)
    y = y - makeButton(w, "Toggle debug chat", y, function() SlashCmdList.DROPCHANCETOOLTIP("debugchat") end)
    y = y - makeSection(w, "Reset", y)
    y = y - makeButton(w, "Reset all settings to defaults", y, resetAll)
    return -y + UI.PAD
end

local SECTIONS = {
    { key = "general", title = "General",      desc = "Master toggle, material aggregation, and appearance.", build = buildGeneral },
    { key = "item",    title = "Item Tooltips", desc = "Drop sources, source counts, and owned-item counts.", tabs = { "Rarity", "Sources", "Owned Counts" }, build = buildItem },
    { key = "mob",     title = "Mob Tooltips",  desc = "Rarity, collapsible groups, quest items, thresholds.", tabs = { "Rarity", "Groups", "Quest", "Thresholds" }, build = buildMob },
    { key = "prof",    title = "Professions",   desc = "Show gather-node / skinning skill requirements, per profession.", tabs = { "Mining", "Herbalism", "Skinning" }, build = buildProfessions },
    { key = "adv",     title = "Advanced",      desc = "Data-gap export, diagnostics, and reset.", build = buildAdvanced },
}
for _, sec in ipairs(SECTIONS) do sectionByKey[sec.key] = sec end

-- ---- window shell ---------------------------------------------------------------------------
local function createOptionsWindow()
    if optionsFrame then return optionsFrame end

    local f = CreateFrame("Frame", "DropChanceTooltipOptionsFrame", UIParent)
    f:SetSize(UI.W, UI.H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    local bg = SolidTex(f, "BACKGROUND", 0.06, 0.06, 0.07, 0.97); bg:SetAllPoints(f)
    MakeBorder(f, 0, 0, 0, 1)
    if UISpecialFrames then tinsert(UISpecialFrames, "DropChanceTooltipOptionsFrame") end

    local titleFs = MakeFont(f, 16, ACCENT[1], ACCENT[2], ACCENT[3]); titleFs:SetPoint("TOPLEFT", 14, -10); titleFs:SetText("DropChanceTooltip")
    local close = CreateFrame("Button", nil, f)
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -8, -7)
    local closeX = MakeFont(close, 17, 0.75, 0.28, 0.28); closeX:SetPoint("CENTER"); closeX:SetText("X")
    close:SetScript("OnEnter", function() closeX:SetTextColor(1, 0.2, 0.2) end)
    close:SetScript("OnLeave", function() closeX:SetTextColor(0.75, 0.28, 0.28) end)
    close:SetScript("OnClick", function() f:Hide() end)
    local titleLine = SolidTex(f, "ARTWORK", 1, 1, 1, 0.08); titleLine:SetPoint("TOPLEFT", 0, -34); titleLine:SetPoint("TOPRIGHT", 0, -34); titleLine:SetHeight(1)

    local sidebar = CreateFrame("Frame", nil, f)
    sidebar:SetPoint("TOPLEFT", 0, -34); sidebar:SetPoint("BOTTOMLEFT", 0, 0); sidebar:SetWidth(UI.SIDEBAR_W)
    local sbBg = SolidTex(sidebar, "BACKGROUND", 1, 1, 1, 0.02); sbBg:SetAllPoints(sidebar)
    local sbLine = SolidTex(sidebar, "ARTWORK", 1, 1, 1, 0.08); sbLine:SetPoint("TOPRIGHT"); sbLine:SetPoint("BOTTOMRIGHT"); sbLine:SetWidth(1)

    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0); right:SetPoint("BOTTOMRIGHT", 0, 0)
    local headerFs = MakeFont(right, 18, 0.95, 0.95, 0.97); headerFs:SetPoint("TOPLEFT", UI.PAD, -12)
    local descFs = MakeFont(right, 12, 0.6, 0.6, 0.64)
    descFs:SetPoint("TOPLEFT", headerFs, "BOTTOMLEFT", 0, -4); descFs:SetPoint("RIGHT", right, "RIGHT", -UI.PAD, 0); descFs:SetJustifyH("LEFT")

    local tabBar = CreateFrame("Frame", nil, right)
    tabBar:SetPoint("TOPLEFT", 0, -UI.HEADER_H); tabBar:SetPoint("TOPRIGHT", 0, -UI.HEADER_H); tabBar:SetHeight(UI.TABBAR_H)
    local tabLine = SolidTex(tabBar, "ARTWORK", 1, 1, 1, 0.08); tabLine:SetPoint("BOTTOMLEFT"); tabLine:SetPoint("BOTTOMRIGHT"); tabLine:SetHeight(1)

    local scrollFrame = CreateFrame("ScrollFrame", nil, right)
    scrollFrame:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -6, 8)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(1, 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (scrollChild:GetHeight() or 0) - (self:GetHeight() or 0))
        local nv = math.min(maxScroll, math.max(0, self:GetVerticalScroll() - (delta or 0) * 28))
        self:SetVerticalScroll(nv)
    end)

    local function getTab(i)
        local t = tabPool[i]
        if not t then
            t = CreateFrame("Button", nil, tabBar)
            t:SetHeight(UI.TABBAR_H)
            t._label = MakeFont(t, 13, 0.7, 0.7, 0.72); t._label:SetPoint("CENTER", 0, 0)
            t._underline = SolidTex(t, "OVERLAY", ACCENT[1], ACCENT[2], ACCENT[3], 1)
            t._underline:SetPoint("BOTTOMLEFT", 6, 0); t._underline:SetPoint("BOTTOMRIGHT", -6, 0); t._underline:SetHeight(2)
            tabPool[i] = t
        end
        return t
    end

    local function runList(list) if list then for _, fn in ipairs(list) do fn() end end end

    local function selectTab(name)
        activeTab = name
        for _, t in ipairs(tabButtons) do
            local on = (t._name == name)
            t._label:SetTextColor(on and 1 or 0.7, on and 1 or 0.7, on and 1 or 0.72)
            if on then t._underline:Show() else t._underline:Hide() end
        end
        for _, wpr in pairs(pageCache) do wpr:Hide() end
        local ckey = activeSection .. "::" .. name
        local wrapper = pageCache[ckey]
        local contentW = scrollFrame:GetWidth()
        if not contentW or contentW < 1 then contentW = UI.W - UI.SIDEBAR_W - 12 end
        if not wrapper then
            wrapper = CreateFrame("Frame", nil, scrollChild)
            wrapper:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
            wrapper:SetWidth(contentW)
            wrapper._refreshers = {}
            pageCache[ckey] = wrapper
            activeRefreshers = wrapper._refreshers
            local h = sectionByKey[activeSection].build(name, wrapper) or 20
            wrapper:SetHeight(h)
            activeRefreshers = nil
        end
        wrapper:SetWidth(contentW)
        wrapper:Show()
        scrollChild:SetSize(contentW, wrapper:GetHeight())
        scrollFrame:SetVerticalScroll(0)
        runList(wrapper._refreshers)
    end

    local function selectSection(key)
        activeSection = key
        local section = sectionByKey[key]
        if not section then return end
        headerFs:SetText(section.title)
        descFs:SetText(section.desc or "")
        for k, b in pairs(sectionButtons) do
            local on = (k == key)
            if on then b._accent:Show() else b._accent:Hide() end
            b._label:SetTextColor(on and 1 or 0.72, on and 1 or 0.72, on and 1 or 0.75)
            if on then b._hl:Show() else b._hl:Hide() end
        end
        for _, t in ipairs(tabPool) do t:Hide() end
        wipe(tabButtons)
        local tabs = section.tabs
        if tabs and #tabs > 0 then
            local x = UI.PAD
            for i, tabName in ipairs(tabs) do
                local t = getTab(i)
                t._name = tabName
                t._label:SetText(tabName)
                t:SetWidth((t._label:GetStringWidth() or 40) + 22)
                t:ClearAllPoints(); t:SetPoint("BOTTOMLEFT", tabBar, "BOTTOMLEFT", x, 0)
                x = x + t:GetWidth() + 8
                t:SetScript("OnClick", function() selectTab(tabName) end)
                t:Show()
                tabButtons[i] = t
            end
            selectTab(tabs[1])
        else
            selectTab("_")
        end
    end
    doSelectSection = selectSection

    for i, section in ipairs(SECTIONS) do
        local b = CreateFrame("Button", nil, sidebar)
        b:SetHeight(32)
        b:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -8 - (i - 1) * 34)
        b:SetPoint("RIGHT", sidebar, "RIGHT", 0, 0)
        b._accent = SolidTex(b, "OVERLAY", ACCENT[1], ACCENT[2], ACCENT[3], 1)
        b._accent:SetPoint("TOPLEFT"); b._accent:SetPoint("BOTTOMLEFT"); b._accent:SetWidth(3); b._accent:Hide()
        b._hl = SolidTex(b, "BACKGROUND", 1, 1, 1, 0.05); b._hl:SetAllPoints(b); b._hl:Hide()
        b._label = MakeFont(b, 14, 0.72, 0.72, 0.75); b._label:SetPoint("LEFT", 16, 0); b._label:SetText(section.title)
        b:SetScript("OnEnter", function() if activeSection ~= section.key then b._hl:Show() end end)
        b:SetScript("OnLeave", function() if activeSection ~= section.key then b._hl:Hide() end end)
        b:SetScript("OnClick", function() selectSection(section.key) end)
        sectionButtons[section.key] = b
    end

    optionsFrame = f
    return f
end

local function openOptionsWindow()
    ensureSettings()
    local f = createOptionsWindow()
    f:Show()
    refreshAllFonts()
    doSelectSection(activeSection or SECTIONS[1].key)
end

-- Open the options window (slash + bare /dct).
local function openSettings()
    openOptionsWindow()
end

-- Register a launcher entry in Blizzard's AddOns settings list that opens our window.
local function registerSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        return
    end
    local panel = CreateFrame("Frame")
    panel.name = "DropChanceTooltip"
    local t = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge"); t:SetPoint("TOPLEFT", 16, -16); t:SetText("DropChanceTooltip")
    local d = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall"); d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -8); d:SetText("Open the DropChanceTooltip options window.")
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate"); b:SetSize(200, 26); b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -12); b:SetText("Open Options")
    b:SetScript("OnClick", function() openOptionsWindow() end)
    settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "DropChanceTooltip")
    Settings.RegisterAddOnCategory(settingsCategory)
    settingsCategoryID = (settingsCategory.GetID and settingsCategory:GetID()) or settingsCategory.ID
end

-- Keybinding labels (Key Bindings UI, under the "DropChanceTooltip" header).
BINDING_HEADER_DROPCHANCETOOLTIP = "DropChanceTooltip"
BINDING_NAME_DROPCHANCETOOLTIP_TOGGLE = "Toggle Drop Tooltips"

-- Master toggle for the tooltip additions. GLOBAL on purpose so the keybind (Bindings.xml) and
-- macros can drive it: put  /run DropChanceTooltip_Toggle()  on an action button, or use /dct toggle.
-- Pass true/false to force a state; omit to flip.
function DropChanceTooltip_Toggle(force)
    ensureSettings()

    local newState
    if force == true or force == false then
        newState = force
    else
        newState = not (DropChanceTooltipDB.enabled ~= false)
    end
    DropChanceTooltipDB.enabled = newState

    local msg = "|cff66ccffDCT|r drop tooltips " .. (newState and "|cff20ff20ON|r" or "|cffff2020OFF|r")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    else
        print(msg)
    end

    -- Reflect immediately: drop cached signatures and hide the current tooltip so the next hover
    -- re-renders with the new state.
    if GameTooltip then
        GameTooltip.__dctSignature = nil
        GameTooltip.__dctMobSignature = nil
        GameTooltip.__dctCountSig = nil
        if GameTooltip.IsShown and GameTooltip:IsShown() and GameTooltip.Hide then
            GameTooltip:Hide()
        end
    end

    return newState
end

-- One-shot diagnostics: prints unconditionally (independent of debugchat). /dct diag
local function runDiagnostics()
    local function out(msg)
        local line = "|cff66ccffDCT-DIAG|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(line)
        else
            print(line)
        end
    end

    out("=== diagnostics ===")
    local hasLDB = type(LootDBLua) == "table"
    out("LootDBLua present: " .. tostring(hasLDB))
    if hasLDB then
        out("IsLoaded: " .. tostring(LootDBLua.IsLoaded and LootDBLua.IsLoaded()))
        if LootDBLua.GetStats then
            local s = LootDBLua.GetStats() or {}
            out(string.format("stats: chunks=%s items=%s pending=%s queued=%s preloadStarted=%s",
                tostring(s.loadedChunkCount), tostring(s.loadedItemCount),
                tostring(s.pendingChunkCount), tostring(s.queuedChunkCount), tostring(s.preloadStarted)))
        end
    end
    out("TooltipDataProcessor: " .. tostring(TooltipDataProcessor ~= nil)
        .. " | Enum.TooltipDataType.Item: "
        .. tostring(Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item ~= nil))
    out("modern hooks installed: " .. tostring(modernHooksInstalled))
    out("enabled: " .. tostring(not (DropChanceTooltipDB and DropChanceTooltipDB.enabled == false)))

    -- Probe well-known drops: Linen Cloth (2589), Wool Cloth (2592).
    for _, id in ipairs({ 2589, 2592 }) do
        local q, n = nil, "nil"
        if hasLDB and LootDBLua.GetItemQuality then q = LootDBLua.GetItemQuality(id) end
        if hasLDB and LootDBLua.GetSourcesForItem then
            local src = LootDBLua.GetSourcesForItem(id, q)
            n = src and #src or "nil"
        end
        out(string.format("item %d: quality=%s sources=%s", id, tostring(q), tostring(n)))
    end
    local npcCount = 0
    for _ in pairs(mobDropIndex) do npcCount = npcCount + 1 end
    out("mob reverse index: " .. npcCount .. " npcs (fills during preload; open-world tooltips only)")

    out("Now hover an item and run /dct debugchat first to see per-hover logs.")
end

-- Dump every indexed drop for an NPC (raw, no bucketing/filtering) with class/subclass ids, so we
-- can confirm what's in the data (e.g. a quest item) and identify class ids (e.g. scrolls).
local function runNpcDump(arg)
    local function out(msg)
        local line = "|cff66ccffDCT-NPC|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(line)
        else
            print(line)
        end
    end

    local npcID = tonumber(arg)
    if not npcID then
        local guid = (UnitGUID and (UnitGUID("mouseover") or UnitGUID("target")))
        if guid then
            local unitType, _, _, _, _, id = strsplit("-", guid)
            if unitType == "Creature" or unitType == "Vehicle" then
                npcID = tonumber(id)
            end
        end
    end
    if not npcID then
        out("no npcID -- hover/target a mob, or /dct npc <id>")
        return
    end

    local bucket = mobDropIndex[npcID]
    if not bucket then
        out(string.format("npc %d: no indexed drops (preload may be incomplete -- /dct diag)", npcID))
        return
    end

    local list = {}
    for itemID, chance in pairs(bucket) do
        list[#list + 1] = { itemID = itemID, chance = chance }
    end
    table.sort(list, function(a, b) return a.chance > b.chance end)

    out(string.format("npc %d: %d drops  (itemID | qN | class:sub | chance | name)", npcID, #list))
    for _, e in ipairs(list) do
        local name = GetItemInfo(e.itemID)
            or (DropChanceTooltip_QuestieItemNames and DropChanceTooltip_QuestieItemNames[e.itemID])
            or "?"
        local q = LootDBLua and LootDBLua.GetItemQuality and LootDBLua.GetItemQuality(e.itemID)
        local classID, subID = getItemClassInfo(e.itemID)
        out(string.format("  %d | q%s | %s:%s | %s | %s",
            e.itemID, tostring(q), tostring(classID), tostring(subID), formatChance(e.chance), tostring(name)))
    end
end

-- /dct various [<group>|expandall [mode]]: manage the collapsible "various X" categories.
local function handleVariousCommand(key, mode)
    local function out(msg)
        local line = "|cff66ccffDCT|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(line)
        else
            print(line)
        end
    end
    ensureSettings()

    if not key or key == "" then
        out("various groups (collapse | expand | hide):")
        for _, g in ipairs(GROUP_ORDER) do
            out(string.format("  %s = %s", g, tostring(DropChanceTooltipDB.variousMode[g])))
        end
        out("  expandAllVarious = " .. tostring(DropChanceTooltipDB.expandAllVarious))
        out("usage: /dct various <group> collapse|expand|hide   |   /dct various expandall")
        return
    end

    key = string.lower(key)
    if key == "expandall" then
        DropChanceTooltipDB.expandAllVarious = not DropChanceTooltipDB.expandAllVarious
        out("expandAllVarious = " .. tostring(DropChanceTooltipDB.expandAllVarious))
    elseif GROUP_META[key] then
        mode = string.lower(mode or "")
        if mode == "hide" then mode = "hidden" end
        if mode == "collapse" or mode == "expand" or mode == "hidden" then
            DropChanceTooltipDB.variousMode[key] = mode
            out(string.format("various %s = %s", key, mode))
        else
            out(string.format("various %s is %s -- set with: collapse | expand | hide",
                key, tostring(DropChanceTooltipDB.variousMode[key])))
        end
    else
        out("unknown group '" .. key .. "'. Groups: " .. table.concat(GROUP_ORDER, ", ") .. ", expandall")
        return
    end

    clearTooltipState(GameTooltip)
    clearTooltipState(ItemRefTooltip)
end

-- Build a readable, machine-parseable string of all collected gaps. Lines beginning `npc:`/`item:`
-- carry the id first so a GitHub Action (or tools/) can extract them; the rest is human context.
local function buildGapsExportString()
    ensureSettings()
    local gaps = DropChanceTooltipDB.gaps
    local ver, bld = GetBuildInfo()
    local npcIDs, itemIDs = {}, {}
    for id in pairs(gaps.npcs) do npcIDs[#npcIDs + 1] = id end
    for id in pairs(gaps.items) do itemIDs[#itemIDs + 1] = id end
    table.sort(npcIDs)
    table.sort(itemIDs)

    local function fmt(id, rec)
        local r = (type(rec) == "table") and rec or nil
        local extra = {}
        if r then
            if r.name then extra[#extra + 1] = r.name end
            if r.zone then extra[#extra + 1] = "[" .. r.zone .. "]" end
            if r.level then extra[#extra + 1] = "lvl" .. r.level end
            if r.count then extra[#extra + 1] = "x" .. r.count end
            if r.last then extra[#extra + 1] = "(" .. r.last .. ")" end
        end
        return (#extra > 0) and (id .. "  " .. table.concat(extra, "  ")) or tostring(id)
    end

    local lines = {}
    lines[#lines + 1] = string.format("DropChanceTooltip gaps | client %s build %s | %d npcs, %d items",
        tostring(ver), tostring(bld), #npcIDs, #itemIDs)
    lines[#lines + 1] = "# Forever-specific candidates: hovered in-world with NO drop data in any source."
    lines[#lines + 1] = "## NPCs"
    for _, id in ipairs(npcIDs) do lines[#lines + 1] = "npc:" .. fmt(id, gaps.npcs[id]) end
    lines[#lines + 1] = "## Items"
    for _, id in ipairs(itemIDs) do lines[#lines + 1] = "item:" .. fmt(id, gaps.items[id]) end
    return table.concat(lines, "\n"), #npcIDs, #itemIDs
end

-- Copyable export dialog (mirrors ForeverVO's proven InputScrollFrame pattern for this client):
-- the string goes out via a GitHub issue -- the only crash-proof channel, since it leaves the game.
local gapsExportFrame
local function showGapsExport()
    local text, nn, ni = buildGapsExportString()
    if (nn + ni) == 0 then
        local msg = "|cff66ccffDCT-GAPS|r no gaps collected yet -- hover open-world mobs/items with no drop data first."
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
        return
    end
    if not gapsExportFrame then
        local frame = CreateFrame("Frame", "DropChanceTooltipGapsExport", UIParent, "ButtonFrameTemplate")
        gapsExportFrame = frame
        frame:SetSize(560, 380)
        frame:SetPoint("CENTER")
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        if frame.SetTitle then frame:SetTitle("DropChanceTooltip: contribute gaps") end
        if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(frame) end
        tinsert(UISpecialFrames, "DropChanceTooltipGapsExport") -- Escape closes

        local hint = frame:CreateFontString(nil, "ARTWORK")
        hint:SetFontObject("GameFontHighlight")
        hint:SetJustifyH("LEFT")
        hint:SetPoint("TOPLEFT", 16, -32)
        hint:SetPoint("RIGHT", -16, 0)
        hint:SetText("Press Ctrl+C to copy, then open a new issue at\n|cff6ec6ffgithub.com/defnotjec/DropChanceTooltip-Forever/issues/new?template=gaps.yml|r\nand paste. These are mobs/items with no drop data yet.")

        local scroll = CreateFrame("ScrollFrame", nil, frame, "InputScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -12)
        scroll:SetPoint("BOTTOMRIGHT", -30, 16)
        scroll.EditBox:SetMaxLetters(0)
        scroll.EditBox:SetFontObject("GameFontHighlightSmall")
        scroll.EditBox:SetScript("OnEscapePressed", function() frame:Hide() end)
        scroll.EditBox:SetScript("OnTextChanged", function(editBox, userInput)
            if userInput then
                editBox:SetText(frame.exportString or "")
                editBox:HighlightText()
            end
        end)
        if scroll.CharCount then scroll.CharCount:Hide() end
        frame.scrollEdit = scroll.EditBox
    end
    gapsExportFrame.exportString = text
    gapsExportFrame.scrollEdit:SetText(text)
    gapsExportFrame:Show()
    gapsExportFrame.scrollEdit:SetFocus()
    gapsExportFrame.scrollEdit:HighlightText()
    DropChanceTooltipDB.gapsDirty = false      -- assume the open block will be pasted
end

-- Remind the player to export before a clean logout/quit (or, throttled, on zone change), since an
-- unclean exit is the only case that loses the in-memory gaps the client hasn't flushed yet.
local lastGapNudge = 0
local function nudgeGapsExport(reason)
    if not (DropChanceTooltipDB and DropChanceTooltipDB.gaps and DropChanceTooltipDB.gapsDirty) then return end
    local n = 0
    for _ in pairs(DropChanceTooltipDB.gaps.npcs) do n = n + 1 end
    for _ in pairs(DropChanceTooltipDB.gaps.items) do n = n + 1 end
    if n == 0 then return end
    local now = (time and time()) or 0
    if reason == "zone" and (now - lastGapNudge) < 600 then return end   -- throttle zone nudges to 10 min
    lastGapNudge = now
    local msg = string.format("|cff66ccffDCT|r %d un-exported drop-data gap(s). |cffffd100/dct gaps export|r to copy them for contribution.", n)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
end

-- /dct gaps [clear|export]: show, reset, or copy the item/npc ids we found NO drop data for -- the
-- evidence list for a targeted Wowhead-Forever scrape (paste items into tools/scrape_ids.txt).
local function runGapsCommand(arg)
    local function out(msg)
        local line = "|cff66ccffDCT-GAPS|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(line)
        else
            print(line)
        end
    end
    ensureSettings()
    local gaps = DropChanceTooltipDB.gaps

    local a = arg and arg:lower() or ""

    if a == "clear" then
        gaps.items, gaps.npcs = {}, {}
        DropChanceTooltipDB.gapsDirty = false
        out("cleared.")
        return
    end

    if a == "export" then
        showGapsExport()
        return
    end

    if a == "test" then
        -- Inject a synthetic gap so the whole flow (record -> persist -> list -> export) is verifiable
        -- without hunting for a data-less mob. Sentinel ids 999901/999902 -- remove with /dct gaps clear.
        recordGap("npcs", 999901, "Test Dummy (DCT)", { zone = "Nowhere", level = 60 })
        recordGap("items", 999902, "Test Trinket (DCT)")
        out("injected a test npc (999901) + item (999902). Run |cffffd100/dct gaps|r to list, ")
        out("|cffffd100/dct gaps export|r to see the copyable block, then |cffffd100/dct gaps clear|r.")
        return
    end

    local items, npcs = {}, {}
    for id in pairs(gaps.items) do items[#items + 1] = id end
    for id in pairs(gaps.npcs) do npcs[#npcs + 1] = id end
    table.sort(items)
    table.sort(npcs)
    local function join(t)
        local s = {}
        for i = 1, #t do s[i] = tostring(t[i]) end
        return table.concat(s, " ")
    end

    out(string.format("%d gap items, %d gap npcs (no data in any source = Forever-specific candidates)", #items, #npcs))
    if #items > 0 then out("items: " .. join(items)) end
    if #npcs > 0 then out("npcs:  " .. join(npcs)) end
    out("These persist across sessions (SavedVariables). |cffffd100/dct gaps export|r opens a copyable")
    out("block to paste into a GitHub issue; /dct gaps clear to reset.")
end

-- /dct count [selfbags|selfbank|altsbags|altsbank]: toggle the item-tooltip count lines, or list state.
local function runCountCommand(arg)
    local function out(msg)
        local line = "|cff66ccffDCT-COUNT|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(line) else print(line) end
    end
    ensureSettings()
    local map = {
        selfbags = "showSelfBags", selfbank = "showSelfBank",
        altsbags = "showAltsBags", altsbank = "showAltsBank",
        consolidate = "countConsolidated",
    }
    local a = arg and arg:lower() or ""
    if a == "includealts" then
        if not DropChanceTooltipDB.countConsolidated then
            out("enable /dct count consolidate first -- include-alts only applies to the consolidated total")
            return
        end
        DropChanceTooltipDB.countIncludeAlts = not DropChanceTooltipDB.countIncludeAlts
        out("include alts in total = " .. tostring(DropChanceTooltipDB.countIncludeAlts))
        return
    end
    if map[a] then
        DropChanceTooltipDB[map[a]] = not DropChanceTooltipDB[map[a]]
        out(a .. " = " .. tostring(DropChanceTooltipDB[map[a]]))
        return
    end

    local function whoName(snap)
        local nm = (snap and snap.name) or (UnitName and UnitName("player")) or "?"
        local cf = snap and snap.class
        if cf then nm = nm .. " (" .. ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cf]) or cf) .. ")" end
        return nm
    end

    if a == "bank" then
        local counts, slots = scanContainers(bankContainers())
        local n = 0
        for _ in pairs(counts) do n = n + 1 end
        out(string.format("bank scan RIGHT NOW: %d slots, %d distinct items (bankIsOpen=%s)", slots, n, tostring(_bankIsOpen)))
        if slots == 0 then
            out("0 slots -> the bank isn't readable. Open your bank and re-run; if still 0, the bank container ids are wrong for this client.")
        else
            out("scan works -> your bank IS captured on open. If an alt's bank is missing, open that alt's bank once then log out cleanly.")
        end
        return
    end

    if a == "clear" then
        DropChanceTooltipDB.inventory = {}
        snapshotBags()
        snapshotBank()
        out("cleared recorded characters; re-saved the current one. Log each alt + /dct count save.")
        return
    end

    if a == "save" then
        snapshotBags()
        snapshotBank()  -- no-op unless the bank is open
        local snap = DropChanceTooltipDB.inventory[charKey() or ""]
        local nb, nk = 0, 0
        if snap then
            for _ in pairs(snap.bags or {}) do nb = nb + 1 end
            for _ in pairs(snap.bank or {}) do nk = nk + 1 end
        end
        out(string.format("saved %s: %d bag items, %d bank items%s",
            whoName(snap), nb, nk, snap and "" or " (FAILED -- no GUID/name?)"))
        return
    end

    if a == "list" then
        local names = {}
        for _, snap in pairs(DropChanceTooltipDB.inventory or {}) do
            local nb, nk = 0, 0
            for _ in pairs(snap.bags or {}) do nb = nb + 1 end
            for _ in pairs(snap.bank or {}) do nk = nk + 1 end
            names[#names + 1] = string.format("  %s: %d bag / %d bank items", whoName(snap), nb, nk)
        end
        table.sort(names)
        out((#names) .. " character(s) recorded:")
        for _, l in ipairs(names) do out(l) end
        out("you are " .. whoName(DropChanceTooltipDB.inventory[charKey() or ""]) .. " (/dct count save to record now)")
        return
    end

    out("item-count toggles (hover shows your total; Shift expands per character):")
    out(string.format("  self bags: %s  ·  self bank: %s  ·  alts bags: %s  ·  alts bank: %s",
        tostring(DropChanceTooltipDB.showSelfBags), tostring(DropChanceTooltipDB.showSelfBank),
        tostring(DropChanceTooltipDB.showAltsBags), tostring(DropChanceTooltipDB.showAltsBank)))
    out(string.format("  consolidated: %s  ·  include alts in total: %s",
        tostring(DropChanceTooltipDB.countConsolidated), tostring(DropChanceTooltipDB.countIncludeAlts)))
    out("toggle: /dct count selfbags | selfbank | altsbags | altsbank | consolidate | includealts")
    out("also: /dct count list | save | bank (diagnose)")
end

-- /dct whoami: probe every name API to find which one surfaces the full "First Last" name on this
-- client (UnitName returns first only). Whichever shows the full name, we wire into the snapshot.
local function runWhoAmI()
    local function out(msg)
        local line = "|cff66ccffDCT-WHO|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(line) else print(line) end
    end
    local function try(label, fn)
        local ok, a, b = pcall(fn)
        if not ok then a = "err" end
        out(string.format("%-24s = %s%s", label, tostring(a), (b ~= nil) and (" | realm=" .. tostring(b)) or ""))
    end
    try("UnitName", function() return UnitName("player") end)
    try("GetUnitName(true)", function() return GetUnitName("player", true) end)
    try("UnitFullName", function() return UnitFullName("player") end)
    try("UnitPVPName", function() return UnitPVPName("player") end)
    try("UnitNameUnmodified", function() return UnitNameUnmodified("player") end)
    try("GetPlayerInfoByGUID.name", function() return (select(6, GetPlayerInfoByGUID(UnitGUID("player")))) end)
    -- tooltip scrape: on RP clients the unit tooltip's first line shows the full displayed name.
    local ok, txt = pcall(function()
        local tt = _G.DCTScanTip or CreateFrame("GameTooltip", "DCTScanTip", nil, "GameTooltipTemplate")
        tt:SetOwner(UIParent, "ANCHOR_NONE")
        tt:ClearLines()
        tt:SetUnit("player")
        local left = _G["DCTScanTipTextLeft1"]
        return left and left:GetText()
    end)
    out(string.format("%-24s = %s", "tooltip line1", ok and tostring(txt) or "err"))
    out("-> tell me which line shows your FULL name and I'll store that.")
end

-- /dct matdump [itemID]: break down what feeds a material's aggregation (per-source %/level, and why
-- each is kept or excluded), so the level range and band low/high ends can be understood and tuned.
local function runMatDump(arg)
    local function out(msg)
        local line = "|cff66ccffDCT-MAT|r " .. tostring(msg)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(line) else print(line) end
    end
    ensureSettings()
    local itemID = tonumber(arg)
    if not itemID then
        itemID = (GameTooltip and getItemIDFromTooltip(GameTooltip)) or (ItemRefTooltip and getItemIDFromTooltip(ItemRefTooltip))
    end
    if not itemID then out("usage: /dct matdump <itemID>  (or hover an item first)"); return end
    local name = (GetItemInfo and GetItemInfo(itemID)) or ("item " .. itemID)
    local gn = DropChanceTooltip_GatherNodes

    -- herb / ore: dump zones by node density
    local function dumpZones(kind, nodes)
        local zones = {}
        for _, node in ipairs(nodes) do
            local z = gn and gn[kind] and gn[kind][node]
            if z then for zone, c in pairs(z) do zones[zone] = (zones[zone] or 0) + c end end
        end
        local zl = {}
        for zone, c in pairs(zones) do zl[#zl + 1] = { zone, c } end
        table.sort(zl, function(a, b) return a[2] > b[2] end)
        out(name .. " = " .. kind .. " (" .. table.concat(nodes, ", ") .. ")")
        for _, z in ipairs(zl) do out(string.format("  %-24s %d nodes", z[1], z[2])) end
    end
    if name and gn and gn.herb and gn.herb[name] then return dumpZones("herb", { name }) end
    if name and ORE_ITEM_TO_NODES[name] and gn and gn.ore then return dumpZones("ore", ORE_ITEM_TO_NODES[name]) end

    -- cloth / leather: dump creature sources
    local entries, label
    if CLOTH_ITEMS[itemID] then
        entries, label = creatureSourceEntries(itemID), "cloth (Humanoids)"
    elseif DropChanceTooltip_SkinningSources and DropChanceTooltip_SkinningSources[itemID] then
        entries = {}
        for _, n in ipairs(DropChanceTooltip_SkinningSources[itemID]) do entries[#entries + 1] = { npcID = n } end
        label = "leather (Beasts)"
    else
        out(name .. " is not a recognized material (no aggregation)"); return
    end

    local lv = DropChanceTooltip_MobLevels
    local floor = DropChanceTooltipDB.materialMinPercent or defaultSettings.materialMinPercent
    local trashOnly = DropChanceTooltipDB.materialTrashOnly ~= false
    local rows = {}
    for _, e in ipairs(entries) do
        local ml = lv and lv[e.npcID]
        rows[#rows + 1] = { id = e.npcID, pct = e.pct, mn = ml and ml[1] or 0, mx = ml and ml[2] or 0, rk = ml and (ml[3] or 0) or nil, lvl = ml ~= nil }
    end
    table.sort(rows, function(a, b) return (a.pct or 0) > (b.pct or 0) end)
    out(string.format("%s = %s: %d sources | min %.0f%% (/dct matmin) | ceiling %d%% | trash-only %s (/dct mattrash)",
        name, label, #rows, floor, MATERIAL_PCT_CEILING, trashOnly and "ON" or "off"))
    out("  %drop  level    npc  [excluded: reason]")
    local shown = 0
    for _, r in ipairs(rows) do
        shown = shown + 1
        if shown <= 40 then
            local why = {}
            if not r.lvl then why[#why + 1] = "no-level" end
            if r.rk and r.rk ~= 0 then why[#why + 1] = "rank" .. r.rk end
            if trashOnly and r.lvl and (r.rk == 0) and not (r.mn > 0 and r.mx > r.mn) then why[#why + 1] = "named" end
            if r.pct and r.pct >= MATERIAL_PCT_CEILING then why[#why + 1] = "noise%" end
            if r.pct and r.pct < floor then why[#why + 1] = "below-min" end
            local nm = getCachedSourceName(0, r.id) or ("npc " .. r.id)
            out(string.format("  %5s  L%d-%d  %s  %s",
                r.pct and string.format("%.1f%%", r.pct) or "  -  ", r.mn, r.mx, nm, table.concat(why, " ")))
        end
    end
    if #rows > 40 then out("  ... " .. (#rows - 40) .. " more") end
end

-- /dct prof [mining|herbalism|skinning] [on|off|override]: per-profession requirement display.
local function runProfCommand(key, action)
    ensureSettings()
    local out = function(m)
        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(m) else print(m) end
    end
    local labels = { mining = "Mining", herbalism = "Herbalism", skinning = "Skinning" }
    key = key and string.lower(key) or nil
    if not key or not labels[key] then
        out("|cff66ccffDCT|r profession skill display:")
        for _, k in ipairs({ "mining", "herbalism", "skinning" }) do
            local p = DropChanceTooltipDB.professions[k]
            out(string.format("  %s: enabled=%s override=%s", labels[k], tostring(p.enabled), tostring(p.showWithoutProfession)))
        end
        out("usage: /dct prof <mining|herbalism|skinning> on|off|override")
        return
    end
    local p = DropChanceTooltipDB.professions[key]
    action = action and string.lower(action) or "toggle"
    if action == "on" then p.enabled = true
    elseif action == "off" then p.enabled = false
    elseif action == "override" then p.showWithoutProfession = not p.showWithoutProfession
    else p.enabled = not p.enabled end
    if GameTooltip then GameTooltip.__dctNodeSig = nil; GameTooltip.__dctSkinSig = nil end
    out(string.format("|cff66ccffDCT|r %s: enabled=%s override=%s", labels[key], tostring(p.enabled), tostring(p.showWithoutProfession)))
end

local function installSlashCommands()
    SLASH_DROPCHANCETOOLTIP1 = "/dct"
    SLASH_DROPCHANCETOOLTIP2 = "/dc"
    SlashCmdList.DROPCHANCETOOLTIP = function(msg)
        local command = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")

        -- Word-split for subcommands that take arguments.
        local args = {}
        for w in string.gmatch(msg or "", "%S+") do args[#args + 1] = w end
        local sub = string.lower(args[1] or "")

        if sub == "prof" then
            runProfCommand(args[2], args[3])
            return
        end

        if sub == "npc" then
            runNpcDump(args[2])
            return
        end

        if sub == "gaps" then
            runGapsCommand(args[2])
            return
        end

        if sub == "count" then
            runCountCommand(args[2])
            return
        end

        if sub == "matdump" then
            runMatDump(args[2])
            return
        end

        if sub == "whoami" then
            runWhoAmI()
            return
        end

        if sub == "mattrash" then
            ensureSettings()
            DropChanceTooltipDB.materialTrashOnly = not DropChanceTooltipDB.materialTrashOnly
            if GameTooltip then GameTooltip.__dctSignature = nil end
            local msg = string.format("|cff66ccffDCT|r material trash-only = %s (exclude named/unique + elite/rare mobs from the range)",
                tostring(DropChanceTooltipDB.materialTrashOnly))
            if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
            return
        end

        if sub == "matmin" then
            ensureSettings()
            local n = tonumber(args[2])
            if n then
                DropChanceTooltipDB.materialMinPercent = math.max(0, math.min(n, 100))
                if GameTooltip then GameTooltip.__dctSignature = nil end
            end
            local msg = string.format("|cff66ccffDCT|r material min drop = %.0f%% (a mob must drop it this often to set the range/bands)", DropChanceTooltipDB.materialMinPercent)
            if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
            return
        end

        if sub == "materials" or sub == "mats" then
            ensureSettings()
            DropChanceTooltipDB.enableMaterialAggregation = not DropChanceTooltipDB.enableMaterialAggregation
            local msg = "|cff66ccffDCT|r material aggregation = " .. tostring(DropChanceTooltipDB.enableMaterialAggregation)
            if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then DEFAULT_CHAT_FRAME:AddMessage(msg) else print(msg) end
            if GameTooltip then GameTooltip.__dctSignature = nil end
            return
        end

        if sub == "various" then
            handleVariousCommand(args[2], args[3])
            return
        end

        if command == "debugchat" then
            debugEnabled = not debugEnabled
            if debugEnabled then
                debugPrint("Debug chat enabled")
                printDebugStatus()
            else
                if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Debug chat disabled")
                else
                    print("|cff66ccffDCT|r Debug chat disabled")
                end
            end
            return
        end

        if command == "diag" then
            runDiagnostics()
            return
        end

        if command == "toggle" then
            DropChanceTooltip_Toggle()
            return
        end

        if command == "on" then
            DropChanceTooltip_Toggle(true)
            return
        end

        if command == "off" then
            DropChanceTooltip_Toggle(false)
            return
        end

        if command == "settings" then
            openSettings()
            return
        end

        if command == "" then
            -- Bare /dct opens the options panel.
            openSettings()
            return
        end

        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | count | materials | matmin [%] | mattrash | matdump [id] | npc [id] | gaps [export|clear|test] | prof [mining|herbalism|skinning] | settings | debugchat | diag")
        else
            print(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            print("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | count | materials | matmin [%] | mattrash | matdump [id] | npc [id] | gaps [export|clear|test] | prof [mining|herbalism|skinning] | settings | debugchat | diag")
        end
    end
end

DropChanceTooltip:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then
            return
        end

        ensureSettings()
        installTooltipHooks()
        installMobDropIndex()
        installSlashCommands()
        registerSettingsPanel()
        return
    end

    if event == "QUEST_LOG_UPDATE" then
        questObjectivesDirty = true
        return
    end

    if event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        nudgeGapsExport("logout")
        return
    end

    if event == "ZONE_CHANGED_NEW_AREA" then
        nudgeGapsExport("zone")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        -- Bags aren't loaded yet at ENTERING_WORLD; snapshot a few seconds later once they are.
        if C_Timer and C_Timer.After then
            C_Timer.After(3, snapshotBags)
        else
            snapshotBags()
        end
        return
    end

    if event == "BAG_UPDATE_DELAYED" or event == "PLAYER_LOGOUT" then
        snapshotBags()   -- bags are loaded here; PLAYER_LOGOUT fires right before the SavedVariables flush
        return
    end

    if event == "BANKFRAME_OPENED" then
        _bankIsOpen = true
        snapshotBank()
        if C_Timer and C_Timer.After then C_Timer.After(1, snapshotBank) end  -- slots can populate late
        return
    end

    if event == "BANKFRAME_CLOSED" then
        _bankIsOpen = false
        return
    end

    if event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then
        snapshotBank()  -- no-op unless the bank is open
        return
    end

    if event == "MODIFIER_STATE_CHANGED" then
        local key = arg1
        if key ~= "LSHIFT" and key ~= "RSHIFT" then
            return
        end

        rerenderTooltip(GameTooltip)
        rerenderTooltip(ItemRefTooltip)
    end
end)
