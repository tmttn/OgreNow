-- Ogre Now: yell when the Krol'dok Battlegear (5/5) bonus turns you into an ogre.
--
-- The set buff "Ogre Dominance" shows its size in the tooltip
-- ("Stamina increased by 4.") rather than as a stack number on the icon,
-- so the stack count is read from the aura's value (or its tooltip text).
-- At 20 stacks (+20 Stamina) you are an ogre.
--
-- Outside instances Blizzard only allows /yell from a key press or click,
-- so the yell then waits for your next action-bar press or a click on the
-- pop-up button.

local MESSAGE = "IT'S ALL OGRE NOW"

local BUFF = "Ogre Dominance"
local MAX_STACKS = 20
local db
local isOgre = false
local pending = false

-- Fallback: read "increased by N" from the buff's tooltip.
local scanTip
local function TooltipNumber(index)
    if C_TooltipInfo and C_TooltipInfo.GetUnitBuff then
        local data = C_TooltipInfo.GetUnitBuff("player", index)
        if data and data.lines then
            for _, line in ipairs(data.lines) do
                local text = line.leftText
                if issecretvalue and issecretvalue(text) then text = nil end
                local n = text and text:match("increased by (%d+)")
                if n then return tonumber(n) end
            end
        end
        return 0
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "OgreNowScanTip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:SetUnitBuff("player", index)
    for i = 2, scanTip:NumLines() do
        local fs = _G["OgreNowScanTipTextLeft" .. i]
        local n = fs and fs:GetText() and fs:GetText():match("increased by (%d+)")
        if n then return tonumber(n) end
    end
    return 0
end

-- This client can hide aura data from add-ons ("secret values").
local function Secret(v)
    return issecretvalue and issecretvalue(v) or false
end

local function Plain(v)
    if v == nil or Secret(v) then return nil end
    return v
end

-- Iterate player buffs: callback(index, name, stacks, value, spellId)
-- index is the buff's position, used for the tooltip fallback.
local function ForEachBuff(callback)
    -- In combat the client hides auras; reading them then can error.
    if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
        return
    end
    local index = 0
    local function Handle(aura)
        if not aura or Secret(aura) then return end
        index = index + 1
        local name = Plain(aura.name)
        if not name then return end
        local points = Plain(aura.points)
        local value = points and Plain(points[1])
        callback(index, name, tonumber(Plain(aura.applications)) or 0,
                 tonumber(value) or 0, Plain(aura.spellId))
    end

    if C_UnitAuras and C_UnitAuras.GetAuraSlots and C_UnitAuras.GetAuraDataBySlot then
        local token
        for _ = 1, 20 do
            -- slots[1] (the continuation token) is usually nil, so #slots is
            -- unreliable; count the returns with select("#") instead.
            local slots = { n = 0 }
            local function Pack(...)
                slots.n = select("#", ...)
                for k = 1, slots.n do slots[k] = (select(k, ...)) end
            end
            Pack(C_UnitAuras.GetAuraSlots("player", "HELPFUL", nil, token))
            if Secret(slots[1]) then return end
            token = slots[1]
            for i = 2, slots.n do
                local slot = Plain(slots[i])
                if slot then Handle(C_UnitAuras.GetAuraDataBySlot("player", slot)) end
            end
            if not token then return end
        end
    elseif C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
            local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
            if not aura then return end
            Handle(aura)
        end
    else
        for i = 1, 40 do
            local n, _, c, _, _, _, _, _, _, id, _, _, _, _, _, v1 = UnitBuff("player", i)
            if not n then return end
            Handle({ name = n, applications = c, spellId = id, points = { v1 } })
        end
    end
end

local function BuffStacks(index, count, value)
    local stacks = math.max(count, value)
    if stacks == 0 then stacks = TooltipNumber(index) end
    return stacks
end

-- Every stack is +1 Stamina. Out of combat we learn
-- baseStamina = Stamina - known stacks; when stats are readable but auras
-- are not, the stacks are estimated as Stamina - baseStamina.
-- (In combat this client usually hides stats too.)
local baseStamina
local function Stamina()
    if C_Secrets and C_Secrets.ShouldUnitStatsBeSecret and C_Secrets.ShouldUnitStatsBeSecret() then
        return nil
    end
    local ok, _, effective = pcall(UnitStat, "player", 3)
    if not ok then return nil end
    return tonumber(Plain(effective))
end

local function EstimatedStacks()
    local stam = Stamina()
    if not (stam and baseStamina) then return nil end
    return stam - baseStamina
end

local function OgreActive()
    local active, seen, readable = false, false, false
    local stacks = 0
    ForEachBuff(function(i, name, count, value, id)
        readable = true
        if name == BUFF then
            seen = true
            if id then db.spellId = id end
            stacks = BuffStacks(i, count, value)
            if stacks >= MAX_STACKS then active = true end
        end
    end)
    if readable then
        local stam = Stamina()
        if stam then baseStamina = stam - stacks end
    else
        local est = EstimatedStacks()
        if est and est >= MAX_STACKS then active = true end
    end
    -- Fallback: look the buff up directly by its remembered spell ID.
    if not seen and db.spellId and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = Plain(C_UnitAuras.GetPlayerAuraBySpellID(db.spellId))
        if aura then
            local points = Plain(aura.points)
            local stacks = math.max(tonumber(Plain(aura.applications)) or 0,
                                    tonumber(points and Plain(points[1])) or 0)
            if stacks >= MAX_STACKS then active = true end
        end
    end
    return active
end

-- Pop-up button (a click is always allowed to yell)
local button = CreateFrame("Button", "OgreNowButton", UIParent, "UIPanelButtonTemplate")
button:SetSize(220, 40)
button:SetPoint("CENTER", 0, 180)
button:SetText(MESSAGE .. "!")
button:Hide()

local function DoYell()
    if not pending then return end
    pending = false
    button:Hide()
    SendChatMessage(MESSAGE, "YELL")
end

button:SetScript("OnClick", DoYell)

-- Outside instances the game only allows /yell during a key press or
-- click, so the yell is queued and fires on the very next key you press
-- (any key, also movement). Only if you press nothing for 3 seconds does
-- the button appear.
local yellHeard = false
local function Trigger()
    pending = true
    yellHeard = false
    if IsInInstance() then
        DoYell()
        return
    end
    C_Timer.After(3, function()
        if pending then
            button:Show()
            PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
        end
    end)
end

-- Sees every key press without eating it (keys still reach the game).
local keyWatcher = CreateFrame("Frame", "OgreNowKeyWatcher", UIParent)
local function SetupKeyWatcher()
    -- SetPropagateKeyboardInput is not allowed in combat
    if InCombatLockdown() then return C_Timer.After(5, SetupKeyWatcher) end
    keyWatcher:SetPropagateKeyboardInput(true)
    keyWatcher:EnableKeyboard(true)
end
SetupKeyWatcher()
keyWatcher:SetScript("OnKeyDown", function() DoYell() end)
WorldFrame:HookScript("OnMouseDown", function() DoYell() end)

-- Fire the queued yell on the next action button press (key or click).
for _, fn in ipairs({ "ActionButtonDown", "MultiActionButtonDown" }) do
    if type(_G[fn]) == "function" then hooksecurefunc(fn, DoYell) end
end
for _, prefix in ipairs({ "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
                          "MultiBarRightButton", "MultiBarLeftButton" }) do
    for i = 1, 12 do
        local b = _G[prefix .. i]
        if b then b:HookScript("OnClick", DoYell) end
    end
end

-- In combat this client hides all aura data (and the combat log) from
-- add-ons. The ogre form changes your character model, which is still
-- readable: a hidden model frame reports the player's model file ID.
-- normalModel is learned whenever you are certainly not an ogre.
local normalModel
local modelFrame = CreateFrame("PlayerModel", nil, UIParent)
modelFrame:SetSize(1, 1)
modelFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMRIGHT", 10, -10) -- off screen
modelFrame:SetAlpha(0)

local function CurrentModel()
    local ok, id = pcall(function()
        modelFrame:SetUnit("player")
        return modelFrame.GetModelFileID and modelFrame:GetModelFileID()
    end)
    if not ok then return nil end
    return Plain(id)
end

-- Last resort when even the model ID is hidden: the ogre form is the only
-- way a paladin's model changes in combat, so a model change in combat
-- sets this flag. Reset when combat ends.
local combatToggle = false

local function ModelIsOgre()
    if IsMounted() then return false end
    local id = CurrentModel()
    if id == nil then return combatToggle end
    return normalModel ~= nil and id ~= normalModel
end

local function LearnNormalModel()
    if InCombatLockdown() or IsMounted() or OgreActive() then return end
    local id = CurrentModel()
    if id then normalModel = id end
end

local function Update(event)
    local ok, now = pcall(function() return OgreActive() or ModelIsOgre() end)
    if not ok then return end
    if now and not isOgre then Trigger() end
    if not now then
        pending = false
        button:Hide()
    end
    isOgre = now
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
-- unit events for the player only, so the (possibly secret) unit argument
-- never has to be compared
f:RegisterUnitEvent("UNIT_AURA", "player")
f:RegisterUnitEvent("UNIT_MODEL_CHANGED", "player")
f:RegisterUnitEvent("UNIT_STATS", "player")
f:RegisterEvent("CHAT_MSG_YELL")
f:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "CHAT_MSG_YELL" then
        local msg, sender = Plain(arg1), Plain(arg2)
        if msg == MESSAGE and sender and Ambiguate(sender, "short") == UnitName("player") then
            yellHeard = true
            pending = false
            button:Hide()
        end
        return
    end
    if event == "ADDON_LOADED" then
        if arg1 ~= "OgreNow" then return end
        OgreNowDB = OgreNowDB or {}
        -- the trigger used to be configurable; drop old saved values
        OgreNowDB.buff, OgreNowDB.maxStacks = nil, nil
        db = OgreNowDB
        return
    end
    if not db then return end
    if event == "PLAYER_ENTERING_WORLD" then
        -- the model needs a moment to load after a loading screen
        C_Timer.After(2, function()
            LearnNormalModel()
            isOgre = OgreActive() or ModelIsOgre() -- no yell for logging in as an ogre
        end)
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        combatToggle = false
        LearnNormalModel()
    end
    if event == "UNIT_MODEL_CHANGED" then
        -- UNIT_MODEL_CHANGED also fires without a real change, so only
        -- switch on (once per fight), never back off until combat ends.
        if InCombatLockdown() and not IsMounted() then combatToggle = true end
        -- give the new model a moment to load before reading it
        C_Timer.After(0.3, function() Update(event) end)
        return
    end
    Update(event)
end)
