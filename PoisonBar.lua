--[[--------------------------------------------------------------------
  PoisonBar - rogue poison bar for Emberveil (WoW 1.12.1 API)

  One row per weapon (main hand, off hand):
    weapon icon | chosen poison icon (+ how many you carry) | poison name,
    time left and charges on the weapon

    Left-click the row   : put the chosen poison on that weapon
    Right-click the row  : choose the poison for that weapon
    Drag the title bar   : move the bar (/pb lock to lock it)

  Written for Lua 5.0 and 5.1 (no "#", no string methods, no select).
  All UI is built in Lua; the bar is moved by hand from the cursor, because
  StartMoving() on the Emberveil client only moves the picture and the
  frame snaps back on release.
----------------------------------------------------------------------]]

PoisonBar = {}
local PB = PoisonBar
PB.VERSION = "1.1.0"

local getn = table.getn
local strfind, strlower, strformat, gsub = string.find, string.lower, string.format, string.gsub
local floor = math.floor

local FONT = "Fonts\\FRIZQT__.TTF"
local SLOTS = { 16, 17 }            -- main hand, off hand
local HAND = { [16] = "Main hand", [17] = "Off hand" }

local DEFAULTS = {
    locked = false,
    warnMinutes = 3,     -- name turns red below this many minutes
    warnCharges = 10,    -- ... or below this many charges
    warnSound = true,    -- one sound when a poison runs out
    choice = {},         -- [16] / [17] = poison name chosen for that hand
    applied = {},        -- [16] / [17] = poison put on by this addon (name)
}

local function echo(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9cff4fPoisonBar:|r " .. tostring(msg))
    end
end
PB.echo = echo

----------------------------------------------------------------------
-- poisons in the bags
----------------------------------------------------------------------

local function linkName(link)
    if not link then return nil end
    local _, _, name = strfind(link, "%[(.-)%]")
    return name
end

-- "Poison" in the main client languages
local POISON_WORDS = { "poison", "gift", "veneno", "veleno", "яд" }

local function isPoisonName(name)
    if not name then return false end
    local n = strlower(name)
    for i = 1, getn(POISON_WORDS) do
        if strfind(n, POISON_WORDS[i], 1, true) then return true end
    end
    return false
end
PB.isPoisonName = isPoisonName

local function linkId(link)
    if not link then return nil end
    local _, _, id = strfind(link, "item:(%d+)")
    return tonumber(id)
end

-- fishing lures (by item id, so any client language): short label, bonus
local LURES = {
    [6529] = { "Bauble", 25 },        -- Shiny Bauble
    [6530] = { "Worms", 50 },         -- Nightcrawlers
    [6811] = { "Fish Lens", 50 },     -- Aquadynamic Fish Lens
    [6532] = { "Baubles", 75 },       -- Bright Baubles
    [7307] = { "Flesh Worm", 75 },    -- Flesh Eating Worm
    [6533] = { "Attractor", 100 },    -- Aquadynamic Fish Attractor
}
PB.LURES = LURES

local POLES = {
    [6256] = true, [6365] = true, [6366] = true, [6367] = true,
    [12225] = true, [19022] = true, [19970] = true,
}

local function texHas(tex, word)
    return tex and strfind(strlower(tex), word, 1, true) ~= nil
end

-- fishing pole in the main hand: that row works with lures, not poisons
function PB.HasPole()
    local link = GetInventoryItemLink("player", 16)
    if not link then return false end
    local id = linkId(link)
    if id and POLES[id] then return true end
    return texHas(GetInventoryItemTexture("player", 16), "fishingpole")
end

local function isLureSlot(slot)
    return slot == 16 and PB.HasPole()
end
PB.isLureSlot = isLureSlot

-- the chosen item / what this addon put on, kept apart for pole and blades
local function choiceOf(slot)
    if isLureSlot(slot) then return PoisonBarDB.lureChoice end
    return PoisonBarDB.choice[slot]
end
local function setChoice(slot, name)
    if isLureSlot(slot) then PoisonBarDB.lureChoice = name
    else PoisonBarDB.choice[slot] = name end
end
local function appliedKey(slot)
    if isLureSlot(slot) then return "lure" end
    return slot
end

-- list of { name, texture, count, bag, slot } (first stack of each kind),
-- for poisons and for fishing lures
function PB.ScanPoisons()
    local list, byName, lures, lureByName = {}, {}, {}, {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            local name = linkName(link)
            local id = linkId(link)
            local L, B
            if id and LURES[id] then L, B = lures, lureByName
            elseif isPoisonName(name) then L, B = list, byName end
            if L then
                local tex, count = GetContainerItemInfo(bag, slot)
                count = count or 1
                local p = B[name]
                if p then
                    p.count = p.count + count
                else
                    p = { name = name, texture = tex, count = count, bag = bag, slot = slot, id = id }
                    B[name] = p
                    table.insert(L, p)
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    table.sort(lures, function(a, b) return LURES[a.id][2] < LURES[b.id][2] end)
    PB.poisons, PB.poisonByName = list, byName
    PB.lures, PB.lureByName = lures, lureByName
    return list
end

local function itemsFor(slot)
    if isLureSlot(slot) then return PB.lures or {}, PB.lureByName or {} end
    return PB.poisons or {}, PB.poisonByName or {}
end

----------------------------------------------------------------------
-- what is on the weapons
----------------------------------------------------------------------

-- has, seconds left, charges, poison name (or nil)
function PB.WeaponPoison(slot)
    local mh, mhTime, mhCharges, oh, ohTime, ohCharges = GetWeaponEnchantInfo()
    local has, ms, charges
    if slot == 16 then has, ms, charges = mh, mhTime, mhCharges
    else has, ms, charges = oh, ohTime, ohCharges end
    if not has then return false end
    local name = PoisonBarDB and PoisonBarDB.applied[appliedKey(slot)]
    return true, (ms or 0) / 1000, charges or 0, name
end

----------------------------------------------------------------------
-- applying a poison (always a click by the player)
----------------------------------------------------------------------

local function call(fname, fmt, a, b)
    local f = getglobal(fname)
    if f and pcall(f, a, b) then return true end
    -- a direct call has been refused on this client: RunScript fallback
    if RunScript then
        return pcall(RunScript, strformat(fmt, a, b))
    end
    return false
end

local pending = {} -- [slot] = { name = "...", t = GetTime() }

function PB.Apply(slot)
    if not GetInventoryItemLink("player", slot) then
        echo(HAND[slot] .. ": no weapon")
        return
    end
    PB.ScanPoisons()
    local lure = isLureSlot(slot)
    local name = choiceOf(slot)
    local _, byName = itemsFor(slot)
    local p = name and byName[name]
    if not p then
        if name then
            echo("no " .. name .. " in your bags")
        else
            echo("right-click the " .. strlower(HAND[slot]) .. " row to choose a " .. (lure and "fishing lure" or "poison"))
        end
        return
    end
    if UnitAffectingCombat and UnitAffectingCombat("player") then
        -- the client may refuse; try anyway, it is the player's click
    end
    local _, before = PB.WeaponPoison(slot)
    if SpellIsTargeting and SpellIsTargeting() then SpellStopTargeting() end
    if CursorHasItem and CursorHasItem() then ClearCursor() end

    call("UseContainerItem", "UseContainerItem(%d,%d)", p.bag, p.slot)

    -- a poison now waits for a target item: the weapon. A lure may go on
    -- the equipped pole by itself, without asking for a target.
    local targeting = true
    if SpellIsTargeting then targeting = SpellIsTargeting() end
    if not targeting then
        if lure then
            pending[appliedKey(slot)] = { slot = slot, name = p.name, t = GetTime(), prev = before or -1 }
            return
        end
        echo("could not use " .. p.name)
        return
    end
    call("PickupInventoryItem", "PickupInventoryItem(%d)", slot)
    -- without SpellIsTargeting the weapon itself may have been picked up:
    -- clicking the same slot again puts it back
    if not SpellIsTargeting and CursorHasItem and CursorHasItem() then
        PickupInventoryItem(slot)
    end
    -- "replace the existing enchantment?" dialog
    if StaticPopup_Visible and StaticPopup_Visible("REPLACE_ENCHANT") then
        if ReplaceEnchant then pcall(ReplaceEnchant) end
        if StaticPopup_Hide then StaticPopup_Hide("REPLACE_ENCHANT") end
    end
    pending[appliedKey(slot)] = { slot = slot, name = p.name, t = GetTime(), prev = before or -1 }
end

----------------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------------

local function mkText(parent, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(FONT, size or 11, "OUTLINE")
    fs:SetJustifyH("LEFT")
    return fs
end

local function fmtTime(sec)
    sec = floor(sec)
    if sec >= 3600 then
        return strformat("%dh", floor(sec / 3600 + 0.5))
    end
    local m = floor(sec / 60)
    return strformat("%d:%02d", m, sec - m * 60)
end

-- short label: "Instant Poison VI" -> "Instant VI"
local function shortName(name)
    if not name then return "?" end
    local _, _, first, rank = strfind(name, "^(%S+).-%s([IVX]+)$")
    if first then return first .. " " .. rank end
    local _, _, word = strfind(name, "^(%S+)")
    if word then return word end
    local s = gsub(name, "%s*[Pp]oison%s*", " ")
    s = gsub(s, "^%s+", "")
    s = gsub(s, "%s+$", "")
    s = gsub(s, "%s%s+", " ")
    if s == "" then return name end
    return s
end

----------------------------------------------------------------------
-- moving by hand (see header comment)
----------------------------------------------------------------------

local bar
local drag

local function uiScale()
    local ok, s = pcall(UIParent.GetEffectiveScale, UIParent)
    if ok and s and s > 0 then return s end
    return 1
end

-- GetCursorPosition() is in pixels on Blizzard clients but may be in UI
-- units here: the conversion that puts the cursor inside the bar wins
local function cursorScale(cx, cy)
    local s1 = uiScale()
    local l, r, t, b = bar:GetLeft(), bar:GetRight(), bar:GetTop(), bar:GetBottom()
    if l and r and t and b then
        local cands = { s1, 1 }
        for i = 1, 2 do
            local x, y = cx / cands[i], cy / cands[i]
            if x >= l - 4 and x <= r + 4 and y >= b - 4 and y <= t + 4 then
                return cands[i]
            end
        end
    end
    return s1
end

local function place(x, y)
    bar:ClearAllPoints()
    bar:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

local function startDrag()
    if PoisonBarDB.locked then return end
    if not GetCursorPosition then return end
    local cx, cy = GetCursorPosition()
    if not cx then return end
    local x, y = bar:GetCenter()
    local ux, uy = UIParent:GetCenter()
    drag = { sx = cx, sy = cy, x = (x or 0) - (ux or 0), y = (y or 0) - (uy or 0), s = cursorScale(cx, cy) }
end

local function updateDrag()
    if not drag then return end
    local cx, cy = GetCursorPosition()
    if not cx then return end
    drag.cx = drag.x + (cx - drag.sx) / drag.s
    drag.cy = drag.y + (cy - drag.sy) / drag.s
    place(drag.cx, drag.cy)
end

local function stopDrag()
    if not drag then return end
    local x = floor((drag.cx or drag.x) + 0.5)
    local y = floor((drag.cy or drag.y) + 0.5)
    drag = nil
    place(x, y)
    PoisonBarDB.pos = { x = x, y = y }
end

PB.dragActive = function() return drag ~= nil end

----------------------------------------------------------------------
-- poison chooser menu
----------------------------------------------------------------------

local menu

local function buildMenu()
    menu = CreateFrame("Frame", "PoisonBarMenu", UIParent)
    menu:SetFrameStrata("DIALOG")
    menu:SetWidth(190)
    menu:SetHeight(40)
    menu:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    menu:SetBackdropColor(0, 0, 0, 0.92)
    menu:EnableMouse(true)
    menu:Hide()
    menu.rows = {}
    menu.title = mkText(menu, 11)
    menu.title:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -7)
    table.insert(UISpecialFrames, "PoisonBarMenu")
end

local function menuRow(i)
    local r = menu.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, menu)
    -- one anchor + fixed size: two-point anchors collapse rows on this client
    r:SetHeight(20)
    r:SetWidth(178)
    r:SetPoint("TOPLEFT", menu, "TOPLEFT", 6, -6 - 16 - (i - 1) * 21)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetWidth(18) r.icon:SetHeight(18)
    r.icon:SetPoint("LEFT", r, "LEFT", 2, 0)
    r.text = mkText(r, 11)
    r.text:SetPoint("LEFT", r, "LEFT", 25, 0)
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(r)
    hl:SetTexture(1, 1, 1, 0.15)
    r:SetScript("OnClick", function()
        setChoice(menu.slot, this.poison)
        menu:Hide()
        PB.Update()
        if this.poison then
            echo(HAND[menu.slot] .. ": " .. this.poison)
        end
    end)
    menu.rows[i] = r
    return r
end

function PB.OpenMenu(slot, anchor)
    if not menu then return end
    if menu:IsShown() and menu.slot == slot then menu:Hide() return end
    menu.slot = slot
    local lure = isLureSlot(slot)
    menu.title:SetText(lure and "Fishing lure:" or (HAND[slot] .. " poison:"))
    PB.ScanPoisons()
    local list = itemsFor(slot)
    local n = getn(list)
    for i = 1, n do
        local r = menuRow(i)
        r.poison = list[i].name
        r.icon:SetTexture(list[i].texture)
        r.icon:Show()
        local mark = choiceOf(slot) == list[i].name and "|cff9cff4f> |r" or ""
        local bonus = lure and LURES[list[i].id] and ("  |cff80c0ff+" .. LURES[list[i].id][2] .. "|r") or ""
        r.text:SetText(mark .. list[i].name .. bonus .. "  |cffaaaaaa(" .. list[i].count .. ")|r")
        r:Show()
    end
    -- last row: none
    local r = menuRow(n + 1)
    r.poison = nil
    r.icon:Hide()
    r.text:SetText(n == 0 and ("|cffff8080no " .. (lure and "fishing lures" or "poisons") .. " in your bags|r") or "|cffaaaaaanone|r")
    r:Show()
    for i = n + 2, getn(menu.rows) do menu.rows[i]:Hide() end
    menu:SetHeight(16 + 12 + (n + 1) * 21)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    menu:Show()
end

----------------------------------------------------------------------
-- the bar
----------------------------------------------------------------------

local rows = {}

local function buildRow(i, slot)
    local r = CreateFrame("Button", "PoisonBarRow" .. i, bar)
    r:SetWidth(134)
    r:SetHeight(34)
    r:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -16 - (i - 1) * 36)
    r.slot = slot

    r.weapon = r:CreateTexture(nil, "ARTWORK")
    r.weapon:SetWidth(30) r.weapon:SetHeight(30)
    r.weapon:SetPoint("LEFT", r, "LEFT", 2, 0)

    r.poison = r:CreateTexture(nil, "ARTWORK")
    r.poison:SetWidth(20) r.poison:SetHeight(20)
    r.poison:SetPoint("BOTTOMLEFT", r.weapon, "BOTTOMRIGHT", 3, 0)
    r.count = mkText(r, 8)
    -- how many of the chosen poison you carry: small, inside the icon
    r.count:SetPoint("BOTTOMRIGHT", r.poison, "BOTTOMRIGHT", -1, 1)

    r.name = mkText(r, 10)
    r.name:SetPoint("TOPLEFT", r.weapon, "TOPRIGHT", 25, -1)
    r.info = mkText(r, 11)
    r.info:SetPoint("BOTTOMLEFT", r.weapon, "BOTTOMRIGHT", 25, 1)

    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(r)
    hl:SetTexture(1, 1, 1, 0.12)

    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            PB.OpenMenu(this.slot, this)
        else
            PB.Apply(this.slot)
        end
    end)
    r:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if GetInventoryItemLink("player", this.slot) then
            GameTooltip:SetInventoryItem("player", this.slot)
        else
            GameTooltip:SetText(HAND[this.slot], 1, 1, 1)
        end
        GameTooltip:AddLine("Left-click: apply " .. (choiceOf(this.slot) or "(choose first)"), 0.6, 1, 0.3)
        GameTooltip:AddLine(isLureSlot(this.slot) and "Right-click: choose fishing lure" or "Right-click: choose poison", 0.6, 1, 0.3)
        GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
end

local function buildBar()
    bar = CreateFrame("Frame", "PoisonBarFrame", UIParent)
    bar:SetWidth(142)
    bar:SetHeight(16 + 2 * 36 + 4)
    bar:SetFrameStrata("MEDIUM")
    bar:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bar:SetBackdropColor(0, 0, 0, 0.7)
    local pos = PoisonBarDB.pos
    place(pos and pos.x or 0, pos and pos.y or -180)

    -- title bar = drag handle (a Button, so the button-up arrives)
    local title = CreateFrame("Button", "PoisonBarTitle", bar)
    title:SetHeight(14)
    title:SetWidth(134)
    title:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -2)
    local t = mkText(title, 10)
    t:SetPoint("LEFT", title, "LEFT", 4, 0)
    t:SetText("|cff9cff4fPoisons|r")
    title.lock = mkText(title, 9)
    title.lock:SetPoint("RIGHT", title, "RIGHT", -3, 0)
    title:SetScript("OnMouseDown", function()
        if drag then stopDrag() return end -- a lost button-up: next press drops
        startDrag()
    end)
    title:SetScript("OnMouseUp", function() stopDrag() end)
    title:SetScript("OnUpdate", updateDrag)
    title:SetScript("OnHide", function() stopDrag() end)
    bar.title = title

    buildRow(1, 16)
    buildRow(2, 17)
end

local warned = {}

function PB.Update()
    if not bar then return end
    bar.title.lock:SetText(PoisonBarDB.locked and "|cff888888locked|r" or "")
    local shown = 0
    for i = 1, 2 do
        local r = rows[i]
        local slot = r.slot
        local link = GetInventoryItemLink("player", slot)
        if not link then
            r:Hide()
        else
            shown = shown + 1
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -16 - (shown - 1) * 36)
            r:Show()
            r.weapon:SetTexture(GetInventoryItemTexture("player", slot))

            local lure = isLureSlot(slot)
            local _, items = itemsFor(slot)
            local choice = choiceOf(slot)
            local p = choice and items[choice]
            if p then
                r.poison:SetTexture(p.texture)
                r.poison:SetVertexColor(1, 1, 1)
                r.count:SetText(p.count)
            elseif choice then
                -- chosen but none left in the bags
                r.poison:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                r.poison:SetVertexColor(1, 0.3, 0.3)
                r.count:SetText("|cffff40400|r")
            else
                r.poison:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                r.poison:SetVertexColor(0.6, 0.6, 0.6)
                r.count:SetText("")
            end

            local has, sec, charges, name = PB.WeaponPoison(slot)
            local key = appliedKey(slot)
            if has then
                local low
                if lure then
                    low = sec < 60 -- lures last 10 minutes
                else
                    low = sec < PoisonBarDB.warnMinutes * 60 or (charges > 0 and charges < PoisonBarDB.warnCharges)
                end
                local col = low and "|cffff5040" or "|cff9cff4f"
                local label
                if lure then
                    local lp = name and PB.lureByName and PB.lureByName[name]
                    local info = lp and LURES[lp.id]
                    label = info and (info[1] .. " +" .. info[2]) or (name or "Lure")
                else
                    label = shortName(name or "Poison")
                end
                r.name:SetText(col .. label .. "|r")
                -- charges left on the weapon, marked "x38" so it is not read as a time
                local c = charges > 0 and (" |cffffd200x" .. charges .. "|r") or ""
                r.info:SetText(fmtTime(sec) .. c)
                warned[key] = nil
            else
                r.name:SetText("|cffff5040none|r")
                r.info:SetText("")
                if PoisonBarDB.applied[key] and not warned[key] then
                    -- it was on and has run out
                    warned[key] = true
                    PoisonBarDB.applied[key] = nil
                    if PoisonBarDB.warnSound and PlaySound then pcall(PlaySound, "RaidWarning") end
                    if UIErrorsFrame then
                        UIErrorsFrame:AddMessage(lure and "Fishing lure has worn off" or (HAND[slot] .. " poison has worn off"), 1, 0.3, 0.2, 1, 3)
                    end
                end
            end
        end
    end
    bar:SetHeight(16 + (shown > 0 and shown or 1) * 36 + 4)
end

----------------------------------------------------------------------
-- events
----------------------------------------------------------------------

-- a poison we started has landed on the weapon: remember its name
-- (the charges/time come back from GetWeaponEnchantInfo, the name does not)
function PB.CheckPending()
    for key, p in pairs(pending) do
        local _, sec = PB.WeaponPoison(p.slot)
        if sec and sec > (p.prev or -1) + 60 then
            -- fresh poison/lure: more time left than before the click
            PoisonBarDB.applied[key] = p.name
            pending[key] = nil
        elseif GetTime() - p.t > 8 then
            pending[key] = nil -- cancelled or interrupted
        end
    end
end

local frame = CreateFrame("Frame", "PoisonBarEvents")
frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("BAG_UPDATE")
frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

local loaded = false

frame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        PoisonBarDB = PoisonBarDB or {}
        for k, v in pairs(DEFAULTS) do
            if PoisonBarDB[k] == nil then
                if type(v) == "table" then PoisonBarDB[k] = {} else PoisonBarDB[k] = v end
            end
        end
        -- no hidden scan tooltip: this client shows it on screen even when
        -- hidden, so the name comes from the poison this addon put on
        buildBar()
        buildMenu()
        loaded = true
        PB.ScanPoisons()
        PB.Update()
        return
    end
    if not loaded then return end
    if event == "BAG_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        PB.ScanPoisons()
    end
    if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
    PB.CheckPending()
    PB.Update()
end)

local tick = 0
frame:SetScript("OnUpdate", function()
    if not loaded then return end
    tick = tick + arg1
    if tick < 0.5 then return end
    tick = 0
    PB.CheckPending()
    PB.Update()
end)

----------------------------------------------------------------------
-- slash commands
----------------------------------------------------------------------

SLASH_POISONBAR1 = "/pb"
SLASH_POISONBAR2 = "/poisonbar"
SlashCmdList["POISONBAR"] = function(msg)
    if not loaded then return end
    msg = strlower(gsub(msg or "", "^%s*(.-)%s*$", "%1"))
    local _, _, cmd, rest = strfind(msg, "^(%S*)%s*(.*)$")
    if cmd == "mh" or cmd == "main" then
        PB.Apply(16)
    elseif cmd == "oh" or cmd == "off" then
        PB.Apply(17)
    elseif cmd == "lock" then
        PoisonBarDB.locked = not PoisonBarDB.locked
        echo(PoisonBarDB.locked and "bar locked" or "bar unlocked")
        PB.Update()
    elseif cmd == "show" then
        bar:Show()
    elseif cmd == "hide" then
        bar:Hide()
    elseif cmd == "reset" then
        PoisonBarDB.pos = nil
        place(0, -180)
        bar:Show()
    elseif cmd == "warn" and tonumber(rest) then
        PoisonBarDB.warnMinutes = tonumber(rest)
        echo("warning below " .. rest .. " minutes")
    elseif cmd == "sound" then
        PoisonBarDB.warnSound = not PoisonBarDB.warnSound
        echo("sound " .. (PoisonBarDB.warnSound and "on" or "off"))
    else
        echo("left-click a row: apply poison, right-click: choose poison")
        echo("/pb mh | oh - apply (for macros/keys)")
        echo("/pb lock, /pb reset, /pb show | hide")
        echo("/pb warn <minutes>, /pb sound")
    end
end
