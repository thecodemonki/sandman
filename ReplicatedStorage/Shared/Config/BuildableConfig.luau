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
	Footprint: { Width: number, Height: number }, -- cells
	AllowedZones: { string }, -- PlotTemplate.ZoneType values this can be placed in
	MaxLevel: number?, -- nil = not per-instance levelable (build-only, no tower-style state)
	EvolvesInto: { EvolutionDef }?, -- nil = no evolution path
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

		Category = "Utility",
		Footprint = { Width = 2, Height = 2 },
		AllowedZones = { "Farm", "Open" },
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
	},
}

return BuildableConfig
