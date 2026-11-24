-- Portable Characters: shared core (runs on the client, the server and in single player).
--
-- A character is kept in files on the player's own PC, not in the world. The world still holds its
-- own copy of the player (the game needs one), linked to the saved character by an id in the
-- player's mod data. See PC_Client.lua for how the two are kept in step.

PortableCharacters = PortableCharacters or {}
local PC = PortableCharacters

PC.MOD = "PortableCharacters"
PC.VERSION = "1.0.0"
PC.FORMAT = 1            -- version of the saved character files
PC.LINK_KEY = "PortableCharacters"   -- key in the player's mod data: { id = "...", rev = n }
PC.DEBUG = false

function PC.log(msg)
    print("[PortableCharacters] " .. tostring(msg))
end

function PC.debug(msg)
    if PC.DEBUG then
        print("[PortableCharacters] (debug) " .. tostring(msg))
    end
end

-- Call fn(...) and give back its first result, or nil when it raised an error.
-- Reading and writing a character touches dozens of game calls; one of them failing (a renamed
-- method after a game update, an item from a missing mod) must not lose the rest.
function PC.try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    PC.debug("call failed: " .. tostring(result))
    return nil
end

function PC.isSinglePlayer()
    return not isClient() and not isServer()
end

-- The server owner's settings (sandbox options, page "Portable Characters").
local DEFAULTS = {
    AllowTransfer = true,
    TransferInventory = true,
    AllowRevive = false,
}

function PC.option(name)
    local value = nil
    pcall(function()
        local option = getSandboxOptions():getOptionByName(PC.MOD .. "." .. name)
        if option then
            value = option:getValue()
        end
    end)
    if value == nil and SandboxVars and SandboxVars[PC.MOD] then
        value = SandboxVars[PC.MOD][name]
    end
    if value == nil then
        value = DEFAULTS[name]
    end
    return value
end

function PC.options()
    return {
        AllowTransfer = PC.option("AllowTransfer") and true or false,
        TransferInventory = PC.option("TransferInventory") and true or false,
        AllowRevive = PC.option("AllowRevive") and true or false,
    }
end

-- Java lists (ArrayList and friends) as a Lua array.
function PC.listToTable(list)
    local out = {}
    if not list then
        return out
    end
    for i = 0, list:size() - 1 do
        out[#out + 1] = list:get(i)
    end
    return out
end

-- Every skill the game knows (not the category headings), in the game's own order.
function PC.allSkills()
    local out = {}
    local list = PerkFactory.PerkList
    for i = 0, list:size() - 1 do
        local perk = list:get(i)
        if perk:getParent() ~= Perks.None then
            out[#out + 1] = perk
        end
    end
    return out
end

function PC.findTrait(id)
    if not id then
        return nil
    end
    local found = PC.try(function()
        return CharacterTrait.get(ResourceLocation.of(id))
    end)
    if found then
        return found
    end
    -- An id written by another version of the game or the mod: look it up by name.
    local defs = CharacterTraitDefinition.getTraits()
    for i = 0, defs:size() - 1 do
        local trait = defs:get(i):getType()
        if tostring(trait) == id or trait:getName() == id then
            return trait
        end
    end
    return nil
end

function PC.findProfession(id)
    if not id then
        return nil
    end
    local found = PC.try(function()
        return CharacterProfession.get(ResourceLocation.of(id))
    end)
    if found then
        return found
    end
    local defs = CharacterProfessionDefinition.getProfessions()
    for i = 0, defs:size() - 1 do
        local prof = defs:get(i):getType()
        if tostring(prof) == id or prof:getName() == id then
            return prof
        end
    end
    return nil
end

-- The profession's and a trait's name as the player sees it.
function PC.professionLabel(id)
    local prof = PC.findProfession(id)
    if prof then
        local def = CharacterProfessionDefinition.getCharacterProfessionDefinition(prof)
        if def then
            return def:getUIName()
        end
    end
    return id or ""
end

function PC.traitLabel(id)
    local trait = PC.findTrait(id)
    if trait then
        local def = CharacterTraitDefinition.getCharacterTraitDefinition(trait)
        if def then
            return def:getLabel()
        end
    end
    return id or ""
end

function PC.totalLevel(snap)
    local total = 0
    if snap and snap.perks then
        for _, perk in pairs(snap.perks) do
            total = total + (perk.l or 0)
        end
    end
    return total
end

return PC
