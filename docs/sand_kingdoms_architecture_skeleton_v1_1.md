# SAND KINGDOMS — Architecture Skeleton v1.1 (Gap Fill)
Companion to the v1 skeleton. Fills the five identified gaps. Same rules: structure and contracts only, no implementation logic. Everything here slots into the existing folder layout without moving anything.

---

## 1. GateService — Instance Lifecycle & Party Params

Gates are server-side instances (reserved-server teleport OR in-place arena, decided per biome size — see note at end of section).

```luau
-- Shared/Types/GateTypes.luau
export type GateParams = {
    GateId: string,                  -- unique per run
    Biome: string,                   -- Enums.GateBiome
    Difficulty: number,              -- tier 1..N, drives drop table + mob stats
    PartySize: number,               -- LOCKED rule: scales spawns UP, never splits loot
    MemberIds: { number },           -- snapshot of squad at entry (squad may dissolve mid-run
                                     --  on disconnect; run continues for remaining members)
}

export type GateRunState = {
    Params: GateParams,
    Phase: string,                   -- "Loading" | "Clearing" | "Boss" | "Looting" | "Closed"
    StartedAt: number,
    KillCount: number,
    BossSpawned: boolean,
}
```

**Lifecycle contract (GateService owns all of it):**

```
RequestGate(player, biome, difficulty)
  → validates rank/level gate access (ProgressionService)
  → snapshots current squad from SquadService → GateParams
  → CreateGateInstance(params)
       → clones prefab set from ServerStorage/GatePrefabs/<Biome>/
       → registers run in ActiveRuns: { [GateId]: GateRunState }
       → tells MonsterService to run a GATE spawn table (separate from ambient
         base spawning — same service, two spawn modes)
  → phase transitions: Clearing → Boss (kill threshold from BiomeConfig)
                       Boss → Looting (boss death event from CombatService)
  → CloseGate(gateId): grants loot via EconomyService (PER-PLAYER rolls,
    party size multiplies spawn density + drop table weight — never divides),
    XP via ProgressionService, teardown prefabs, remove from ActiveRuns
```

**Party-size scaling hook** (formula is OPEN; the *contract* is locked):

```luau
-- BiomeConfig.luau (per biome)
ScaleForParty = function(base: number, partySize: number): number
    return base * (1 + (partySize - 1) * PLACEHOLDER_SCALAR)  -- tune later
end
```

**Instancing note (decision needed eventually, structure supports both):** small gates can be arenas placed far from bases in the same server (cheap, fast joins); large biomes should be separate places via reserved-server teleport (Roblox streaming/memory limits). `GateService.CreateGateInstance` is the single seam where this choice lives — nothing else in the codebase knows which mode a gate used.

---

## 2. EventService — Scheduler Internals

One scheduler, one active event at a time for v1 (layering is a config flag flip later, not a rewrite).

```luau
-- Shared/Config/EventConfig.luau
export type EventDef = {
    EventId: string,                 -- "GoldenBloom" | "MeteorCrash" | "MonsterSurge" | "WanderingTrader"
    Weight: number,                  -- roll weight in the pool
    Duration: number,                -- seconds the event stays active
    Cooldown: number,                -- min seconds before this event can repeat
    TargetService: string,           -- which service executes it (see routing below)
    Params: { [string]: any },       -- event-specific tunables (multiplier, monster tier, stock)
}

EVENT_INTERVAL = 600                 -- ~10 min, LOCKED cadence; tunable constant
ALLOW_CONCURRENT = false             -- v1: one event at a time
```

**Scheduler contract:**

```
loop every EVENT_INTERVAL (per base plot, offset randomly ±60s so
                           neighboring plots don't fire in sync):
  → filter pool by cooldowns
  → weighted roll → EventDef
  → dispatch to TargetService:
       GoldenBloom     → FarmingService:ApplyEvent(def, basePlot)
       MeteorCrash     → spawns pickup via BuildService plot grid (free cell lookup)
       MonsterSurge    → MonsterService:SpawnSurge(def, basePlot)
       WanderingTrader → EconomyService:OpenTraderShop(def, basePlot)
  → broadcast Net.EventStarted to plot occupants (UIController banner + stinger)
  → after Duration: TargetService:EndEvent(eventId), broadcast Net.EventEnded
```

Events are **per-base-plot**, not server-global — a player alone on their base still gets the full cadence, and a Team base gets one shared event stream (not one per member).

---

## 3. AbilityConfig — Definition Shape (one kit, both contexts)

```luau
-- Shared/Types/CombatTypes.luau
export type AbilityDef = {
    AbilityId: string,               -- "SandSlash" | "DuneDash" | "SandSpike" | ...
    Slot: number,                    -- input slot 1..4
    UnlockRank: string,              -- Enums.RankTier gate ("E" = starter)
    RequiresAwakening: boolean,      -- the hidden-power tier lives behind this flag
    Cooldown: number,
    Cost: number?,                   -- stamina/essence cost (resource OPEN; field reserved)

    Targeting: string,               -- "Melee" | "Projectile" | "AOEGround" | "Self"
    Range: number,
    BaseDamage: number,              -- scaled by gear via CombatService, single formula

    Movement: string?,               -- "Dash" | "Surf" | "Flight" | nil — movement abilities
                                     --  and attack abilities share one def shape

    VFXStyleId: string,              -- → cosmetic sand-skin overrides resolve here;
                                     --  skins swap VFXStyleId output, NEVER touch damage
}
```

**Context rule (structural):** `CombatService:Execute(player, abilityId, targetInfo)` is the only entry point. It does not know whether the caller is standing in a gate or on a base — `MonsterService` owns which monsters exist in each context, so the same execution path resolves both. Bonus-income-for-manual-kills is an `EconomyService` listener on the monster-killed signal filtered by context == "Base", not a separate combat path.

---

## 4. MonsterService — Two Spawn Modes, One Service

```luau
-- Shared/Config/MonsterConfig.luau
export type MonsterDef = {
    MonsterId: string,
    Tier: number,
    Health: number, Damage: number, Speed: number,
    Behavior: string,                -- "TrampleCrops" | "StealCoin" | "AttackDefenses" | "Boss"
    Bounty: number,                  -- manual-kill payout (the optional-combat reward)
    DropTable: { { ItemId: string, Weight: number } },
}

-- Ambient scaling stub (formula OPEN, signature locked):
AmbientSpawnRate = function(baseDevelopmentScore: number): number
    -- baseDevelopmentScore computed by BaseService from BaseLevel + placement count.
    -- Must stay a "light hum": clamp output at MAX_CONCURRENT_AMBIENT (placeholder 6).
    return PLACEHOLDER_FORMULA(baseDevelopmentScore)
end
```

**Mode A — Ambient (base plots):** continuous trickle per occupied plot, rate from `AmbientSpawnRate`, hard concurrency clamp, monsters despawn if the plot empties (no offline pressure — LOCKED). Targets: crops (trample) → stored coin (steal) → defenses, priority order in config.

**Mode B — Gate (dungeon runs):** spawn tables driven by `GateParams` (biome, difficulty, party scaling). No clamp — density IS the difficulty. Owned by the same service so monster defs, drops, and the killed-signal exist exactly once.

---

## 5. Net.luau — Remote Registry (complete v1 list)

Single registry module; nothing creates remotes ad hoc. Server-authoritative: every client→server call is a *request* the server validates.

```luau
-- Client → Server (RemoteFunctions: request/response)
Net.RequestPlaceBuild      -- (itemId, plotPos, rotation) → ok/err     [BuildService]
Net.RequestRemoveBuild     -- (placementId) → ok/err                   [BuildService]
Net.RequestUpgrade         -- (upgradeId) → ok/newTier/err             [BuildService]
Net.RequestPlantCrop       -- (plotPlacementId, cropId) → ok/err       [FarmingService]
Net.RequestHarvest         -- (plotPlacementId) → ok/yield/err         [FarmingService]
Net.RequestSellCrops       -- (cropId, amount) → ok/coins/err          [EconomyService]
Net.RequestEnterGate       -- (biome, difficulty) → ok/gateId/err      [GateService]
Net.RequestUseAbility      -- (abilityId, targetInfo) → ok/err         [CombatService]
Net.RequestCreateTeam      -- (name) → ok/teamId/err                   [TeamService]
Net.RequestTeamInvite      -- (targetPlayerId) → ok/err                [TeamService]
Net.RequestVisit           -- (targetBaseOwnerId) → ok/err             [VisitService]
Net.RequestLoadIntoBase    -- ("Personal" | "Team") → ok/err           [BaseService]
Net.RequestPurchase        -- (productId) → ok/err                     [MonetizationService]
Net.RequestPrestige        -- () → ok/summary/err                      [ProgressionService]

-- Server → Client (RemoteEvents: fire-and-forget)
Net.BaseLoaded             -- full BaseData snapshot on plot entry
Net.PlacementChanged       -- delta: placement added/removed/state-changed
Net.CurrencyChanged        -- new balance (+ source tag for UI feedback)
Net.CropStageChanged       -- growth-stage visual updates
Net.MonsterSpawned / Net.MonsterDied
Net.EventStarted / Net.EventEnded      -- 10-min event banners
Net.XPGained / Net.RankUp              -- RankUp drives the system-window flash + stinger
Net.AwakeningUnlocked                  -- the big one; full-screen moment
Net.TeamUpdated                        -- membership/stockpile changes
Net.GatePhaseChanged                   -- Clearing → Boss → Looting UI states
Net.LootGranted                        -- per-player gate rewards reveal
```

---

## 6. Updated Review Checklist (adds to v1's four items)

5. Gate instancing mode (same-server arena vs reserved-server teleport) — structure supports both behind one seam; decide per-biome before building gate content.
6. Events are per-plot with a ±60s desync offset — confirm you want Team bases to share ONE event stream (current design) rather than per-member streams.
7. `MAX_CONCURRENT_AMBIENT = 6` placeholder — the "light hum, never punishing" clamp. Tune in playtesting, but the clamp itself should survive.
8. Ability resource cost (stamina/essence/none) is undecided — field is reserved in AbilityDef so adding it later is config, not schema surgery.
