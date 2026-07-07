-- Farming visuals: click a CropPlot to plant/harvest, and render CropStageChanged as real
-- stage models (sprouts -> golden wheat) swapped on top of a static soil block, instead of
-- the old recolor/resize of the plot part itself. Warm desert palette per the art brief --
-- muted olive sprouts, sun-gold grown wheat, no bright cartoon green.
--
-- ponytail: also carries the "monster is trampling something" warning overlay (item 5).
-- Approximate, not per-monster-target: MonsterSpawned/MonsterDied don't say which plot a
-- monster is after, so this shows the warning on ALL of the player's active crop plots
-- whenever at least one monster is alive, rather than pretending to know which one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Util.Net)
local UIController = require(script.Parent.UIController)
local MonsterController = require(script.Parent.MonsterController)

local SOIL_COLOR = Color3.fromRGB(120, 100, 70) -- matches BuildController's CropPlot style
local WARNING_COLOR = Color3.fromRGB(230, 60, 60)

local SPROUT_COLOR = Color3.fromRGB(146, 138, 92) -- desert-muted olive, not cartoon green
local STALK_COLOR = Color3.fromRGB(208, 178, 102) -- sun-gold wheat
local HEAD_COLOR = Color3.fromRGB(224, 198, 124)

-- Fixed stalk offsets (studs, plot-local X/Z) so a plot's crop looks scattered without RNG.
local SPROUT_OFFSETS = { { -1, -0.8 }, { 0.9, 0.2 }, { -0.2, 1.1 } }
local STALK_OFFSETS = { { -1.4, -1.2 }, { 0, -1 }, { 1.3, -0.6 }, { -1, 0.6 }, { 0.3, 1.2 }, { 1.4, 0.9 } }

local FarmController = {}

local cropPlots = {} -- [placementId] = { Part: BasePart, Stage: string, CropModel: Model? }

local function addStalk(model: Model, topOfPlot: Vector3, dx: number, dz: number, height: number, color: Color3, withHead: boolean)
	local stalk = Instance.new("Part")
	stalk.Anchored = true
	stalk.CanCollide = false -- decorative: must not block movement
	stalk.CanQuery = false -- must not intercept clicks meant for the plot beneath
	stalk.CastShadow = false
	stalk.Material = Enum.Material.Grass
	stalk.Color = color
	stalk.Size = Vector3.new(0.2, height, 0.2)
	-- Slight deterministic lean per stalk so the cluster doesn't read as a comb.
	stalk.CFrame = CFrame.new(topOfPlot + Vector3.new(dx, height / 2, dz)) * CFrame.Angles(dz * 0.06, 0, dx * 0.06)
	stalk.Parent = model

	if withHead then
		local head = Instance.new("Part")
		head.Anchored = true
		head.CanCollide = false
		head.CanQuery = false
		head.CastShadow = false
		head.Material = Enum.Material.Grass
		head.Color = HEAD_COLOR
		head.Size = Vector3.new(0.35, 0.7, 0.35)
		head.CFrame = stalk.CFrame * CFrame.new(0, height / 2 + 0.3, 0)
		head.Parent = model
	end
end

-- Stage models sit on the plot part's top surface; "Empty" renders nothing (bare soil).
local function buildCropModel(stage: string, plotPart: BasePart): Model?
	if stage ~= "Growing" and stage ~= "Grown" then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = "Crop_" .. stage
	local top = plotPart.Position + Vector3.new(0, plotPart.Size.Y / 2, 0)

	if stage == "Growing" then
		for _, offset in SPROUT_OFFSETS do
			addStalk(model, top, offset[1], offset[2], 0.9, SPROUT_COLOR, false)
		end
	else -- Grown
		for _, offset in STALK_OFFSETS do
			addStalk(model, top, offset[1], offset[2], 2.2, STALK_COLOR, true)
		end
	end

	model.Parent = plotPart
	return model
end

local function applyVisual(plot)
	if plot.CropModel then
		plot.CropModel:Destroy()
	end
	plot.CropModel = buildCropModel(plot.Stage, plot.Part)

	-- Trample warning stays on the soil block itself (cheap, readable from a distance).
	-- Count comes from MonsterController (id-keyed, snapshot-seeded) so it can't drift the
	-- way a local event counter could.
	if plot.Stage ~= "Empty" and MonsterController.GetActiveMonsterCount() > 0 then
		plot.Part.Color = WARNING_COLOR
	else
		plot.Part.Color = SOIL_COLOR
	end
end

local function refreshAllWarnings()
	for _, plot in cropPlots do
		applyVisual(plot)
	end
end

local function setStage(placementId, stage)
	local plot = cropPlots[placementId]
	if not plot then
		return
	end
	plot.Stage = stage
	applyVisual(plot)
end

local function onCropPlotClicked(placementId)
	local plot = cropPlots[placementId]
	if not plot then
		return
	end

	if plot.Stage == "Empty" then
		local ok, err = Net.RequestPlantCrop:InvokeServer(placementId, "DuneWheat")
		if not ok then
			UIController.ShowMessage("Can't plant: " .. tostring(err))
		end
	elseif plot.Stage == "Grown" then
		local ok, err = Net.RequestHarvest:InvokeServer(placementId)
		if not ok then
			UIController.ShowMessage("Can't harvest: " .. tostring(err))
		end
	end
	-- "Growing": nothing to do yet, clicking is a no-op.
end

-- Called by BuildController right after it places a CropPlot placeholder.
function FarmController.RegisterCropPlot(placementId: string, part: BasePart)
	cropPlots[placementId] = { Part = part, Stage = "Empty", CropModel = nil }
	applyVisual(cropPlots[placementId])

	local clickDetector = Instance.new("ClickDetector")
	clickDetector.Parent = part
	clickDetector.MouseClick:Connect(function()
		onCropPlotClicked(placementId)
	end)
end

function FarmController.Init()
	Net.CropStageChanged.OnClientEvent:Connect(function(placementId, stage)
		setStage(placementId, stage)
	end)

	-- Deferred so MonsterController's handler for the same event has definitely updated its
	-- monster table first (signal invocation order across scripts isn't guaranteed).
	local function refreshNextStep()
		task.defer(refreshAllWarnings)
	end
	Net.MonsterSpawned.OnClientEvent:Connect(refreshNextStep)
	Net.MonsterDied.OnClientEvent:Connect(refreshNextStep)
end

return FarmController
