# Tidecaller

**Version:** 0.2  
**Author:** Rel  
**Client:** Turtle WoW 1.12 / SuperWoW

Shaman healing addon with aggro-aware target selection, position-based Chain Heal scoring, and pressure-driven LHW rank selection. Built for multibox and small group play, with raid support via downrank aggressiveness controls.

---

## Changelog

### 0.2
- **Removed Solo/Raid mode split** — unified into a single healing decision tree that works correctly in both contexts. `/tcsolo` and `/tcraid` removed.
- **Chain Heal minimum cluster requirement raised to 3** — Chain Heal now requires at least 3 injured players in range. At 2 targets, two LHW casts are more time-efficient; at 3 the math firmly favours Chain Heal.
- **Chain Heal always R1** — marginal mana cost of R2/R3 upgrades (~3.1 hp/mana) is worse than LHW R6. R1 at 6.06 hp/mana across 3 targets is the most efficient cast in the kit.
- **Full LHW rank ladder (R1–R6)** — replaced the binary R2/R6 system. `PickLHWRank` walks R1→R6 and selects the lowest rank whose effective heal covers the target's required threshold. Mana gate steps down if a rank is unaffordable, flooring at R1.
- **Crisis path now rank-selects** — LHW_CRISIS no longer hardcodes R6. Uses `CRISIS_AGGRESSIVENESS` to scale the required threshold and picks the lowest rank that covers it. No mana gate in crisis.
- **Downrank aggressiveness system** — two new settings scale the required healing threshold as a fraction of the deficit:
  - `DOWNRANK_AGGRESSIVENESS` (0.0–1.0) — applied to all normal LHW casts
  - `CRISIS_AGGRESSIVENESS` (0.0–1.0) — applied to LHW_CRISIS casts only
  - At 1.0 (default) behaviour is unchanged. At 0.5 the addon targets 50% of the deficit (× tank factor), allowing other healers to cover the rest.
- **Downrank GUI** — `/tcdr` opens a minimal draggable window with two sliders for live adjustment of both aggressiveness values. Changes apply immediately and persist across sessions.
- **Own healing power scanner** — replaced BonusScanner/BCS dependency. Tooltip-scans all 19 equipment slots, weapon oils, and active buffs. Correctly buckets `+damage and healing` and `+healing only` separately. Cache invalidates on inventory or aura change.
- **Corrected spell coefficients and base heals** — all LHW and Chain Heal base heals updated to match in-game tooltip values on Turtle WoW. Chain Heal coefficient empirically derived as 0.6500.
- **Corrected mana costs** — LHW and Chain Heal mana costs updated to in-game confirmed values.
- **Follow fix** — `/tcl` now resolves the follow target to a unitid (`party1`, `raid1`, etc.) via `UnitGUID` matching and calls `FollowUnit()` directly, bypassing Turtle WoW's fuzzy name matching.
- **Expanded log format** — log now includes `healingPower`, `missingHP`, `required`, `effectiveHeal`, `aggressiveness`, and `isTank` per cast. The `mode` column has been removed.
- **Fixed log timestamps** — `LogTimestamp()` now uses `GetGameTime()` for h/m/s and `GetTime()` fraction for centiseconds.
- **`/tcstatus` command** — shows healing power breakdown, effective heal for all 6 LHW ranks, and per-member rank decisions at current HP.

---

## Features

- **Unified healing logic** — single priority tree covering both small group and raid play
- **Pressure scoring** — combines HP deficit, live aggro status, and aggro history into a per-unit score driving target selection and spell choice
- **Position-aware Chain Heal** — uses SuperWoW `UnitPosition` to score clusters of nearby hurt players; picks the primary target that maximises total healing across all bounces
- **LHW rank selection** — picks the lowest rank covering the required threshold (deficit × tank factor × aggressiveness). Mana gate steps down if unaffordable
- **Crisis path** — when a tank-like unit reaches pressure ≥ 0.80, LHW fires immediately at the lowest rank covering the crisis threshold. No mana gate
- **Downrank aggressiveness** — two independent 0.0–1.0 sliders (normal and crisis) for tuning how aggressively the addon commits to high ranks. Designed for raids where other healers share the load
- **Banzai-1.0 aggro integration** — tracks tanking in real time; tank-like units receive priority healing and a 1.20× overheal buffer on required thresholds
- **Own healing power scanner** — no external dependency; correct `+damage and healing` bucketing
- **QuickHeal avoidance** — optional mode that skips the lowest-pressure target
- **Follow-by-unitid** — resolves target to a party/raid unitid and calls `FollowUnit()` directly
- **Heal decision logging** — structured per-cast log with all relevant state; exportable via SuperWoW `ExportFile`

---

## Requirements

| Dependency | Notes |
|---|---|
| **SuperWoW** | Required for `UnitPosition` (cluster scoring) and `ExportFile` (log export) |
| **AceLibrary** | Bundled in `libs\` |
| **AceEvent-2.0** | Bundled in `libs\` |
| **RosterLib-2.0** | Bundled in `libs\` |
| **Banzai-1.0** | Bundled in `libs\` — aggro features disabled gracefully if missing |

---

## Installation

1. Copy the `Tidecaller` folder into your `Interface\AddOns\` directory:

```
Interface/
  AddOns/
    Tidecaller/
      libs/
        AceLibrary/
        AceEvent-2.0/
        RosterLib-2.0/
        Banzai-1.0/
      Tidecaller.lua
      Tidecaller.toc
```

2. Enable the addon at the character select screen and log in.

---

## Slash Commands

| Command | Description |
|---|---|
| `/tcheal` | Cast a heal based on current decision logic |
| `/tcqh` | Toggle QuickHeal avoidance |
| `/tcfollow` | Toggle follow on/off |
| `/tcl` | Set follow target to current target (saves unitid) |
| `/tcdr` | Toggle downrank aggressiveness GUI |
| `/tclog` | Toggle heal decision logging on/off |
| `/tcexport` | Write log buffer to `TidecallerLog.txt` |
| `/tclogclear` | Clear log buffer without writing |
| `/tclogstat` | Show log buffer status |
| `/tcstatus` | Show healing power, LHW rank effective heals, and per-member rank decisions |
| `/tcdebug` | Toggle debug output |
| `/tcbanzai` | Diagnose Banzai-1.0 integration |
| `/tc` | Show command help |

---

## Healing Logic

### Decision Priority (per `/tcheal` press)

1. **Tank in crisis** (pressure ≥ 0.80) → LHW at rank per `CRISIS_AGGRESSIVENESS`, no mana gate
2. **Tank with 2+ nearby hurt players** → Chain Heal R1 on the tank
3. **Tank isolated or cluster too small** → LHW at rank per `PickLHWRank`
4. **No tank, 3+ injured in cluster** → Chain Heal R1 on best cluster target
5. **Fallback** → LHW on highest-pressure unit

### Pressure Score

Each unit's pressure score (0.0–1.0):

| Component | Contribution |
|---|---|
| HP deficit | up to 0.50 |
| Live aggro (currently tanking) | +0.25 |
| Aggro history (rolling count) | 0.0–0.25 |

Units below 20% HP receive a minimum pressure of 0.75 regardless of aggro.

### LHW Rank Selection (`PickLHWRank`)

```
required = missingHP × tankFactor × DOWNRANK_AGGRESSIVENESS
```

- `tankFactor` = `TANK_OVERHEAL_FACTOR` (1.20) for tank-like units, 1.0 otherwise
- Walk R1→R6, pick the first rank where `effectiveHeal >= required`
- Mana gate: step down until affordable, floor at R1

Effective heal per rank at 769 +healing (example):

| Rank | Mana | Effective |
|---|---|---|
| R1 | 99 | ~512 |
| R2 | 137 | ~604 |
| R3 | 175 | ~701 |
| R4 | 223 | ~831 |
| R5 | 289 | ~1016 |
| R6 | 361 | ~1210 |

### Chain Heal

Always R1. Efficiency at 769 +healing across 3 targets: **6.06 hp/mana** — the most efficient cast in the kit. Fires only when `CHAIN_HEAL_MIN` (default 3) or more injured players are within `CHAIN_HEAL_RANGE` yards of the primary target.

### Downrank Aggressiveness

Two independent settings, adjustable live via `/tcdr`:

| Setting | Applies to |
|---|---|
| `DOWNRANK_AGGRESSIVENESS` | All normal LHW casts |
| `CRISIS_AGGRESSIVENESS` | LHW_CRISIS casts only |

At 1.0: picks the minimum rank needed to cover the full required threshold. At 0.5: targets 50% of the required threshold, leaving the rest for other healers. Note: the tank overheal factor (1.20) is applied before aggressiveness, so 0.5 on a tank effectively covers ~60% of raw missing HP.

---

## Logging

`/tclog` records a structured entry per cast:

```
ts | unit | hp% | pressure | clusterScore | liveAggro | aggroScore | action | spellRank | healingPower | missingHP | required | effectiveHeal | aggressiveness | isTank
```

`/tcexport` writes the buffer to `TidecallerLog.txt` (requires SuperWoW). Buffer holds up to 500 entries, drops oldest when full.

---

## Configuration

All settings persist in `TidecallerDB` across sessions.

| Variable | Default | Description |
|---|---|---|
| `HEAL_THRESHOLD` | `90` | Only consider units below this HP% as heal candidates |
| `CHAIN_HEAL_MIN` | `3` | Minimum injured players in cluster to use Chain Heal |
| `CHAIN_HEAL_RANGE` | `12` | Yard radius for Chain Heal cluster scoring |
| `TANK_OVERHEAL_FACTOR` | `1.20` | Required threshold multiplier for tank-like targets |
| `DOWNRANK_AGGRESSIVENESS` | `1.0` | Fraction of required threshold to target (normal casts) |
| `CRISIS_AGGRESSIVENESS` | `1.0` | Fraction of required threshold to target (crisis casts) |
| `LHW_PRESSURE_FLOOR` | `0.55` | Pressure gate for QuickHeal avoidance logic |
| `QUICKHEAL_AVOID` | `false` | Skip lowest-pressure target to avoid overlapping with QuickHeal users |
| `FOLLOW_ENABLED` | `false` | Follow after `/tcheal` finds no candidates |
| `FOLLOW_TARGET_UNIT` | `nil` | Unitid of follow target (set via `/tcl`) |

---

## Follow

`/tcl` saves the **unitid** (`party1`, `party2`, `raid1`, etc.) of your current target and calls `FollowUnit()` directly. This avoids Turtle WoW's fuzzy `/followbyname` matching, which incorrectly resolves similar names (e.g. `Rels` vs `Relsh`).

> **Note:** Unitids are not persistent across sessions. Re-run `/tcl` after reforming a group or relogging.
