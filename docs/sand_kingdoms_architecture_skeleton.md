# SAND KINGDOMS — Architecture Skeleton v1
Folder/module structure + DataStore schema. No implementation code. Built against the Architecture Brief: LOCKED decisions are hard-coded into the structure; OPEN items live in config modules so they can be tuned later without schema rewrites.

---

## 1. Project Folder Structure (Roblox Studio / Rojo layout)

```
SandKingdoms/
│
├── ReplicatedStorage/
│   └── Shared/
│       ├── Config/                      -- ALL tunable numbers live here, never in player data
│       │   ├── CropConfig.luau          -- crop tiers, grow times*, sell prices*, gating type
│       │   ├── BuildableConfig.luau     -- every placeable: costs*, footprint, category, flags
│       │   ├── UpgradeConfig.luau       -- base-wide upgrade tracks, tier costs*, effects
│       │   ├── MonsterConfig.luau       -- monster types, stats, spawn scaling formula*
│       │   ├── BiomeConfig.luau         -- 4 biomes: palettes, lighting, particles, drop tables
│       │   ├── EventConfig.luau         -- ~10-min event pool, weights, durations
│       │   ├── RankConfig.luau          -- E→S thresholds, Awakening milestone, prestige rules
│       │   ├── AbilityConfig.luau       -- sand-manipulation kit definitions (ONE kit, shared)
│       │   └── EconomyConfig.luau       -- currency defs, income leak rates*, caps
│       │                                   (* = OPEN numbers, placeholder values)
│       │
│       ├── Types/
│       │   ├── BaseTypes.luau           -- BaseData, Placement, UpgradeState
│       │   ├── PlayerTypes.luau         -- PersistentProfile, ResettableProgress
│       │   ├── TeamTypes.luau           -- TeamData, TeamMember, roles
│       │   ├── ItemTypes.luau           -- ItemDef + the four required flags
│       │   └── CombatTypes.luau         -- AbilityDef, DamageInfo, TargetInfo
│       │
│       ├── Util/
│       │   ├── Signal.luau
│       │   ├── Net.luau                 -- RemoteEvent/Function wrapper, single registry
│       │   └── TableUtil.luau
│       │
│       └── Enums.luau                   -- ItemType, GateBiome, RankTier, RelationshipType
│                                           (RelationshipType: Owner | TeamMember | Visitor —
│                                            three distinct values, per brief §9)
│
├── ServerScriptService/
│   ├── Services/
│   │   ├── DataService.luau             -- ONLY module that touches DataStores; session locking
│   │   ├── BaseService.luau             -- loads/saves base by PlayerId or TeamId; server-agnostic
│   │   ├── BuildService.luau            -- placement validation, build/upgrade requests
│   │   ├── FarmingService.luau          -- plant/grow/harvest lifecycle, trample handling
│   │   ├── EconomyService.luau          -- currency mutations (single authority), sell flow
│   │   ├── MonsterService.luau          -- ambient spawn loop, scaling, trample/steal behavior
│   │   ├── DefenseService.luau          -- tower targeting, trap triggers, golem AI, totem auras
│   │   ├── CombatService.luau           -- shared ability execution (gates AND base bonus-combat)
│   │   ├── GateService.luau             -- portal instancing, biome selection, party-size params
│   │   ├── ProgressionService.luau      -- XP, rank ladder, Awakening unlock, PrestigeManager
│   │   ├── EventService.luau            -- ~10-min event scheduler, event lifecycle
│   │   ├── TeamService.luau             -- team create/invite/leave; TeamId lifecycle
│   │   ├── SquadService.luau            -- ephemeral gate-run groups; NO persistence
│   │   ├── VisitService.luau            -- visitor sessions on bases; permission gate, no ownership
│   │   └── MonetizationService.luau     -- purchase flows; enforces IsCosmetic/AffectsCombat rule
│   │
│   └── Runtime/
│       └── Bootstrap.server.luau        -- service init order, one entry point
│
├── ServerStorage/
│   ├── Assets/
│   │   ├── Buildables/                  -- one model per BuildableConfig entry
│   │   ├── Monsters/
│   │   ├── Crops/                       -- growth-stage models per crop
│   │   └── GatePrefabs/                 -- per-biome dungeon pieces
│   └── BasePlots/
│       └── PlotTemplate.luau            -- empty plot layout, spawn zones, buildable grid def
│
├── StarterPlayer/
│   └── StarterPlayerScripts/
│       └── Controllers/
│           ├── BuildController.luau     -- placement UI/preview, sends requests to BuildService
│           ├── FarmController.luau      -- plant/harvest interactions
│           ├── CombatController.luau    -- ability input; same kit in gates and base
│           ├── CameraController.luau
│           └── UIController.luau        -- system-window UI shell, notifications, event banners
│
└── StarterGui/
    └── (UI screens; owned by UIController, not listed per-screen here)
```

---

## 2. DataStore Layout

Three stores. Nothing base-related is ever keyed to a server instance (brief §9).

```
DataStore: "PlayerProfiles"     key = tostring(PlayerId)
DataStore: "TeamBases"          key = TeamId (GUID string)
DataStore: "TeamRegistry"       key = tostring(PlayerId)  → their TeamId (or nil)
```

`TeamRegistry` exists so a player's profile never embeds team base data — it only points at it. Deleting/leaving a team touches the registry, never the base payload.

---

## 3. Schemas (Luau type skeletons)

### 3.1 Player profile — two explicit buckets (brief §6)

```luau
export type PlayerProfile = {
    SchemaVersion: number,               -- migration hook, day one

    Persistent: {                        -- NEVER reset by prestige
        Titles: { string },
        Cosmetics: { [string]: boolean },    -- owned cosmetic IDs
        Achievements: { [string]: boolean },
        EternalStats: {
            TotalGatesCleared: number,
            TotalMonstersKilled: number,
            TotalPrestiges: number,
        },
        AwakeningUnlocked: boolean,          -- persists per brief; revisit if prestige should reset it
    },

    Resettable: {                        -- wiped/reduced by PrestigeManager
        Level: number,
        XP: number,
        RankTier: string,                    -- Enums.RankTier: "E".."S"
        Currency: number,
        Materials: { [string]: number },     -- wilderness material ID → count
        Gear: { GearInstance },              -- non-legendary wiped on prestige (rule in RankConfig)
    },

    PersonalBase: BaseData,              -- lives inside the profile: 1:1 with player, always
}
```

### 3.2 Base data — ONE shared shape for Personal and Team bases

```luau
export type BaseData = {
    SchemaVersion: number,

    BaseLevel: number,                   -- master gate (plot size, tier unlocks)

    Placements: { Placement },           -- everything physically placed
    Upgrades: { [string]: number },      -- upgradeId → current tier (base-WIDE stats only)
                                         -- e.g. Upgrades["WallMaterial"] = 2 applies to ALL
                                         -- wall segments in Placements (hybrid rule, brief §4)

    Storage: {
        Crops: { [string]: number },
        Capacity: number,                -- derived cap lives in config; stored for quick reads
    },

    Decor: { Placement },                -- cosmetic-only placements, separated so combat/econ
                                         -- systems can ignore this array entirely
}

export type Placement = {
    Id: string,                          -- unique instance id
    ItemId: string,                      -- → BuildableConfig entry
    Position: { X: number, Y: number, Z: number },  -- plot-local coords
    Rotation: number,
    State: { [string]: any }?,           -- per-instance state (crop growth stage, tower HP,
                                         --  per-tower tier IF that OPEN question resolves
                                         --  to per-tower — field exists either way)
}
```

Personal currency stays on the *player*, not the base — a Team base therefore has a separate donated stockpile:

```luau
export type TeamBaseRecord = {
    SchemaVersion: number,
    TeamId: string,
    Name: string,
    CreatedAt: number,

    Members: { TeamMember },             -- deliberate membership, small cap
    Base: BaseData,                      -- same shape as personal
    SharedStockpile: {                   -- donated materials/currency, owned by the TEAM
        Currency: number,
        Materials: { [string]: number },
    },
}

export type TeamMember = {
    PlayerId: number,
    Role: string,                        -- "Leader" | "Member" (keep flat for v1)
    JoinedAt: number,
}
```

### 3.3 Squad — deliberately NOT a schema

Squads are runtime-only tables inside `SquadService` (server memory, per gate run). They have no DataStore, no ID that any base system can reference, and dissolve on run end. This is structural enforcement of Squad ≠ Team: a squad *cannot* own anything because there is nowhere to persist it.

### 3.4 Item definitions — required flags (brief §9)

```luau
export type ItemDef = {
    ItemId: string,
    ItemType: string,        -- Enums.ItemType: Build | Upgrade | Crop | Gear | Cosmetic
    IsCosmetic: boolean,
    AffectsCombat: boolean,  -- MonetizationService rejects real-money purchase where
                             -- AffectsCombat == true (until/unless PvP-event rules change this)
    IsMaterialGated: boolean,
    GatingMaterialId: string?,
    CurrencyCost: number?,   -- nil = not currency-purchasable
}
```

---

## 4. Relationship & Access Model

```
Player ──owns──────────────▶ PersonalBase        (automatic, PlayerId key)
Player ──member-of (0..1)──▶ Team ──owns──▶ TeamBase   (TeamId key, via TeamRegistry)
Player ──in (0..1, runtime)▶ Squad               (server memory only, gate runs)
Player ──visiting (0..1)───▶ any Base            (VisitService session: build perms
                                                  grantable, ownership never)
```

Access checks route through one function in `BaseService` (`GetAccessLevel(player, base) → Owner | TeamMember | Visitor | None`) so permission logic exists in exactly one place.

---

## 5. Where the OPEN Items Land (no schema rewrite needed)

| Open question (brief §8) | Where it's absorbed |
|---|---|
| Economy numbers | `CropConfig` / `EconomyConfig` / `BuildableConfig` values only |
| Monster scaling formula | `MonsterConfig` function stub; `MonsterService` reads it |
| Per-tower vs base-wide tower upgrades | Both paths exist: `Placement.State` (per-tower) and `Upgrades` (base-wide); pick one, delete nothing |
| God Contract requirements | `GateService` treats it as a gate type with a requirements table in config; solo/Team/rank gating is just config data |
| Future guild raiding / PvP events | New services later; `BaseData` needs no changes because attackability was never baked into it |

---

## 6. Service Event Flow (high level)

```
FarmingService ─crop harvested──▶ EconomyService ─currency granted─▶ client UI
MonsterService ─monster killed──▶ EconomyService (bounty) + ProgressionService (XP)
MonsterService ─crop trampled───▶ FarmingService (destroy plot instance)
DefenseService ─reads Placements─▶ acts on monsters from MonsterService
EventService ──event started────▶ relevant service (FarmingService for golden bloom,
                                   MonsterService for surge, etc.) + UIController banner
CombatService ─one ability kit──▶ used by GateService instances AND base bonus-combat
ProgressionService ─rank up─────▶ UIController (system-window flash + stinger)
```

---

## 7. Review Checklist (what to sanity-check before implementation)

1. `PersonalBase` living *inside* `PlayerProfile` vs. its own store — inside is simpler (one load per player) but caps base size to profile size limits. Fine for v1; flag if bases get huge.
2. `AwakeningUnlocked` currently persists through prestige — confirm that's the intended fantasy (I'd argue yes: re-earning the awakening every prestige undercuts the "hidden power" beat).
3. Team member cap — brief implies small (2–4 friends); suggest hard cap 4 in `TeamService` for v1.
4. `Decor` as a separate array from `Placements` — keeps cosmetic items out of every combat/economy iteration loop; costs a tiny bit of duplication in placement code. Recommend keeping.
