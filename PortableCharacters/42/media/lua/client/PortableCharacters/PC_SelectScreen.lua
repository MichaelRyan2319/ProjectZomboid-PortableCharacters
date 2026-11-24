-- Portable Characters: the character screen.
-- Left: the saved characters (Alive / Dead) with Create New under the list. Middle: the selected
-- character. Right: its skills, traits and history, with Rename and Delete.

if isServer() then return end

require "ISUI/ISPanelJoypad"
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISScrollingListBox"
require "ISUI/ISUI3DModel"
require "ISUI/ISTextBox"
require "ISUI/ISModalDialog"
require "PortableCharacters/PC_Core"
require "PortableCharacters/PC_Items"
require "PortableCharacters/PC_Snapshot"
require "PortableCharacters/PC_Roster"

local PC = PortableCharacters
local Roster = PC.Roster

local FONT_HGT_SMALL = getTextManager():getFontHeight(UIFont.Small)
local FONT_HGT_MEDIUM = getTextManager():getFontHeight(UIFont.Medium)
local FONT_HGT_LARGE = getTextManager():getFontHeight(UIFont.Large)
local PAD = 10
local BUTTON_HGT = FONT_HGT_SMALL + 6
local BIG_BUTTON_HGT = FONT_HGT_MEDIUM + 12

local function measure(font, text)
    return getTextManager():MeasureStringX(font, text)
end

local function survivedText(hours)
    hours = math.floor(hours or 0)
    local days = math.floor(hours / 24)
    local rest = hours - days * 24
    if days > 0 then
        return getText("UI_PC_DaysHours", tostring(days), tostring(rest))
    end
    return getText("UI_PC_Hours", tostring(rest))
end

local function wrap(text, font, width)
    local lines = {}
    local line = ""
    for word in string.gmatch(text, "%S+") do
        local try = (line == "") and word or (line .. " " .. word)
        if line ~= "" and measure(font, try) > width then
            lines[#lines + 1] = line
            line = word
        else
            line = try
        end
    end
    if line ~= "" then
        lines[#lines + 1] = line
    end
    return lines
end

-- The panel on the right ----------------------------------------------------------------------

local PCInfoPanel = ISPanel:derive("PCInfoPanel")

function PCInfoPanel:new(x, y, width, height)
    local o = ISPanel.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.4 }
    o.borderColor = { r = 1, g = 1, b = 1, a = 0.25 }
    o.char = nil
    o.lines = nil
    return o
end

function PCInfoPanel:setCharacter(char)
    self.char = char
    self.lines = nil
    self:setYScroll(0)
end

function PCInfoPanel:onMouseWheel(del)
    self:setYScroll(self:getYScroll() - del * 40)
    return true
end

-- Works the panel's content out once per character and width: a list of things to draw.
function PCInfoPanel:build()
    local char = self.char
    local lines = {}
    local y = PAD
    local width = self.width - PAD * 2 - 14      -- room for the scroll bar
    local function text(str, font, r, g, b, x)
        lines[#lines + 1] = { kind = "text", text = str, font = font, x = x or PAD, y = y, r = r or 1, g = g or 1, b = b or 1 }
    end
    local function gap(h)
        y = y + h
    end
    local function rule()
        lines[#lines + 1] = { kind = "rule", y = y }
        y = y + PAD
    end
    local function pair(label, value, r, g, b)
        text(label, UIFont.Small, 0.65, 0.65, 0.65)
        lines[#lines + 1] = { kind = "right", text = value, font = UIFont.Small, y = y, r = r or 1, g = g or 1, b = b or 1 }
        gap(FONT_HGT_SMALL + 3)
    end

    if not char then
        self.lines = lines
        self:setScrollHeight(self.height)
        return
    end
    local snap = char.snap or {}

    lines[#lines + 1] = { kind = "centre", text = getText("UI_PC_TotalLevel", tostring(PC.totalLevel(snap))), font = UIFont.Large, y = y }
    gap(FONT_HGT_LARGE + PAD)
    rule()

    pair(getText("UI_PC_InGameName"), tostring(snap.forename or "") .. " " .. tostring(snap.surname or ""))
    pair(getText("UI_PC_Profession"), PC.professionLabel(snap.profession))
    pair(getText("UI_PC_Survived"), survivedText(snap.hours))
    pair(getText("UI_PC_Kills"), tostring(snap.kills or 0))
    if not char.dead then
        -- injuries travel with the character, so say what it is carrying
        local condition = PC.Snapshot.condition(snap.body)
        if condition.bitten then
            pair(getText("UI_PC_Condition"), getText("UI_PC_Bitten"), 1, 0.45, 0.4)
        elseif condition.infected then
            pair(getText("UI_PC_Condition"), getText("UI_PC_Infected"), 1, 0.45, 0.4)
        elseif condition.wounds > 0 then
            pair(getText("UI_PC_Condition"), getText("UI_PC_Injured", tostring(condition.wounds)), 1, 0.8, 0.45)
        else
            pair(getText("UI_PC_Condition"), getText("UI_PC_Healthy"), 0.6, 0.9, 0.6)
        end
    end
    if char.lastWorld and char.lastWorld ~= "" then
        pair(getText(char.dead and "UI_PC_DiedIn" or "UI_PC_LastWorld"), char.lastWorld)
    end
    gap(PAD - 3)
    rule()

    -- skills, two to a row
    text(getText("UI_PC_Skills"), UIFont.Medium)
    gap(FONT_HGT_MEDIUM + 6)
    local columnWidth = math.floor((width - PAD) / 2)
    local rowHeight = FONT_HGT_SMALL + 5
    local column = 0
    for _, perk in ipairs(PC.allSkills()) do
        local entry = snap.perks and snap.perks[perk:getId()]
        local level = entry and entry.l or 0
        lines[#lines + 1] = {
            kind = "skill", text = perk:getName(), level = level,
            x = PAD + column * (columnWidth + PAD), y = y, width = columnWidth,
        }
        column = column + 1
        if column > 1 then
            column = 0
            gap(rowHeight)
        end
    end
    if column ~= 0 then
        gap(rowHeight)
    end
    gap(PAD - 3)
    rule()

    text(getText("UI_PC_Traits"), UIFont.Medium)
    gap(FONT_HGT_MEDIUM + 6)
    local names = {}
    for _, id in ipairs(snap.traits or {}) do
        names[#names + 1] = PC.traitLabel(id)
    end
    table.sort(names)
    local traitText = (#names > 0) and table.concat(names, ",  ") or getText("UI_PC_None")
    for _, line in ipairs(wrap(traitText, UIFont.Small, width)) do
        text(line, UIFont.Small, 0.85, 0.85, 0.85)
        gap(FONT_HGT_SMALL + 2)
    end
    gap(PAD)

    self.lines = lines
    self.builtWidth = self.width
    self:setScrollHeight(math.max(y, self.height))
end

function PCInfoPanel:prerender()
    ISPanel.prerender(self)
    self:setStencilRect(0, 0, self.width, self.height)
end

function PCInfoPanel:render()
    if not self.lines or self.builtWidth ~= self.width then
        self:build()
    end
    local right = self.width - PAD - 14
    for _, line in ipairs(self.lines) do
        if line.kind == "text" then
            self:drawText(line.text, line.x, line.y, line.r, line.g, line.b, 1, line.font)
        elseif line.kind == "right" then
            local w = measure(line.font, line.text)
            self:drawText(line.text, right - w, line.y, line.r, line.g, line.b, 1, line.font)
        elseif line.kind == "centre" then
            self:drawTextCentre(line.text, self.width / 2, line.y, 1, 0.92, 0.65, 1, line.font)
        elseif line.kind == "rule" then
            self:drawRect(PAD, line.y, self.width - PAD * 2 - 14, 1, 0.35, 1, 1, 1)
        elseif line.kind == "skill" then
            local shade = (line.level > 0) and 1 or 0.45
            self:drawText(line.text, line.x, line.y, shade, shade, shade, 1, UIFont.Small)
            -- ten pips, filled up to the level
            local pip, pipGap = 5, 2
            local pipsWidth = 10 * pip + 9 * pipGap
            local px = line.x + line.width - pipsWidth
            local py = line.y + math.floor((FONT_HGT_SMALL - pip) / 2) + 1
            for i = 1, 10 do
                if i <= line.level then
                    self:drawRect(px, py, pip, pip, 1, 0.9, 0.78, 0.35)
                else
                    self:drawRect(px, py, pip, pip, 0.35, 0.5, 0.5, 0.5)
                end
                px = px + pip + pipGap
            end
        end
    end
    self:clearStencilRect()
end

-- The screen ----------------------------------------------------------------------------------

PCSelectScreen = ISPanelJoypad:derive("PCSelectScreen")

function PCSelectScreen:new(x, y, width, height)
    local o = ISPanelJoypad.new(self, x, y, width, height)
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.8 }
    o.borderColor = { r = 1, g = 1, b = 1, a = 0.2 }
    o.showDead = false
    o.selectedId = nil
    o.profScreen = nil
    o.avatarBackground = getTexture("media/ui/avatarBackgroundWhite.png")
    o:setUIName("PCSelectScreen")
    return o
end

local function drawCharacterItem(list, y, item, alt)
    local char = item.item
    local height = item.height
    if list.selected == item.index then
        list:drawRect(0, y, list:getWidth(), height - 1, 0.35, 0.9, 0.78, 0.35)
        list:drawRectBorder(0, y, list:getWidth(), height - 1, 0.9, 0.9, 0.78, 0.35)
    elseif list.mouseoverselected == item.index and list:isMouseOver() and not list:isMouseOverScrollBar() then
        list:drawRect(0, y, list:getWidth(), height - 1, 0.15, 1, 1, 1)
    end
    list:drawRectBorder(0, y, list:getWidth(), height, 0.25, 1, 1, 1)
    local snap = char.snap or {}
    local r, g, b = 1, 1, 1
    if char.dead then
        r, g, b = 0.75, 0.55, 0.55
    end
    list:drawText(char.label or "?", PAD, y + 5, r, g, b, 1, UIFont.Medium)
    local sub = getText("UI_PC_ListLevel", tostring(PC.totalLevel(snap)))
    local profession = PC.professionLabel(snap.profession)
    if profession ~= "" then
        sub = sub .. "  -  " .. profession
    end
    list:drawText(sub, PAD, y + 5 + FONT_HGT_MEDIUM + 1, 0.65, 0.65, 0.65, 1, UIFont.Small)
    return y + height
end

function PCSelectScreen:createChildren()
    ISPanelJoypad.createChildren(self)

    self.tabAlive = ISButton:new(0, 0, 100, BUTTON_HGT, "", self, PCSelectScreen.onTab)
    self.tabAlive.internal = "ALIVE"
    self.tabAlive:initialise()
    self.tabAlive:instantiate()
    self:addChild(self.tabAlive)

    self.tabDead = ISButton:new(0, 0, 100, BUTTON_HGT, "", self, PCSelectScreen.onTab)
    self.tabDead.internal = "DEAD"
    self.tabDead:initialise()
    self.tabDead:instantiate()
    self:addChild(self.tabDead)

    self.list = ISScrollingListBox:new(0, 0, 100, 100)
    self.list:initialise()
    self.list:instantiate()
    self.list.itemheight = FONT_HGT_MEDIUM + FONT_HGT_SMALL + 14
    self.list.font = UIFont.Medium
    self.list.drawBorder = true
    self.list.backgroundColor = { r = 0, g = 0, b = 0, a = 0.4 }
    self.list.doDrawItem = drawCharacterItem
    self.list:setOnMouseDownFunction(self, PCSelectScreen.onSelect)
    self.list:setOnMouseDoubleClick(self, PCSelectScreen.onDoubleClick)
    self:addChild(self.list)

    self.createButton = ISButton:new(0, 0, 100, BIG_BUTTON_HGT, getText("UI_PC_CreateNew"), self, PCSelectScreen.onCreateNew)
    self.createButton:initialise()
    self.createButton:instantiate()
    self.createButton.font = UIFont.Medium
    self.createButton:enableAcceptColor()
    self:addChild(self.createButton)

    self.avatar = ISUI3DModel:new(0, 0, 100, 200)
    self.avatar.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.avatar.borderColor = { r = 1, g = 1, b = 1, a = 0 }
    self:addChild(self.avatar)
    self.avatar:setState("idle")
    self.avatar:setDirection(IsoDirections.S)
    self.avatar:setIsometric(false)
    self.avatar:setDoRandomExtAnimations(true)
    self.avatar:setZoom(-3)
    self.avatar:setYOffset(0)

    self.turnLeft = ISButton:new(0, 0, BUTTON_HGT, BUTTON_HGT, "", self, PCSelectScreen.onTurn)
    self.turnLeft.internal = "LEFT"
    self.turnLeft:initialise()
    self.turnLeft:instantiate()
    self.turnLeft:setImage(getTexture("media/ui/ArrowLeft.png"))
    self:addChild(self.turnLeft)

    self.turnRight = ISButton:new(0, 0, BUTTON_HGT, BUTTON_HGT, "", self, PCSelectScreen.onTurn)
    self.turnRight.internal = "RIGHT"
    self.turnRight:initialise()
    self.turnRight:instantiate()
    self.turnRight:setImage(getTexture("media/ui/ArrowRight.png"))
    self:addChild(self.turnRight)

    self.info = PCInfoPanel:new(0, 0, 100, 100)
    self.info:initialise()
    self.info:instantiate()
    self.info:addScrollBars()
    self:addChild(self.info)

    self.renameButton = ISButton:new(0, 0, 100, BUTTON_HGT, getText("UI_PC_Rename"), self, PCSelectScreen.onRename)
    self.renameButton:initialise()
    self.renameButton:instantiate()
    self:addChild(self.renameButton)

    self.deleteButton = ISButton:new(0, 0, 100, BUTTON_HGT, getText("UI_PC_Delete"), self, PCSelectScreen.onDelete)
    self.deleteButton:initialise()
    self.deleteButton:instantiate()
    self.deleteButton:enableCancelColor()
    self:addChild(self.deleteButton)

    self.backButton = ISButton:new(0, 0, 100, BUTTON_HGT, getText("UI_btn_back"), self, PCSelectScreen.onBack)
    self.backButton:initialise()
    self.backButton:instantiate()
    self.backButton:enableCancelColor()
    self:addChild(self.backButton)

    self.playButton = ISButton:new(0, 0, 100, BUTTON_HGT, getText("UI_btn_next"), self, PCSelectScreen.onPlay)
    self.playButton:initialise()
    self.playButton:instantiate()
    self.playButton:enableAcceptColor()
    self:addChild(self.playButton)

    self:layout()
end

-- Takes the size and place of the game's own creation screen, which it stands in for.
function PCSelectScreen:fit()
    local prof = self.profScreen
    if prof then
        self:setX(prof:getX())
        self:setY(prof:getY())
        self:setWidth(prof:getWidth())
        self:setHeight(prof:getHeight())
    end
    if self.list then
        self:layout()
    end
end

function PCSelectScreen:layout()
    local w, h = self.width, self.height
    local top = PAD + FONT_HGT_LARGE + PAD + 1
    local bottomRow = h - PAD - BUTTON_HGT - 1
    local contentBottom = bottomRow - PAD

    local leftW = math.floor(math.max(260, math.min(420, w * 0.26)))
    local rightW = math.floor(math.max(330, math.min(520, w * 0.32)))
    local leftX = PAD + 1
    local rightX = w - PAD - 1 - rightW

    -- left: tabs, list, create new
    local tabW = math.floor((leftW - PAD) / 2)
    self.tabAlive:setX(leftX); self.tabAlive:setY(top); self.tabAlive:setWidth(tabW)
    self.tabDead:setX(leftX + tabW + PAD); self.tabDead:setY(top); self.tabDead:setWidth(leftW - tabW - PAD)
    local listY = top + BUTTON_HGT + PAD
    self.createButton:setX(leftX); self.createButton:setWidth(leftW)
    self.createButton:setY(contentBottom - BIG_BUTTON_HGT)
    self.list:setX(leftX); self.list:setY(listY); self.list:setWidth(leftW)
    self.list:setHeight(math.max(60, self.createButton:getY() - PAD - listY))

    -- right: info, then rename and delete
    self.info:setX(rightX); self.info:setY(top); self.info:setWidth(rightW)
    self.info:setHeight(math.max(60, contentBottom - BUTTON_HGT - PAD - top))
    local half = math.floor((rightW - PAD) / 2)
    local actionY = contentBottom - BUTTON_HGT
    self.renameButton:setX(rightX); self.renameButton:setY(actionY); self.renameButton:setWidth(half)
    self.deleteButton:setX(rightX + half + PAD); self.deleteButton:setY(actionY); self.deleteButton:setWidth(rightW - half - PAD)

    -- middle: the character, twice as tall as wide
    local midX = leftX + leftW + PAD
    local midW = rightX - PAD - midX
    self.nameY = top
    local avatarTop = top + FONT_HGT_LARGE + FONT_HGT_SMALL + PAD
    local avatarH = math.max(80, contentBottom - avatarTop)
    local avatarW = math.floor(avatarH / 2)
    if avatarW > midW then
        avatarW = math.max(40, midW)
        avatarH = avatarW * 2
    end
    self.midX, self.midW = midX, midW
    self.avatar:setX(midX + math.floor((midW - avatarW) / 2))
    self.avatar:setY(avatarTop)
    self.avatar:setWidth(avatarW)
    self.avatar:setHeight(avatarH)
    self.turnLeft:setX(self.avatar:getX()); self.turnLeft:setY(self.avatar:getBottom() - BUTTON_HGT)
    self.turnRight:setX(self.avatar:getRight() - BUTTON_HGT); self.turnRight:setY(self.avatar:getBottom() - BUTTON_HGT)

    -- bottom row
    local backW = PAD * 4 + measure(UIFont.Small, getText("UI_btn_back"))
    self.backButton:setX(leftX); self.backButton:setY(bottomRow); self.backButton:setWidth(backW)
    local playW = math.max(PAD * 6 + measure(UIFont.Small, getText("UI_btn_next")),
        PAD * 6 + measure(UIFont.Small, getText("UI_PC_Revive")))
    self.playButton:setX(w - PAD - 1 - playW); self.playButton:setY(bottomRow); self.playButton:setWidth(playW)

    -- the scroll bars were made for the size the panels started with
    for _, panel in ipairs({ self.info, self.list }) do
        local bar = panel.vscroll
        if bar then
            bar:setX(panel.width - bar:getWidth())
            bar:setHeight(panel.height)
        end
    end
    self.info.lines = nil
end

function PCSelectScreen:selected()
    local item = self.list.items[self.list.selected]
    return item and item.item or nil
end

-- A stand-in character with the saved one's body, hair and clothes, for the picture.
function PCSelectScreen:makeDesc(char)
    local snap = char.snap or {}
    local visual = snap.visual or {}
    local female = snap.female and true or false
    local desc = PC.try(function() return SurvivorFactory.CreateSurvivor(SurvivorType.Neutral, female) end)
        or SurvivorFactory.CreateSurvivor()
    desc:setFemale(female)
    pcall(function() desc:getWornItems():clear() end)
    local human = desc:getHumanVisual()
    pcall(function()
        human:clear()
        human:setSkinTextureIndex(visual.skin or 0)
        human:setHairModel(visual.hair or "")
        human:setBeardModel((not snap.female) and (visual.beard or "") or "")
        human:setBodyHairIndex(visual.bodyHair or -1)
        local hair = PC.Items.makeColor(visual.hairColor)
        if hair then
            human:setHairColor(hair)
            human:setNaturalHairColor(PC.Items.makeColor(visual.naturalHair) or hair)
        end
        local beard = PC.Items.makeColor(visual.beardColor) or hair
        if beard then
            human:setBeardColor(beard)
            human:setNaturalBeardColor(PC.Items.makeColor(visual.naturalBeard) or beard)
        end
        if visual.hairStubble then
            human:addBodyVisualFromItemType(snap.female and "Base.F_Hair_Stubble" or "Base.M_Hair_Stubble")
        end
        if visual.beardStubble and not snap.female then
            human:addBodyVisualFromItemType("Base.M_Beard_Stubble")
        end
    end)
    for _, piece in ipairs(snap.outfit or {}) do
        pcall(function()
            local item = instanceItem(piece.t)
            if not item then return end
            local itemVisual = item:getVisual()
            if itemVisual then
                if piece.base and piece.base >= 0 then itemVisual:setBaseTexture(piece.base) end
                if piece.tex and piece.tex >= 0 then itemVisual:setTextureChoice(piece.tex) end
                local tint = PC.Items.makeColor(piece.tint)
                if tint then itemVisual:setTint(tint) end
            end
            local location = PC.Items.findBodyLocation(piece.loc)
            if not location then
                location = item:IsClothing() and item:getBodyLocation() or item:canBeEquipped()
            end
            if location then
                desc:setWornItem(location, item)
            end
        end)
    end
    return desc
end

function PCSelectScreen:showCharacter(char)
    self.selectedId = char and char.id or nil
    self.info:setCharacter(char)
    if char then
        local ok, desc = pcall(self.makeDesc, self, char)
        if ok and desc then
            self.avatar:setVisible(true)
            pcall(function() self.avatar:setSurvivorDesc(desc) end)
            self.avatarDesc = desc     -- keep it alive while it is shown
        else
            self.avatar:setVisible(false)
        end
    else
        self.avatar:setVisible(false)
    end
    self.turnLeft:setVisible(char ~= nil)
    self.turnRight:setVisible(char ~= nil)
    self:updateButtons()
end

-- Called each time the screen comes up: starts on Alive, or on Dead when nobody is left alive
-- (right after a death, that is where the character just played is).
function PCSelectScreen:open()
    Roster.load(true)
    self.showDead = (Roster.count(false) == 0 and Roster.count(true) > 0)
    self.selectedId = nil
    self:refresh()
end

-- Reads the saved characters again and fills the list for the tab that is showing.
function PCSelectScreen:refresh()
    Roster.load(true)
    local alive = Roster.list(false)
    local dead = Roster.list(true)
    if self.showDead and #dead == 0 then
        self.showDead = false
    end
    self.tabAlive:setTitle(getText("UI_PC_TabAlive", tostring(#alive)))
    self.tabDead:setTitle(getText("UI_PC_TabDead", tostring(#dead)))
    local chosen = { r = 0.9, g = 0.78, b = 0.35, a = 0.35 }
    local plain = { r = 0, g = 0, b = 0, a = 0.6 }
    self.tabAlive.backgroundColor = self.showDead and plain or chosen
    self.tabDead.backgroundColor = self.showDead and chosen or plain

    local wanted = self.selectedId
    self.list:clear()
    local pick = 1
    for index, char in ipairs(self.showDead and dead or alive) do
        self.list:addItem(char.label or "?", char)
        if char.id == wanted then
            pick = index
        end
    end
    self.list.selected = pick
    self:showCharacter(self:selected())
end

-- Whether the selected character may enter this world, and why not if it may not.
function PCSelectScreen:verdict(char)
    if not char then
        return false, nil
    end
    local options = PC.options()
    if not options.AllowTransfer then
        return false, getText("UI_PC_NoTransfer")
    end
    if char.dead and not options.AllowRevive then
        return false, getText("UI_PC_NoRevive")
    end
    if char.dead then
        return true, getText("UI_PC_ReviveNote")
    end
    if not options.TransferInventory then
        return true, getText("UI_PC_NoItemsNote")
    end
    return true, nil
end

function PCSelectScreen:updateButtons()
    local char = self:selected()
    local allowed, note = self:verdict(char)
    self.note = note
    self.noteIsWarning = (char ~= nil) and not allowed
    self.playButton:setTitle(getText((char and char.dead) and "UI_PC_Revive" or "UI_btn_next"))
    self.playButton:setEnable(allowed)
    self.playButton:setVisible(char ~= nil)
    self.renameButton:setVisible(char ~= nil)
    self.deleteButton:setVisible(char ~= nil)
    self.info:setVisible(char ~= nil)
end

function PCSelectScreen:prerender()
    ISPanelJoypad.prerender(self)
    local prof = self.profScreen
    if prof and (prof:getWidth() ~= self.width or prof:getHeight() ~= self.height or prof:getX() ~= self.x or prof:getY() ~= self.y) then
        self:fit()
    end
    self:drawTextCentre(getText("UI_PC_Title"), self.width / 2, PAD + 1, 1, 1, 1, 1, UIFont.Large)

    local char = self:selected()
    if char then
        local midCentre = self.midX + self.midW / 2
        local r, g, b = 1, 0.92, 0.65
        if char.dead then r, g, b = 0.8, 0.5, 0.5 end
        self:drawTextCentre(char.label or "?", midCentre, self.nameY, r, g, b, 1, UIFont.Large)
        local snap = char.snap or {}
        local sub = tostring(snap.forename or "") .. " " .. tostring(snap.surname or "")
        if char.dead then
            sub = sub .. "  -  " .. getText("UI_PC_DiedAfter", survivedText(snap.hours))
        end
        self:drawTextCentre(sub, midCentre, self.nameY + FONT_HGT_LARGE + 1, 0.7, 0.7, 0.7, 1, UIFont.Small)
        if self.avatar:isVisible() then
            self:drawTextureScaled(self.avatarBackground, self.avatar.x, self.avatar.y, self.avatar.width, self.avatar.height, 1, 0.4, 0.4, 0.4)
            self:drawRectBorder(self.avatar.x - 2, self.avatar.y - 2, self.avatar.width + 4, self.avatar.height + 4, 1, 0.3, 0.3, 0.3)
        end
    else
        local midCentre = self.midX + self.midW / 2
        local key = "UI_PC_NoCharacters"
        if self.showDead then
            key = "UI_PC_NoDead"
        elseif Roster.count(true) > 0 then
            key = "UI_PC_NoneAlive"
        end
        local text = getText(key)
        self:drawTextCentre(text, midCentre, self.height / 2 - FONT_HGT_MEDIUM, 0.8, 0.8, 0.8, 1, UIFont.Medium)
    end

    if self.note then
        local r, g, b = 0.75, 0.75, 0.75
        if self.noteIsWarning then r, g, b = 1, 0.55, 0.45 end
        local x = self.playButton:getX() - PAD
        self:drawTextRight(self.note, x, self.playButton:getY() + (BUTTON_HGT - FONT_HGT_SMALL) / 2, r, g, b, 1, UIFont.Small)
    end
end

function PCSelectScreen:render()
    ISPanelJoypad.render(self)
    -- a renamed or deleted character changes the list without a new selection
    local char = self:selected()
    if (char and char.id or nil) ~= self.selectedId then
        self:showCharacter(char)
    end
end

-- Buttons -------------------------------------------------------------------------------------

function PCSelectScreen:joypad()
    return JoypadState.getMainMenuJoypad() or CoopCharacterCreation.getJoypad()
end

function PCSelectScreen:onTab(button)
    self.showDead = (button.internal == "DEAD")
    self.selectedId = nil
    self:refresh()
end

function PCSelectScreen:onSelect(char)
    self:showCharacter(char)
end

function PCSelectScreen:onDoubleClick(char)
    self:showCharacter(char)
    self:onPlay()
end

function PCSelectScreen:onTurn(button)
    local direction = self.avatar:getDirection()
    if button.internal == "LEFT" then
        self.avatar:setDirection(direction:RotRight())
    else
        self.avatar:setDirection(direction:RotLeft())
    end
end

function PCSelectScreen:onBack()
    PC.Flow.back(self, self:joypad())
end

function PCSelectScreen:onPlay()
    local char = self:selected()
    if not char then return end
    if not self:verdict(char) then return end
    PC.Flow.chooseExisting(self, char, self:joypad())
end

local function textPrompt(self, prompt, default, callback)
    local width, height = 360, 150
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local modal = ISTextBox:new(x, y, width, height, prompt, default or "", self, callback)
    modal:initialise()
    modal:setAlwaysOnTop(true)
    modal:setCapture(true)
    modal:addToUIManager()
    modal.backgroundColor.a = 0.9
    if modal.entry then
        modal.entry:focus()
    end
    local joypadData = self:joypad()
    if joypadData then
        modal.prevFocus = joypadData.focus
        joypadData.focus = modal
        updateJoypadFocus(joypadData)
    end
    self.prompt = modal
    return modal
end

local function restoreFocus(self)
    local joypadData = self:joypad()
    if joypadData then
        joypadData.focus = self
        updateJoypadFocus(joypadData)
    end
end

function PCSelectScreen:onCreateNew()
    textPrompt(self, getText("UI_PC_NamePrompt"), "", PCSelectScreen.onCreateNamed)
end

function PCSelectScreen:onCreateNamed(button)
    restoreFocus(self)
    if button.internal ~= "OK" then return end
    local label = button.parent.entry:getText()
    label = Roster.cleanLabel(label, "")
    if label == "" then
        label = nil      -- the name in game is used
    end
    PC.Flow.chooseNew(self, label, self:joypad())
end

function PCSelectScreen:onRename()
    local char = self:selected()
    if not char then return end
    self.renameId = char.id
    textPrompt(self, getText("UI_PC_RenamePrompt"), char.label or "", PCSelectScreen.onRenamed)
end

function PCSelectScreen:onRenamed(button)
    restoreFocus(self)
    if button.internal ~= "OK" or not self.renameId then return end
    Roster.rename(self.renameId, button.parent.entry:getText())
    self.selectedId = self.renameId
    self.renameId = nil
    self:refresh()
end

function PCSelectScreen:onDelete()
    local char = self:selected()
    if not char then return end
    self.deleteId = char.id
    local width, height = 380, 140
    local x = (getCore():getScreenWidth() - width) / 2
    local y = (getCore():getScreenHeight() - height) / 2
    local modal = ISModalDialog:new(x, y, width, height, getText("UI_PC_DeletePrompt", char.label or "?"), true, self, PCSelectScreen.onDeleteConfirmed)
    modal.backgroundColor.a = 0.9
    modal:initialise()
    modal:setCapture(true)
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    local joypadData = self:joypad()
    if joypadData then
        modal.param1 = joypadData
        joypadData.focus = modal
        updateJoypadFocus(joypadData)
    end
end

function PCSelectScreen:onDeleteConfirmed(button)
    restoreFocus(self)
    if button.internal ~= "YES" or not self.deleteId then return end
    Roster.delete(self.deleteId)
    self.deleteId = nil
    self.selectedId = nil
    self:refresh()
end

-- Controller: A next, B back, Y create new, X switches between Alive and Dead.
function PCSelectScreen:onJoypadDown(button, joypadData)
    if button == Joypad.AButton then
        self:onPlay()
    elseif button == Joypad.BButton then
        self:onBack()
    elseif button == Joypad.YButton then
        self:onCreateNew()
    elseif button == Joypad.XButton then
        self.showDead = not self.showDead
        self.selectedId = nil
        self:refresh()
    end
end

function PCSelectScreen:onJoypadDirUp(joypadData)
    if self.list.selected > 1 then
        self.list.selected = self.list.selected - 1
        self.list:ensureVisible(self.list.selected)
        self:showCharacter(self:selected())
    end
end

function PCSelectScreen:onJoypadDirDown(joypadData)
    if self.list.selected < #self.list.items then
        self.list.selected = self.list.selected + 1
        self.list:ensureVisible(self.list.selected)
        self:showCharacter(self:selected())
    end
end

return PCSelectScreen
