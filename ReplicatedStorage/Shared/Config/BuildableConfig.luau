-- Starter buildable set for the grid/placement prompt. Costs and material ids are
-- placeholders (brief §8, OPEN) — tune in EconomyConfig later without a schema change.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Enums = require(ReplicatedStorage.Shared.Enums)
local ItemTypes = require(ReplicatedStorage.Shared.Types.ItemTypes)

type ItemDef = ItemTypes.ItemDef

export type EvolutionDef = {
	ToItemId: string,
	GatingMaterialId: string,
	GatingMaterialCount: number,
}

-- Extends ItemDef with the placement-specific fields BuildService needs.
export type BuildableDef = ItemDef & {
	Category: string, -- "Farming" | "Defense" | "Utility" | "Cosmetic"
	Description: string?, -- one-liner shown in the build catalog HUD
	Footprint: { Width: number, Height: number }, -- cells
	AllowedZones: { string }, -- PlotTemplate.ZoneType values this can be placed in
	MaxLevel: number?, -- nil = not per-instance levelable (build-only, no tower-style state)
	EvolvesInto: { EvolutionDef }?, -- nil = no evolution path

	-- Per-level stats, keyed by Placement.State.Level (1..MaxLevel). DefenseService reads
	-- Range/Damage/FireRateSeconds; BuildService only reads UpgradeCost (cost to reach that
	-- level from the previous one -- Level 1's UpgradeCost is unused, already paid via
	-- CurrencyCost at placement time). Buildables without MaxLevel don't need this.
	LevelStats: { [number]: { Range: number?, Damage: number?, FireRateSeconds: number?, UpgradeCost: number? } }?,

	-- Crop-only fields (ItemType == Enums.ItemType.Crop). Footprint/AllowedZones above are
	-- unused for these: a crop is planted into an existing CropPlot placement, it isn't
	-- itself grid-placed, so those are left as harmless zero/empty values on crop entries.
	GrowSeconds: number?,
	SellPrice: number?,
}

local BuildableConfig: { [string]: BuildableDef } = {

	CropPlot = {
		ItemId = "CropPlot",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 50, -- PLACEHOLDER (brief §8)

		Category = "Farming",
		Description = "Tillable soil. Click after placing to plant crops.",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Farm" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	StorageSilo = {
		ItemId = "StorageSilo",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 150, -- PLACEHOLDER (brief §8)

		Category = "Farming",
		Description = "Bulk storage for harvested crops.",
		Footprint = { Width = 2, Height = 2 },
		AllowedZones = { "Farm", "Open" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	-- TradePost is gone from here on purpose: it's a fixed world structure now (built by
	-- BuildController alongside the campfire/walls), not something players purchase/place.

	-- Passive perimeter defense: intended role is AoE contact damage to monsters that touch
	-- it -- mechanically distinct from SandTurret's ranged auto-fire. Config/catalog entry
	-- only for now: deliberately no LevelStats/MaxLevel so DefenseService's turret tick
	-- ignores it; the contact-damage tick is future DefenseService work.
	SpikeWall = {
		ItemId = "SpikeWall",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = true,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 120, -- PLACEHOLDER (brief §8)

		Category = "Defense",
		Description = "Jagged stone. Wounds monsters that touch it.",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Protected", "Open" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	CraftingStation = {
		ItemId = "CraftingStation",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 300, -- PLACEHOLDER (brief §8)

		Category = "Utility",
		Description = "Workbench for crafting. (Recipes coming soon.)",
		Footprint = { Width = 2, Height = 2 },
		AllowedZones = { "Protected", "Open" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	SandLantern = {
		ItemId = "SandLantern",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = true,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 25, -- PLACEHOLDER (brief §8)

		Category = "Cosmetic",
		Description = "A warm little light for the camp.",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Protected", "Farm", "Open" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	ClothBanner = {
		ItemId = "ClothBanner",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = true,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 40, -- PLACEHOLDER (brief §8)

		Category = "Cosmetic",
		Description = "Plain camp banner. A guild emblem, someday.",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Protected", "Farm", "Open" },
		MaxLevel = nil,
		EvolvesInto = nil,
	},

	SandTurret = {
		ItemId = "SandTurret",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = true,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 200, -- PLACEHOLDER (brief §8)

		Category = "Defense",
		Description = "Auto-fires at nearby monsters. Upgradable.",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Protected" },
		MaxLevel = 3, -- must reach max level before it's eligible to evolve
		EvolvesInto = {
			{
				ToItemId = "SandTurret_Crystal",
				GatingMaterialId = "CrystalShard", -- placeholder Gate material (brief §8)
				GatingMaterialCount = 5,
			},
		},

		-- PLACEHOLDER (brief §8). Range is set well above the distance from the Protected
		-- zone to MonsterService's current (also-placeholder) ambient spawn anchor, so the
		-- turret can actually reach ambient monsters until both get real spatial placement.
		-- Recalculated for center-anchored positions: the nearest Protected-zone cell (8,8)
		-- now sits ~80.6 studs from the spawn anchor (was ~76.4 under the old corner-anchored
		-- math), so Range needed a matching bump to stay in reach.
		LevelStats = {
			[1] = { Range = 90, Damage = 15, FireRateSeconds = 2, UpgradeCost = 0 },
			[2] = { Range = 100, Damage = 20, FireRateSeconds = 1.5, UpgradeCost = 100 },
			[3] = { Range = 110, Damage = 25, FireRateSeconds = 1, UpgradeCost = 200 },
		},
	},

	-- Evolved form. Its own entry so footprint/flags resolve normally once CurrentFormId
	-- swaps to it; not directly buildable (no CurrencyCost) and has no further evolution.
	SandTurret_Crystal = {
		ItemId = "SandTurret_Crystal",
		ItemType = Enums.ItemType.Build,
		IsCosmetic = false,
		AffectsCombat = true,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = nil,

		Category = "Defense",
		Footprint = { Width = 1, Height = 1 },
		AllowedZones = { "Protected" },
		MaxLevel = 3,
		EvolvesInto = nil,

		-- PLACEHOLDER (brief §8), stronger than the base form -- the evolution payoff.
		-- Recalculated alongside SandTurret's Range for the center-anchored position fix.
		LevelStats = {
			[1] = { Range = 100, Damage = 30, FireRateSeconds = 1.5, UpgradeCost = 0 },
			[2] = { Range = 110, Damage = 35, FireRateSeconds = 1.2, UpgradeCost = 150 },
			[3] = { Range = 120, Damage = 45, FireRateSeconds = 1, UpgradeCost = 300 },
		},
	},

	-- Starter crop tier (brief crop tier table): currency-gated only, cheap, fast, low payout.
	-- Planted into a CropPlot placement by FarmingService, not placed on the grid itself.
	DuneWheat = {
		ItemId = "DuneWheat",
		ItemType = Enums.ItemType.Crop,
		IsCosmetic = false,
		AffectsCombat = false,
		IsMaterialGated = false,
		GatingMaterialId = nil,
		CurrencyCost = 10, -- PLACEHOLDER (brief §8) -- seed cost

		Category = "Farming",
		Footprint = { Width = 0, Height = 0 }, -- unused, see BuildableDef note above
		AllowedZones = {}, -- unused, see BuildableDef note above
		MaxLevel = nil,
		EvolvesInto = nil,

		GrowSeconds = 30, -- PLACEHOLDER (brief §8)
		SellPrice = 20, -- PLACEHOLDER (brief §8)
	},
}

return BuildableConfig
