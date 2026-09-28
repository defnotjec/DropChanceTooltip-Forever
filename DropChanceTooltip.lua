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
local settingsWindow
local settingsPanel
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

local function renderMaterialAggregation(tooltip, agg, expanded)
    tooltip:AddLine(" ")
    if agg.kind == "alchemy" or agg.kind == "minebar" then
        local label = (agg.kind == "minebar") and "Smelted" or "Crafted"
        tooltip:AddDoubleLine(label, agg.skill and (agg.prof .. " " .. agg.skill) or agg.prof, 1, 0.82, 0, 1, 1, 1)
        if expanded and agg.reagents and #agg.reagents > 0 then
            for _, r in ipairs(agg.reagents) do
                tooltip:AddDoubleLine("  " .. tostring(r.name or r[1]), "x" .. tostring(r.count or r[2] or 1), 1, 1, 1, 0.8, 0.8, 0.8)
            end
        end
        return
    end
    if agg.kind == "leatherrange" then
        local rng = (agg.min and agg.max and agg.min ~= agg.max) and (agg.min .. "-" .. agg.max)
            or tostring(agg.min or agg.max or "?")
        tooltip:AddDoubleLine(agg.prof or "Skinning", agg.label .. " " .. rng, 1, 0.82, 0, 1, 1, 1)
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
                    local dc = GetQuestDifficultyColor and GetQuestDifficultyColor(lvl[2])
                    local r, g, b = (dc and dc.r) or 1, (dc and dc.g) or 0.82, (dc and dc.b) or 0
                    tooltip:AddDoubleLine("  " .. zone, lvl[1] .. "-" .. lvl[2], 0.8, 0.8, 0.8, r, g, b)
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
    local rangeText = (lo and hi) and (agg.label .. " " .. lo .. "-" .. hi) or agg.label
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
            tooltip:AddDoubleLine(string.format("  %d-%d", b, btop), right, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
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
        end)

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


local function createSettingsWindow()
    if settingsWindow then
        return settingsWindow
    end

    local frame = CreateFrame("Frame", "DropChanceTooltipSettingsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    frame:SetSize(460, 250)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(0, 0, 0, 0.9)
    end

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("DropChanceTooltip Settings")

    local itemSubtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemSubtitle:SetPoint("TOPLEFT", 16, -42)
    itemSubtitle:SetText("Item tooltips: show rarities")

    local itemFilterCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    itemFilterCheck:SetPoint("TOPLEFT", itemSubtitle, "BOTTOMLEFT", 0, -4)
    setCheckButtonLabel(itemFilterCheck, "Enable rarity filter")
    itemFilterCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.enableItemRarityFilter = self:GetChecked() and true or false
    end)
    frame.itemFilterCheck = itemFilterCheck

    local mobSubtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mobSubtitle:SetPoint("TOPLEFT", 152, -42)
    mobSubtitle:SetText("Mob tooltips: show rarities")

    local mobFilterCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    mobFilterCheck:SetPoint("TOPLEFT", mobSubtitle, "BOTTOMLEFT", 0, -4)
    setCheckButtonLabel(mobFilterCheck, "Enable rarity filter")
    mobFilterCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.enableMobRarityFilter = self:GetChecked() and true or false
    end)
    frame.mobFilterCheck = mobFilterCheck

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", -4, -4)

    frame.itemCheckboxes = {}
    frame.mobCheckboxes = {}
    local previousItem
    local previousMob
    for i = 1, #rarityOrder do
        local rarity = rarityOrder[i]
        local itemCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        itemCheck.rarity = rarity

        local itemLabel = itemCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        itemLabel:SetPoint("LEFT", itemCheck, "RIGHT", 2, 1)
        itemLabel:SetText(rarityLabels[rarity] or string.format("Rarity %d", rarity))
        if not previousItem then
            -- Indent the rarity rows so they read as children of the Enable toggle above.
            itemCheck:SetPoint("TOPLEFT", itemFilterCheck, "BOTTOMLEFT", 16, -8)
        else
            itemCheck:SetPoint("TOPLEFT", previousItem, "BOTTOMLEFT", 0, -4)
        end

        itemCheck:SetScript("OnClick", function(self)
            ensureSettings()
            DropChanceTooltipDB.showItemByRarity[self.rarity] = self:GetChecked() and true or false
            clearTooltipState(GameTooltip)
            clearTooltipState(ItemRefTooltip)
            if GameTooltip and GameTooltip:IsShown() then
                GameTooltip:Hide()
            end
            if ItemRefTooltip and ItemRefTooltip:IsShown() then
                ItemRefTooltip:Hide()
            end
        end)

        frame.itemCheckboxes[rarity] = itemCheck
        previousItem = itemCheck

        local mobCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
        mobCheck.rarity = rarity

        local mobLabel = mobCheck:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mobLabel:SetPoint("LEFT", mobCheck, "RIGHT", 2, 1)
        mobLabel:SetText(rarityLabels[rarity] or string.format("Rarity %d", rarity))
        if not previousMob then
            mobCheck:SetPoint("TOPLEFT", mobFilterCheck, "BOTTOMLEFT", 16, -8)
        else
            mobCheck:SetPoint("TOPLEFT", previousMob, "BOTTOMLEFT", 0, -4)
        end

        mobCheck:SetScript("OnClick", function(self)
            ensureSettings()
            DropChanceTooltipDB.showMobByRarity[self.rarity] = self:GetChecked() and true or false
            clearTooltipState(GameTooltip)
            clearTooltipState(ItemRefTooltip)
            if GameTooltip and GameTooltip:IsShown() then
                GameTooltip:Hide()
            end
            if ItemRefTooltip and ItemRefTooltip:IsShown() then
                ItemRefTooltip:Hide()
            end
        end)

        frame.mobCheckboxes[rarity] = mobCheck
        previousMob = mobCheck
    end

    settingsWindow = frame
    return frame
end

local function openSettingsWindow()
    ensureSettings()

    local frame = createSettingsWindow()
    for i = 1, #rarityOrder do
        local rarity = rarityOrder[i]
        local itemCheck = frame.itemCheckboxes and frame.itemCheckboxes[rarity]
        if itemCheck then
            itemCheck:SetChecked(DropChanceTooltipDB.showItemByRarity[rarity] == true)
        end

        local mobCheck = frame.mobCheckboxes and frame.mobCheckboxes[rarity]
        if mobCheck then
            mobCheck:SetChecked(DropChanceTooltipDB.showMobByRarity[rarity] == true)
        end
    end

    if frame.itemFilterCheck then
        frame.itemFilterCheck:SetChecked(DropChanceTooltipDB.enableItemRarityFilter == true)
    end
    if frame.mobFilterCheck then
        frame.mobFilterCheck:SetChecked(DropChanceTooltipDB.enableMobRarityFilter == true)
    end

    frame:Show()
end

local function createSettingsPanel()
    if settingsPanel then
        return settingsPanel
    end

    local panel = CreateFrame("Frame", "DropChanceTooltipInterfaceOptions")
    panel.name = "DropChanceTooltip"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("DropChanceTooltip")

    local itemSubtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    itemSubtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    itemSubtitle:SetText("Item tooltips: show rarities")

    local itemFilterCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    itemFilterCheck:SetPoint("TOPLEFT", itemSubtitle, "BOTTOMLEFT", 0, -2)
    setCheckButtonLabel(itemFilterCheck, "Enable rarity filter")
    itemFilterCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.enableItemRarityFilter = self:GetChecked() and true or false
    end)
    panel.itemFilterCheck = itemFilterCheck

    local mobSubtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    mobSubtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 220, -8)
    mobSubtitle:SetText("Mob tooltips: show rarities")

    local mobFilterCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    mobFilterCheck:SetPoint("TOPLEFT", mobSubtitle, "BOTTOMLEFT", 0, -2)
    setCheckButtonLabel(mobFilterCheck, "Enable rarity filter")
    mobFilterCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.enableMobRarityFilter = self:GetChecked() and true or false
    end)
    panel.mobFilterCheck = mobFilterCheck

    panel.itemCheckboxes = {}
    panel.mobCheckboxes = {}
    local previousItem
    local previousMob
    for i = 1, #rarityOrder do
        local rarity = rarityOrder[i]
        local itemCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        itemCheck.rarity = rarity
        setCheckButtonLabel(itemCheck, rarityLabels[rarity] or string.format("Rarity %d", rarity))

        if not previousItem then
            -- Indent the rarity rows so they read as children of the Enable toggle above.
            itemCheck:SetPoint("TOPLEFT", itemFilterCheck, "BOTTOMLEFT", 16, -8)
        else
            itemCheck:SetPoint("TOPLEFT", previousItem, "BOTTOMLEFT", 0, -4)
        end

        itemCheck:SetScript("OnClick", function(self)
            ensureSettings()
            DropChanceTooltipDB.showItemByRarity[self.rarity] = self:GetChecked() and true or false
        end)

        panel.itemCheckboxes[rarity] = itemCheck
        previousItem = itemCheck

        local mobCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        mobCheck.rarity = rarity
        setCheckButtonLabel(mobCheck, rarityLabels[rarity] or string.format("Rarity %d", rarity))

        if not previousMob then
            mobCheck:SetPoint("TOPLEFT", mobFilterCheck, "BOTTOMLEFT", 16, -8)
        else
            mobCheck:SetPoint("TOPLEFT", previousMob, "BOTTOMLEFT", 0, -4)
        end

        mobCheck:SetScript("OnClick", function(self)
            ensureSettings()
            DropChanceTooltipDB.showMobByRarity[self.rarity] = self:GetChecked() and true or false
        end)

        panel.mobCheckboxes[rarity] = mobCheck
        previousMob = mobCheck
    end

    -- ---- Item tooltip: owned counts (self + alts), below the item-rarity column -----------------
    local countSubtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    countSubtitle:SetPoint("TOPLEFT", previousItem, "BOTTOMLEFT", -16, -14)
    countSubtitle:SetText("Item tooltip: owned counts")

    panel.countChecks = {}
    local countSpec = {
        { key = "showSelfBags", label = "Your bags" },
        { key = "showSelfBank", label = "Your bank" },
        { key = "showAltsBags", label = "Alts' bags" },
        { key = "showAltsBank", label = "Alts' bank" },
        { key = "countConsolidated", label = "Consolidated total (n bags, n bank)" },
        { key = "countIncludeAlts", label = "Include alts in total", indent = true },
    }
    -- "Include alts in total" only applies to the consolidated total, so it's disabled unless
    -- Consolidated is checked.
    local function syncIncludeAlts()
        local ia = panel.countChecks.countIncludeAlts
        if ia then ia:SetEnabled(DropChanceTooltipDB.countConsolidated == true) end
    end
    panel.syncIncludeAlts = syncIncludeAlts

    local prevCount
    for _, spec in ipairs(countSpec) do
        local check = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        check.dbKey = spec.key
        setCheckButtonLabel(check, spec.label)
        if not prevCount then
            check:SetPoint("TOPLEFT", countSubtitle, "BOTTOMLEFT", 16, -6)
        else
            check:SetPoint("TOPLEFT", prevCount, "BOTTOMLEFT", spec.indent and 12 or 0, -4)
        end
        check:SetScript("OnClick", function(self)
            ensureSettings()
            DropChanceTooltipDB[self.dbKey] = self:GetChecked() and true or false
            if self.dbKey == "countConsolidated" then syncIncludeAlts() end
        end)
        panel.countChecks[spec.key] = check
        prevCount = check
    end
    syncIncludeAlts()

    -- ---- Mob tooltip: "various X" groups + drop-chance floor (third column) ------------------
    local variousSubtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    variousSubtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 400, -8)
    variousSubtitle:SetText("Mob tooltips: groups")

    local questAlwaysCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    questAlwaysCheck:SetPoint("TOPLEFT", variousSubtitle, "BOTTOMLEFT", 0, -6)
    setCheckButtonLabel(questAlwaysCheck, "Always show quest items")
    questAlwaysCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.alwaysShowQuestItems = self:GetChecked() and true or false
    end)
    panel.questAlwaysCheck = questAlwaysCheck

    local expandAllCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    expandAllCheck:SetPoint("TOPLEFT", questAlwaysCheck, "BOTTOMLEFT", 0, -6)
    setCheckButtonLabel(expandAllCheck, "Expand all groups")
    expandAllCheck:SetScript("OnClick", function(self)
        ensureSettings()
        DropChanceTooltipDB.expandAllVarious = self:GetChecked() and true or false
    end)
    panel.expandAllCheck = expandAllCheck

    -- Per-group: Show (off = hidden) + Expand (on = list individually, off = collapse to one line).
    -- Indented under Expand-all to read as its detail rows.
    panel.groupShow = {}
    panel.groupExpand = {}
    local prevGroup
    for _, key in ipairs(GROUP_ORDER) do
        local shortLabel = GROUP_META[key].label:gsub("^Various ", "")
        local showCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        showCheck.groupKey = key
        setCheckButtonLabel(showCheck, shortLabel)
        if not prevGroup then
            showCheck:SetPoint("TOPLEFT", expandAllCheck, "BOTTOMLEFT", 16, -6)
        else
            showCheck:SetPoint("TOPLEFT", prevGroup, "BOTTOMLEFT", 0, -4)
        end

        local expandCheck = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
        expandCheck.groupKey = key
        setCheckButtonLabel(expandCheck, "exp")
        expandCheck:SetPoint("LEFT", showCheck, "LEFT", 140, 0)

        local function writeMode()
            ensureSettings()
            if not showCheck:GetChecked() then
                DropChanceTooltipDB.variousMode[key] = "hidden"
            elseif expandCheck:GetChecked() then
                DropChanceTooltipDB.variousMode[key] = "expand"
            else
                DropChanceTooltipDB.variousMode[key] = "collapse"
            end
            expandCheck:SetEnabled(showCheck:GetChecked())
        end
        showCheck:SetScript("OnClick", writeMode)
        expandCheck:SetScript("OnClick", writeMode)

        panel.groupShow[key] = showCheck
        panel.groupExpand[key] = expandCheck
        prevGroup = showCheck
    end

    -- Drop-chance floor slider at the BOTTOM of the column (below the group rows).
    local threshold = CreateFrame("Slider", "DCTThresholdSlider", panel, "OptionsSliderTemplate")
    threshold:SetPoint("TOPLEFT", prevGroup, "BOTTOMLEFT", -16, -28)
    threshold:SetWidth(180)
    threshold:SetMinMaxValues(0, 5)
    threshold:SetValueStep(0.25)
    if threshold.SetObeyStepOnDrag then threshold:SetObeyStepOnDrag(true) end
    _G[threshold:GetName() .. "Low"]:SetText("0%")
    _G[threshold:GetName() .. "High"]:SetText("5%")
    threshold:SetScript("OnValueChanged", function(self, value)
        ensureSettings()
        value = math.floor(value * 4 + 0.5) / 4
        DropChanceTooltipDB.minDropChancePercent = value
        _G[self:GetName() .. "Text"]:SetText(string.format("Min drop chance: %.2f%%", value))
    end)
    panel.thresholdSlider = threshold

    local function refreshSettingsPanelState()
        ensureSettings()
        for i = 1, #rarityOrder do
            local rarity = rarityOrder[i]
            local itemCheck = panel.itemCheckboxes and panel.itemCheckboxes[rarity]
            if itemCheck then
                itemCheck:SetChecked(DropChanceTooltipDB.showItemByRarity[rarity] == true)
            end

            local mobCheck = panel.mobCheckboxes and panel.mobCheckboxes[rarity]
            if mobCheck then
                mobCheck:SetChecked(DropChanceTooltipDB.showMobByRarity[rarity] == true)
            end
        end

        if panel.itemFilterCheck then
            panel.itemFilterCheck:SetChecked(DropChanceTooltipDB.enableItemRarityFilter == true)
        end
        if panel.mobFilterCheck then
            panel.mobFilterCheck:SetChecked(DropChanceTooltipDB.enableMobRarityFilter == true)
        end

        if panel.thresholdSlider then
            local v = tonumber(DropChanceTooltipDB.minDropChancePercent) or 1.0
            panel.thresholdSlider:SetValue(v)
            _G[panel.thresholdSlider:GetName() .. "Text"]:SetText(string.format("Min drop chance: %.2f%%", v))
        end
        if panel.expandAllCheck then
            panel.expandAllCheck:SetChecked(DropChanceTooltipDB.expandAllVarious == true)
        end
        if panel.questAlwaysCheck then
            panel.questAlwaysCheck:SetChecked(DropChanceTooltipDB.alwaysShowQuestItems == true)
        end
        if panel.countChecks then
            for key, check in pairs(panel.countChecks) do
                check:SetChecked(DropChanceTooltipDB[key] == true)
            end
            if panel.syncIncludeAlts then panel.syncIncludeAlts() end
        end
        for _, key in ipairs(GROUP_ORDER) do
            local mode = DropChanceTooltipDB.variousMode[key] or "collapse"
            local showCheck = panel.groupShow[key]
            local expandCheck = panel.groupExpand[key]
            if showCheck then showCheck:SetChecked(mode ~= "hidden") end
            if expandCheck then
                expandCheck:SetChecked(mode == "expand")
                expandCheck:SetEnabled(mode ~= "hidden")
            end
        end
    end

    panel.refresh = refreshSettingsPanelState
    panel:SetScript("OnShow", refreshSettingsPanelState)

    settingsPanel = panel
    return panel
end

local function registerSettingsPanel()
    local panel = createSettingsPanel()

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        -- Keep the category object and its REAL id (do NOT overwrite category.ID -- that desyncs it
        -- from Settings' internal registry and breaks Settings.OpenToCategory).
        settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "DropChanceTooltip")
        Settings.RegisterAddOnCategory(settingsCategory)
        settingsCategoryID = (settingsCategory.GetID and settingsCategory:GetID()) or settingsCategory.ID
        return
    end

    if type(InterfaceOptions_AddCategory) == "function" then
        InterfaceOptions_AddCategory(panel)
    end
end

-- Open the options panel reliably across client variants.
local function openSettings()
    createSettingsPanel()
    if Settings and Settings.OpenToCategory and settingsCategoryID then
        Settings.OpenToCategory(settingsCategoryID)
        return
    end
    if InterfaceOptionsFrame_OpenToCategory then
        local panel = createSettingsPanel()
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel) -- twice: Blizzard bug workaround
        return
    end
    openSettingsWindow()
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

local function installSlashCommands()
    SLASH_DROPCHANCETOOLTIP1 = "/dct"
    SLASH_DROPCHANCETOOLTIP2 = "/dc"
    SlashCmdList.DROPCHANCETOOLTIP = function(msg)
        local command = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")

        -- Word-split for subcommands that take arguments.
        local args = {}
        for w in string.gmatch(msg or "", "%S+") do args[#args + 1] = w end
        local sub = string.lower(args[1] or "")

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
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | count | materials | matmin [%] | mattrash | matdump [id] | npc [id] | gaps [export|clear|test] | settings | debugchat | diag")
        else
            print(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            print("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | count | materials | matmin [%] | mattrash | matdump [id] | npc [id] | gaps [export|clear|test] | settings | debugchat | diag")
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
