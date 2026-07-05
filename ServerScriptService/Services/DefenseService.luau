-- Automated defense only (brief §3: "automated-by-default, manual-combat-optional, not
-- manual-combat-core"). Turrets auto-target and auto-fire on ambient monsters from
-- MonsterService. No manual/bonus combat here — that's a future prompt. Towers only ever
-- reduce MonsterService's leak; no lose condition, no Core HP.
--
-- ponytail: same abstract/timer-simulated approach as MonsterService — no projectiles or
-- visuals, just elapsed-time fire-rate checks and distance math against MonsterService's
-- (also abstract) monster positions. Per-turret combat runtime state (LastFiredAt) lives
-- directly on Placement.State, same place Level/CurrentFormId already live — no separate
-- DefenseService-side table duplicating BuildService's placements.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BuildService = require(ServerScriptService.Services.BuildService)
local MonsterService = require(ServerScriptService.Services.MonsterService)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)

local DEFENSE_CATEGORY = "Defense"
local TICK_INTERVAL = 1 -- seconds, PLACEHOLDER (brief §8) -- polling resolution, not fire rate

local DefenseService = {}

-- Set by Init(); only ever read after Init() has required it.
local Net = nil

local function findNearestMonsterInRange(monsters, fromPosition, range: number)
	local nearestId, nearestDistance = nil, math.huge
	for monsterId, monster in monsters do
		local dx = monster.SpawnPosition.X - fromPosition.X
		local dz = monster.SpawnPosition.Z - fromPosition.Z
		local distance = math.sqrt(dx * dx + dz * dz)
		if distance <= range and distance < nearestDistance then
			nearestDistance = distance
			nearestId = monsterId
		end
	end
	return nearestId, nearestDistance
end

-- One placement at a time; no-ops for anything that isn't an active Defense buildable.
local function tickTurret(player: Player, placement)
	local entry = placement.State and BuildableConfig[placement.State.CurrentFormId]
	if not entry or entry.Category ~= DEFENSE_CATEGORY or not entry.LevelStats then
		return
	end

	local levelStats = entry.LevelStats[placement.State.Level]
	if not levelStats then
		return
	end

	local lastFiredAt = placement.State.LastFiredAt or 0
	if os.time() - lastFiredAt < levelStats.FireRateSeconds then
		return
	end

	local monsters = MonsterService.GetPlayerMonsters(player)
	local targetId = findNearestMonsterInRange(monsters, placement.Position, levelStats.Range)
	if not targetId then
		return
	end

	placement.State.LastFiredAt = os.time()

	local target = monsters[targetId]
	target.CurrentHealth -= levelStats.Damage

	if target.CurrentHealth <= 0 then
		MonsterService.RemoveMonster(player, targetId)
		Net.MonsterDied:FireClient(player, targetId)
	end
end

local function defenseTickLoop(player: Player)
	while player.Parent do
		local placements = BuildService.GetOrCreatePlayerState(player)
		for _, placement in placements do
			tickTurret(player, placement)
		end
		task.wait(TICK_INTERVAL)
	end
end

local function onPlayerAdded(player: Player)
	task.spawn(defenseTickLoop, player)
end

function DefenseService.Init()
	Net = require(ReplicatedStorage.Shared.Util.Net)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
end

return DefenseService
