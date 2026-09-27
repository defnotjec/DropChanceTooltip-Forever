local ADDON_NAME = ...

-- Forever/modern clients removed the global GetItemInfo in favour of C_Item.GetItemInfo (same
-- return signature). Bind a local so every GetItemInfo(...) call in this file works on both.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (C_Item and C_Item.GetItemInfoInstant)
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
    -- Ensure the whole DB loads so the index fills (also auto-starts on PLAYER_ENTERING_WORLD).
    if LootDBLua and LootDBLua.StartPreload then
        LootDBLua.StartPreload()
    end
end

local DropChanceTooltip = CreateFrame("Frame")
DropChanceTooltip:RegisterEvent("ADDON_LOADED")
DropChanceTooltip:RegisterEvent("MODIFIER_STATE_CHANGED")
DropChanceTooltip:RegisterEvent("QUEST_LOG_UPDATE")

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
    -- Per-group display for the collapsible "various X" categories: "collapse" | "expand" | "hidden".
    variousMode = {
        gems = "collapse", patterns = "collapse", schematics = "collapse",
        enchants = "collapse", recipes = "collapse", scrolls = "collapse", greens = "collapse",
    },
    expandAllVarious = false,  -- persistent "always expand every various group"
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

    return {
        itemID = itemID,
        chance = chance,
        quality = quality,
        name = raw.name or name,
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

    local sources = getSources(itemID)
    if not sources or #sources == 0 then
        debugPrint(string.format("addItem %d: no sources", itemID))
        tooltip.__dctSignature = signature
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
        local questShown = {}
        for _, drop in ipairs(buckets.quest) do
            if alwaysShow or isQuestDropRelevant(drop) then
                questShown[#questShown + 1] = drop
            end
        end
        if #questShown > 0 then
            tooltip:AddLine("Quest Items:", 1, 0.82, 0)
            for _, drop in ipairs(questShown) do
                tooltip:AddDoubleLine(getItemDisplayText(drop), chanceText(drop.chance), 1, 1, 1, 0.2, 1, 0.2)
            end
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

    if tooltip.__dctSignature or tooltip.__dctMobSignature then
        debugPrint("clearTooltipState: reset signatures")
    end
    tooltip.__dctSignature = nil
    tooltip.__dctMobSignature = nil
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
        local name = GetItemInfo(e.itemID) or "?"
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
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | npc [id] | settings | debugchat | diag")
        else
            print(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            print("|cff66ccffDCT|r Usage: /dct toggle|on|off | various | npc [id] | settings | debugchat | diag")
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

    if event == "MODIFIER_STATE_CHANGED" then
        local key = arg1
        if key ~= "LSHIFT" and key ~= "RSHIFT" then
            return
        end

        rerenderTooltip(GameTooltip)
        rerenderTooltip(ItemRefTooltip)
    end
end)
