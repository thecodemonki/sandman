-- Ambient-mode monster spawning only (brief §5/§9 Mode A). No Gate spawn-table mode, no
-- monster-vs-tower logic (DefenseService's job later), no death/removal path yet — a
-- SandCrawler just keeps existing and re-trampling until DefenseService can kill it.
--
-- ponytail: monsters have no Workspace representation yet. A monster is a data record
-- with an abstract SpawnPosition; "reaching" a target is an elapsed-time check
-- (distance/Speed), same pattern FarmingService uses for grow timers, not a physical
-- movement loop. PlayerMonsters below is the same in-memory stub pattern as BuildService's
-- PlayerBases/PlayerWallets — swap for real per-base tracking once BaseService exists.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local BuildService = require(ServerScriptService.Services.BuildService)
local FarmingService = require(ServerScriptService.Services.FarmingService)
local MonsterConfig = require(ReplicatedStorage.Shared.Config.MonsterConfig)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)

local DEFENSE_CATEGORY = "Defense"

local CROP_PLOT_ITEM_ID = "CropPlot"
local SPAWN_CHECK_INTERVAL = 5 -- seconds, PLACEHOLDER (brief §8)
local RETARGET_INTERVAL = 5 -- seconds to wait before re-checking when no crop target exists
-- Fixed abstract point just outside the plot grid. Monsters don't move visually yet, so
-- this only feeds the distance/Speed travel-time math below. PLACEHOLDER (brief §8).
local MONSTER_SPAWN_POSITION = { X = -6, Y = 0, Z = -6 }

type MonsterRecord = {
	Id: string,
	MonsterId: string,
	SpawnPosition: { X: number, Y: number, Z: number },
	SpawnedAt: number,
	CurrentHealth: number,
}

local MonsterService = {}

-- ponytail: stub storage, see note above.
local PlayerMonsters: { [Player]: { [string]: MonsterRecord } } = {}

-- Set by Init(); only ever read after Init() has required it.
local Net = nil

local function countEntries(dict): number
	local count = 0
	for _ in dict do
		count += 1
	end
	return count
end

-- A turret shouldn't feed the threat it exists to reduce, so development score only counts
-- economy/farming buildings (crops, storage, trade post, ...) -- anything NOT Category ==
-- "Defense". Reuses BuildableConfig's existing Category field rather than a new flag.
local function countDevelopmentPlacements(placements): number
	local count = 0
	for _, placement in placements do
		local formId = placement.State and placement.State.CurrentFormId or placement.ItemId
		local entry = BuildableConfig[formId]
		if entry and entry.Category ~= DEFENSE_CATEGORY then
			count += 1
		end
	end
	return count
end

local function findNearestActiveCropPlot(placements, fromPosition)
	local nearestId, nearestDistance = nil, math.huge
	for placementId, placement in placements do
		if placement.ItemId == CROP_PLOT_ITEM_ID and placement.State and placement.State.CropId then
			local dx = placement.Position.X - fromPosition.X
			local dz = placement.Position.Z - fromPosition.Z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance < nearestDistance then
				nearestDistance = distance
				nearestId = placementId
			end
		end
	end
	return nearestId, nearestDistance
end

-- Repeats forever: pick nearest active crop, travel (elapsed-time wait), trample, retarget.
-- Terminates on its own next wake once PlayerMonsters[player][monsterId] is gone (leave or,
-- eventually, death).
local function runMonsterBehavior(player: Player, monsterId: string)
	local monsterDef = MonsterConfig.Monsters.SandCrawler -- only type spawned in this prompt

	while PlayerMonsters[player] and PlayerMonsters[player][monsterId] do
		local monster = PlayerMonsters[player][monsterId]
		local placements = BuildService.GetOrCreatePlayerState(player)
		local targetId, distance = findNearestActiveCropPlot(placements, monster.SpawnPosition)

		if not targetId then
			task.wait(RETARGET_INTERVAL)
		else
			local travelSeconds = distance / monsterDef.Speed
			task.wait(travelSeconds)
			if PlayerMonsters[player] and PlayerMonsters[player][monsterId] then
				FarmingService.TrampleCrop(player, targetId)
			end
		end
	end
end

local function spawnMonster(player: Player, monsterTypeId: string)
	local monsterId = HttpService:GenerateGUID(false)
	PlayerMonsters[player][monsterId] = {
		Id = monsterId,
		MonsterId = monsterTypeId,
		SpawnPosition = MONSTER_SPAWN_POSITION,
		SpawnedAt = os.time(),
		CurrentHealth = MonsterConfig.Monsters[monsterTypeId].Health,
	}

	Net.MonsterSpawned:FireClient(player, monsterId, monsterTypeId, MONSTER_SPAWN_POSITION)
	task.spawn(runMonsterBehavior, player, monsterId)
end

-- One loop per occupied plot (brief §4/§9: ambient, continuous, scales with development).
local function ambientSpawnLoop(player: Player)
	while PlayerMonsters[player] do
		local placements = BuildService.GetOrCreatePlayerState(player)
		local devScore = countDevelopmentPlacements(placements) -- stand-in for BaseLevel+placementCount (brief §8)
		local targetCount = MonsterConfig.AmbientSpawnRate(devScore)
		local aliveCount = countEntries(PlayerMonsters[player])

		if aliveCount < targetCount then
			spawnMonster(player, "SandCrawler")
		end

		task.wait(SPAWN_CHECK_INTERVAL)
	end
end

local function onPlayerAdded(player: Player)
	PlayerMonsters[player] = {}
	task.spawn(ambientSpawnLoop, player)
end

local function onPlayerRemoving(player: Player)
	-- No offline pressure (locked rule): monsters never persist or act once the plot
	-- empties. Loops above check this table on their next wake and stop on their own.
	PlayerMonsters[player] = nil
end

-- Exposed so DefenseService can target/damage monsters through the same records this
-- service already tracks, instead of keeping a second copy of monster state.
function MonsterService.GetPlayerMonsters(player: Player): { [string]: MonsterRecord }
	if not PlayerMonsters[player] then
		PlayerMonsters[player] = {}
	end
	return PlayerMonsters[player]
end

-- Exposed so DefenseService can remove a monster it just killed without reaching into
-- PlayerMonsters directly. Behavior loops for the removed monster stop on their own next
-- wake (same mechanism as despawn-on-leave).
function MonsterService.RemoveMonster(player: Player, monsterId: string): boolean
	if PlayerMonsters[player] and PlayerMonsters[player][monsterId] then
		PlayerMonsters[player][monsterId] = nil
		return true
	end
	return false
end

function MonsterService.Init()
	Net = require(ReplicatedStorage.Shared.Util.Net)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

return MonsterService
