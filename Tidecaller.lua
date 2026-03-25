--[[
Name: Tidecaller
Description: Shaman healing addon with Banzai-1.0 aggro integration,
             position-aware Chain Heal target selection, and pressure-based
             Lesser Healing Wave downranking.
             Two modes: Solo (pressure-driven, LHW primary) and
             Raid (Chain Heal primary with cluster scoring).
Dependencies: Banzai-1.0 (which requires AceLibrary, AceEvent-2.0, RosterLib-2.0)
Client: TurtleWoW 1.12 / SuperWoW -- Lua 5.0 compatible, no goto statements
--]]

-------------------------------------------------------------------------------
-- Saved Variables
-------------------------------------------------------------------------------

TidecallerDB = TidecallerDB or {
    DEBUG_MODE          = false,
    HEAL_THRESHOLD      = 90,      -- Only consider units below this hp%
    CHAIN_HEAL_MIN      = 2,       -- Min hurt players in cluster to prefer Chain Heal
    CHAIN_HEAL_RANGE    = 12,      -- Yards for Chain Heal bounce scoring
    LHW_PRESSURE_FLOOR  = 0.55,    -- Urgency gate for QuickHeal avoidance; below this pressure = skippable
    TANK_OVERHEAL_FACTOR = 1.20,   -- Chosen rank must cover this multiple of a tank's deficit
    DOWNRANK_AGGRESSIVENESS = 1.0, -- 0.0-1.0: scales required threshold in PickLHWRank (1.0 = full)
    CRISIS_AGGRESSIVENESS   = 1.0, -- 0.0-1.0: scales required threshold in crisis path (1.0 = full)
    LHW_RANKS_ENABLED  = { true, true, true, true, true, true }, -- R1-R6
    CH_RANKS_ENABLED   = { true, false, false },                 -- R1-R3 (R2/R3 off by default)
    QUICKHEAL_AVOID     = false,   -- Skip lowest HP target (assume QuickHeal users cover them)
    FOLLOW_ENABLED      = false,
    FOLLOW_TARGET_NAME  = nil,   -- kept for backward compat; runtime uses FOLLOW_TARGET_UNIT
    FOLLOW_TARGET_UNIT  = nil,   -- unitid: "party1", "party2", "raid1", etc.
}

-------------------------------------------------------------------------------
-- Local Settings (runtime copy)
-------------------------------------------------------------------------------

local settings = {}
for k, v in pairs(TidecallerDB) do settings[k] = v end

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local Banzai         = nil
local TidecallerEvents = nil
local inCombat       = false

local aggroCount     = {}   -- aggroCount[unitName] = rolling integer
local liveAggro      = {}   -- liveAggro[unitName]  = true/false

-------------------------------------------------------------------------------
-- Heal Decision Log
-------------------------------------------------------------------------------

local LOG_MAX_ENTRIES = 500
local logBuffer       = nil
local logEntryCount   = 0

-------------------------------------------------------------------------------
-- Spell ID Tables
-- Chain Heal:         R1=1064  R2=10622  R3=10623  (only R1 used — best mana efficiency)
-- Lesser Healing Wave: R1=516  R2=8005  R3=8006  R4=10466  R5=10467  R6=25420
-------------------------------------------------------------------------------

-- Spell IDs for reference (not used at runtime; CastSpellByName handles lookup):
--   Chain Heal R1: 1064
--   LHW R1:516  R2:8005  R3:8006  R4:10466  R5:10467  R6:25420

-- LHW mana costs (in-game confirmed)
local LHW_MANA = { 99, 137, 175, 223, 289, 361 }

-- LHW average base heals (midpoint of in-game tooltip ranges, untalented at 60)
-- R1: 170-195 → 182   R2: 257-292 → 274   R3: 349-394 → 371
-- R4: 473-529 → 501   R5: 649-723 → 686   R6: 832-928 → 880
local LHW_BASE = { 182, 274, 371, 501, 686, 880 }

-- +healing coefficient for LHW (1.5s cast time; coefficient = 1.5/3.5)
-- No downranking penalty on Turtle WoW — confirmed empirically.
local LHW_HEAL_COEFF = 0.4286

-- Chain Heal R1 is always used — best mana efficiency (6.06 hp/mana across 3 targets).
-- R2/R3 marginal upgrade cost (~3.1 hp/mana) is worse than LHW R6 (3.35 hp/mana).
-- R1: 332-381 base → midpoint 356, ~856 effective at 769 +healing
local CH_BASE_R1    = 356
local CH_HEAL_COEFF = 0.6500  -- empirically derived (theoretical 2.5/3.5=0.7143 overshoots R1)

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("Tidecaller: " .. msg)
end

local function Debug(msg)
    if settings.DEBUG_MODE then
        DEFAULT_CHAT_FRAME:AddMessage("|cff88ffffTidecaller:|r " .. msg)
    end
end

-------------------------------------------------------------------------------
-- Healing Power Scanner
--
-- Self-contained; no dependency on BonusScanner or BetterCharacterStats.
-- Scans all 19 equipment slots and active buffs for:
--   damage_and_healing  (+spell damage and healing items, weapon oils)
--   healing_only        (+healing only items, healing buffs)
-- Total healing power = damage_and_healing + healing_only
--
-- Cache is invalidated on UNIT_INVENTORY_CHANGED and PLAYER_AURAS_CHANGED.
-- Actual scan is deferred until GetEffectiveHealingPower() is called so we
-- never do tooltip work inside an event handler.
-------------------------------------------------------------------------------

local TCL_Tooltip = CreateFrame("GameTooltip", "TidecallerScanTooltip", nil, "GameTooltipTemplate")
TCL_Tooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
local TCL_PREFIX = "TidecallerScanTooltip"

local healCache = {
    damage_and_healing = 0,
    healing_only       = 0,
    dirty              = true,   -- start dirty so first call triggers a scan
}

-- Register cache invalidation events on the existing eventFrame (defined later,
-- but event registration is deferred to ADDON_LOADED anyway, so this is fine).
-- We use a separate small frame here to keep it self-contained.
local healCacheFrame = CreateFrame("Frame")
healCacheFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
healCacheFrame:RegisterEvent("PLAYER_AURAS_CHANGED")
healCacheFrame:SetScript("OnEvent", function()
    if event == "UNIT_INVENTORY_CHANGED" and arg1 ~= "player" then return end
    healCache.dirty = true
end)

local function ScanHealingPower()
    local dah = 0   -- damage and healing
    local ho  = 0   -- healing only

    -- Track which set bonuses we've already counted.
    -- Key: setName.."|"..value so each distinct bonus value is counted once
    -- per set regardless of how many pieces are equipped.
    local countedSets = {}

    -- ---- Gear scan ----
    for slot = 1, 19 do
        local itemLink = GetInventoryItemLink("player", slot)
        if itemLink then
            local _, _, eqLink = string.find(itemLink, "(item:%d+:%d+:%d+:%d+)")
            if eqLink then
                TCL_Tooltip:ClearLines()
                TCL_Tooltip:SetHyperlink(eqLink)
                local setName = nil
                for line = 1, TCL_Tooltip:NumLines() do
                    local text = _G[TCL_PREFIX .. "TextLeft" .. line]:GetText()
                    if text then
                        local _, _, v

                        -- +damage and healing (5 tooltip variants)
                        -- Guard against matching set bonus lines like "(3) Set: Increases..."
                        _, _, v = string.find(text, "Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                        if v and not string.find(text, "Set:") then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "Spell Damage %+(%d+)")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Spell Damage and Healing")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Damage and Healing Spells")
                        if v then dah = dah + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Spell Power")
                        if v then dah = dah + tonumber(v) end

                        -- +healing only (5 tooltip variants)
                        -- Guard against matching set bonus lines like "(3) Set: Increases..."
                        _, _, v = string.find(text, "Increases healing done by spells and effects by up to (%d+)%.")
                        if v and not string.find(text, "Set:") then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "Healing Spells %+(%d+)")
                        if v then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "^%+(%d+) Healing Spells")
                        if v then ho = ho + tonumber(v) end

                        _, _, v = string.find(text, "Healing %+(%d+)")
                        if v then ho = ho + tonumber(v) end

                        -- Atiesh healing portion
                        _, _, v = string.find(text, "Increases your spell damage by up to %d+ and your healing by up to (%d+)%.")
                        if v then ho = ho + tonumber(v) end

                        -- Set name line e.g. "Regalia of the Archmage (2/8)"
                        _, _, v = string.find(text, "^(.+) %(%d/%d%)$")
                        if v then setName = v end

                        -- Set bonuses: active bonuses start with "Set: ...",
                        -- inactive ones start with "(N) Set: ..." where N is pieces required.
                        -- Deduplicate per (setName, type, value) across all equipped pieces.
                        if setName then
                            -- Only match lines that start with "Set:" (no leading number)
                            _, _, v = string.find(text, "^Set: Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                            if v then
                                local key = setName .. "|dah|" .. v
                                if not countedSets[key] then
                                    Debug(string.format("SetBonus DAH +%s from [%s] line: %s", v, setName, string.sub(text,1,40)))
                                    dah = dah + tonumber(v)
                                    countedSets[key] = true
                                end
                            end

                            _, _, v = string.find(text, "^Set: Increases healing done by spells and effects by up to (%d+)%.")
                            if v then
                                local key = setName .. "|ho|" .. v
                                if not countedSets[key] then
                                    Debug(string.format("SetBonus HO +%s from [%s] line: %s", v, setName, string.sub(text,1,40)))
                                    ho = ho + tonumber(v)
                                    countedSets[key] = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Weapon oils (must use SetInventoryItem, not SetHyperlink)
    if TCL_Tooltip:SetInventoryItem("player", 16) then
        for line = 1, TCL_Tooltip:NumLines() do
            local text = _G[TCL_PREFIX .. "TextLeft" .. line]:GetText()
            if text then
                if string.find(text, "^Brilliant Wizard Oil") then
                    dah = dah + 36; break
                elseif string.find(text, "^Lesser Wizard Oil") then
                    dah = dah + 16; break
                elseif string.find(text, "^Minor Wizard Oil") then
                    dah = dah + 8;  break
                elseif string.find(text, "^Wizard Oil") then
                    dah = dah + 24; break
                elseif string.find(text, "^Brilliant Mana Oil") then
                    ho = ho + 25;   break
                end
            end
        end
    end

    -- ---- Aura (buff) scan ----
    for i = 1, 32 do
        local texture = UnitBuff("player", i)
        if not texture then break end

        -- Read buff tooltip lines
        TCL_Tooltip:ClearLines()
        TCL_Tooltip:SetUnitBuff("player", i)
        for line = 1, TCL_Tooltip:NumLines() do
            local text = _G[TCL_PREFIX .. "TextLeft" .. line]:GetText()
            if text then
                local _, _, v

                -- +damage and healing auras (Flask of Supreme Power, etc.)
                _, _, v = string.find(text, "Increases damage and healing done by magical spells and effects by up to (%d+)%.")
                if v then dah = dah + tonumber(v) end

                -- +healing auras (Sayge's Fortune, Songflower, etc.)
                _, _, v = string.find(text, "Healing done by magical spells is increased by up to (%d+)%.")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Increases healing done by magical spells by up to (%d+) for 3600 sec%.")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Healing increased by up to (%d+)%.")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Healing spells increased by up to (%d+)%.")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Increases healing done by magical spells and effects by up to (%d+)%.")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Healing done is increased by up to (%d+)")
                if v then ho = ho + tonumber(v) end

                _, _, v = string.find(text, "Healing Bonus increased by (%d+)")
                if v then ho = ho + tonumber(v) end
            end
        end
    end

    healCache.damage_and_healing = dah
    healCache.healing_only       = ho
    healCache.dirty              = false

    Debug(string.format("HealPower scan: dah=%d ho=%d total=%d", dah, ho, dah + ho))
end

-- Returns total effective healing power (gear + buffs).
-- Scans lazily: only re-scans when inventory or auras changed.
local function GetEffectiveHealingPower()
    if healCache.dirty then
        ScanHealingPower()
    end
    return healCache.damage_and_healing + healCache.healing_only
end

-- Returns the estimated effective heal of LHW rank (1-6) given current +healing gear.
local function LHWEffectiveHeal(rank)
    return LHW_BASE[rank] + GetEffectiveHealingPower() * LHW_HEAL_COEFF
end

-- Returns effective heal on Chain Heal primary target for a given rank (1-3)
local function CHEffectiveHeal(rank)
    rank = rank or 1
    return CH_BASE[rank] + GetEffectiveHealingPower() * CH_HEAL_COEFF
end

-- Chain Heal base heals for all ranks (used by PickCHRank)
-- CH_BASE_R1 kept for backward compat, full table defined below
CH_BASE = { CH_BASE_R1, 449, 606 }
CH_MANA = { 247, 299, 384 }

-- Returns the best enabled Chain Heal rank for a given deficit.
-- Picks the lowest enabled rank whose effective heal covers the deficit.
-- Falls back to highest enabled affordable rank if none covers it.
-- Returns nil if no CH ranks are enabled.
local function PickCHRank(missingHP)
    local enabled = settings.CH_RANKS_ENABLED or { true, false, false }
    local mana    = UnitMana("player")

    -- Find highest enabled affordable rank as fallback
    local fallback = nil
    for r = 3, 1, -1 do
        if enabled[r] and mana >= CH_MANA[r] then
            fallback = r
            break
        end
    end
    if not fallback then
        -- Check if any rank is enabled at all (even if unaffordable)
        for r = 1, 3 do
            if enabled[r] then fallback = r; break end
        end
    end
    if not fallback then return nil end  -- all ranks disabled

    -- Walk R1->R3, pick lowest enabled rank that covers deficit
    for r = 1, 3 do
        if enabled[r] and CHEffectiveHeal(r) >= (missingHP or 0) then
            -- Still respect mana — if unaffordable, step down
            if mana >= CH_MANA[r] then
                return r
            end
        end
    end
    return fallback
end

local function TANK_SCORE_FLOOR() return 5 end

local function IsTankLike(unit)
    local name = UnitName(unit)
    if not name then return false end
    return liveAggro[name] or (aggroCount[name] or 0) >= TANK_SCORE_FLOOR()
end

-- Returns hp% 0-100
local function GetHP(unit)
    local max = UnitHealthMax(unit)
    if not max or max == 0 then return 100 end
    return (UnitHealth(unit) / max) * 100
end

-- Returns deficit as 0.0-1.0 fraction (0 = full, 1 = dead)
local function GetDeficit(unit)
    return 1.0 - (UnitHealth(unit) / UnitHealthMax(unit))
end

-- Euclidean distance between two units using SuperWoW UnitPosition
local function UnitDistance(unitA, unitB)
    local ax, ay = UnitPosition(unitA)
    local bx, by = UnitPosition(unitB)
    if not ax or not bx then return 999 end
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx*dx + dy*dy)
end

-------------------------------------------------------------------------------
-- Pressure Score
-- Mirrors Moonpacker's ComputeTankPressureScore but without HoT reduction
-- (shaman has no persistent HoTs in this model).
-- Components:
--   deficit     0.0 - 0.50   (hp% mapped to 0..0.50)
--   live aggro  +0.25        (currently tanking)
--   history     0.0 - 0.25   (aggroCount scaled)
-- Clamped 0..1. Floor: below 20% hp -> minimum 0.75.
-------------------------------------------------------------------------------

local function ComputePressure(unit)
    local name = UnitName(unit)
    if not name then return 0 end

    local deficit    = GetDeficit(unit)
    local score      = aggroCount[name] or 0
    local pressure   = deficit * 0.50

    if liveAggro[name] then
        pressure = pressure + 0.25
    end
    pressure = pressure + math.min(score, 30) / 30 * 0.25

    if pressure < 0 then pressure = 0 end
    if pressure > 1 then pressure = 1 end

    local hp = GetHP(unit)
    if hp < 20 and pressure < 0.75 then pressure = 0.75 end

    return pressure
end

-------------------------------------------------------------------------------
-- Chain Heal Cluster Scoring
-- For a given primary target, cluster score = primary deficit bonus
-- + sum of deficits of all hurt players within CHAIN_HEAL_RANGE yards.
-- Aggro holders contribute extra to the score.
-------------------------------------------------------------------------------

local AGGRO_BOUNCE_BONUS = 0.20   -- extra deficit credit for aggro holders

local function ClusterScore(primaryUnit, allCandidates)
    local score = GetDeficit(primaryUnit)

    -- Aggro bonus for primary
    local pName = UnitName(primaryUnit)
    if liveAggro[pName] or (aggroCount[pName] or 0) >= TANK_SCORE_FLOOR() then
        score = score + AGGRO_BOUNCE_BONUS
    end

    -- Add deficit of nearby hurt players (potential bounces)
    for _, candidate in ipairs(allCandidates) do
        if candidate ~= primaryUnit then
            local dist = UnitDistance(primaryUnit, candidate)
            if dist <= settings.CHAIN_HEAL_RANGE then
                local def = GetDeficit(candidate)
                local cName = UnitName(candidate)
                if liveAggro[cName] or (aggroCount[cName] or 0) >= TANK_SCORE_FLOOR() then
                    def = def + AGGRO_BOUNCE_BONUS
                end
                score = score + def
            end
        end
    end

    return score
end

-- Returns the best primary target for Chain Heal and the cluster score,
-- or nil if no suitable candidates exist.
local function PickChainHealTarget(candidates)
    if not candidates or table.getn(candidates) == 0 then return nil, 0 end

    local bestUnit  = nil
    local bestScore = -1

    for _, unit in ipairs(candidates) do
        local cs = ClusterScore(unit, candidates)
        Debug(string.format("ClusterScore: %s = %.3f", UnitName(unit) or unit, cs))
        if cs > bestScore then
            bestScore = cs
            bestUnit  = unit
        end
    end

    return bestUnit, bestScore
end

-- Count how many candidates are within CHAIN_HEAL_RANGE of a given unit
local function NearbyHurtCount(primaryUnit, candidates)
    local count = 0
    for _, candidate in ipairs(candidates) do
        if candidate ~= primaryUnit then
            local dist = UnitDistance(primaryUnit, candidate)
            if dist <= settings.CHAIN_HEAL_RANGE then
                count = count + 1
            end
        end
    end
    return count
end

-------------------------------------------------------------------------------
-- LHW Rank Selection
-- Picks the lowest rank whose effective heal covers the target's need,
-- then steps down if we can't afford that rank.
--
-- "required" = raw HP deficit for non-tanks.
-- "required" = deficit * TANK_OVERHEAL_FACTOR for tanks, so we land a small
--              buffer rather than a perfectly fitted heal on someone still
--              taking hits.
--
-- Walk R1..R6: use the first rank where effectiveHeal >= required.
-- If no rank covers it (target is very low, deficit > R6 effective), use R6.
-- Mana gate: step down from chosen rank until we can afford it; floor at R1.
-------------------------------------------------------------------------------

local function PickLHWRank(unit)
    local missing        = UnitHealthMax(unit) - UnitHealth(unit)
    local factor         = IsTankLike(unit) and (settings.TANK_OVERHEAL_FACTOR or 1.20) or 1.0
    local aggressiveness = settings.DOWNRANK_AGGRESSIVENESS or 1.0
    local required       = missing * factor * aggressiveness
    local mana           = UnitMana("player")

    -- Find the lowest enabled rank that covers the required amount
    local enabled = settings.LHW_RANKS_ENABLED or { true, true, true, true, true, true }

    -- Find highest enabled rank as ceiling/fallback
    local maxEnabled = 1
    for r = 6, 1, -1 do
        if enabled[r] then maxEnabled = r; break end
    end

    local intendedRank = maxEnabled
    for rank = 1, 6 do
        if enabled[rank] and LHWEffectiveHeal(rank) >= required then
            intendedRank = rank
            break
        end
    end

    -- Mana gate: step down through enabled ranks until affordable
    while intendedRank > 1 and mana < LHW_MANA[intendedRank] do
        intendedRank = intendedRank - 1
        while intendedRank > 1 and not enabled[intendedRank] do
            intendedRank = intendedRank - 1
        end
    end

    local effectiveHeal = LHWEffectiveHeal(intendedRank)
    Debug(string.format("PickLHWRank: %s missing=%d required=%.0f effective=%.0f -> R%d",
          UnitName(unit) or "?", missing, required, effectiveHeal, intendedRank))

    return intendedRank, required, effectiveHeal
end

-------------------------------------------------------------------------------
-- Heal Decision Logging
-- Fields: ts | unit | hp% | pressure | clusterScore | liveAggro |
--         aggroScore | action | spellRank | healingPower | missingHP |
--         required | effectiveHeal
--
-- healingPower:    total +healing power at cast time
-- missingHP:       raw HP deficit of the target at cast time
-- required:        HP threshold the chosen rank must meet; 0 for Chain Heal
-- effectiveHeal:   estimated heal of the chosen rank; 0 for Chain Heal
-- aggressiveness:  DOWNRANK_AGGRESSIVENESS or CRISIS_AGGRESSIVENESS at cast time
-- isTank:          1 if Banzai flagged target as tank-like, 0 otherwise
--
-- action values:
--   LHW, LHW_CRISIS         normal LHW cast
--   CHAIN_HEAL               normal Chain Heal cast
-------------------------------------------------------------------------------

local function LogTimestamp()
    -- GetTime() is high-resolution uptime; GetGameTime() is seconds since midnight.
    -- Combine them: use GetGameTime() for h/m/s and GetTime() fraction for cs.
    local gt = math.floor(GetGameTime())
    local h  = math.mod(math.floor(gt / 3600), 24)
    local m  = math.floor(math.mod(gt, 3600) / 60)
    local s  = math.mod(gt, 60)
    local cs = math.floor(math.mod(GetTime(), 1) * 100)
    return string.format("%02d:%02d:%02d.%02d", h, m, s, cs)
end

local function LogAction(unit, pressure, clusterScore, action, spellRank, required, effectiveHeal, aggr, isTank)
    if not logBuffer then return end
    local name   = UnitName(unit) or "?"
    local hp     = math.floor(GetHP(unit))
    local live   = liveAggro[name] and "1" or "0"
    local score  = aggroCount[name] or 0
    local ts     = LogTimestamp()

    local healingPower = GetEffectiveHealingPower()
    local missingHP    = UnitHealthMax(unit) - UnitHealth(unit)

    local line   = string.format("%s|%s|%d|%.2f|%.3f|%s|%d|%s|%s|%d|%d|%d|%d|%.2f|%s",
        ts, name, hp, pressure, clusterScore,
        live, score, action, tostring(spellRank),
        healingPower, missingHP,
        math.floor(required or 0), math.floor(effectiveHeal or 0),
        aggr or 1.0, isTank and "1" or "0")
    if table.getn(logBuffer) >= LOG_MAX_ENTRIES then
        table.remove(logBuffer, 1)
    end
    table.insert(logBuffer, line)
    logEntryCount = logEntryCount + 1
end

local function FlushLog()
    if not logBuffer then
        Print("Logging is not active. Use /tclog to start.")
        return
    end
    if table.getn(logBuffer) == 0 then
        Print("Log buffer is empty.")
        return
    end
    local lines = {}
    table.insert(lines, "# Tidecaller session export " .. LogTimestamp() ..
                         " zone=" .. (GetZoneText() or "?"))
    table.insert(lines, "# ts(hh:mm:ss.cs)|unit|hp%|pressure|clusterScore|liveAggro|aggroScore|action|spellRank|healingPower|missingHP|required|effectiveHeal|aggressiveness|isTank")
    for _, line in ipairs(logBuffer) do
        table.insert(lines, line)
    end
    table.insert(lines, "# end entries=" .. table.getn(logBuffer) ..
                         " total_this_session=" .. logEntryCount)
    local payload = table.concat(lines, "\n")
    if ExportFile then
        ExportFile("TidecallerLog.txt", payload)
        Print(string.format("Log exported: %d entries -> TidecallerLog.txt",
              table.getn(logBuffer)))
    else
        Print("ExportFile not available — SuperWoW required.")
    end
end

local function ToggleLogging()
    if logBuffer then
        FlushLog()
        logBuffer     = nil
        logEntryCount = 0
        Print("Heal logging OFF.")
    else
        logBuffer     = {}
        logEntryCount = 0
        Print("Heal logging ON. /tcexport to write, /tclog again to stop.")
    end
end

-------------------------------------------------------------------------------
-- Banzai / Aggro Tracking
-------------------------------------------------------------------------------

local function OnUnitGainedAggro(unitId)
    local name = UnitName(unitId)
    if not name then return end
    liveAggro[name]   = true
    aggroCount[name]  = math.min((aggroCount[name] or 0) + 10, 30)
    Debug("Banzai: " .. name .. " gained aggro (score=" .. aggroCount[name] .. ")")
end

local function OnUnitLostAggro(unitId)
    local name = UnitName(unitId)
    if not name then return end
    liveAggro[name] = nil
    Debug("Banzai: " .. name .. " lost aggro")
end

-------------------------------------------------------------------------------
-- Member Iteration (player + party + raid)
-------------------------------------------------------------------------------

local function IterateMembers(callback)
    callback("player")
    local numRaid = GetNumRaidMembers()
    if numRaid > 0 then
        for i = 1, numRaid do callback("raid" .. i) end
    else
        for i = 1, GetNumPartyMembers() do callback("party" .. i) end
    end
end

-------------------------------------------------------------------------------
-- Main Healing Logic
--
--   1. Any unit in crisis (pressure >= 0.80) → LHW rank per CRISIS_AGGRESSIVENESS
--   2. Tank with enough nearby hurt players (>= CHAIN_HEAL_MIN) → Chain Heal R1
--   3. Tank isolated or deficit too large → LHW at appropriate rank
--   4. No tank, cluster exists (>= CHAIN_HEAL_MIN nearby hurt) → Chain Heal R1
--   5. Fallback → LHW on highest pressure unit
-------------------------------------------------------------------------------

local function HealMembers()
    -- Build candidate list: all valid in-range units below threshold
    local candidates = {}
    local allValid   = {}   -- all valid members regardless of HP

    IterateMembers(function(unit)
        if not UnitExists(unit) then return end
        if UnitIsDeadOrGhost(unit) then return end
        if not UnitIsConnected(unit) then return end
        local hp = GetHP(unit)
        table.insert(allValid, unit)
        if hp < settings.HEAL_THRESHOLD then
            table.insert(candidates, unit)
        end
    end)

    if table.getn(candidates) == 0 then
        Debug("HealMembers: no candidates below threshold")
        if settings.FOLLOW_ENABLED then
            local followUnit = settings.FOLLOW_TARGET_UNIT
            if followUnit and UnitExists(followUnit) then
                FollowUnit(followUnit)
            elseif GetNumPartyMembers() > 0 then
                FollowUnit("party1")
            end
        end
        return
    end

    -- Sort candidates by pressure descending
    table.sort(candidates, function(a, b)
        return ComputePressure(a) > ComputePressure(b)
    end)

    local topUnit     = candidates[1]
    local topPressure = ComputePressure(topUnit)

    -- QuickHeal avoidance: if enabled and top candidate is low pressure,
    -- assume QuickHeal users are already covering them and heal the 2nd
    -- highest pressure target instead.  High pressure (>= LHW_PRESSURE_FLOOR
    -- urgency threshold) always overrides — never let a tank die to avoid doubling up.
    if settings.QUICKHEAL_AVOID
    and topPressure < settings.LHW_PRESSURE_FLOOR
    and table.getn(candidates) >= 2 then
        Debug(string.format("QUICKHEAL_AVOID: skipping %s (pressure=%.2f) -> %s",
              UnitName(topUnit) or "?", topPressure,
              UnitName(candidates[2]) or "?"))
        topUnit     = candidates[2]
        topPressure = ComputePressure(topUnit)
    end

    Debug("Heal: top=" .. (UnitName(topUnit) or "?") ..
          string.format(" pressure=%.2f", topPressure))

    -- 1. Any unit in crisis (pressure >= 0.80) — rank selected by CRISIS_AGGRESSIVENESS, no mana gate
    if topPressure >= 0.80 then
        local missing    = UnitHealthMax(topUnit) - UnitHealth(topUnit)
        local crisisAggr = settings.CRISIS_AGGRESSIVENESS or 1.0
        local required   = missing * (settings.TANK_OVERHEAL_FACTOR or 1.20) * crisisAggr
        local crisisEnabled = settings.LHW_RANKS_ENABLED or { true, true, true, true, true, true }
        local crisisRank = 6
        for r = 6, 1, -1 do
            if crisisEnabled[r] then crisisRank = r; break end
        end
        for r = 1, 6 do
            if crisisEnabled[r] and LHWEffectiveHeal(r) >= required then
                crisisRank = r
                break
            end
        end
        local eff = LHWEffectiveHeal(crisisRank)
        TargetUnit(topUnit)
        CastSpellByName("Lesser Healing Wave(Rank " .. crisisRank .. ")")
        TargetLastTarget()
        LogAction(topUnit, topPressure, 0, "LHW_CRISIS", crisisRank, required, eff, settings.CRISIS_AGGRESSIVENESS or 1.0, true)
        Debug(string.format("LHW R%d CRISIS on tank %s (pressure=%.2f aggr=%.2f)",
              crisisRank, UnitName(topUnit) or "?", topPressure, crisisAggr))
        return
    end

    -- 2. Tank with nearby hurt players — Chain Heal if enough injured for it
    if IsTankLike(topUnit) then
        local nearbyHurt = NearbyHurtCount(topUnit, candidates)
        local chRank = nearbyHurt >= (settings.CHAIN_HEAL_MIN - 1) and PickCHRank(UnitHealthMax(topUnit) - UnitHealth(topUnit)) or nil
        if chRank then
            local clusterScore = ClusterScore(topUnit, candidates)
            TargetUnit(topUnit)
            CastSpellByName("Chain Heal(Rank " .. chRank .. ")")
            TargetLastTarget()
            LogAction(topUnit, topPressure, clusterScore, "CHAIN_HEAL", chRank, 0, CHEffectiveHeal(chRank), settings.DOWNRANK_AGGRESSIVENESS or 1.0, IsTankLike(topUnit))
            Debug(string.format("CHAIN HEAL R%d on tank %s (cluster=%.3f nearbyHurt=%d)",
                  chRank, UnitName(topUnit) or "?", clusterScore, nearbyHurt))
            return
        else
            local rank, req, eff = PickLHWRank(topUnit)
            TargetUnit(topUnit)
            CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
            TargetLastTarget()
            LogAction(topUnit, topPressure, 0, "LHW", rank, req, eff, settings.DOWNRANK_AGGRESSIVENESS or 1.0, IsTankLike(topUnit))
            Debug(string.format("LHW R%d on tank %s (pressure=%.2f)",
                  rank, UnitName(topUnit) or "?", topPressure))
            return
        end
    end

    -- 3. Non-tank: Chain Heal if enough injured players clustered, otherwise LHW
    local chainTarget, clusterScore = PickChainHealTarget(candidates)
    if chainTarget then
        local nearby = NearbyHurtCount(chainTarget, candidates)
        local chRank = nearby >= (settings.CHAIN_HEAL_MIN - 1) and PickCHRank(UnitHealthMax(chainTarget) - UnitHealth(chainTarget)) or nil
        if chRank then
            TargetUnit(chainTarget)
            CastSpellByName("Chain Heal(Rank " .. chRank .. ")")
            TargetLastTarget()
            LogAction(chainTarget, topPressure, clusterScore, "CHAIN_HEAL", chRank, 0, CHEffectiveHeal(chRank), settings.DOWNRANK_AGGRESSIVENESS or 1.0, IsTankLike(chainTarget))
            Debug(string.format("CHAIN HEAL R%d on %s (cluster=%.3f nearby=%d)",
                  chRank, UnitName(chainTarget) or "?", clusterScore, nearby))
            return
        end
    end

    -- 4. Fallback: LHW
    local rank, req, eff = PickLHWRank(topUnit)
    TargetUnit(topUnit)
    CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
    TargetLastTarget()
    LogAction(topUnit, topPressure, 0, "LHW", rank, req, eff, settings.DOWNRANK_AGGRESSIVENESS or 1.0, IsTankLike(topUnit))
    Debug(string.format("LHW R%d on %s (fallback, pressure=%.2f)",
          rank, UnitName(topUnit) or "?", topPressure))
end

-------------------------------------------------------------------------------
-- Event Frame
-------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("PLAYER_ALIVE")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")

local function InitBanzai()
    if TidecallerEvents then return end
    if not (AceLibrary and AceLibrary:HasInstance("Banzai-1.0")
                       and AceLibrary:HasInstance("AceEvent-2.0")) then
        Print("WARNING: Banzai-1.0 or AceEvent-2.0 not found. Aggro features disabled.")
        return
    end
    Banzai = AceLibrary("Banzai-1.0")
    TidecallerEvents = {
        Banzai_UnitGainedAggro = function(self, unitId)
            OnUnitGainedAggro(unitId)
        end,
        Banzai_UnitLostAggro = function(self, unitId)
            OnUnitLostAggro(unitId)
        end,
    }
    AceLibrary("AceEvent-2.0"):embed(TidecallerEvents)
    TidecallerEvents:RegisterEvent("Banzai_UnitGainedAggro", "Banzai_UnitGainedAggro")
    TidecallerEvents:RegisterEvent("Banzai_UnitLostAggro",   "Banzai_UnitLostAggro")
    Print("Banzai-1.0 integration active.")
end

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "Tidecaller" then
        for k, v in pairs(TidecallerDB) do settings[k] = v end
        BuildDRFrame()
        -- Backfill sub-tables that may be missing from older saved variables
        if not TidecallerDB.LHW_RANKS_ENABLED then
            TidecallerDB.LHW_RANKS_ENABLED = { true, true, true, true, true, true }
        end
        if not TidecallerDB.CH_RANKS_ENABLED then
            TidecallerDB.CH_RANKS_ENABLED = { true, false, false }
        end
        settings.LHW_RANKS_ENABLED = TidecallerDB.LHW_RANKS_ENABLED
        settings.CH_RANKS_ENABLED  = TidecallerDB.CH_RANKS_ENABLED
        Print("Loaded. Type /tc for help.")

    elseif event == "VARIABLES_LOADED" then
        InitBanzai()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        for k in pairs(liveAggro)   do liveAggro[k]   = nil end
        for k in pairs(aggroCount)  do aggroCount[k]  = nil end
        if logBuffer and table.getn(logBuffer) > 0 then
            FlushLog()
        end

    end
end)


-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- Downrank GUI — /tcdr to toggle
-------------------------------------------------------------------------------

local drFrame = nil

local function MakeSlider(parent, name, yOffset, getSetting, setSetting)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(1.0, 0.82, 0.0)
    lbl:SetText(name .. "  " .. string.format("%.2f", getSetting()))

    local s = CreateFrame("Slider", "TidecallerSlider"..name, parent,
                          "OptionsSliderTemplate")
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset - 16)
    s:SetWidth(180)
    s:SetHeight(16)
    s:SetMinMaxValues(0, 1)
    s:SetValueStep(0.05)
    s:SetValue(getSetting())

    local lo = _G[s:GetName().."Low"]
    local hi = _G[s:GetName().."High"]
    local tx = _G[s:GetName().."Text"]
    if lo then lo:SetText("") end
    if hi then hi:SetText("") end
    if tx then tx:SetText("") end

    s:SetScript("OnValueChanged", function()
        local v = math.floor(s:GetValue() * 20 + 0.5) / 20
        setSetting(v)
        lbl:SetText(name .. "  " .. string.format("%.2f", v))
    end)
end

local function MakeCheckbox(parent, label, x, y, getSetting, setSetting)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetWidth(20)
    cb:SetHeight(20)
    cb:SetChecked(getSetting())

    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("RIGHT", cb, "LEFT", -2, 0)
    lbl:SetText(label)
    lbl:SetTextColor(0.8, 0.8, 0.8)
    lbl:SetJustifyH("RIGHT")

    cb:SetScript("OnClick", function()
        setSetting(cb:GetChecked() == 1)
    end)
    return cb
end

local function BuildDRFrame()
    local f = CreateFrame("Frame", "TidecallerDRFrame", UIParent)
    f:SetWidth(220)
    f:SetHeight(230)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetFrameStrata("DIALOG")

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetTexture(0.06, 0.06, 0.10, 0.85)

    -- Sliders
    MakeSlider(f, "Normal", -10,
        function() return settings.DOWNRANK_AGGRESSIVENESS or 1.0 end,
        function(v)
            settings.DOWNRANK_AGGRESSIVENESS    = v
            TidecallerDB.DOWNRANK_AGGRESSIVENESS = v
        end)

    MakeSlider(f, "Crisis", -46,
        function() return settings.CRISIS_AGGRESSIVENESS or 1.0 end,
        function(v)
            settings.CRISIS_AGGRESSIVENESS    = v
            TidecallerDB.CRISIS_AGGRESSIVENESS = v
        end)

    -- Divider
    local div = f:CreateTexture(nil, "OVERLAY")
    div:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -92)
    div:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -92)
    div:SetHeight(1)
    div:SetTexture(0.3, 0.3, 0.3, 0.8)

    -- LHW rank checkboxes — 2 rows of 3
    local lhwLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lhwLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -98)
    lhwLabel:SetText("LHW")
    lhwLabel:SetTextColor(1.0, 0.82, 0.0)

    local lhwRows = { {1,2,3}, {4,5,6} }
    for row, ranks in ipairs(lhwRows) do
        local yOff = -112 - (row - 1) * 26
        local cbX  = 30
        for _, r in ipairs(ranks) do
            local rank = r
            MakeCheckbox(f, "R"..r, cbX, yOff,
                function() return (settings.LHW_RANKS_ENABLED or {})[rank] ~= false end,
                function(v)
                    if not settings.LHW_RANKS_ENABLED then
                        settings.LHW_RANKS_ENABLED = { true, true, true, true, true, true }
                    end
                    if not TidecallerDB.LHW_RANKS_ENABLED then
                        TidecallerDB.LHW_RANKS_ENABLED = { true, true, true, true, true, true }
                    end
                    settings.LHW_RANKS_ENABLED[rank]    = v
                    TidecallerDB.LHW_RANKS_ENABLED[rank] = v
                end)
            cbX = cbX + 60
        end
    end

    -- Divider
    local div2 = f:CreateTexture(nil, "OVERLAY")
    div2:SetPoint("TOPLEFT",  f, "TOPLEFT",  8, -168)
    div2:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -168)
    div2:SetHeight(1)
    div2:SetTexture(0.3, 0.3, 0.3, 0.8)

    -- Chain Heal rank checkboxes — single row
    local chLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -174)
    chLabel:SetText("Chain Heal")
    chLabel:SetTextColor(1.0, 0.82, 0.0)

    local chX = 30
    for r = 1, 3 do
        local rank = r
        MakeCheckbox(f, "CH"..r, chX, -188,
            function() return (settings.CH_RANKS_ENABLED or {})[rank] ~= false end,
            function(v)
                if not settings.CH_RANKS_ENABLED then
                    settings.CH_RANKS_ENABLED = { true, false, false }
                end
                if not TidecallerDB.CH_RANKS_ENABLED then
                    TidecallerDB.CH_RANKS_ENABLED = { true, false, false }
                end
                settings.CH_RANKS_ENABLED[rank]    = v
                TidecallerDB.CH_RANKS_ENABLED[rank] = v
            end)
        chX = chX + 60
    end

    f:SetHeight(215)

    f:Hide()
    drFrame = f
    return f
end

-- Slash Commands
-------------------------------------------------------------------------------

local function PrintUsage()
    Print("Commands:")
    Print("  /tcheal              - Cast heal decision")
    Print("  /tcqh                - Toggle QuickHeal avoidance (skip lowest HP target)")
    Print("  /tclog               - Toggle heal decision logging on/off")
    Print("  /tcexport            - Write log buffer to TidecallerLog.txt")
    Print("  /tclogclear          - Clear log buffer without writing")
    Print("  /tclogstat           - Show log buffer status")
    Print("  /tcfollow            - Toggle follow")
    Print("  /tcl                 - Set follow target to current target")
    Print("  /tcdr                - Toggle downrank aggressiveness GUI")
    Print("  /tcdebug             - Toggle debug output")
    Print("  /tcbanzai            - Diagnose Banzai integration")
    Print("  /tcstatus            - Show healing power, effective heals, and rank decisions")
    Print("  /tc                  - Show this help")
end

-- Main heal
SLASH_TCHEAL1 = "/tcheal"
SlashCmdList["TCHEAL"] = function()
    HealMembers()
end

SLASH_TCQH1 = "/tcqh"
SlashCmdList["TCQH"] = function()
    settings.QUICKHEAL_AVOID    = not settings.QUICKHEAL_AVOID
    TidecallerDB.QUICKHEAL_AVOID = settings.QUICKHEAL_AVOID
    Print("QuickHeal avoidance: " .. (settings.QUICKHEAL_AVOID and "ON" or "OFF"))
end

-- Logging
SLASH_TCLOG1 = "/tclog"
SlashCmdList["TCLOG"] = function()
    ToggleLogging()
end

SLASH_TCEXPORT1 = "/tcexport"
SlashCmdList["TCEXPORT"] = function()
    FlushLog()
end

SLASH_TCLOGCLEAR1 = "/tclogclear"
SlashCmdList["TCLOGCLEAR"] = function()
    if not logBuffer then
        Print("Logging is not active.")
        return
    end
    logBuffer     = {}
    logEntryCount = 0
    Print("Log buffer cleared.")
end

SLASH_TCLOGSTAT1 = "/tclogstat"
SlashCmdList["TCLOGSTAT"] = function()
    if not logBuffer then
        Print("Logging is OFF.")
        return
    end
    Print(string.format("Logging ON. Buffer: %d/%d entries (session total: %d).",
          table.getn(logBuffer), LOG_MAX_ENTRIES, logEntryCount))
end

-- Follow
SLASH_TCFOLLOW1 = "/tcfollow"
SlashCmdList["TCFOLLOW"] = function()
    settings.FOLLOW_ENABLED    = not settings.FOLLOW_ENABLED
    TidecallerDB.FOLLOW_ENABLED = settings.FOLLOW_ENABLED
    Print("Follow: " .. (settings.FOLLOW_ENABLED and "ON" or "OFF"))
end

SLASH_TCL1 = "/tcl"
SlashCmdList["TCL"] = function()
    if not UnitExists("target") or not UnitIsPlayer("target") then
        Print("No valid player target selected.")
        return
    end

    -- Resolve the target to a stable unitid so FollowUnit() can be used,
    -- avoiding Turtle WoW's fuzzy name-matching with /followbyname.
    local targetGUID = UnitGUID and UnitGUID("target")
    local foundUnit  = nil

    -- Helper: check if a unitid matches our target
    local function matchesTarget(uid)
        if not UnitExists(uid) then return false end
        if targetGUID then
            return UnitGUID(uid) == targetGUID
        else
            -- Fallback: exact name + same class (no GUID available)
            return UnitName(uid) == UnitName("target")
                   and UnitClass(uid) == UnitClass("target")
        end
    end

    IterateMembers(function(uid)
        if not foundUnit and uid ~= "player" and matchesTarget(uid) then
            foundUnit = uid
        end
    end)

    if foundUnit then
        settings.FOLLOW_TARGET_UNIT    = foundUnit
        TidecallerDB.FOLLOW_TARGET_UNIT = foundUnit
        -- Also update legacy name field so saved DB stays readable
        settings.FOLLOW_TARGET_NAME    = UnitName("target")
        TidecallerDB.FOLLOW_TARGET_NAME = UnitName("target")
        Print("Follow target set to " .. UnitName("target") .. " (" .. foundUnit .. ")")
    else
        Print("Target is not in your party or raid.")
    end
end

-- Downrank GUI
SLASH_TCDR1 = "/tcdr"
SlashCmdList["TCDR"] = function()
    if not drFrame then BuildDRFrame() end
    if drFrame:IsShown() then
        drFrame:Hide()
    else
        drFrame:Show()
    end
end

-- Tooltip colour debug — hover an item and run /tctipcolors
SLASH_TCTIPCOLORS1 = "/tctipcolors"
SlashCmdList["TCTIPCOLORS"] = function()
    local tip = TidecallerScanTooltip
    local link = GetInventoryItemLink("player", 8)  -- head slot, change as needed
    if not link then Print("No item in head slot"); return end
    local _, _, eqLink = string.find(link, "(item:%d+:%d+:%d+:%d+)")
    if not eqLink then return end
    tip:ClearLines()
    tip:SetHyperlink(eqLink)
    for i = 1, tip:NumLines() do
        local fs = _G["TidecallerScanTooltipTextLeft"..i]
        local text = fs:GetText() or ""
        local r, g, b = fs:GetTextColor()
        Print(string.format("L%d r=%.2f g=%.2f b=%.2f  %s", i, r or 0, g or 0, b or 0, string.sub(text,1,40)))
    end
end

-- Debug
SLASH_TCDEBUG1 = "/tcdebug"
SlashCmdList["TCDEBUG"] = function()
    settings.DEBUG_MODE    = not settings.DEBUG_MODE
    TidecallerDB.DEBUG_MODE = settings.DEBUG_MODE
    Print("Debug mode: " .. (settings.DEBUG_MODE and "ON" or "OFF"))
end

-- Banzai diagnostic
SLASH_TCBANZAI1 = "/tcbanzai"
SlashCmdList["TCBANZAI"] = function()
    Print("=== Banzai Diagnostic ===")
    if not AceLibrary then
        Print("  AceLibrary: NOT FOUND")
        return
    end
    Print("  AceLibrary: ok")
    Print("  Banzai-1.0: " .. tostring(AceLibrary:HasInstance("Banzai-1.0")))
    Print("  AceEvent-2.0: " .. tostring(AceLibrary:HasInstance("AceEvent-2.0")))
    if not TidecallerEvents then
        Print("  TidecallerEvents: NIL")
    else
        Print("  TidecallerEvents: ok")
    end
    if not Banzai then
        Print("  Banzai object: NIL")
    else
        Print("  Banzai object: ok")
        local found = false
        IterateMembers(function(uid)
            if UnitExists(uid) and Banzai:GetUnitAggroByUnitId(uid) then
                Print("  Aggro: " .. (UnitName(uid) or uid))
                found = true
            end
        end)
        if not found then Print("  Aggro: none detected") end
    end
    local liveCount, scoreCount = 0, 0
    for _ in pairs(liveAggro)   do liveCount  = liveCount  + 1 end
    for _ in pairs(aggroCount)  do scoreCount = scoreCount + 1 end
    Print("  liveAggro entries: "  .. liveCount)
    Print("  aggroCount entries: " .. scoreCount)
end

-- Status / healing power diagnostic
SLASH_TCSTATUS1 = "/tcstatus"
SlashCmdList["TCSTATUS"] = function()
    Print("=== Tidecaller Status ===")

    -- Healing power source check (always uses Tidecaller's own scanner)
    healCache.dirty = true   -- force a fresh scan for accurate readout
    local healingPower = GetEffectiveHealingPower()
    Print("  Healing power source: Tidecaller internal scanner")
    Print(string.format("  +Damage & healing (gear/buffs): %d", healCache.damage_and_healing))
    Print(string.format("  +Healing only (gear/buffs):     %d", healCache.healing_only))
    Print(string.format("  Total healing power:            %d", healingPower))

    -- Effective heal values for all ranks
    Print(string.format("  Coeff: %.4f    Tank overheal factor: %.2f",
          LHW_HEAL_COEFF, settings.TANK_OVERHEAL_FACTOR or 1.20))
    for rank = 1, 6 do
        Print(string.format("  LHW R%d: base=%d  effective=%.0f",
              rank, LHW_BASE[rank], LHWEffectiveHeal(rank)))
    end

    -- Per-member rank decisions
    Print("  --- Rank decisions (current HP) ---")
    IterateMembers(function(uid)
        if not UnitExists(uid) then return end
        if UnitIsDeadOrGhost(uid) then return end
        local name    = UnitName(uid) or uid
        local maxHP   = UnitHealthMax(uid)
        local missing = maxHP - UnitHealth(uid)
        local hp      = math.floor(GetHP(uid))
        local tank    = IsTankLike(uid)
        local factor  = tank and (settings.TANK_OVERHEAL_FACTOR or 1.20) or 1.0
        local required = missing * factor
        local rank = PickLHWRank(uid)
        Print(string.format("  %s: %d%% hp  missing=%d  required=%.0f  tank=%s  -> LHW R%d",
              name, hp, missing, required, tank and "yes" or "no", rank))
    end)
end

-- Help
SLASH_TC1 = "/tc"
SlashCmdList["TC"] = PrintUsage