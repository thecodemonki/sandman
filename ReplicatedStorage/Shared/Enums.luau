-- Shared enum tables. Only ItemType is populated for this prompt; GateBiome, RankTier,
-- and RelationshipType get filled in when the systems that need them land.

local Enums = {}

Enums.ItemType = {
	Build = "Build",
	Upgrade = "Upgrade",
	Crop = "Crop",
	Gear = "Gear",
	Cosmetic = "Cosmetic",
}

return Enums
