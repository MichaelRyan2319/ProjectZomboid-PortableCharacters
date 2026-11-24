-- Portable Characters: turning carried items into plain data and back.
--
-- The game has no call a mod can use to pack an item whole, so each kind of state is read and set
-- through the item's own methods. Every read and write goes through get()/set(), which do nothing
-- when a method is missing or fails: a game update that renames one costs that one detail only.

require "PortableCharacters/PC_Core"

local PC = PortableCharacters
local Items = {}
PC.Items = Items

local function get(obj, method, ...)
    local fn = obj[method]
    if not fn then
        return nil
    end
    local ok, value = pcall(fn, obj, ...)
    if ok then
        return value
    end
    return nil
end

local function set(obj, method, ...)
    local fn = obj[method]
    if not fn then
        return false
    end
    local ok = pcall(fn, obj, ...)
    return ok
end

Items.get = get
Items.set = set

local function round(value, places)
    local scale = 10 ^ (places or 3)
    return math.floor(value * scale + 0.5) / scale
end

local bloodPartsCache = nil
local function bloodParts()
    if bloodPartsCache then
        return bloodPartsCache
    end
    local parts = {}
    pcall(function()
        local max = BloodBodyPartType.MAX:index()
        for i = 0, max - 1 do
            parts[#parts + 1] = BloodBodyPartType.FromIndex(i)
        end
    end)
    bloodPartsCache = parts
    return parts
end

-- Keys belong to their world: a key, a key ring, or anything else with a lock number (a padlock)
-- only means something where its lock is. They never travel with a character.
function Items.isWorldTied(item)
    if not item then
        return false
    end
    if instanceof(item, "Key") or instanceof(item, "KeyRing") or get(item, "isKeyRing") then
        return true
    end
    local keyId = get(item, "getKeyId")
    return keyId ~= nil and keyId >= 0
end

-- Items that stay where they are: the ones the mod cannot rebuild from data (a carried animal)
-- and the ones tied to their world (keys). They are never saved, and never removed from a
-- character either (see Items.clear), so nothing is lost by a sync.
function Items.isSupported(item)
    if not item then
        return false
    end
    if instanceof(item, "AnimalInventoryItem") then
        return false
    end
    if Items.isWorldTied(item) then
        return false
    end
    -- the game's own stand-ins for wounds and bandages: it makes and removes those itself
    if get(item, "isHidden") then
        return false
    end
    local fullType = get(item, "getFullType")
    if not fullType or fullType == "" then
        return false
    end
    if string.find(fullType, "Corpse", 1, true) then
        return false
    end
    return true
end

-- Mod data: plain values and tables only.
local function copyPlain(value, depth)
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end
    if kind == "table" and depth < 6 then
        local out = {}
        local any = false
        for key, inner in pairs(value) do
            local keyKind = type(key)
            if keyKind == "string" or keyKind == "number" then
                local copy = copyPlain(inner, depth + 1)
                if copy ~= nil then
                    out[tostring(key)] = copy
                    any = true
                end
            end
        end
        if any then
            return out
        end
    end
    return nil
end

local function restorePlain(target, saved)
    for key, value in pairs(saved) do
        local realKey = key
        local asNumber = tonumber(key)
        if asNumber and tostring(asNumber) == key then
            realKey = asNumber
        end
        if type(value) == "table" then
            local inner = {}
            restorePlain(inner, value)
            target[realKey] = inner
        else
            target[realKey] = value
        end
    end
end

local function captureColor(color)
    if not color then
        return nil
    end
    local r = get(color, "getRedFloat")
    local g = get(color, "getGreenFloat")
    local b = get(color, "getBlueFloat")
    if r and g and b then
        return { round(r), round(g), round(b) }
    end
    return nil
end

Items.captureColor = captureColor

function Items.makeColor(rgb)
    if not rgb or not rgb[1] then
        return nil
    end
    return PC.try(function()
        return ImmutableColor.new(rgb[1], rgb[2], rgb[3], 1)
    end)
end

-- What a piece of clothing looks like: colour, texture, decal, holes, patches, blood and dirt.
local function captureVisual(item, out)
    local visual = get(item, "getVisual")
    if not visual then
        return
    end
    local v = {}
    v.tint = captureColor(get(visual, "getTint"))
    v.base = get(visual, "getBaseTexture")
    v.tex = get(visual, "getTextureChoice")
    local clothingItem = get(visual, "getClothingItem")
    if clothingItem then
        local decal = get(visual, "getDecal", clothingItem)
        if decal and decal ~= "" then
            v.decal = decal
        end
    end
    local parts = bloodParts()
    for index, part in ipairs(parts) do
        local entry = nil
        local hole = get(visual, "getHole", part)
        if hole and hole > 0 then
            entry = entry or {}
            entry.h = 1
        end
        local blood = get(visual, "getBlood", part)
        if blood and blood > 0.01 then
            entry = entry or {}
            entry.b = round(blood, 2)
        end
        local dirt = get(visual, "getDirt", part)
        if dirt and dirt > 0.01 then
            entry = entry or {}
            entry.d = round(dirt, 2)
        end
        local patch = get(item, "getPatchType", part)
        if patch then
            entry = entry or {}
            entry.p = get(patch, "getFabricType") or 1
        end
        if entry then
            v.parts = v.parts or {}
            v.parts[tostring(index - 1)] = entry
        end
    end
    out.vis = v
end

local function restoreVisual(item, saved)
    local visual = get(item, "getVisual")
    if not visual or not saved then
        return
    end
    if saved.base and saved.base >= 0 then
        set(visual, "setBaseTexture", saved.base)
    end
    if saved.tex and saved.tex >= 0 then
        set(visual, "setTextureChoice", saved.tex)
    end
    local tint = Items.makeColor(saved.tint)
    if tint then
        set(visual, "setTint", tint)
    end
    if saved.decal then
        set(visual, "setDecal", saved.decal)
    end
    if saved.parts then
        local parts = bloodParts()
        for key, entry in pairs(saved.parts) do
            local index = tonumber(key)
            local part = index and parts[index + 1]
            if part then
                if entry.p then
                    -- part, tailoring level, fabric (1 cotton, 2 denim, 3 leather), over a hole
                    set(item, "addPatchForSync", index, 5, entry.p, entry.h ~= nil)
                    if entry.p == 2 then
                        set(visual, "setDenimPatch", part)
                    elseif entry.p == 3 then
                        set(visual, "setLeatherPatch", part)
                    else
                        set(visual, "setBasicPatch", part)
                    end
                elseif entry.h then
                    set(visual, "setHole", part)
                end
                if entry.b then
                    set(visual, "setBlood", part, entry.b)
                end
                if entry.d then
                    set(visual, "setDirt", part, entry.d)
                end
            end
        end
    end
end

local function captureFluids(item, out)
    local container = get(item, "getFluidContainer")
    if not container then
        return
    end
    local fluids = {}
    local amount = get(container, "getAmount") or 0
    if amount > 0 then
        if get(container, "isMixture") then
            local all = PC.try(function() return Fluid.getAllFluids() end)
            if all then
                for i = 0, all:size() - 1 do
                    local fluid = all:get(i)
                    local part = get(container, "getSpecificFluidAmount", fluid)
                    if part and part > 0 then
                        fluids[#fluids + 1] = { f = get(fluid, "getFluidTypeString"), a = round(part) }
                    end
                end
            end
        end
        if #fluids == 0 then
            local primary = get(container, "getPrimaryFluid")
            local name = primary and get(primary, "getFluidTypeString")
            if name then
                fluids[#fluids + 1] = { f = name, a = round(amount) }
            end
        end
    end
    -- An empty list is kept on purpose: it says "this bottle is empty", where a new one is full.
    out.fluid = { list = fluids }
end

local function restoreFluids(item, saved)
    local container = get(item, "getFluidContainer")
    if not container or not saved then
        return
    end
    set(container, "Empty")
    for _, entry in ipairs(saved.list or {}) do
        if entry.f and entry.a then
            set(container, "addFluid", entry.f, entry.a)
        end
    end
end

local FOOD_NUMBERS = {
    { "hung", "getHungChange", "setHungChange" },
    { "thirst", "getThirstChange", "setThirstChange" },
    { "baseHung", "getBaseHunger", "setBaseHunger" },
    { "cal", "getCalories", "setCalories" },
    { "carb", "getCarbohydrates", "setCarbohydrates" },
    { "lip", "getLipids", "setLipids" },
    { "prot", "getProteins", "setProteins" },
    { "poison", "getPoisonPower", "setPoisonPower" },
    { "freeze", "getFreezingTime", "setFreezingTime" },
}

-- One item, and everything inside it, as plain data. Gives nil for an item that can't be saved.
function Items.capture(item, worldId)
    if not Items.isSupported(item) then
        return nil
    end
    local t = { t = item:getFullType() }

    local condition = get(item, "getCondition")
    local conditionMax = get(item, "getConditionMax")
    if condition and conditionMax and condition ~= conditionMax then
        t.c = condition
    end
    local repaired = get(item, "getHaveBeenRepaired")
    if repaired and repaired > 1 then
        t.rep = repaired
    end
    local timesRepaired = get(item, "getTimesRepaired")
    if timesRepaired and timesRepaired > 0 then
        t.trep = timesRepaired
    end
    if get(item, "isBroken") then
        t.broken = true
    end
    if get(item, "isCustomName") then
        t.n = get(item, "getName")
    end
    if get(item, "isFavorite") then
        t.fav = true
    end
    if get(item, "isActivated") then
        t.on = true
    end

    if get(item, "IsDrainable") then
        local uses = get(item, "getCurrentUsesFloat")
        if uses then
            t.uf = round(uses, 4)
        end
    else
        local maxUses = get(item, "getMaxUses")
        local uses = get(item, "getCurrentUses")
        if maxUses and uses and maxUses > 1 and uses ~= maxUses then
            t.u = uses
        end
    end

    local age = get(item, "getAge")
    if age and age > 0 then
        t.age = round(age, 2)
    end
    if get(item, "isCooked") then
        t.cooked = true
    end
    if get(item, "isBurnt") then
        t.burnt = true
    end

    local red, green, blue = get(item, "getColorRed"), get(item, "getColorGreen"), get(item, "getColorBlue")
    if red and green and blue and (red < 0.999 or green < 0.999 or blue < 0.999) then
        t.col = { round(red), round(green), round(blue) }
    end

    local maxAmmo = get(item, "getMaxAmmo")
    if maxAmmo and maxAmmo > 0 then
        t.ammo = get(item, "getCurrentAmmoCount") or 0
    end
    if get(item, "hasSharpness") then
        local sharpness = get(item, "getSharpness")
        if sharpness then
            t.sharp = round(sharpness)
        end
    end
    if get(item, "hasHeadCondition") then
        t.head = get(item, "getHeadCondition")
        local headRepairs = get(item, "getTimesHeadRepaired")
        if headRepairs and headRepairs > 0 then
            t.thr = headRepairs
        end
    end
    local wetness = get(item, "getWetness")
    if wetness and wetness > 0.5 then
        t.wet = round(wetness, 1)
    end
    local modelIndex = get(item, "getModelIndex")
    if modelIndex and modelIndex > 0 then
        t.model = modelIndex
    end

    if instanceof(item, "HandWeapon") then
        local w = {}
        if get(item, "isRoundChambered") then w.chamber = true end
        if get(item, "isSpentRoundChambered") then w.spent = true end
        if get(item, "isContainsClip") then w.clip = true end
        if get(item, "isJammed") then w.jam = true end
        local fireMode = get(item, "getFireMode")
        if fireMode and fireMode ~= "" then w.mode = fireMode end
        local parts = get(item, "getAllWeaponParts")
        if parts and parts:size() > 0 then
            w.parts = {}
            for i = 0, parts:size() - 1 do
                local partType = get(parts:get(i), "getFullType")
                if partType then
                    w.parts[#w.parts + 1] = partType
                end
            end
        end
        t.w = w
    end

    if instanceof(item, "Food") then
        local f = {}
        for _, field in ipairs(FOOD_NUMBERS) do
            local value = get(item, field[2])
            if value and value ~= 0 then
                f[field[1]] = round(value, 4)
            end
        end
        if get(item, "isRotten") then f.rotten = true end
        if get(item, "isFrozen") then f.frozen = true end
        if get(item, "isTainted") then f.tainted = true end
        -- only a weight somebody set by hand (the game works a food's weight out from what is left)
        if get(item, "isCustomWeight") then
            local weight = get(item, "getActualWeight")
            if weight then f.weight = round(weight, 4) end
        end
        t.f = f
    end

    if instanceof(item, "Literature") then
        local l = {}
        local pages = get(item, "getCustomPages")
        if pages then
            local asTable = PC.try(function() return transformIntoKahluaTable(pages) end)
            if asTable then
                for page, text in pairs(asTable) do
                    if type(text) == "string" and text ~= "" then
                        l.pages = l.pages or {}
                        l.pages[tostring(page)] = text
                    end
                end
            end
        end
        local lockedBy = get(item, "getLockedBy")
        if lockedBy and lockedBy ~= "" then l.lock = lockedBy end
        if l.pages or l.lock then
            t.lit = l
        end
    end

    if get(item, "IsClothing") or instanceof(item, "InventoryContainer") then
        captureVisual(item, t)
    end
    captureFluids(item, t)

    if get(item, "hasModData") then
        local data = get(item, "getModData")
        if data then
            t.md = copyPlain(data, 0)
        end
    end

    -- where the item sits on the hotbar
    local slot = get(item, "getAttachedSlot")
    if slot and slot >= 0 then
        t.slot = { i = slot, type = get(item, "getAttachedSlotType"), model = get(item, "getAttachedToModel") }
    end

    if instanceof(item, "InventoryContainer") then
        local inner = get(item, "getItemContainer")
        if inner then
            local list = inner:getItems()
            if list and list:size() > 0 then
                t.items = {}
                for i = 0, list:size() - 1 do
                    local child = Items.capture(list:get(i), worldId)
                    if child then
                        t.items[#t.items + 1] = child
                    end
                end
            end
        end
    end

    return t
end

-- Builds the item a saved entry describes. Gives nil when the game has no such item (a mod that
-- is not installed here). `report` counts what was made and what was missing.
function Items.restore(saved, worldId, report)
    if type(saved) ~= "table" or type(saved.t) ~= "string" then
        return nil
    end
    local item = PC.try(function() return instanceItem(saved.t) end)
    if not item then
        if report then
            report.missing = (report.missing or 0) + 1
        end
        return nil
    end
    -- a key saved by version 1.0.0, which still carried them: keys stay in their world now
    if saved.key or Items.isWorldTied(item) then
        return nil
    end
    if report then
        report.items = (report.items or 0) + 1
    end

    if saved.rep then set(item, "setHaveBeenRepaired", saved.rep) end
    if saved.trep then set(item, "setTimesRepaired", saved.trep) end
    if saved.n then
        set(item, "setName", saved.n)
        set(item, "setCustomName", true)
    end
    if saved.fav then set(item, "setFavorite", true) end
    if saved.uf then
        set(item, "setCurrentUsesFloat", saved.uf)
    elseif saved.u then
        set(item, "setCurrentUses", saved.u)
    end
    if saved.age then set(item, "setAge", saved.age) end
    if saved.cooked then set(item, "setCooked", true) end
    if saved.burnt then set(item, "setBurnt", true) end
    if saved.col then
        set(item, "setColorRed", saved.col[1])
        set(item, "setColorGreen", saved.col[2])
        set(item, "setColorBlue", saved.col[3])
        set(item, "setCustomColor", true)
    end
    if saved.ammo then set(item, "setCurrentAmmoCount", saved.ammo) end
    if saved.sharp then set(item, "setSharpness", saved.sharp) end
    if saved.head then set(item, "setHeadCondition", saved.head) end
    if saved.thr then set(item, "setTimesHeadRepaired", saved.thr) end
    if saved.wet then set(item, "setWetness", saved.wet) end
    if saved.model then set(item, "setModelIndex", saved.model) end

    if saved.w then
        local w = saved.w
        set(item, "setRoundChambered", w.chamber and true or false)
        set(item, "setSpentRoundChambered", w.spent and true or false)
        set(item, "setContainsClip", w.clip and true or false)
        if w.jam then set(item, "setJammed", true) end
        if w.mode then set(item, "setFireMode", w.mode) end
        if w.parts then
            for _, partType in ipairs(w.parts) do
                local part = PC.try(function() return instanceItem(partType) end)
                if part then
                    set(item, "attachWeaponPart", part)
                end
            end
        end
    end

    if saved.f then
        local f = saved.f
        for _, field in ipairs(FOOD_NUMBERS) do
            if f[field[1]] ~= nil then
                set(item, field[3], f[field[1]])
            end
        end
        if f.rotten then set(item, "setRotten", true) end
        if f.frozen then set(item, "setFrozen", true) end
        if f.tainted then set(item, "setTainted", true) end
        if f.weight then
            set(item, "setActualWeight", f.weight)
            set(item, "setCustomWeight", true)
        end
    end

    if saved.lit then
        if saved.lit.pages then
            for page, text in pairs(saved.lit.pages) do
                local number = tonumber(page)
                if number then
                    set(item, "addPage", number, text)
                end
            end
        end
        if saved.lit.lock then set(item, "setLockedBy", saved.lit.lock) end
    end

    restoreVisual(item, saved.vis)
    if saved.fluid then
        restoreFluids(item, saved.fluid)
    end

    if saved.md then
        local data = get(item, "getModData")
        if data then
            pcall(restorePlain, data, saved.md)
        end
    end

    if saved.slot then
        set(item, "setAttachedSlot", saved.slot.i)
        if saved.slot.type then set(item, "setAttachedSlotType", saved.slot.type) end
        if saved.slot.model then set(item, "setAttachedToModel", saved.slot.model) end
    end

    -- condition last: holes and patches change it on the way
    if saved.c then set(item, "setCondition", saved.c, false) end
    if saved.broken then set(item, "setBroken", true) end
    if saved.on then set(item, "setActivated", true) end

    if saved.items then
        local inner = get(item, "getItemContainer")
        if inner then
            for _, childSaved in ipairs(saved.items) do
                local child = Items.restore(childSaved, worldId, report)
                if child then
                    inner:AddItem(child)
                end
            end
        end
    end

    return item
end

local function locationName(location)
    if not location then
        return nil
    end
    return tostring(location)
end

local function findBodyLocation(name)
    if not name then
        return nil
    end
    return PC.try(function()
        return ItemBodyLocation.get(ResourceLocation.of(name))
    end)
end

Items.findBodyLocation = findBodyLocation

-- Everything the player carries: { items = {...} }, each top-level entry marked with where it is
-- worn ("worn"), attached ("att") or held ("hand": 1 primary, 2 secondary, 3 both).
function Items.captureInventory(player, worldId)
    local inventory = player:getInventory()
    local out = { items = {} }
    if not inventory then
        return out
    end

    local wornAt = {}
    local worn = player:getWornItems()
    if worn then
        for i = 0, worn:size() - 1 do
            local entry = worn:get(i)
            local item = entry and entry:getItem()
            if item then
                wornAt[item] = locationName(entry:getLocation())
            end
        end
    end
    local attachedAt = {}
    local attached = player:getAttachedItems()
    if attached then
        for i = 0, attached:size() - 1 do
            local entry = attached:get(i)
            local item = entry and entry:getItem()
            if item then
                attachedAt[item] = entry:getLocation()
            end
        end
    end
    local primary = player:getPrimaryHandItem()
    local secondary = player:getSecondaryHandItem()

    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        local saved = Items.capture(item, worldId)
        if saved then
            if wornAt[item] then saved.worn = wornAt[item] end
            if attachedAt[item] then saved.att = attachedAt[item] end
            local hand = 0
            if item == primary then hand = hand + 1 end
            if item == secondary then hand = hand + 2 end
            if hand > 0 then saved.hand = hand end
            out.items[#out.items + 1] = saved
        end
    end
    return out
end

-- The clothes a character is wearing, for the picture on the character screen.
function Items.captureOutfit(player)
    local out = {}
    local worn = player:getWornItems()
    if not worn then
        return out
    end
    for i = 0, worn:size() - 1 do
        local entry = worn:get(i)
        local item = entry and entry:getItem()
        if item and Items.isSupported(item) then
            local piece = { t = item:getFullType(), loc = locationName(entry:getLocation()) }
            local visual = get(item, "getVisual")
            if visual then
                piece.tint = captureColor(get(visual, "getTint"))
                piece.base = get(visual, "getBaseTexture")
                piece.tex = get(visual, "getTextureChoice")
            end
            out[#out + 1] = piece
        end
    end
    return out
end

-- Everything inside `container` (at any depth) that has to stay with this world, e.g. a key in a
-- bag that is about to be replaced.
local function collectTied(container, found)
    local list = container and container:getItems()
    if not list then
        return
    end
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if not Items.isSupported(item) then
            found[#found + 1] = { item = item, from = container }
        elseif instanceof(item, "InventoryContainer") then
            collectTied(get(item, "getItemContainer"), found)
        end
    end
end

-- Takes every item the mod could have saved off the player. On a server each removal is sent to
-- the clients. Keys and other things that stay are left alone; one that sat inside a bag that
-- goes is put into the player's main inventory.
function Items.clear(player)
    local inventory = player:getInventory()
    if not inventory then
        return
    end
    local server = isServer()
    local doomed = {}
    local list = inventory:getItems()
    for i = 0, list:size() - 1 do
        local item = list:get(i)
        if Items.isSupported(item) then
            doomed[#doomed + 1] = item
        end
    end
    for _, item in ipairs(doomed) do
        pcall(function()
            if player:getPrimaryHandItem() == item then player:setPrimaryHandItem(nil) end
            if player:getSecondaryHandItem() == item then player:setSecondaryHandItem(nil) end
        end)
        pcall(function() player:removeAttachedItem(item) end)
        pcall(function() player:removeWornItem(item, false) end)
        local staying = {}
        if instanceof(item, "InventoryContainer") then
            collectTied(get(item, "getItemContainer"), staying)
        end
        pcall(function()
            inventory:Remove(item)
            if server then
                sendRemoveItemFromContainer(inventory, item)
            end
        end)
        -- after the bag is gone (for the player's game too), hand back what stays
        for _, entry in ipairs(staying) do
            pcall(function()
                entry.from:Remove(entry.item)
                inventory:AddItem(entry.item)
                if server then
                    sendAddItemToContainer(inventory, entry.item)
                end
            end)
        end
    end
    if server then
        pcall(function() sendEquip(player) end)
    end
end

-- Gives the player the saved items. Returns a report: { items = n, missing = n }.
function Items.restoreInventory(player, saved, worldId)
    local report = { items = 0, missing = 0 }
    if type(saved) ~= "table" or type(saved.items) ~= "table" then
        return report
    end
    local inventory = player:getInventory()
    local server = isServer()
    local primary, secondary = nil, nil
    local equipChanged = false

    for _, entry in ipairs(saved.items) do
        local item = Items.restore(entry, worldId, report)
        if item then
            inventory:AddItem(item)
            if server then
                pcall(function() sendAddItemToContainer(inventory, item) end)
            end
            if entry.worn then
                local location = findBodyLocation(entry.worn) or get(item, "getBodyLocation") or get(item, "canBeEquipped")
                if location then
                    local ok = pcall(function() player:setWornItem(location, item) end)
                    if ok and server then
                        pcall(function() sendClothing(player, location, item) end)
                    end
                end
            end
            if entry.att then
                local ok = pcall(function() player:setAttachedItem(entry.att, item) end)
                if ok and server then
                    pcall(function() sendAttachedItem(player, entry.att, item) end)
                end
            end
            if entry.hand then
                if entry.hand == 1 or entry.hand == 3 then primary = item end
                if entry.hand == 2 or entry.hand == 3 then secondary = item end
            end
        end
    end

    if primary then
        pcall(function() player:setPrimaryHandItem(primary) end)
        equipChanged = true
    end
    if secondary then
        pcall(function() player:setSecondaryHandItem(secondary) end)
        equipChanged = true
    end
    if server then
        if equipChanged then
            pcall(function() sendEquip(player) end)
        end
        pcall(function() syncVisuals(player) end)
    else
        pcall(function() player:resetModelNextFrame() end)
    end
    pcall(function() inventory:setDrawDirty(true) end)
    return report
end

-- How many items an entry stands for, counting what is inside it.
function Items.count(entry)
    local n = 1
    if entry.items then
        for _, child in ipairs(entry.items) do
            n = n + Items.count(child)
        end
    end
    return n
end

return Items
