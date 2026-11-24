-- Portable Characters: the player's saved characters, in files under Zomboid/Lua/PortableCharacters.
--
--   roster.json       every character's light part (name, look, skills, traits) - what the
--                     character screen shows
--   data_<id>.json    one character's heavy part (recipes, books read, carried items)
--
-- The game gives Lua no way to delete a file, so a deleted character's data file is emptied.

if isServer() then return end

require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Json"

local PC = PortableCharacters
local Json = PC.Json

local Roster = {}
PC.Roster = Roster

local DIR = "PortableCharacters/"
local ROSTER_FILE = DIR .. "roster.json"

Roster.loaded = false
Roster.characters = {}      -- array, in file order
Roster.byId = {}

local function readFile(name)
    local reader = PC.try(function() return getFileReader(name, false) end)
    if not reader then
        return nil
    end
    local lines = {}
    while true do
        local line = reader:readLine()
        if line == nil then
            break
        end
        lines[#lines + 1] = line
    end
    reader:close()
    if #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

local function writeFile(name, text)
    local writer = PC.try(function() return getFileWriter(name, true, false) end)
    if not writer then
        PC.log("could not write " .. name)
        return false
    end
    writer:write(text)
    writer:close()
    return true
end

local function index()
    Roster.byId = {}
    for _, char in ipairs(Roster.characters) do
        Roster.byId[char.id] = char
    end
end

function Roster.load(force)
    if Roster.loaded and not force then
        return
    end
    Roster.loaded = true
    Roster.characters = {}
    local text = readFile(ROSTER_FILE)
    if text then
        local parsed, err = Json.decode(text)
        if type(parsed) == "table" and type(parsed.characters) == "table" then
            for _, char in ipairs(parsed.characters) do
                if type(char) == "table" and type(char.id) == "string" then
                    char.snap = type(char.snap) == "table" and char.snap or {}
                    char.rev = tonumber(char.rev) or 0
                    char.dead = char.dead and true or false
                    Roster.characters[#Roster.characters + 1] = char
                end
            end
        elseif err then
            -- Keep what is there: never overwrite a file that could not be read.
            PC.log("roster.json could not be read (" .. tostring(err) .. "); a copy is kept as roster_unreadable.json")
            writeFile(DIR .. "roster_unreadable.json", text)
        end
    end
    index()
end

function Roster.save()
    local text = Json.encode({ format = PC.FORMAT, version = PC.VERSION, characters = Roster.characters })
    return writeFile(ROSTER_FILE, text)
end

function Roster.get(id)
    Roster.load()
    if not id then
        return nil
    end
    return Roster.byId[id]
end

-- Living or dead characters, the one played last first.
function Roster.list(dead)
    Roster.load()
    local out = {}
    for _, char in ipairs(Roster.characters) do
        if (char.dead and true or false) == (dead and true or false) then
            out[#out + 1] = char
        end
    end
    table.sort(out, function(a, b)
        local left, right = a.lastPlayed or 0, b.lastPlayed or 0
        if left == right then
            return (a.created or 0) > (b.created or 0)
        end
        return left > right
    end)
    return out
end

function Roster.count(dead)
    return #Roster.list(dead)
end

local function newId()
    local id
    repeat
        id = "c" .. tostring(getTimestampMs()) .. tostring(ZombRand(1000, 9999))
    until not Roster.byId[id]
    return id
end

local function dataFile(id)
    return DIR .. "data_" .. id .. ".json"
end

function Roster.loadData(id)
    local text = readFile(dataFile(id))
    if not text then
        return {}
    end
    local parsed = Json.decode(text)
    if type(parsed) == "table" then
        return parsed
    end
    return {}
end

function Roster.saveData(id, data)
    return writeFile(dataFile(id), Json.encode(data or {}))
end

-- A character's name must be something; any number of words is fine.
function Roster.cleanLabel(label, fallback)
    label = tostring(label or "")
    label = string.gsub(label, "[%c]", " ")
    label = string.gsub(label, "^%s+", "")
    label = string.gsub(label, "%s+$", "")
    if #label > 60 then
        label = string.sub(label, 1, 60)
    end
    if label == "" then
        label = fallback or "Survivor"
    end
    return label
end

function Roster.create(label, snap, data)
    Roster.load()
    local now = getTimestamp()
    local fallback = nil
    if snap and snap.forename then
        fallback = Roster.cleanLabel((snap.forename or "") .. " " .. (snap.surname or ""), "Survivor")
    end
    local char = {
        id = newId(),
        label = Roster.cleanLabel(label, fallback),
        dead = false,
        rev = 1,
        created = now,
        lastPlayed = now,
        snap = snap or {},
    }
    Roster.characters[#Roster.characters + 1] = char
    index()
    Roster.saveData(char.id, data)
    Roster.save()
    return char
end

-- A newer state of a character. Gives the new revision number.
function Roster.update(id, snap, data)
    local char = Roster.get(id)
    if not char then
        return nil
    end
    char.snap = snap or char.snap
    char.rev = (char.rev or 0) + 1
    char.lastPlayed = getTimestamp()
    if data then
        Roster.saveData(id, data)
    end
    Roster.save()
    return char.rev
end

function Roster.rename(id, label)
    local char = Roster.get(id)
    if not char then
        return false
    end
    char.label = Roster.cleanLabel(label, char.label)
    Roster.save()
    return true
end

function Roster.delete(id)
    local char = Roster.get(id)
    if not char then
        return false
    end
    for i, other in ipairs(Roster.characters) do
        if other.id == id then
            table.remove(Roster.characters, i)
            break
        end
    end
    index()
    Roster.saveData(id, {})
    Roster.save()
    return true
end

function Roster.markDead(id, death)
    local char = Roster.get(id)
    if not char then
        return false
    end
    char.dead = true
    char.death = death or {}
    Roster.save()
    return true
end

function Roster.markAlive(id)
    local char = Roster.get(id)
    if not char then
        return false
    end
    char.dead = false
    Roster.save()
    return true
end

return Roster
