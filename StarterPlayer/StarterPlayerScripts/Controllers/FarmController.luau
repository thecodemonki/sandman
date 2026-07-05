-- Minimal first visual pass for farming: click a CropPlot placeholder to plant/harvest,
-- and reflect CropStageChanged visually (color/size per stage). No system-window UI, no
-- VFX, no art pass -- that's a later pass once there's something worth polishing.
--
-- ponytail: also carries the "monster is trampling something" warning overlay (item 5).
-- Approximate, not per-monster-target: MonsterSpawned/MonsterDied don't say which plot a
-- monster is after, so this shows the warning on ALL of the player's active crop plots
-- whenever at least one monster is alive, rather than pretending to know which one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Util.Net)

local STAGE_COLORS = {
	Empty = Color3.fromRGB(120, 100, 70), -- bare soil
	Growing = Color3.fromRGB(150, 170, 70),
	Grown = Color3.fromRGB(90, 200, 90),
}
local STAGE_HEIGHTS = {
	Empty = 1,
	Growing = 2,
	Grown = 3,
}
local WARNING_COLOR = Color3.fromRGB(230, 60, 60)

local FarmController = {}

local cropPlots = {} -- [placementId] = { Part: BasePart, Stage: string }
local activeMonsterCount = 0

local function applyVisual(plot)
	if plot.Stage ~= "Empty" and activeMonsterCount > 0 then
		plot.Part.Color = WARNING_COLOR
	else
		plot.Part.Color = STAGE_COLORS[plot.Stage] or plot.Part.Color
	end
	local size = plot.Part.Size
	plot.Part.Size = Vector3.new(size.X, STAGE_HEIGHTS[plot.Stage] or size.Y, size.Z)
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
			warn("RequestPlantCrop failed: " .. tostring(err))
		end
	elseif plot.Stage == "Grown" then
		local ok, err = Net.RequestHarvest:InvokeServer(placementId)
		if not ok then
			warn("RequestHarvest failed: " .. tostring(err))
		end
	end
	-- "Growing": nothing to do yet, clicking is a no-op.
end

-- Called by BuildController right after it places a CropPlot placeholder.
function FarmController.RegisterCropPlot(placementId: string, part: BasePart)
	cropPlots[placementId] = { Part = part, Stage = "Empty" }
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

	Net.MonsterSpawned.OnClientEvent:Connect(function()
		activeMonsterCount += 1
		refreshAllWarnings()
	end)
	Net.MonsterDied.OnClientEvent:Connect(function()
		activeMonsterCount = math.max(0, activeMonsterCount - 1)
		refreshAllWarnings()
	end)
end

return FarmController
