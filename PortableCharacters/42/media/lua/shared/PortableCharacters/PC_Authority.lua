-- Portable Characters: the part that decides and does things to the real player.
-- In multiplayer it runs on the server (called from PC_Server.lua); in single player the player's
-- own game calls it directly. The server owner's settings are checked here, not on the client.

require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Snapshot"

local PC = PortableCharacters
local Authority = {}
PC.Authority = Authority

-- An id of this world, made once and saved with it. Keys remember which world they belong to.
function Authority.worldId()
    local id = nil
    pcall(function()
        local data = ModData.getOrCreate(PC.MOD)
        if not data.worldId then
            data.worldId = "w" .. tostring(getTimestampMs()) .. tostring(ZombRand(1000, 9999))
        end
        id = data.worldId
    end)
    return id or "unknown"
end

function Authority.getLink(player)
    local link = player:getModData()[PC.LINK_KEY]
    if type(link) == "table" and type(link.id) == "string" then
        return { id = link.id, rev = tonumber(link.rev) or 0 }
    end
    return nil
end

function Authority.setLink(player, id, rev)
    player:getModData()[PC.LINK_KEY] = { id = id, rev = tonumber(rev) or 0 }
end

function Authority.hello(player)
    return {
        link = Authority.getLink(player),
        worldId = Authority.worldId(),
        options = PC.options(),
        version = PC.VERSION,
        hours = PC.try(function() return player:getHoursSurvived() end) or 0,
    }
end

-- The player's game says which saved character this player is, and how new its copy is.
-- (The id may change: a player whose saved characters were lost gets a new one.)
function Authority.stamp(player, id, rev)
    if type(id) ~= "string" or id == "" or #id > 64 then
        return false
    end
    Authority.setLink(player, id, rev)
    return true
end

-- request = { mode = "transfer" | "revive" | "sync", id, rev, snap, data = { recipes, books, inventory } }
-- Gives { ok = true, report = ... } or { ok = false, reason = "..." }.
function Authority.apply(player, request)
    if type(request) ~= "table" or type(request.snap) ~= "table" or type(request.id) ~= "string" then
        return { ok = false, reason = "bad" }
    end
    if player:isDead() then
        return { ok = false, reason = "dead" }
    end
    local options = PC.options()
    local link = Authority.getLink(player)
    local mode = request.mode
    local rev = tonumber(request.rev) or 0

    if mode == "transfer" or mode == "revive" then
        -- only onto a player this world has just made
        if link then
            return { ok = false, reason = "linked" }
        end
        if not options.AllowTransfer then
            return { ok = false, reason = "transfer" }
        end
        if mode == "revive" and not options.AllowRevive then
            return { ok = false, reason = "revive" }
        end
    elseif mode == "sync" then
        -- the same character, played somewhere else in the meantime
        if not link or link.id ~= request.id then
            return { ok = false, reason = "link" }
        end
        if rev <= link.rev then
            return { ok = false, reason = "old" }
        end
        if not options.AllowTransfer then
            -- this world keeps its own copy as it is; just remember that the two have met
            Authority.setLink(player, request.id, rev)
            return { ok = true, kept = true, report = { items = 0, missing = 0, inventory = false } }
        end
    else
        return { ok = false, reason = "mode" }
    end

    local data = type(request.data) == "table" and request.data or {}
    -- a revived character's things stayed on its body
    local withInventory = options.TransferInventory and mode ~= "revive" and type(data.inventory) == "table"

    local report = PC.Snapshot.apply(player, request.snap, data, {
        inventory = withInventory,
        counters = true,
        body = (mode ~= "revive"),      -- injuries travel; a revived character comes back whole
        worldId = Authority.worldId(),
    })
    Authority.setLink(player, request.id, rev)
    PC.log(string.format("%s: %s of character %s (%d items, %d unknown here)",
        tostring(player:getUsername()), tostring(mode), tostring(request.id), report.items or 0, report.missing or 0))
    return { ok = true, report = report }
end

return Authority
