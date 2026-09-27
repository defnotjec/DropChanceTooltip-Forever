local ADDON_NAME = ...

-- Forever/modern clients removed the global GetItemInfo in favour of C_Item.GetItemInfo (same
-- return signature). Bind a local so every GetItemInfo(...) call in this file works on both.
local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)

local DropChanceTooltip = CreateFrame("Frame")
DropChanceTooltip:RegisterEvent("ADDON_LOADED")
DropChanceTooltip:RegisterEvent("MODIFIER_STATE_CHANGED")

local debugEnabled = false
local modernHooksInstalled = false
local settingsWindow
local settingsPanel
local settingsCategoryID

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

local rarityOrder = { 0, 1, 2, 3, 4, 5, 6, 7 }

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
    local provider = getLootDBProvider()
    if not provider then
        debugPrint("Mob lookup: LootDB provider missing")
        return nil
    end

    debugPrint(string.format("Mob lookup: fetching drops for npcID %d", npcID))
    local rawDrops = callMobDropGetter(provider, npcID)
    if not rawDrops then
        debugPrint(string.format("Mob lookup: provider returned no drops for npcID %d", npcID))
        return nil
    end

    local drops = normalizeMobDrops(rawDrops)
    debugPrint(string.format("Mob lookup: normalized %d drops for npcID %d", drops and #drops or 0, npcID))
    return drops
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

    local npcID = getNPCIDFromTooltip(tooltip)
    if not npcID then
        debugPrint("Mob tooltip hover: no npcID found")
        return
    end

    debugPrint(string.format("Mob tooltip hover: npcID=%d", npcID))

    local signature = string.format("mob:%d", npcID)
    if tooltip.__dctMobSignature == signature then
        return
    end

    local drops = getMobDrops(npcID)
    if not drops or #drops == 0 then
        debugPrint(string.format("Mob tooltip hover: no drops shown for npcID %d", npcID))
        tooltip.__dctMobSignature = signature
        return
    end

    debugPrint(string.format("Mob tooltip hover: displaying %d drops for npcID %d", #drops, npcID))

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
            itemCheck:SetPoint("TOPLEFT", itemFilterCheck, "BOTTOMLEFT", 0, -8)
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
            mobCheck:SetPoint("TOPLEFT", mobFilterCheck, "BOTTOMLEFT", 0, -8)
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
            itemCheck:SetPoint("TOPLEFT", itemFilterCheck, "BOTTOMLEFT", 0, -8)
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
            mobCheck:SetPoint("TOPLEFT", mobFilterCheck, "BOTTOMLEFT", 0, -8)
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
    end

    panel.refresh = refreshSettingsPanelState
    panel:SetScript("OnShow", refreshSettingsPanelState)

    settingsPanel = panel
    return panel
end

local function registerSettingsPanel()
    local panel = createSettingsPanel()

    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, "DropChanceTooltip")
        category.ID = "DropChanceTooltip"
        Settings.RegisterAddOnCategory(category)
        settingsCategoryID = category.ID
        return
    end

    if type(InterfaceOptions_AddCategory) == "function" then
        InterfaceOptions_AddCategory(panel)
    end
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
    out("Now hover an item and run /dct debugchat first to see per-hover logs.")
end

local function installSlashCommands()
    SLASH_DROPCHANCETOOLTIP1 = "/dct"
    SLASH_DROPCHANCETOOLTIP2 = "/dc"
    SlashCmdList.DROPCHANCETOOLTIP = function(msg)
        local command = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")

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
            if Settings and Settings.OpenToCategory then
                local categoryID = settingsCategoryID or "DropChanceTooltip"
                Settings.OpenToCategory(categoryID)
            elseif InterfaceOptionsFrame_OpenToCategory then
                local panel = createSettingsPanel()
                InterfaceOptionsFrame_OpenToCategory(panel)
                InterfaceOptionsFrame_OpenToCategory(panel)
            else
                openSettingsWindow()
            end
            return
        end

        if command == "" then
            if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
                DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Usage: /dct toggle | on | off | settings | debugchat")
            else
                print("|cff66ccffDCT|r Usage: /dct toggle | on | off | settings | debugchat")
            end
            return
        end

        if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffDCT|r Usage: /dct toggle | on | off | settings | debugchat")
        else
            print(string.format("|cff66ccffDCT|r Unknown command: %s", command))
            print("|cff66ccffDCT|r Usage: /dct toggle | on | off | settings | debugchat")
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
        installSlashCommands()
        registerSettingsPanel()
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
