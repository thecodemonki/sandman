-- Client-side visual layer for MonsterService's abstract simulation. The server stays the
-- authority on travel timing and trample events; this only makes those events look like
-- something walked there: a blocky SandCrawler model interpolated from spawn point to the
-- target crop over the same travelSeconds the server computed (shipped in MonsterSpawned's
-- payload), plus a fade+poof on MonsterDied.
--
-- ponytail: procedural bob instead of a rigged/animated model -- first visual pass, no
-- assets exist. Monsters that spawn before any crop exists idle at their spawn point
-- forever (the payload has no target and the server doesn't broadcast retargets); their
-- tramples still land server-side. Fix by adding a MonsterTargetChanged event when it matters.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Util.Net)

-- Warm desert palette (art brief §2): sun-bleached browns, no bright primaries.
local BODY_COLOR = Color3.fromRGB(172, 140, 96)
local HEAD_COLOR = Color3.fromRGB(150, 120, 80)
local LEG_COLOR = Color3.fromRGB(120, 96, 64)
local EYE_COLOR = Color3.fromRGB(230, 180, 80)

local RENDER_Y = 1.4 -- body-center height so legs sit on the tile tops (ground plane Y=0.5)
local FADE_SECONDS = 0.4

local MonsterController = {}

-- [monsterId] = { Model, From: Vector3, To: Vector3?, StartClock, Travel: number?, Facing: Vector3 }
local activeMonsters = {}

local function addPart(model: Model, size: Vector3, offset: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false -- visual only: must not block movement
	part.CanQuery = false -- must not intercept clicks meant for cells/plots
	part.CastShadow = false
	part.Material = Enum.Material.Slate
	part.Color = color
	part.Size = size
	part.CFrame = CFrame.new(offset)
	part.Parent = model
	return part
end

local function buildCrawlerModel(monsterId: string): Model
	local model = Instance.new("Model")
	model.Name = "Monster_" .. monsterId

	-- Offsets are model-local (pivot at body center); PivotTo moves the whole rig.
	local body = addPart(model, Vector3.new(2.2, 0.9, 3), Vector3.zero, BODY_COLOR)
	addPart(model, Vector3.new(1.4, 0.7, 1), Vector3.new(0, 0.35, -1.7), HEAD_COLOR) -- head, front = -Z
	for _, x in { -0.8, 0.8 } do
		for _, z in { -1, 1 } do
			addPart(model, Vector3.new(0.4, 0.7, 0.4), Vector3.new(x, -0.7, z), LEG_COLOR)
		end
	end
	for _, x in { -0.35, 0.35 } do
		local eye = addPart(model, Vector3.new(0.18, 0.18, 0.18), Vector3.new(x, 0.5, -2.1), EYE_COLOR)
		eye.Material = Enum.Material.Neon
	end

	model.PrimaryPart = body
	model.Parent = Workspace
	return model
end

local function toVector3(pos): Vector3
	return Vector3.new(pos.X, RENDER_Y, pos.Z)
end

local function onMonsterSpawned(monsterId, monsterTypeId, spawnPosition, targetPosition, travelSeconds)
	if activeMonsters[monsterId] then
		return -- already rendered (snapshot + live event can overlap); keyed by id, idempotent
	end
	local from = toVector3(spawnPosition)
	local to = targetPosition and toVector3(targetPosition) or nil
	local facing = Vector3.new(0, 0, -1)
	if to and (to - from).Magnitude > 0.01 then
		facing = (to - from).Unit
	end

	activeMonsters[monsterId] = {
		Model = buildCrawlerModel(monsterId),
		From = from,
		To = to,
		StartClock = os.clock(),
		Travel = travelSeconds,
		Facing = facing,
	}
end

local function onMonsterDied(monsterId)
	local record = activeMonsters[monsterId]
	if not record then
		return
	end
	activeMonsters[monsterId] = nil -- stops the Heartbeat update; model is frozen where it died

	local model = record.Model

	-- Small sand poof at the death spot, then fade the parts out.
	local poof = Instance.new("ParticleEmitter")
	poof.Color = ColorSequence.new(Color3.fromRGB(199, 166, 118))
	poof.Size = NumberSequence.new(0.6, 1.4)
	poof.Transparency = NumberSequence.new(0.2, 1)
	poof.Lifetime = NumberRange.new(0.4, 0.8)
	poof.Rate = 0 -- burst only
	poof.Speed = NumberRange.new(3, 6)
	poof.SpreadAngle = Vector2.new(60, 60)
	poof.Parent = model.PrimaryPart
	poof:Emit(14)

	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(FADE_SECONDS), { Transparency = 1 }):Play()
		end
	end
	task.delay(1, function() -- outlives the fade AND the poof particles
		model:Destroy()
	end)
end

local function onHeartbeat()
	local now = os.clock()
	for _, record in activeMonsters do
		local walking = false
		local basePos = record.From
		if record.To and record.Travel and record.Travel > 0 then
			local alpha = math.min((now - record.StartClock) / record.Travel, 1)
			basePos = record.From:Lerp(record.To, alpha)
			walking = alpha < 1
		end

		-- Procedural gait: quick bob while walking, slow breathing-style bob while idle.
		local bob = walking and math.sin(now * 10) * 0.12 or math.sin(now * 2) * 0.05
		local lookTarget = basePos + record.Facing
		record.Model:PivotTo(
			CFrame.lookAt(Vector3.new(basePos.X, basePos.Y + bob, basePos.Z), Vector3.new(lookTarget.X, basePos.Y + bob, lookTarget.Z))
		)
	end
end

-- FarmController reads this for its trample-warning overlay instead of keeping its own
-- event counter (which could double-count a monster delivered via both snapshot and event).
function MonsterController.GetActiveMonsterCount(): number
	local count = 0
	for _ in activeMonsters do
		count += 1
	end
	return count
end

function MonsterController.Init()
	Net.MonsterSpawned.OnClientEvent:Connect(onMonsterSpawned)
	Net.MonsterDied.OnClientEvent:Connect(onMonsterDied)
	RunService.Heartbeat:Connect(onHeartbeat)

	-- Connect-then-ask, same as UIController's currency fetch: the first ambient monster
	-- spawns at PlayerAdded, before this script ran, so its MonsterSpawned never reached us.
	local ok, snapshot = pcall(function()
		return Net.RequestActiveMonsters:InvokeServer()
	end)
	if ok then
		for _, monster in snapshot do
			onMonsterSpawned(monster.Id, monster.MonsterTypeId, monster.SpawnPosition, nil, nil)
		end
	else
		warn("MonsterController: RequestActiveMonsters failed: " .. tostring(snapshot))
	end
end

return MonsterController
