-- Portable Characters: the server's side of the conversation with a player's game.
-- A character arrives in several messages (the list of carried items can be long):
--   applyBegin, then any number of applyList / applyItems, then applyEnd.

if isClient() then return end

require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Authority"

local PC = PortableCharacters
local Authority = PC.Authority

local Server = {}
PC.Server = Server

local sessions = {}     -- player name -> the character being received
local MAX_PARTS = 400   -- a character is never this many messages; more is a broken or hostile client

local function key(player)
    return tostring(player:getUsername())
end

local function reply(player, command, args)
    sendServerCommand(player, PC.MOD, command, args or {})
end

local Commands = {}

Commands.hello = function(player, args)
    reply(player, "hello", Authority.hello(player))
end

Commands.stamp = function(player, args)
    Authority.stamp(player, args.id, args.rev)
end

Commands.applyBegin = function(player, args)
    sessions[key(player)] = {
        mode = args.mode,
        id = args.id,
        rev = args.rev,
        snap = args.snap,
        data = { recipes = {}, books = {} },
        items = {},
        hasInventory = args.inventory and true or false,
        parts = 0,
    }
end

Commands.applyList = function(player, args)
    local session = sessions[key(player)]
    if not session or type(args.list) ~= "table" then return end
    session.parts = session.parts + 1
    if session.parts > MAX_PARTS then
        sessions[key(player)] = nil
        return
    end
    local target = (args.kind == "books") and session.data.books or session.data.recipes
    for _, value in ipairs(args.list) do
        if type(value) == "string" then
            target[#target + 1] = value
        end
    end
end

Commands.applyItems = function(player, args)
    local session = sessions[key(player)]
    if not session or type(args.items) ~= "table" then return end
    session.parts = session.parts + 1
    if session.parts > MAX_PARTS then
        sessions[key(player)] = nil
        return
    end
    for _, item in ipairs(args.items) do
        if type(item) == "table" then
            session.items[#session.items + 1] = item
        end
    end
end

Commands.applyEnd = function(player, args)
    local session = sessions[key(player)]
    sessions[key(player)] = nil
    if not session then
        reply(player, "applied", { ok = false, reason = "nothing" })
        return
    end
    if (tonumber(args.parts) or 0) ~= session.parts then
        reply(player, "applied", { ok = false, reason = "incomplete", id = session.id, mode = session.mode })
        return
    end
    if session.hasInventory then
        session.data.inventory = { items = session.items }
    end
    local result = Authority.apply(player, {
        mode = session.mode,
        id = session.id,
        rev = session.rev,
        snap = session.snap,
        data = session.data,
    })
    result.id = session.id
    result.rev = session.rev
    result.mode = session.mode
    reply(player, "applied", result)
end

function Server.onClientCommand(module, command, player, args)
    if module ~= PC.MOD then return end
    local handler = Commands[command]
    if not handler or not player then return end
    local ok, err = pcall(handler, player, args or {})
    if not ok then
        PC.log("command " .. tostring(command) .. " failed: " .. tostring(err))
        if command == "applyEnd" then
            reply(player, "applied", { ok = false, reason = "error" })
        end
    end
end

if isServer() then
    Events.OnClientCommand.Add(Server.onClientCommand)
end

return Server
