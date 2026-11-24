-- Portable Characters: where the character screen fits into the game's own character creation.
--
-- The game's order is: (spawn point) -> profession and traits -> appearance -> play.
-- Every path into "profession and traits" goes through CharacterCreationProfession:setVisible(true),
-- from the main menu, on joining a server and after a death, so that one call is where the
-- character screen steps in:
--
--   (spawn point) -> CHARACTER SCREEN -> create new -> profession and traits -> appearance -> play
--                                     -> saved character ---------------------> appearance -> play

if isServer() then return end

require "OptionScreens/CharacterCreationProfession"
require "OptionScreens/CharacterCreationMain"
require "OptionScreens/CoopCharacterCreationProfession"
require "OptionScreens/CoopCharacterCreationMain"
require "OptionScreens/CoopCharacterCreation"
require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Roster"
require "PortableCharacters/PC_SelectScreen"

local PC = PortableCharacters
local Roster = PC.Roster

local Flow = {}
PC.Flow = Flow

-- The choice made on the character screen:
--   { mode = "new", label } or { mode = "existing", id }, plus outfitBuild / committed / at once
--   the player presses Play.
Flow.state = nil
Flow.allowProfession = false    -- let the next "show profession screen" through
Flow.passBack = false           -- let the next Back on the profession screen do the game's own thing
Flow.screen = nil

function Flow.enabled()
    local tutorial = PC.try(function() return getCore():isTutorial() end)
    return not tutorial
end

-- Called once the new player exists: what did the character screen choose for it?
function Flow.take()
    local state = Flow.state
    Flow.state = nil
    if state and state.committed and (getTimestamp() - (state.at or 0)) < 1800 then
        return state
    end
    return nil
end

-- The appearance screen's settings as text ----------------------------------------------------
-- The game saves an appearance preset as "key=value;key=value;...". A saved character keeps the
-- one it was last made with, in the same form, so the game's own code can read it back.

local function split(text, sep)
    local out = {}
    local from = 1
    while true do
        local at = string.find(text, sep, from, true)
        if not at then
            out[#out + 1] = string.sub(text, from)
            return out
        end
        out[#out + 1] = string.sub(text, from, at - 1)
        from = at + #sep
    end
end

local function parseBuild(build)
    local fields, order = {}, {}
    for _, part in ipairs(split(build or "", ";")) do
        local eq = string.find(part, "=", 1, true)
        if eq and eq > 1 then
            local key = string.sub(part, 1, eq - 1)
            if fields[key] == nil then
                order[#order + 1] = key
            end
            fields[key] = string.sub(part, eq + 1)
        end
    end
    return fields, order
end

local FIRST = { "gender", "skincolor", "stubble", "chesthair", "beard", "beardstubble", "voiceStyle", "voicePitch" }
-- handled by hand in Flow.applyBuild (the game's reader trips over an empty value in these)
local BY_HAND = { name = true, hair = true }

local function joinBuild(fields, order)
    local parts = {}
    local done = {}
    for _, key in ipairs(FIRST) do
        if fields[key] ~= nil then
            parts[#parts + 1] = key .. "=" .. fields[key] .. ";"
            done[key] = true
        end
    end
    for _, key in ipairs(order) do
        if not done[key] and fields[key] ~= nil then
            parts[#parts + 1] = key .. "=" .. fields[key] .. ";"
            done[key] = true
        end
    end
    return table.concat(parts)
end

local function clean(text)
    text = tostring(text or "")
    text = string.gsub(text, "[;|=:\r\n]", " ")
    return text
end

local function rgbText(rgb)
    return tostring(rgb[1]) .. "," .. tostring(rgb[2]) .. "," .. tostring(rgb[3])
end

-- A character's look changes while it is played (a haircut, a beard). Brings the stored settings
-- up to date with the character as it is now.
function Flow.refreshBuild(build, snap)
    if type(snap) ~= "table" then
        return build
    end
    local fields, order = parseBuild(build)
    local function put(key, value)
        if fields[key] == nil then
            order[#order + 1] = key
        end
        fields[key] = value
    end
    local visual = snap.visual or {}
    put("gender", snap.female and "1" or "2")
    if snap.forename then
        put("name", clean(snap.forename) .. "|" .. clean(snap.surname))
    end
    if visual.hairColor then
        put("hair", clean(visual.hair) .. "|" .. rgbText(visual.hairColor))
    end
    if visual.hairStubble ~= nil then
        put("stubble", visual.hairStubble and "1" or "2")
    end
    if snap.female then
        fields.chesthair, fields.beard, fields.beardstubble = nil, nil, nil
    else
        if visual.bodyHair ~= nil then
            put("chesthair", (visual.bodyHair == 0) and "1" or "2")
        end
        put("beard", clean(visual.beard))
        if visual.beardStubble ~= nil then
            put("beardstubble", visual.beardStubble and "1" or "2")
        end
    end
    return joinBuild(fields, order)
end

-- Reads the appearance screen as it stands, with the game's own "save preset" code.
function Flow.captureBuild(main)
    local captured = nil
    local originalRead = CharacterCreationMain.readSavedOutfitFile
    local originalWrite = CharacterCreationMain.writeSaveFile
    local savedOptions = main.savedBuilds and main.savedBuilds.options
    local savedSelected = main.savedBuilds and main.savedBuilds.selected
    CharacterCreationMain.readSavedOutfitFile = function() return {} end
    CharacterCreationMain.writeSaveFile = function(builds) captured = builds["PCBuild"] end
    local button = { internal = "OK", parent = { entry = { getText = function() return "PCBuild" end } } }
    local ok, err = pcall(CharacterCreationMain.saveBuildStep2, main, button, nil, nil)
    CharacterCreationMain.readSavedOutfitFile = originalRead
    CharacterCreationMain.writeSaveFile = originalWrite
    if main.savedBuilds then
        main.savedBuilds.options = savedOptions
        main.savedBuilds.selected = savedSelected
    end
    if not ok then
        PC.log("could not read the appearance screen: " .. tostring(err))
        return nil
    end
    return captured
end

-- Sets the appearance screen from stored settings, with the game's own "load preset" code.
function Flow.applyBuild(main, build)
    local fields, order = parseBuild(build)
    local desc = MainScreen.instance.desc

    local rest = {}
    for _, key in ipairs(order) do
        if not BY_HAND[key] then
            rest[#rest + 1] = key
        end
    end
    local stripped = {}
    for key, value in pairs(fields) do
        if not BY_HAND[key] then
            stripped[key] = value
        end
    end
    local text = joinBuild(stripped, rest)

    local originalRead = CharacterCreationMain.readSavedOutfitFile
    CharacterCreationMain.readSavedOutfitFile = function() return { PCBuild = text } end
    local ok, err = pcall(main.loadOutfit, main, { options = { "PCBuild" }, selected = 1 })
    CharacterCreationMain.readSavedOutfitFile = originalRead
    if not ok then
        PC.log("could not set the appearance screen: " .. tostring(err))
    end

    if fields.hair then
        pcall(function()
            local bits = split(fields.hair, "|")
            local model = bits[1] or ""
            local rgb = split(bits[2] or "", ",")
            if #rgb == 3 then
                main:onHairColorPicked({ r = tonumber(rgb[1]), g = tonumber(rgb[2]), b = tonumber(rgb[3]) }, true)
            end
            main.hairTypeCombo.selected = 1
            main.hairTypeCombo:selectData(model)
            main:onHairTypeSelected(main.hairTypeCombo)
        end)
    end
    if fields.name then
        pcall(function()
            local bits = split(fields.name, "|")
            local forename, surname = bits[1] or "", bits[2] or ""
            desc:setForename(forename)
            desc:setSurname(surname)
            main.forenameEntry:setText(forename)
            main.surnameEntry:setText(surname)
        end)
    end
    pcall(function() main:disableBtn() end)
end

-- The saved character's settings on the appearance screen: what it was last made with, brought up
-- to date with how it looks now. A character taken over from an old save has none stored, so the
-- screen's own (random clothes) are the starting point.
function Flow.prefill(main, char)
    if not char then return end
    local snap = char.snap or {}
    local build = char.outfitBuild
    if not build or build == "" then
        build = Flow.captureBuild(main) or ""
        local fields, order = parseBuild(build)
        local visual = snap.visual or {}
        if visual.skin and main.skinColors and main.skinColors[visual.skin + 1] then
            local color = main.skinColors[visual.skin + 1]
            if fields.skincolor == nil then order[#order + 1] = "skincolor" end
            fields.skincolor = tostring(color.r) .. "," .. tostring(color.g) .. "," .. tostring(color.b)
        end
        -- the voice, by its sound-name prefix
        pcall(function()
            local prefix = snap.voice and snap.voice.prefix
            if prefix and main.voiceTypeCombo then
                for i in ipairs(main.voiceTypeCombo.options) do
                    local style = main.voiceTypeCombo:getOptionData(i)
                    if style and style:getPrefix() == prefix then
                        if fields.voiceStyle == nil then order[#order + 1] = "voiceStyle" end
                        fields.voiceStyle = style:getName()
                    end
                end
                if snap.voice.pitch then
                    if fields.voicePitch == nil then order[#order + 1] = "voicePitch" end
                    fields.voicePitch = tostring(snap.voice.pitch)
                end
            end
        end)
        build = joinBuild(fields, order)
    end
    build = Flow.refreshBuild(build, snap)
    Flow.applyBuild(main, build)
end

-- The hidden profession screen holds the profession and traits the game will use for the new
-- player. Sets it to the saved character's, the way the game loads a preset.
function Flow.loadProfession(prof, snap)
    snap = snap or {}
    pcall(function() prof:resetBuild() end)
    if snap.profession then
        for i = 1, #prof.listboxProf.items do
            local def = prof.listboxProf.items[i].item
            if tostring(def:getType()) == snap.profession then
                prof.listboxProf.selected = i
                pcall(function() prof:onSelectProf(def) end)
                break
            end
        end
    end
    for _, id in ipairs(snap.traits or {}) do
        pcall(function()
            if prof.listboxTraitSelected and prof.listboxTraitSelected.items then
                for _, chosen in ipairs(prof.listboxTraitSelected.items) do
                    if tostring(chosen.item:getType()) == id then
                        return
                    end
                end
            end
            for i, entry in ipairs(prof.listboxTrait.items) do
                if tostring(entry.item:getType()) == id then
                    prof.listboxTrait.selected = i
                    prof:addGoodTrait()
                    prof:checkXPBoost()
                    return
                end
            end
            for i, entry in ipairs(prof.listboxBadTrait.items) do
                if tostring(entry.item:getType()) == id then
                    prof.listboxBadTrait.selected = i
                    prof:addBadTrait()
                    prof:checkXPBoost()
                    return
                end
            end
        end)
    end
end

-- The character screen ------------------------------------------------------------------------

local originalProfSetVisible = CharacterCreationProfession.setVisible
local originalProfClick = CharacterCreationProfession.onOptionMouseDown
local originalCoopProfClick = CoopCharacterCreationProfession.onOptionMouseDown
local originalMainSetVisible = CharacterCreationMain.setVisible
local originalMainClick = CharacterCreationMain.onOptionMouseDown
local originalCoopMainClick = CoopCharacterCreationMain.onOptionMouseDown
local originalCoopCancel = CoopCharacterCreation.cancel

function Flow.showSelect(prof, joypadData)
    local parent = prof.parent
    if not parent then
        -- nowhere to put the screen: fall back to the game's own flow
        Flow.allowProfession = true
        prof:setVisible(true, joypadData)
        return
    end
    if Flow.screen and Flow.screen.parent ~= parent then
        pcall(function()
            Flow.screen:setVisible(false)
            Flow.screen.parent:removeChild(Flow.screen)
        end)
        Flow.screen = nil
    end
    if not Flow.screen then
        local screen = PCSelectScreen:new(prof:getX(), prof:getY(), prof:getWidth(), prof:getHeight())
        screen:initialise()
        parent:addChild(screen)
        Flow.screen = screen
    end
    Flow.state = nil
    Flow.screen.profScreen = prof
    Flow.screen:fit()
    Flow.screen:open()
    Flow.screen:setVisible(true, joypadData)
end

function Flow.mainScreenFor(prof)
    local parent = prof.parent
    if parent and parent.charCreationMain then
        return parent.charCreationMain
    end
    return CharacterCreationMain.instance
end

-- "Create new" on the character screen.
function Flow.chooseNew(screen, label, joypadData)
    local prof = screen.profScreen
    Flow.state = { mode = "new", label = label }
    screen:setVisible(false)
    pcall(function() prof:resetBuild() end)
    Flow.allowProfession = true
    prof:setVisible(true, joypadData)
end

-- A saved character on the character screen: straight to the appearance screen.
function Flow.chooseExisting(screen, char, joypadData)
    local prof = screen.profScreen
    local main = Flow.mainScreenFor(prof)
    if not CharacterCreationMain.instance then
        CharacterCreationMain.instance = main
    end
    Flow.state = { mode = "existing", id = char.id }
    Flow.loadProfession(prof, char.snap)
    screen:setVisible(false)
    main:setVisible(true, joypadData)
end

-- Back on the character screen: what Back on the profession screen used to do.
function Flow.back(screen, joypadData)
    local prof = screen.profScreen
    Flow.state = nil
    screen:setVisible(false)
    Flow.passBack = true
    local ok, err = pcall(function()
        prof:onOptionMouseDown({ internal = "BACK" }, 0, 0)
    end)
    Flow.passBack = false
    if not ok then
        PC.log("back failed: " .. tostring(err))
    end
end

function CharacterCreationProfession:setVisible(visible, joypadData)
    if visible and Flow.enabled() then
        if Flow.allowProfession then
            Flow.allowProfession = false
        else
            originalProfSetVisible(self, false)
            Flow.showSelect(self, joypadData)
            return
        end
    end
    return originalProfSetVisible(self, visible, joypadData)
end

local function profBack(self, joypadData)
    if self.infoRichText then
        self.infoRichText:removeFromUIManager()
        self.infoRichText = nil
    end
    originalProfSetVisible(self, false)
    Flow.showSelect(self, joypadData)
end

function CharacterCreationProfession:onOptionMouseDown(button, x, y)
    if button.internal == "BACK" and Flow.enabled() and not Flow.passBack then
        profBack(self, JoypadState.getMainMenuJoypad() or CoopCharacterCreation.getJoypad())
        return
    end
    return originalProfClick(self, button, x, y)
end

function CoopCharacterCreationProfession:onOptionMouseDown(button, x, y)
    if button.internal == "BACK" and Flow.enabled() and not Flow.passBack then
        profBack(self, self.joyfocus)
        return
    end
    return originalCoopProfClick(self, button, x, y)
end

function CharacterCreationMain:setVisible(visible, joypadData)
    originalMainSetVisible(self, visible, joypadData)
    if visible and Flow.enabled() and Flow.state and Flow.state.mode == "existing" then
        local ok, err = pcall(Flow.prefill, self, Roster.get(Flow.state.id))
        if not ok then
            PC.log("could not fill in the appearance screen: " .. tostring(err))
        end
    end
end

-- Play, or Back, on the appearance screen.
local function beforeMainClick(main, button)
    if not Flow.enabled() then return end
    if button.internal == "NEXT" then
        Flow.state = Flow.state or { mode = "new" }
        Flow.state.outfitBuild = Flow.captureBuild(main)
        Flow.state.committed = true
        Flow.state.at = getTimestamp()
    elseif button.internal == "BACK" then
        if not Flow.state or Flow.state.mode == "new" then
            Flow.allowProfession = true
        end
    end
end

function CharacterCreationMain:onOptionMouseDown(button, x, y)
    beforeMainClick(self, button)
    return originalMainClick(self, button, x, y)
end

function CoopCharacterCreationMain:onOptionMouseDown(button, x, y)
    -- (this one hands Random and the voice test on to the function above, which then does nothing
    -- extra for them)
    if button.internal == "NEXT" or button.internal == "BACK" then
        beforeMainClick(self, button)
    end
    return originalCoopMainClick(self, button, x, y)
end

function CoopCharacterCreation:cancel()
    Flow.state = nil
    Flow.allowProfession = false
    if Flow.screen and Flow.screen.parent == self then
        Flow.screen = nil
    end
    return originalCoopCancel(self)
end

return Flow
