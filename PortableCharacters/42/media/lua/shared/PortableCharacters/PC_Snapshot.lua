-- Portable Characters: reading a live player into plain data (capture, always on the player's own
-- game) and writing saved data onto a live player (apply, in single player or on the server).

require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Items"

local PC = PortableCharacters
local Items = PC.Items
local get, set = Items.get, Items.set

local Snapshot = {}
PC.Snapshot = Snapshot

local function round(value, places)
    local scale = 10 ^ (places or 3)
    return math.floor(value * scale + 0.5) / scale
end

-- Capture -------------------------------------------------------------------------------------

local function captureVisual(player)
    local visual = player:getHumanVisual()
    if not visual then
        return {}
    end
    local female = player:isFemale()
    local v = {
        skin = get(visual, "getSkinTextureIndex"),
        hair = get(visual, "getHairModel"),
        beard = get(visual, "getBeardModel"),
        bodyHair = get(visual, "getBodyHairIndex"),
        hairColor = Items.captureColor(get(visual, "getHairColor")),
        beardColor = Items.captureColor(get(visual, "getBeardColor")),
        naturalHair = Items.captureColor(get(visual, "getNaturalHairColor")),
        naturalBeard = Items.captureColor(get(visual, "getNaturalBeardColor")),
    }
    if female then
        v.hairStubble = get(visual, "hasBodyVisualFromItemType", "Base.F_Hair_Stubble") and true or false
    else
        v.hairStubble = get(visual, "hasBodyVisualFromItemType", "Base.M_Hair_Stubble") and true or false
        v.beardStubble = get(visual, "hasBodyVisualFromItemType", "Base.M_Beard_Stubble") and true or false
    end
    return v
end

-- The light part of a character: who they are, how they look, what they can do.
function Snapshot.capture(player)
    local desc = player:getDescriptor()
    local snap = { format = PC.FORMAT }

    snap.forename = desc:getForename()
    snap.surname = desc:getSurname()
    snap.female = player:isFemale() and true or false
    local profession = desc:getCharacterProfession()
    snap.profession = profession and tostring(profession) or nil
    snap.voice = {
        prefix = get(desc, "getVoicePrefix"),
        type = get(desc, "getVoiceType"),
        pitch = get(desc, "getVoicePitch"),
    }
    snap.visual = captureVisual(player)
    snap.outfit = PC.try(Items.captureOutfit, player) or {}

    snap.traits = {}
    local traits = player:getCharacterTraits():getKnownTraits()
    for i = 0, traits:size() - 1 do
        snap.traits[#snap.traits + 1] = tostring(traits:get(i))
    end

    snap.perks = {}
    local xp = player:getXp()
    for _, perk in ipairs(PC.allSkills()) do
        local entry = { l = player:getPerkLevel(perk), x = round(xp:getXP(perk), 2) }
        local boost = get(xp, "getPerkBoost", perk)
        if boost and boost ~= 0 then
            entry.b = boost
        end
        local multiplier = get(xp, "getMultiplier", perk)
        if multiplier and multiplier > 0 then
            entry.m = round(multiplier, 2)
        end
        snap.perks[perk:getId()] = entry
    end

    local nutrition = get(player, "getNutrition")
    if nutrition then
        snap.nutrition = {
            weight = round(get(nutrition, "getWeight") or 80, 2),
            calories = round(get(nutrition, "getCalories") or 0, 1),
            carbs = round(get(nutrition, "getCarbohydrates") or 0, 1),
            lipids = round(get(nutrition, "getLipids") or 0, 1),
            proteins = round(get(nutrition, "getProteins") or 0, 1),
        }
    end

    snap.kills = get(player, "getZombieKills") or 0
    snap.hours = round(get(player, "getHoursSurvived") or 0, 2)
    return snap
end

-- The heavy part, kept in its own file: recipes, books read and (optionally) carried items.
function Snapshot.captureData(player, worldId, withInventory)
    local data = { format = PC.FORMAT }
    data.recipes = {}
    local recipes = get(player, "getKnownRecipes")
    if recipes then
        for i = 0, recipes:size() - 1 do
            data.recipes[#data.recipes + 1] = tostring(recipes:get(i))
        end
    end
    data.books = {}
    local books = get(player, "getAlreadyReadBook")
    if books then
        for i = 0, books:size() - 1 do
            data.books[#data.books + 1] = tostring(books:get(i))
        end
    end
    if withInventory then
        data.inventory = Items.captureInventory(player, worldId)
    end
    return data
end

-- Apply ---------------------------------------------------------------------------------------

local function applyTraits(player, wanted)
    if type(wanted) ~= "table" then
        return
    end
    local traits = player:getCharacterTraits()
    local want = {}
    for _, id in ipairs(wanted) do
        want[id] = true
    end
    local current = {}
    local remove = {}
    local known = traits:getKnownTraits()
    for i = 0, known:size() - 1 do
        local trait = known:get(i)
        local id = tostring(trait)
        current[id] = true
        if not want[id] then
            remove[#remove + 1] = trait
        end
    end
    for _, trait in ipairs(remove) do
        pcall(function()
            traits:remove(trait)
            player:modifyTraitXPBoost(trait, true)
        end)
    end
    for _, id in ipairs(wanted) do
        if not current[id] then
            local trait = PC.findTrait(id)
            if trait then
                pcall(function()
                    traits:add(trait)
                    player:modifyTraitXPBoost(trait, false)
                end)
            end
        end
    end
end

-- The two levels a skill book would be helping with at this level (books come in pairs: 1-2, 3-4...).
local function bookRange(level)
    if level % 2 == 0 then
        return level + 1, level + 2
    end
    return level, level + 1
end

local function applyPerks(player, perks)
    if type(perks) ~= "table" then
        return
    end
    local xp = player:getXp()
    for id, entry in pairs(perks) do
        local perk = PC.try(function() return Perks.FromString(id) end)
        if perk and perk ~= Perks.None and type(entry) == "table" then
            local level = math.max(0, math.min(10, math.floor(entry.l or 0)))
            pcall(function()
                player:setPerkLevelDebug(perk, level)
                xp:setXPToLevel(perk, level)
            end)
            -- what was earned towards the next level
            if level < 10 and entry.x then
                pcall(function()
                    local base = perk:getTotalXpForLevel(level)
                    local nextLevel = perk:getTotalXpForLevel(level + 1)
                    local extra = math.min(entry.x - base, nextLevel - base - 0.1)
                    if extra > 0.01 then
                        xp:AddXP(perk, extra, false, false, false, false)
                    end
                end)
                -- AddXP may not level a skill up here; make sure the level is what was saved
                pcall(function()
                    if player:getPerkLevel(perk) ~= level then
                        player:setPerkLevelDebug(perk, level)
                        xp:setXPToLevel(perk, level)
                    end
                end)
            end
            if entry.b then
                set(xp, "setPerkBoost", perk, entry.b)
            end
            if entry.m and entry.m > 0 then
                local low, high = bookRange(level)
                set(xp, "addXpMultiplier", perk, entry.m, low, high)
            end
        end
    end
end

local function applyKnowledge(player, data)
    if type(data) ~= "table" then
        return
    end
    if type(data.recipes) == "table" then
        for _, name in ipairs(data.recipes) do
            pcall(function() player:learnRecipe(name) end)
        end
    end
    if type(data.books) == "table" then
        local read = get(player, "getAlreadyReadBook")
        if read then
            for _, name in ipairs(data.books) do
                pcall(function()
                    if not read:contains(name) then
                        read:add(name)
                    end
                end)
            end
        end
    end
end

local function applyNutrition(player, saved)
    local nutrition = get(player, "getNutrition")
    if not nutrition or type(saved) ~= "table" then
        return
    end
    if saved.weight then set(nutrition, "setWeight", saved.weight) end
    if saved.calories then set(nutrition, "setCalories", saved.calories) end
    if saved.carbs then set(nutrition, "setCarbohydrates", saved.carbs) end
    if saved.lipids then set(nutrition, "setLipids", saved.lipids) end
    if saved.proteins then set(nutrition, "setProteins", saved.proteins) end
end

-- Writes a saved character onto a live player.
--   snap  the light part (Snapshot.capture)
--   data  the heavy part (Snapshot.captureData), may be nil
--   opts  { inventory = true/false, counters = true/false, worldId = "..." }
-- Runs where the game keeps the real player: in single player, or on the server.
-- Returns a report: { items = n, missing = n, inventory = true/false }.
function Snapshot.apply(player, snap, data, opts)
    opts = opts or {}
    local report = { items = 0, missing = 0, inventory = false }
    if not player or type(snap) ~= "table" then
        return report
    end

    applyTraits(player, snap.traits)
    applyPerks(player, snap.perks)
    applyKnowledge(player, data)
    applyNutrition(player, snap.nutrition)

    if opts.counters then
        if snap.kills then set(player, "setZombieKills", snap.kills) end
        if snap.hours then set(player, "setHoursSurvived", snap.hours) end
    end

    if opts.inventory and type(data) == "table" and type(data.inventory) == "table" then
        Items.clear(player)
        local itemReport = Items.restoreInventory(player, data.inventory, opts.worldId)
        report.items = itemReport.items
        report.missing = itemReport.missing
        report.inventory = true
    end

    if isServer() then
        -- recipes, traits, books read (the server sends skills and stats by itself)
        pcall(function() sendSyncPlayerFields(player, 0x00000007) end)
        pcall(function() syncPlayerStats(player, -1) end)
    end
    return report
end

return Snapshot
