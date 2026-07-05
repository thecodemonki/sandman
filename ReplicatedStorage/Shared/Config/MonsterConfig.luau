-- Ambient-mode monster data (brief §5/§9 Mode A only). Only SandCrawler is defined for this
-- prompt; more monster types and the Gate spawn-table mode land with MonsterService's
-- future gate-side work.

export type MonsterDef = {
	MonsterId: string,
	Health: number,
	Damage: number,
	Speed: number, -- studs/sec, used for ambient travel-time math
	Behavior: string, -- "TrampleCrops" | "StealCoin" | "AttackDefenses" | "Boss"
	Bounty: number, -- manual-kill payout; reserved, not wired up (no manual combat yet)
	DropTable: { { ItemId: string, Weight: number } },
}

local Monsters: { [string]: MonsterDef } = {
	SandCrawler = {
		MonsterId = "SandCrawler",
		Health = 50, -- PLACEHOLDER (brief §8)
		Damage = 5, -- PLACEHOLDER (brief §8)
		Speed = 8, -- PLACEHOLDER (brief §8)
		Behavior = "TrampleCrops",
		Bounty = 15, -- PLACEHOLDER (brief §8) -- reserved, unused until manual combat exists
		DropTable = {},
	},
}

local MonsterConfig = {
	Monsters = Monsters,

	-- "Light hum, never punishing" clamp (brief §8 OPEN item; this is the resolved contract).
	MAX_CONCURRENT_AMBIENT = 6,
}

-- baseDevelopmentScore is a stand-in for BaseService's future BaseLevel+placementCount
-- formula; MonsterService currently just passes its placement count. The formula itself
-- is a placeholder, tuned later -- the clamp is the part that must hold.
function MonsterConfig.AmbientSpawnRate(baseDevelopmentScore: number): number
	local raw = math.floor(baseDevelopmentScore / 2) + 1
	return math.min(raw, MonsterConfig.MAX_CONCURRENT_AMBIENT)
end

return MonsterConfig
