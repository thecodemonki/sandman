# SAND KINGDOMS — Fable 5 Architecture Brief
Consolidated from full design discussion. Everything under **LOCKED** should be treated as a firm decision to build the folder/module/schema structure around. Everything under **OPEN** needs a placeholder/flexible structure, not a hard-coded assumption — these will be decided in a later pass.

---

## 1. Game Concept (one paragraph)

A manhwa-inspired Roblox RPG. Sand manipulation is the visual differentiator. Players build a **personal tycoon-style sand base** (farm + auto-defense, no lose condition), venture into **Gate portals** across four biomes to fight monsters and collect materials, use those materials to upgrade both their combat tools and their base defenses, and progress through a **rank ladder (E → S → prestige)** with a real "hidden power" awakening mechanic. A **Team base** lets small, deliberately-formed friend groups build something together, separate from solo play. PvP is deferred — not a raiding system on the base, but a future separate opt-in event layer.

---

## 2. LOCKED — Base Ownership Model

- **Personal base**: automatic, one per player, keyed to `PlayerId`. Always saved. Never affected by who the player is currently grouped with.
- **Team base**: a second, separate base tied to a small, *deliberately formed* group (`TeamId`), not a random per-session queue. Saved independently of who is currently online — any member can load in solo and the base is exactly as they left it.
- **Squad** ≠ **Team**. Squad = whoever you're doing a Gate run with right now (friends or randoms, casual, dissolves after the run). Team = the persistent group that owns a Team base. These must be separate data structures; squad membership must never trigger a base reset or reassignment.
- **Randoms** can visit and help build on a Team base if invited in for a session, but do not gain ownership/persistent access. Visiting ≠ owning.
- Both base types must be centrally stored and keyed by ID, not bound to a specific server instance — a base must load identically regardless of which server the owner joins.

---

## 3. LOCKED — Personal Base: Core Loop

Tycoon-style, inspired by lemon-stand/RingFarm-type games. No wave system. No lose condition. No Core HP. No shields (shields solve an offline-PvP-raid problem this base does not have).

**Loop:**
1. Plant crops → grow over time → harvest → sell for currency.
2. Monsters spawn **ambiently and continuously** near the base (not in discrete rounds), at a rate that scales with how developed the base is.
3. Towers/traps **automatically** kill most ambient monsters — this is the entire point of defense in this model: it protects income *uptime*, not a lose-condition. Unmanaged monsters don't end anything; they just cause income to leak (trampled crops, stolen coin).
4. Players may **optionally** fight monsters manually for a bonus payout. This is never required. (Explicitly decided: automated-by-default, manual-combat-optional, not manual-combat-core.)
5. Currency and wilderness materials (from Gates, see Section 5) are spent on upgrades and new builds.
6. A better-developed base attracts more ambient monsters → more optional bonus-combat opportunities → more money to reinvest. This is an intentional positive feedback loop.

**Recurring pacing hook:** small special events roughly every 10 minutes (RingFarm-style), to keep the screen worth checking without requiring constant attention. Examples already scoped:
- Golden bloom — a crop plot glows briefly for a harvest multiplier
- Meteor/comet crash — a rare wilderness material appears briefly near the base
- Monster surge — a tougher monster appears, worth manually fighting
- Wandering trader — sells a rare seed/blueprint for a limited window

---

## 4. LOCKED — Buildable vs. Upgradable Rule

**Rule for the data schema:** if a player would ever want more than one of something on their plot, it's a **Build** (placeable object, instanced, can have multiple). If it's a single number that improves, it's an **Upgrade** (base-wide stat, no instancing). Walls are the one hybrid case: you *build* individual wall segments, but you *upgrade* the material tier as a single base-wide stat that retroactively strengthens every placed segment.

### Buildables

**Farming/economy:**
- Crop plots (placeable, plant crops — see tier list below)
- Watering well/oasis pump (speeds growth of nearby plots)
- Storage silo (holds harvested crops before sale)
- Trade post / market stall (sells crops for currency)
- Livestock pen *(optional, lower priority — passive slow income, needs feeding)*

**Defense** (each has a distinct mechanical role, not just a damage recolor):
- Sand turret — single-target ranged, hits nearest monster
- Blast cannon — AoE splash, slower fire rate, good vs. groups
- Spike wall — passive damage to anything touching it
- Quicksand trap — no damage, slows/roots (crowd control)
- Sentinel golem — the one *mobile* defense unit, chases nearest threat
- Ward totem — buffs range/damage of nearby towers (rewards deliberate base layout)
- Wall segments (build individually; strength comes from the global material-tier upgrade)

**Utility:**
- Crafting station (turns Gate materials into gear)
- Repair station (auto-repairs damaged walls/towers over time, or speed via feeding materials)
- Portal pad (fast travel to the Gate hub)

**Cosmetic (zero stat effect):**
- Decorations (statues, banners, sand sculptures)
- Biome-themed decor sets, unlocked by which Gates/biomes the player has actually cleared

### Upgradables
- Seed tier unlocks (which crops become plantable)
- Growth speed multiplier (from watering upgrades)
- Sell price multiplier (trade post tier)
- Storage capacity
- Wall material tier (global: packed sand → sandstone → crystal-infused → obsidian)
- Tower damage/range/fire rate (per-tower or base-wide tech tier — TBD, see Open Questions)
- Base level (the master gate: unlocks plot size, higher crop tiers, higher wall/tower tiers, more storage)
- Plot size

### Crop tier list (each tier gated by something different, intentionally)
| Crop | Gate | Notes |
|---|---|---|
| Dune wheat | Currency only | Starter crop, cheap, fast, low payout |
| Sand melon | Currency + watering upgrade | Needs infrastructure to be worth it |
| Glow cactus | Currency, higher cost | Slow grow, better payout, Crystal Caves flavor |
| Crystal berries | Requires a wilderness material from Gates | Ties farming loop to exploration loop |
| Void bloom | Requires a rare endgame material | Top tier, long grow time, high flex/status value |

---

## 5. LOCKED — Gates / Wilderness (feeds both combat and base)

The original Gates pillar (biome portals: Desert Dunes, Crystal Caves, Neon Wasteland, Frozen Tundra) is the source of the **wilderness materials** that:
1. Upgrade the player's combat tools/weapons, and
2. Unlock material-gated crops and "special" defense types on the personal base (not everything should be currency-purchasable — some defense/crop tiers should require a specific Gate material, so exploration and base-building stay linked rather than being two separate systems sitting side by side).

**Combat note:** the sand-manipulation ability kit used in Gate combat and the optional bonus-combat on the personal base should be **one shared system**, not two separate combat implementations.

---

## 6. LOCKED — Progression

- Rank ladder: E → D → C → B → A → S → Prestige ("???" beyond S)
- **Awakening/Regression** is a real mechanic, not just flavor: a mid-game milestone unlock (new ability tier, movement option, etc.) that gives the "secretly OP" payoff moment.
- **Prestige** resets some progress and permanently keeps other progress. Data schema needs two explicit buckets:
  - `PersistentProfile`: titles, cosmetics, achievements, eternal stats (e.g. total Gates cleared)
  - `ResettableProgress`: level, rank-within-ladder, base currency, most non-legendary gear

---

## 7. LOCKED — PvP (deferred, scoped down)

- **No base-raiding system for now.** Personal and Team bases are not attackable.
- PvP will exist later as a **separate, opt-in, event-based system** (not tied to base ownership/persistence at all) — exact shape TBD in a future design pass.
- If/when built: **full pay-to-win is acceptable** for that system specifically, but must ship with:
  - Weight-class matchmaking (match by combined power score, not open season)
  - A capped power gap between paid and free players (~1.5–2x max, not unlimited)
  - Preference for consumable/timed power purchases over permanent stat items, to avoid an ever-widening gap
- Cosmetic monetization (skins, emblems, auras, battle pass) applies to the whole game regardless of the PvP decision, and item data needs a strict `IsCosmetic` / `AffectsCombat` flag pair so purchase flows can enforce the rule programmatically, not just by convention.

---

## 8. OPEN — Needs a Decision Later, Build Flexible Structure

- Exact economy numbers: grow times, sell prices, tower/build costs, cost of "a good early base" vs. a maxed base.
- Monster spawn rate/toughness scaling formula (should stay a light ambient hum, never punishing).
- Whether tower damage/range/fire rate upgrades are per-tower or a base-wide tech tier.
- God Contract endgame quest — originally scoped as a guild-only raid boss; since guild PvP raiding is deferred, its exact requirements (solo-viable? Team-only? gated behind Awakening/Prestige?) need to be revisited.
- Whether/when guild-vs-guild base raiding gets reintroduced as a later feature.
- Full PvP event system design (matchmaking specifics, event cadence, reward structure).

---

## 9. Cross-Cutting Notes for Fable 5

- Every buildable item needs: `ItemType`, `IsCosmetic`, `AffectsCombat`, `IsMaterialGated` (bool + material ID if true), `IsCurrencyGated` (cost).
- Base data (Personal and Team) should NOT live in per-server memory — persist centrally, keyed by `PlayerId` or `TeamId`, loaded on join regardless of server instance.
- Keep the combat ability system as one shared module referenced by both Gate combat and personal-base bonus-combat, rather than duplicating logic.
- Squad, Team, and "visitor" are three distinct relationship types and should not share a single `GroupId`-style field — conflating them was the exact bug this whole design pass was trying to avoid.
