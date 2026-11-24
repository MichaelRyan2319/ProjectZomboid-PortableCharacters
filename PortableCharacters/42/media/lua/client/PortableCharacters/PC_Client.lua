-- Portable Characters: the player's own game. Keeps the saved character in step with the one in
-- the world: links them when a world is entered, saves every few minutes, and handles death.

if isServer() then return end

require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Json"
require "PortableCharacters/PC_Snapshot"
require "PortableCharacters/PC_Authority"
require "PortableCharacters/PC_Roster"

local PC = PortableCharacters
local Roster = PC.Roster
local Snapshot = PC.Snapshot
local Authority = PC.Authority

local Client = {}
PC.Client = Client

Client.SAVE_INTERVAL = 300      -- seconds between saves ("about every 5 minutes")
Client.ITEMS_PER_MESSAGE = 40
Client.LIST_PER_MESSAGE = 150

Client.active = nil             -- id of the saved character the local player is
Client.worldId = nil            -- this world's id, from the server (or the save)
Client.options = nil            -- the server owner's settings, as the server sees them
Client.busy = nil               -- a transfer under way: { id, mode, flow, at }
Client.gate = nil               -- after a multiplayer transfer: wait for the skills to arrive
Client.nextSave = 0
Client.start = nil              -- waiting to find out who the local player is

local function now()
    return getTimestamp()
end

local function localPlayer()
    return getSpecificPlayer(0)
end

function Client.worldName()
    local name = nil
    if isClient() then
        name = PC.try(function() return getServerName() end)
        if not name or name == "" then
            name = PC.try(function() return getServerIP() end)
        end
    else
        name = PC.try(function() return getWorld():getWorld() end)
    end
    return tostring(name or "")
end

function Client.say(player, text)
    if not player or not text or text == "" then return end
    PC.log(text)
    pcall(function() player:setHaloNote(text, 220, 220, 220, 400) end)
end

-- Link ------------------------------------------------------------------------------------------

-- Writes "this player is saved character <id>, as of revision <rev>" into the player's mod data.
-- In multiplayer the player's mod data belongs to the player's own game: nothing sends it either
-- way by itself, and transmitModData() replaces the server's copy with this one (the game's
-- hotbar does that too, which would wipe a link that only the server had set).
function Client.stamp(player, id, rev)
    if isClient() then
        pcall(Authority.setLink, player, id, rev)
        pcall(function() player:transmitModData() end)
        sendClientCommand(player, PC.MOD, "stamp", { id = id, rev = rev })
    else
        Authority.stamp(player, id, rev)
    end
end

function Client.activate(player, char)
    Client.active = char.id
    char.lastPlayed = now()
    char.lastWorld = Client.worldName()
    char.worldId = Client.worldId
    Roster.save()
    Client.nextSave = now() + Client.SAVE_INTERVAL
    PC.log("playing saved character '" .. tostring(char.label) .. "' (" .. char.id .. ", revision " .. tostring(char.rev) .. ")")
end

-- Makes a saved character out of the local player as it stands (a new character, or one from a
-- save made before the mod was installed).
function Client.register(player, flow, note)
    local snap = Snapshot.capture(player)
    local data = Snapshot.captureData(player, Client.worldId, true)
    local label = flow and flow.label or nil
    local char = Roster.create(label, snap, data)
    if flow and flow.outfitBuild then
        char.outfitBuild = flow.outfitBuild
    end
    Client.stamp(player, char.id, char.rev)
    Client.activate(player, char)
    if note then
        Client.say(player, note)
    end
    return char
end

-- Save ------------------------------------------------------------------------------------------

local function skillsArrived(player, snap)
    if type(snap) ~= "table" or type(snap.perks) ~= "table" then
        return true
    end
    for id, entry in pairs(snap.perks) do
        local perk = PC.try(function() return Perks.FromString(id) end)
        if perk and perk ~= Perks.None and type(entry) == "table" then
            if player:getPerkLevel(perk) < (entry.l or 0) then
                return false
            end
        end
    end
    return true
end

-- Writes the local player's present state to the saved character. Gives true when it did.
function Client.saveNow(reason)
    if not Client.active or Client.busy then
        return false
    end
    local player = localPlayer()
    if not player or player:isDead() then
        return false
    end
    local char = Roster.get(Client.active)
    if not char then
        return false
    end
    if Client.gate then
        -- The server has given this player a saved character's skills; they reach this game a
        -- moment later. Saving before that would write the unfinished state over the real one.
        if skillsArrived(player, Client.gate.snap) then
            Client.gate = nil
        elseif now() < Client.gate.untilTime then
            return false
        else
            PC.log("the transferred skills never arrived in full; the last good state is kept in backup_" .. char.id .. ".json")
            pcall(function()
                local writer = getFileWriter("PortableCharacters/backup_" .. char.id .. ".json", true, false)
                writer:write(PC.Json.encode(char))
                writer:close()
            end)
            Client.gate = nil
        end
    end

    local ok, err = pcall(function()
        local snap = Snapshot.capture(player)
        local data = Snapshot.captureData(player, Client.worldId, true)
        if char.outfitBuild and PC.Flow then
            char.outfitBuild = PC.Flow.refreshBuild(char.outfitBuild, snap)
        end
        char.lastWorld = Client.worldName()
        char.worldId = Client.worldId
        local rev = Roster.update(char.id, snap, data)
        Client.stamp(player, char.id, rev)
    end)
    if not ok then
        PC.log("save failed (" .. tostring(reason) .. "): " .. tostring(err))
        return false
    end
    Client.nextSave = now() + Client.SAVE_INTERVAL
    PC.debug("saved '" .. tostring(char.label) .. "' (" .. tostring(reason) .. ")")
    return true
end

-- Transfer --------------------------------------------------------------------------------------

local function sendInParts(player, request)
    local parts = 0
    sendClientCommand(player, PC.MOD, "applyBegin", {
        mode = request.mode,
        id = request.id,
        rev = request.rev,
        snap = request.snap,
        inventory = (request.data.inventory ~= nil),
    })
    local function sendList(kind, list)
        if type(list) ~= "table" then return end
        local batch = {}
        for _, value in ipairs(list) do
            batch[#batch + 1] = value
            if #batch >= Client.LIST_PER_MESSAGE then
                sendClientCommand(player, PC.MOD, "applyList", { kind = kind, list = batch })
                parts = parts + 1
                batch = {}
            end
        end
        if #batch > 0 then
            sendClientCommand(player, PC.MOD, "applyList", { kind = kind, list = batch })
            parts = parts + 1
        end
    end
    sendList("recipes", request.data.recipes)
    sendList("books", request.data.books)

    local inventory = request.data.inventory
    if inventory and type(inventory.items) == "table" then
        local batch, size = {}, 0
        for _, entry in ipairs(inventory.items) do
            local count = PC.Items.count(entry)
            if size > 0 and size + count > Client.ITEMS_PER_MESSAGE then
                sendClientCommand(player, PC.MOD, "applyItems", { items = batch })
                parts = parts + 1
                batch, size = {}, 0
            end
            batch[#batch + 1] = entry
            size = size + count
        end
        if #batch > 0 then
            sendClientCommand(player, PC.MOD, "applyItems", { items = batch })
            parts = parts + 1
        end
    end
    sendClientCommand(player, PC.MOD, "applyEnd", { parts = parts })
end

-- Puts a saved character onto the local player: "transfer" (into a new world), "revive" (a dead
-- character, without its things) or "sync" (a world it has been in before).
function Client.startApply(player, char, mode, flow)
    local data = Roster.loadData(char.id)
    if mode == "revive" then
        data.inventory = nil
    end
    local request = { mode = mode, id = char.id, rev = char.rev, snap = char.snap, data = data }
    Client.busy = { id = char.id, mode = mode, flow = flow, at = now() }
    PC.log(mode .. " of '" .. tostring(char.label) .. "' started")
    if isClient() then
        sendInParts(player, request)
    else
        local result = Authority.apply(player, request)
        result.id, result.rev, result.mode = char.id, char.rev, mode
        Client.onApplied(result)
    end
end

function Client.refreshUI(player)
    pcall(function() player:resetModelNextFrame() end)
    pcall(function() triggerEvent("OnClothingUpdated", player) end)
    pcall(function()
        local hotbar = getPlayerHotbar(0)
        if hotbar then hotbar:refresh() end
    end)
    pcall(function()
        local page = getPlayerInventory(0)
        if page then page:refreshBackpacks() end
        local loot = getPlayerLoot(0)
        if loot then loot:refreshBackpacks() end
    end)
end

local REASONS = {
    transfer = "UI_PC_Refused_Transfer",
    revive = "UI_PC_Refused_Revive",
}

function Client.onApplied(result)
    local busy = Client.busy
    Client.busy = nil
    local player = localPlayer()
    if not busy or not player then
        return
    end
    local char = Roster.get(busy.id)
    if not char then
        return
    end

    if result and result.ok then
        if char.dead then
            Roster.markAlive(char.id)
        end
        if busy.flow and busy.flow.outfitBuild then
            char.outfitBuild = busy.flow.outfitBuild
        end
        Client.activate(player, char)
        Client.stamp(player, char.id, char.rev)
        if isClient() and not result.kept then
            -- the server does not send these two counters to the player's game
            pcall(function()
                if char.snap.kills then player:setZombieKills(char.snap.kills) end
                if char.snap.hours then player:setHoursSurvived(char.snap.hours) end
            end)
            Client.gate = { snap = char.snap, untilTime = now() + 300 }
            Client.nextSave = now() + 30
        else
            Client.nextSave = now() + 10
        end
        Client.refreshAt = { getTimestampMs() + 2500, getTimestampMs() + 9000 }
        Client.refreshUI(player)
        if busy.mode ~= "sync" then
            local text = getText("UI_PC_Arrived", char.label)
            local report = result.report
            if report and (report.missing or 0) > 0 then
                text = text .. " " .. getText("UI_PC_MissingItems", tostring(report.missing))
            end
            Client.say(player, text)
        end
        return
    end

    local reason = result and result.reason or "error"
    PC.log(busy.mode .. " of '" .. tostring(char.label) .. "' refused: " .. tostring(reason))
    if busy.mode == "sync" then
        -- Keep playing the world's copy; the saved character stays as it is until the next save.
        Client.activate(player, char)
        return
    end
    -- This world would not take the saved character, so the player it made is somebody new.
    local note = getText(REASONS[reason] or "UI_PC_Refused")
    local flow = { label = char.label .. " " .. getText("UI_PC_NewSuffix"), outfitBuild = busy.flow and busy.flow.outfitBuild }
    Client.register(player, flow, note)
end

-- Entering a world ------------------------------------------------------------------------------

-- link: what the world says about its player ({ id, rev } or nil). hours: how long that player
-- has lived.
function Client.decide(player, link, hours)
    Roster.load(true)
    local flow = PC.Flow and PC.Flow.take() or nil
    local fresh = (hours or 0) < 0.25

    -- chosen on the character screen for a player this world has just made
    if not link and fresh and flow and flow.mode == "existing" then
        local char = Roster.get(flow.id)
        if char then
            Client.startApply(player, char, char.dead and "revive" or "transfer", flow)
            return
        end
    end

    -- a world this character has been in before
    if link then
        local char = Roster.get(link.id)
        if char then
            if char.rev > link.rev then
                Client.startApply(player, char, "sync", nil)
            else
                if char.dead then
                    Roster.markAlive(char.id)      -- still alive in this world
                end
                pcall(Authority.setLink, player, link.id, link.rev)    -- this game's copy of the link
                Client.activate(player, char)
            end
            return
        end
    end

    -- somebody the saved characters don't include yet
    if not fresh then
        flow = nil
    end
    Client.register(player, flow, nil)
end

function Client.onHello(player, hello)
    Client.start = nil
    Client.worldId = hello.worldId
    Client.options = hello.options
    local ok, err = pcall(Client.decide, player, hello.link, hello.hours)
    if not ok then
        PC.log("could not link the player: " .. tostring(err))
        Client.busy = nil
    end
end

local function onCreatePlayer(playerNum, player)
    if playerNum ~= 0 then return end
    Client.active = nil
    Client.busy = nil
    Client.gate = nil
    Client.refreshAt = nil
    -- Wait a moment: the game hands out a new character's starting things right after this.
    Client.start = { at = getTimestampMs() + 1500, tries = 0 }
end

local function onTick()
    local start = Client.start
    if start and getTimestampMs() >= start.at then
        local player = localPlayer()
        if not player or player:isDead() then
            Client.start = nil
        elseif isClient() then
            start.tries = start.tries + 1
            if start.tries > 8 then
                PC.log("the server did not answer: is Portable Characters installed on it?")
                Client.start = nil
            else
                sendClientCommand(player, PC.MOD, "hello", {})
                start.at = getTimestampMs() + 4000
            end
        else
            Client.onHello(player, Authority.hello(player))
        end
    end

    if Client.refreshAt and #Client.refreshAt > 0 and getTimestampMs() >= Client.refreshAt[1] then
        table.remove(Client.refreshAt, 1)
        local player = localPlayer()
        if player then Client.refreshUI(player) end
    end

    if Client.busy and now() - Client.busy.at > 60 then
        PC.log("no answer to the transfer; giving up on it")
        Client.onApplied({ ok = false, reason = "timeout" })
    end

    if Client.active and not Client.busy and now() >= Client.nextSave then
        if not Client.saveNow("timer") then
            Client.nextSave = now() + 15
        end
    end
end

local function onServerCommand(module, command, args)
    if module ~= PC.MOD then return end
    args = args or {}
    if command == "hello" then
        if Client.start then
            local player = localPlayer()
            if player then
                Client.onHello(player, args)
            end
        end
    elseif command == "applied" then
        local ok, err = pcall(Client.onApplied, args)
        if not ok then
            PC.log("after the transfer: " .. tostring(err))
        end
    end
end

-- Death -----------------------------------------------------------------------------------------

local function onPlayerDeath(player)
    if not player then return end
    local mine = PC.try(function() return player:isLocalPlayer() and player:getPlayerNum() == 0 end)
    if not mine then return end
    local id = Client.active
    Client.active = nil
    Client.busy = nil
    Client.gate = nil
    Client.start = nil
    if not id then return end
    local char = Roster.get(id)
    if not char then return end
    pcall(function()
        -- what the character knew when it died; what it carried stays on the body
        local snap = Snapshot.capture(player)
        local data = Snapshot.captureData(player, Client.worldId, false)
        Roster.update(id, snap, data)
    end)
    Roster.markDead(id, {
        time = now(),
        world = Client.worldName(),
        hours = char.snap and char.snap.hours or 0,
        kills = char.snap and char.snap.kills or 0,
    })
    PC.log("'" .. tostring(char.label) .. "' died; it is now under Dead on the character screen")
end

-- Leaving ---------------------------------------------------------------------------------------

require "OptionScreens/MainScreen"

local originalMenuClick = MainScreen.onMenuItemMouseDownMainMenu
if originalMenuClick then
    MainScreen.onMenuItemMouseDownMainMenu = function(item, x, y)
        if item and (item.internal == "EXIT" or item.internal == "QUIT_TO_DESKTOP")
                and MainScreen.instance and MainScreen.instance.inGame then
            pcall(Client.saveNow, "leaving")
        end
        return originalMenuClick(item, x, y)
    end
end

Events.OnCreatePlayer.Add(onCreatePlayer)
-- "even paused": a single-player game can start paused, and the character should be in place
-- before the player presses a key
if Events.OnTickEvenPaused then
    Events.OnTickEvenPaused.Add(onTick)
else
    Events.OnTick.Add(onTick)
end
Events.OnServerCommand.Add(onServerCommand)
Events.OnPlayerDeath.Add(onPlayerDeath)

return Client
