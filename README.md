# Tidecaller

**Version:** 0.1  
**Author:** Rel  
**Client:** Turtle WoW 1.12 / SuperWoW

Shaman healing addon with aggro-aware target selection, position-based Chain Heal scoring, and pressure-driven LHW downranking. Built for multibox and small group play.

---

## Features

- **Two healing modes** — Solo and Raid, each with distinct spell priority logic
- **Pressure scoring** — combines HP deficit, live aggro status, and aggro history into a single score per unit to drive spell rank and target selection
- **Position-aware Chain Heal** — uses SuperWoW `UnitPosition` to score clusters of nearby hurt players; picks the primary target that maximises total healing delivered across all bounces
- **LHW downranking** — automatically steps down from R6 to R2 based on pressure score and mana, avoiding waste on low-priority targets
- **Banzai-1.0 aggro integration** — tracks who is tanking in real time; tank-like units receive priority healing and different rank thresholds
- **QuickHeal avoidance** — optional mode that skips the lowest-HP target on the assumption other healers are already covering them
- **Follow-by-unitid** — follow logic resolves your target to a party/raid unitid (`party1`, `raid3`, etc.) and calls `FollowUnit()` directly, bypassing Turtle WoW's fuzzy name matching
- **Heal decision logging** — structured per-cast log with timestamp, unit, HP%, pressure, cluster score, mode, and spell rank; exportable to `TidecallerLog.txt` via SuperWoW `ExportFile`

---

## Requirements

| Dependency | Notes |
|---|---|
| **SuperWoW** | Required for `UnitPosition` (cluster scoring) and `ExportFile` (log export) |
| **AceLibrary** | Bundled in `libs\` |
| **AceEvent-2.0** | Bundled in `libs\` |
| **RosterLib-2.0** | Bundled in `libs\` |
| **Banzai-1.0** | Bundled in `libs\` — aggro features are disabled gracefully if missing |

---

## Installation

1. Copy the `Tidecaller` folder into your `Interface\AddOns\` directory.
2. The folder structure should look like this:

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

3. Enable the addon at the character select screen and log in.

---

## Slash Commands

| Command | Description |
|---|---|
| `/tcheal` | Cast a heal based on the current decision logic |
| `/tcsolo` | Switch to **Solo mode** (pressure-driven, LHW primary) |
| `/tcraid` | Switch to **Raid mode** (Chain Heal primary) |
| `/tcqh` | Toggle QuickHeal avoidance (skip the lowest HP target) |
| `/tcfollow` | Toggle follow on/off |
| `/tcl` | Set follow target to your current target |
| `/tclog` | Toggle heal decision logging on/off |
| `/tcexport` | Write the log buffer to `TidecallerLog.txt` |
| `/tclogclear` | Clear the log buffer without writing |
| `/tclogstat` | Show current log buffer status |
| `/tcdebug` | Toggle debug output |
| `/tcbanzai` | Diagnose Banzai-1.0 integration |
| `/tc` | Show command help |

---

## Healing Logic

### Solo Mode (`/tcsolo`)

Prioritises tank survival. Spell priority per `/tcheal` press:

1. **Tank in crisis** (pressure ≥ 0.80) → LHW immediately, no cluster check
2. **Tank with nearby hurt players** → Chain Heal ranked by cluster score
3. **Tank isolated** → LHW ranked by pressure
4. **No tank, cluster exists** → Chain Heal if enough nearby hurt players (`CHAIN_HEAL_MIN`)
5. **Fallback** → LHW on highest-pressure unit

### Raid Mode (`/tcraid`)

Chain Heal primary. Spell priority per `/tcheal` press:

1. **Tank with nearby hurt players** → Chain Heal ranked by cluster score
2. **Tank isolated** → LHW on tank
3. **No tank** → Chain Heal on best cluster target
4. **Fallback** → LHW on highest-pressure unit

### Pressure Score

Each unit's pressure score (0.0–1.0) is composed of:

| Component | Max contribution |
|---|---|
| HP deficit | 0.50 |
| Live aggro (currently tanking) | +0.25 |
| Aggro history (rolling count) | 0.0–0.25 |

Units below 20% HP are given a minimum pressure of 0.75 regardless of aggro status.

### LHW Rank Selection

- **Tank-like unit:** R6 if pressure ≥ `LHW_PRESSURE_FLOOR` (default 0.55), otherwise R2
- **Non-tank:** R6 if below 40% HP, otherwise R2
- **Mana gate:** steps down toward R2 if current mana cannot afford the chosen rank

### Chain Heal Cluster Scoring

For each candidate primary target, the cluster score sums:

- The primary target's HP deficit
- The HP deficit of every other hurt player within `CHAIN_HEAL_RANGE` yards (default 12)
- A small aggro bonus for any unit in the cluster that is tank-like

The candidate with the highest cluster score is chosen as the Chain Heal primary.

---

## Follow

`/tcl` saves the **unitid** (`party1`, `party2`, `raid1`, etc.) of your current target rather than their name, then calls `FollowUnit()` directly. This avoids Turtle WoW's fuzzy name matching, which can cause `/followbyname` to resolve incorrectly when character names are similar (e.g. `Rels` vs `Relsh`).

`/tcheal` will automatically follow when called with nobody below the heal threshold and follow is enabled.

> **Note:** Unitids are not persistent across sessions. Re-run `/tcl` after reforming a group or relogging.

---

## Configuration

Settings are saved in `TidecallerDB` and persist across sessions. They can be adjusted directly in the saved variables file or via the slash commands above.

| Variable | Default | Description |
|---|---|---|
| `RAID_MODE` | `false` | `false` = Solo mode, `true` = Raid mode |
| `HEAL_THRESHOLD` | `90` | Only consider units below this HP% as heal candidates |
| `CHAIN_HEAL_MIN` | `2` | Minimum hurt players in cluster to prefer Chain Heal (Solo mode) |
| `CHAIN_HEAL_RANGE` | `12` | Yard radius for Chain Heal bounce scoring |
| `LHW_PRESSURE_FLOOR` | `0.55` | Pressure threshold separating R2 and R6 LHW for tanks |
| `QUICKHEAL_AVOID` | `false` | Skip the lowest HP target to avoid overlapping with QuickHeal users |
| `FOLLOW_ENABLED` | `false` | Whether to follow after `/tcheal` finds no heal candidates |
| `FOLLOW_TARGET_UNIT` | `nil` | Unitid of the follow target (set via `/tcl`) |

---

## Logging

`/tclog` starts recording a structured entry for every heal cast. Each entry contains:

```
timestamp | unit | hp% | pressure | clusterScore | mode | liveAggro | aggroScore | action | spellRank
```

`/tcexport` writes the buffer to `TidecallerLog.txt` (requires SuperWoW). `/tclog` a second time stops logging and also flushes the buffer. The buffer holds up to 500 entries and drops the oldest when full.
