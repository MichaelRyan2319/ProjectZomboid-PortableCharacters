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

-- Injuries ----------------------------------------------------------------------------------------
-- Every body part's wounds and treatment, and the zombie infection. A healthy part is left out.

-- A wound is a yes/no and a clock, and the game keeps them apart (a bandaged deep wound can be
-- "no" with time still on its clock), so both are saved as they are.
local PART_FLAGS = {
    -- saved name, read with
    { "sc", "scratched" },
    { "cut", "isCut" },
    { "dw", "deepWounded" },
    { "bit", "bitten" },
    { "bl", "bleeding" },
    { "st", "stitched" },
}

local PART_NUMBERS = {
    -- saved name, read with, set with: kept when above zero
    { "scT", "getScratchTime", "setScratchTime" },
    { "cutT", "getCutTime", "setCutTime" },
    { "dwT", "getDeepWoundTime", "setDeepWoundTime" },
    { "bitT", "getBiteTime", "setBiteTime" },
    { "blT", "getBleedingTime", "setBleedingTime" },
    { "stT", "getStitchTime", "setStitchTime" },
    { "frac", "getFractureTime", "setFractureTime" },
    { "burn", "getBurnTime", "setBurnTime" },
    { "wash", "getLastTimeBurnWash", "setLastTimeBurnWash" },
    { "wil", "getWoundInfectionLevel", "setWoundInfectionLevel" },
    { "alc", "getAlcoholLevel", "setAlcoholLevel" },
    { "pain", "getAdditionalPain", "setAdditionalPain" },
    { "stiff", "getStiffness", "setStiffness" },
    { "plantain", "getPlantainFactor", "setPlantainFactor" },
    { "garlic", "getGarlicFactor", "setGarlicFactor" },
    { "comfrey", "getComfreyFactor", "setComfreyFactor" },
}

local function captureBody(player)
    local damage = get(player, "getBodyDamage")
    if not damage then
        return nil
    end
    local body = { parts = {} }
    local parts = damage:getBodyParts()
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        local entry = {}
        local any = false
        for _, flag in ipairs(PART_FLAGS) do
            if get(part, flag[2]) then
                entry[flag[1]] = true
                any = true
            end
        end
        for _, number in ipairs(PART_NUMBERS) do
            local value = get(part, number[2])
            if value and value > 0 then
                entry[number[1]] = round(value, 3)
                any = true
            end
        end
        if get(part, "bandaged") then
            entry.ban = { life = round(get(part, "getBandageLife") or 0, 3), type = get(part, "getBandageType") }
            any = true
        end
        if get(part, "isSplint") then
            entry.spl = { factor = round(get(part, "getSplintFactor") or 0, 3), item = get(part, "getSplintItem") }
            any = true
        end
        if get(part, "haveGlass") then entry.glass = true any = true end
        if get(part, "haveBullet") then entry.bullet = true any = true end
        if get(part, "isNeedBurnWash") then entry.needWash = true any = true end
        if get(part, "isInfectedWound") then entry.wi = true any = true end
        if get(part, "IsInfected") then entry.inf = true any = true end
        if get(part, "IsFakeInfected") then entry.fake = true any = true end
        if get(part, "IsCauterized") then entry.caut = true any = true end
        if get(part, "IsBleedingStemmed") then entry.stem = true any = true end
        local health = get(part, "getHealth")
        if health and health < 99.9 then
            entry.hp = round(health, 2)
            any = true
        end
        if any then
            body.parts[tostring(i)] = entry
        end
    end
    body.health = round(get(damage, "getOverallBodyHealth") or 100, 2)
    -- The zombie infection. Its clock is the character's own hours survived, so what is kept is how
    -- far along it is. (Right after a save is loaded the game says "not infected" for a moment
    -- while the clock is already there, so the clock is what counts.)
    local infectionTime = get(damage, "getInfectionTime") or -1
    local duration = get(damage, "getInfectionMortalityDuration") or -1
    if get(damage, "isInfected") or (infectionTime >= 0 and duration > 0) then
        local nowHours = get(player, "getHoursSurvived") or 0
        if infectionTime < 0 then
            infectionTime = nowHours
        end
        body.infected = {
            elapsed = round(math.max(0, nowHours - infectionTime), 3),
            duration = round(duration, 3),
        }
    end
    if get(damage, "isIsFakeInfected") then
        body.fake = true
    end
    local stats = get(player, "getStats")
    if stats then
        pcall(function()
            body.infection = round(stats:get(CharacterStat.ZOMBIE_INFECTION), 3)
            body.fever = round(stats:get(CharacterStat.ZOMBIE_FEVER), 3)
        end)
    end
    return body
end

-- Puts every body part into the saved state (a part that was not saved is made whole).
local function applyBody(player, body)
    local damage = get(player, "getBodyDamage")
    if not damage or type(body) ~= "table" then
        return
    end
    local saved = type(body.parts) == "table" and body.parts or {}
    local parts = damage:getBodyParts()
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        local entry = saved[tostring(i)]
        set(part, "RestoreToFullHealth")
        if type(entry) ~= "table" then
            if (get(part, "getStiffness") or 0) > 0 then
                set(part, "setStiffness", 0)
            end
        else
            -- what leaves a wound behind first, then each wound as it was saved
            if entry.glass then set(part, "setHaveGlass", true) end
            if entry.bullet then set(part, "setHaveBullet", true, 0) end
            if entry.sc then set(part, "setScratched", true, false) end
            if entry.cut then set(part, "setCut", true) end
            if entry.bit then set(part, "SetBitten", true) end
            set(part, "setDeepWounded", entry.dw and true or false)
            set(part, "setStitched", entry.st and true or false)
            -- then every clock and level as it was saved (the calls above start their own)
            for _, number in ipairs(PART_NUMBERS) do
                if entry[number[1]] then
                    set(part, number[3], entry[number[1]])
                end
            end
            set(part, "setNeedBurnWash", entry.needWash and true or false)
            set(part, "setInfectedWound", entry.wi and true or false)
            -- treatment
            if type(entry.spl) == "table" then
                set(part, "setSplint", true, entry.spl.factor or 0)
                if entry.spl.item then set(part, "setSplintItem", entry.spl.item) end
            end
            if type(entry.ban) == "table" then
                set(part, "setBandaged", true, entry.ban.life or 0, (entry.alc or 0) > 0, entry.ban.type or "")
            end
            set(part, "SetCauterized", entry.caut and true or false)
            set(part, "SetBleedingStemmed", entry.stem and true or false)
            -- the wound setters start their own bleeding and infection; these are the saved ones
            set(part, "setBleeding", entry.bl and true or false)
            set(part, "setBleedingTime", entry.blT or 0)
            set(part, "SetInfected", entry.inf and true or false)
            set(part, "SetFakeInfected", entry.fake and true or false)
            if entry.hp then
                set(part, "SetHealth", entry.hp)
            end
        end
    end

    if body.health then
        set(damage, "setOverallBodyHealth", body.health)
    end
    if type(body.infected) == "table" then
        set(damage, "setInfected", true)
        set(damage, "setInfectionMortalityDuration", body.infected.duration or 0)
        local nowHours = get(player, "getHoursSurvived") or 0
        set(damage, "setInfectionTime", nowHours - (body.infected.elapsed or 0))
    else
        set(damage, "setInfected", false)
        set(damage, "setInfectionTime", -1)
    end
    set(damage, "setIsFakeInfected", body.fake and true or false)
    local stats = get(player, "getStats")
    if stats then
        pcall(function()
            stats:set(CharacterStat.ZOMBIE_INFECTION, body.infection or 0)
            stats:set(CharacterStat.ZOMBIE_FEVER, body.fever or 0)
        end)
    end

    if isServer() then
        for i = 0, parts:size() - 1 do
            local part = parts:get(i)
            pcall(function() syncBodyPart(part, 0xFFFFFFFFFFF) end)
        end
        -- infection time and length (0x8: the body's main fields)
        pcall(function() sendSyncPlayerFields(player, 0x00000008) end)
    end
end

Snapshot.captureBody = captureBody
Snapshot.applyBody = applyBody

-- A short account of a saved body, for the character screen: wounds, bitten, infected.
function Snapshot.condition(body)
    local out = { wounds = 0, bitten = false, infected = false }
    if type(body) ~= "table" then
        return out
    end
    for _, entry in pairs(body.parts or {}) do
        if type(entry) == "table" then
            if entry.sc or entry.scT or entry.cut or entry.cutT or entry.dw or entry.dwT or entry.bit
                    or entry.bitT or entry.frac or entry.burn or entry.glass or entry.bullet then
                out.wounds = out.wounds + 1
            end
            if entry.bit or entry.bitT then out.bitten = true end
        end
    end
    out.infected = (type(body.infected) == "table")
    return out
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
    snap.body = PC.try(captureBody, player)
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
--   opts  { inventory = true/false, counters = true/false, body = true/false, worldId = "..." }
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

    -- after the hours: an infection is timed against them
    if opts.body and type(snap.body) == "table" then
        pcall(applyBody, player, snap.body)
        report.body = true
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
