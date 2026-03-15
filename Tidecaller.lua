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
    RAID_MODE           = false,   -- false = Solo mode, true = Raid mode
    HEAL_THRESHOLD      = 90,      -- Only consider units below this hp%
    CHAIN_HEAL_MIN      = 2,       -- Min hurt players in cluster to prefer Chain Heal (solo mode)
    CHAIN_HEAL_RANGE    = 12,      -- Yards for Chain Heal bounce scoring
    LHW_PRESSURE_FLOOR  = 0.55,    -- Below this pressure use LHW R2, above use LHW R6
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
-- Chain Heal:         R1=1064  R2=10622  R3=10623
-- Lesser Healing Wave: R2=8005  R6=25420
-------------------------------------------------------------------------------

local SPELL_ID = {
    ["Chain Heal"] = {
        1064,   -- Rank 1
        10622,  -- Rank 2
        10623,  -- Rank 3
    },
    ["Lesser Healing Wave"] = {
        516,    -- Rank 1
        8005,   -- Rank 2
        8006,   -- Rank 3
        10466,  -- Rank 4
        10467,  -- Rank 5
        25420,  -- Rank 6
    },
}

-- LHW mana costs (approximate, untalented)
local LHW_MANA = {
    50,   -- R1
    105,  -- R2
    185,  -- R3
    250,  -- R4
    310,  -- R5
    395,  -- R6
}

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
-- Tank-like units: pressure-based (R2 below floor, R6 above)
-- Non-tank:        R2 efficient top-off, R6 only if below 40% hp
-- Mana gates: step down if we can't afford chosen rank
-------------------------------------------------------------------------------

local function PickLHWRank(unit)
    local maxRank = table.getn(SPELL_ID["Lesser Healing Wave"])
    local mana    = UnitMana("player")
    local hp      = GetHP(unit)

    local intendedRank
    if IsTankLike(unit) then
        local pressure = ComputePressure(unit)
        if pressure >= settings.LHW_PRESSURE_FLOOR then
            intendedRank = maxRank   -- R6 fast throughput
        else
            intendedRank = 2         -- R2 efficient top-off
        end
    else
        if hp < 40 then
            intendedRank = maxRank
        else
            intendedRank = 2
        end
    end

    -- Step down if mana is too low, floor at R2 (never cast R1 on purpose)
    while intendedRank > 2 do
        local cost = LHW_MANA[intendedRank] or 0
        if mana >= cost then break end
        intendedRank = intendedRank - 1
    end

    return intendedRank
end

-------------------------------------------------------------------------------
-- Heal Decision Logging
-- Fields: ts | unit | hp% | pressure | clusterScore | mode | liveAggro |
--         aggroScore | action | spellRank
-------------------------------------------------------------------------------

local function LogTimestamp()
    local t = GetGameTime()
    local h = math.mod(math.floor(t), 24)
    local m = math.floor(math.mod(t, 1) * 60)
    local s = math.floor(math.mod(math.mod(t, 1) * 60, 1) * 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function LogAction(unit, pressure, clusterScore, action, spellRank)
    if not logBuffer then return end
    local name   = UnitName(unit) or "?"
    local hp     = math.floor(GetHP(unit))
    local live   = liveAggro[name] and "1" or "0"
    local score  = aggroCount[name] or 0
    local mode   = settings.RAID_MODE and "raid" or "solo"
    local ts     = LogTimestamp()
    local line   = string.format("%s|%s|%d|%.2f|%.3f|%s|%s|%d|%s|%s",
        ts, name, hp, pressure, clusterScore, mode,
        live, score, action, tostring(spellRank))
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
    table.insert(lines, "# ts|unit|hp%|pressure|clusterScore|mode|liveAggro|aggroScore|action|spellRank")
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
-- SOLO MODE:
--   1. If a tank-like unit has high pressure (>= LHW_PRESSURE_FLOOR) → LHW
--   2. If 2+ hurt players are clustered → Chain Heal on best cluster target
--   3. Otherwise LHW on highest pressure unit
--
-- RAID MODE:
--   1. If any tank-like unit has crisis pressure (>= 0.80) and is alone → LHW R6
--   2. Otherwise Chain Heal on best cluster target
--   3. Fall back to LHW if no cluster candidates
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
    -- highest pressure target instead.  High pressure (>= LHW_PRESSURE_FLOOR)
    -- always overrides — never let a tank die to avoid doubling up.
    if settings.QUICKHEAL_AVOID
    and topPressure < settings.LHW_PRESSURE_FLOOR
    and table.getn(candidates) >= 2 then
        Debug(string.format("QUICKHEAL_AVOID: skipping %s (pressure=%.2f) -> %s",
              UnitName(topUnit) or "?", topPressure,
              UnitName(candidates[2]) or "?"))
        topUnit     = candidates[2]
        topPressure = ComputePressure(topUnit)
    end

    -- ---- SOLO MODE ----
    -- Prioritises tank survival above all else. If the tank is severely
    -- pressured (>= 0.80), LHW immediately regardless of cluster opportunity.
    -- Otherwise same logic as raid mode: Chain Heal when nearby hurt players
    -- exist, LHW when tank is isolated.
    if not settings.RAID_MODE then
        Debug("SOLO MODE: top=" .. (UnitName(topUnit) or "?") ..
              string.format(" pressure=%.2f", topPressure))

        -- 1. Tank in crisis — LHW immediately, don't waste time on Chain Heal
        if IsTankLike(topUnit) and topPressure >= 0.80 then
            local rank = PickLHWRank(topUnit)
            TargetUnit(topUnit)
            CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
            TargetLastTarget()
            LogAction(topUnit, topPressure, 0, "LHW_CRISIS", rank)
            Debug(string.format("LHW R%d CRISIS on tank %s (pressure=%.2f)",
                  rank, UnitName(topUnit) or "?", topPressure))
            return
        end

        -- 2. Tank with nearby hurt players — Chain Heal
        if IsTankLike(topUnit) then
            local nearbyHurt = NearbyHurtCount(topUnit, candidates)
            if nearbyHurt > 0 then
                local clusterScore = ClusterScore(topUnit, candidates)
                local rank
                if clusterScore >= 0.60 then rank = 3
                elseif clusterScore >= 0.30 then rank = 2
                else rank = 1 end
                TargetUnit(topUnit)
                CastSpellByName("Chain Heal(Rank " .. rank .. ")")
                TargetLastTarget()
                LogAction(topUnit, topPressure, clusterScore, "CHAIN_HEAL", rank)
                Debug(string.format("CHAIN HEAL R%d on tank %s (cluster=%.3f nearbyHurt=%d)",
                      rank, UnitName(topUnit) or "?", clusterScore, nearbyHurt))
                return
            else
                local rank = PickLHWRank(topUnit)
                TargetUnit(topUnit)
                CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
                TargetLastTarget()
                LogAction(topUnit, topPressure, 0, "LHW", rank)
                Debug(string.format("LHW R%d on isolated tank %s (pressure=%.2f)",
                      rank, UnitName(topUnit) or "?", topPressure))
                return
            end
        end

        -- 3. Non-tank: Chain Heal if cluster, otherwise LHW
        local chainTarget, clusterScore = PickChainHealTarget(candidates)
        if chainTarget then
            local nearby = NearbyHurtCount(chainTarget, candidates)
            if nearby >= (settings.CHAIN_HEAL_MIN - 1) then
                local rank
                if clusterScore >= 0.60 then rank = 3
                elseif clusterScore >= 0.30 then rank = 2
                else rank = 1 end
                TargetUnit(chainTarget)
                CastSpellByName("Chain Heal(Rank " .. rank .. ")")
                TargetLastTarget()
                LogAction(chainTarget, topPressure, clusterScore, "CHAIN_HEAL", rank)
                Debug(string.format("CHAIN HEAL R%d on %s (cluster=%.3f nearby=%d)",
                      rank, UnitName(chainTarget) or "?", clusterScore, nearby))
                return
            end
        end

        -- 4. Fallback: LHW
        local rank = PickLHWRank(topUnit)
        TargetUnit(topUnit)
        CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
        TargetLastTarget()
        LogAction(topUnit, topPressure, 0, "LHW", rank)
        Debug(string.format("LHW R%d on %s (fallback, pressure=%.2f)",
              rank, UnitName(topUnit) or "?", topPressure))
        return
    end

    -- ---- RAID MODE ----
    -- Chain Heal primary. LHW only when tank is isolated with no nearby hurt players.
    Debug("RAID MODE: top=" .. (UnitName(topUnit) or "?") ..
          string.format(" pressure=%.2f", topPressure))

    -- 1. Tank with nearby hurt players — Chain Heal
    if IsTankLike(topUnit) then
        local nearbyHurt = NearbyHurtCount(topUnit, candidates)
        if nearbyHurt > 0 then
            local clusterScore = ClusterScore(topUnit, candidates)
            local rank
            if clusterScore >= 0.60 then rank = 3
            elseif clusterScore >= 0.30 then rank = 2
            else rank = 1 end
            TargetUnit(topUnit)
            CastSpellByName("Chain Heal(Rank " .. rank .. ")")
            TargetLastTarget()
            LogAction(topUnit, topPressure, clusterScore, "CHAIN_HEAL", rank)
            Debug(string.format("CHAIN HEAL R%d on tank %s (cluster=%.3f nearbyHurt=%d)",
                  rank, UnitName(topUnit) or "?", clusterScore, nearbyHurt))
            return
        else
            local rank = PickLHWRank(topUnit)
            TargetUnit(topUnit)
            CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
            TargetLastTarget()
            LogAction(topUnit, topPressure, 0, "LHW", rank)
            Debug(string.format("LHW R%d on isolated tank %s (pressure=%.2f)",
                  rank, UnitName(topUnit) or "?", topPressure))
            return
        end
    end

    -- 2. Non-tank: Chain Heal on best cluster target
    local chainTarget, clusterScore = PickChainHealTarget(candidates)
    if chainTarget then
        local rank
        if clusterScore >= 0.80 then rank = 3
        elseif clusterScore >= 0.40 then rank = 2
        else rank = 1 end
        TargetUnit(chainTarget)
        CastSpellByName("Chain Heal(Rank " .. rank .. ")")
        TargetLastTarget()
        LogAction(chainTarget, topPressure, clusterScore, "CHAIN_HEAL", rank)
        Debug(string.format("CHAIN HEAL R%d on %s (cluster=%.3f)",
              rank, UnitName(chainTarget) or "?", clusterScore))
        return
    end

    -- 3. Fallback: LHW
    local rank = PickLHWRank(topUnit)
    TargetUnit(topUnit)
    CastSpellByName("Lesser Healing Wave(Rank " .. rank .. ")")
    TargetLastTarget()
    LogAction(topUnit, topPressure, 0, "LHW", rank)
    Debug(string.format("LHW R%d on %s (no chain candidates, pressure=%.2f)",
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
        Print("Loaded. Type /tc for help.")

    elseif event == "VARIABLES_LOADED" then
        InitBanzai()

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        for k in pairs(liveAggro) do liveAggro[k] = nil end
        if logBuffer and table.getn(logBuffer) > 0 then
            FlushLog()
        end
    end
end)

-------------------------------------------------------------------------------
-- Slash Commands
-------------------------------------------------------------------------------

local function PrintUsage()
    Print("Commands:")
    Print("  /tcheal              - Cast heal decision")
    Print("  /tcsolo              - Switch to Solo mode (pressure-driven)")
    Print("  /tcraid              - Switch to Raid mode (Chain Heal primary)")
    Print("  /tcqh                - Toggle QuickHeal avoidance (skip lowest HP target)")
    Print("  /tclog               - Toggle heal decision logging on/off")
    Print("  /tcexport            - Write log buffer to TidecallerLog.txt")
    Print("  /tclogclear          - Clear log buffer without writing")
    Print("  /tclogstat           - Show log buffer status")
    Print("  /tcfollow            - Toggle follow")
    Print("  /tcl                 - Set follow target to current target")
    Print("  /tcdebug             - Toggle debug output")
    Print("  /tcbanzai            - Diagnose Banzai integration")
    Print("  /tc                  - Show this help")
end

-- Main heal
SLASH_TCHEAL1 = "/tcheal"
SlashCmdList["TCHEAL"] = function()
    HealMembers()
end

-- Mode toggles
SLASH_TCSOLO1 = "/tcsolo"
SlashCmdList["TCSOLO"] = function()
    settings.RAID_MODE    = false
    TidecallerDB.RAID_MODE = false
    Print("Solo mode ON — pressure-driven LHW primary.")
end

SLASH_TCRAID1 = "/tcraid"
SlashCmdList["TCRAID"] = function()
    settings.RAID_MODE    = true
    TidecallerDB.RAID_MODE = true
    Print("Raid mode ON — Chain Heal primary.")
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
    Print("  Mode: " .. (settings.RAID_MODE and "RAID" or "SOLO"))
end

-- Help
SLASH_TC1 = "/tc"
SlashCmdList["TC"] = PrintUsage