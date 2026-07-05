-- Minimal first visual pass: build the static plot floor from PlotTemplate, let the player
-- pick a buildable type and click an empty cell to place it. No preview ghost, no VFX --
-- functional visibility only, polish is a later pass.
--
-- ponytail: placements render as flat colored blocks (no real models -- ServerStorage/
-- Assets/Buildables has no assets yet). Only renders what gets placed THIS session: there's
-- no cross-session persistence yet (BuildService's placement table is an in-memory stub that
-- resets every server restart), so there's nothing to "load in" and restore anyway. Once
-- BaseService/persistence exists and a real snapshot-on-join path is added, this is where
-- it plugs in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Util.Net)
local PlotTemplate = require(ReplicatedStorage.Shared.Config.PlotTemplate)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)

local FarmController = require(script.Parent.FarmController)

-- One fixed plot position for now (brief §8 / skeleton §5: multi-plot instancing per
-- player is BaseService's future job, deliberately out of scope here).
local PLOT_ORIGIN = Vector3.new(0, 0, 0)

local ZONE_COLORS = {
	Protected = Color3.fromRGB(190, 90, 90),
	Farm = Color3.fromRGB(120, 170, 90),
	Open = Color3.fromRGB(210, 190, 140),
}
local UNBUILDABLE_COLOR = Color3.fromRGB(55, 55, 55) -- cells with no zone assigned; not clickable
local HIGHLIGHT_COLOR = Color3.fromRGB(250, 240, 120)

local PLACEMENT_COLORS = {
	CropPlot = Color3.fromRGB(90, 140, 60),
	SandTurret = Color3.fromRGB(140, 120, 90),
	SandTurret_Crystal = Color3.fromRGB(120, 200, 220),
}

local BuildController = {}

local cellData = {} -- [key] = { Part, BaseColor, Col, Row, Zone }
local occupiedKeys = {} -- [key] = true, this-session-only (see ponytail note above)
local selectedItemId = nil

local function cellKey(col: number, row: number): string
	return col .. "_" .. row
end

local function cellPosition(col: number, row: number): Vector3
	return Vector3.new(
		PLOT_ORIGIN.X + col * PlotTemplate.CellSize + PlotTemplate.CellSize / 2,
		PLOT_ORIGIN.Y,
		PLOT_ORIGIN.Z + row * PlotTemplate.CellSize + PlotTemplate.CellSize / 2
	)
end

local function refreshHighlights()
	local entry = selectedItemId and BuildableConfig[selectedItemId]
	for key, cell in cellData do
		local color = cell.BaseColor
		if entry and not occupiedKeys[key] and cell.Zone and table.find(entry.AllowedZones, cell.Zone) then
			color = HIGHLIGHT_COLOR
		end
		cell.Part.Color = color
	end
end

local function spawnPlacementModel(placementId: string, itemId: string, key: string)
	occupiedKeys[key] = true

	local cell = cellData[key]
	local part = Instance.new("Part")
	part.Name = "Placement_" .. placementId
	part.Anchored = true
	part.CanCollide = true
	part.Size = Vector3.new(PlotTemplate.CellSize - 1, 3, PlotTemplate.CellSize - 1)
	part.CFrame = CFrame.new(cell.Part.Position + Vector3.new(0, 2, 0))
	part.Color = PLACEMENT_COLORS[itemId] or Color3.fromRGB(150, 150, 150)
	part.Parent = Workspace

	if itemId == "CropPlot" then
		FarmController.RegisterCropPlot(placementId, part)
	end
end

local function onCellClicked(key: string)
	if occupiedKeys[key] then
		return -- built on; FarmController (etc.) owns clicks on its own placeholder model
	end
	if not selectedItemId then
		return
	end

	local cell = cellData[key]
	local entry = BuildableConfig[selectedItemId]
	if not entry or not cell.Zone or not table.find(entry.AllowedZones, cell.Zone) then
		return
	end

	local ok, placementIdOrErr = Net.RequestPlaceBuild:InvokeServer(selectedItemId, { Col = cell.Col, Row = cell.Row }, 0)
	if ok then
		spawnPlacementModel(placementIdOrErr, selectedItemId, key)
		refreshHighlights()
	else
		warn("RequestPlaceBuild failed: " .. tostring(placementIdOrErr))
	end
end

local function buildFloor()
	local boundary = Instance.new("Part")
	boundary.Name = "PlotBoundary"
	boundary.Anchored = true
	boundary.CanCollide = true
	boundary.Size = Vector3.new(PlotTemplate.GridWidth * PlotTemplate.CellSize + 4, 0.5, PlotTemplate.GridHeight * PlotTemplate.CellSize + 4)
	boundary.Position = Vector3.new(
		PLOT_ORIGIN.X + (PlotTemplate.GridWidth * PlotTemplate.CellSize) / 2,
		PLOT_ORIGIN.Y - 0.75,
		PLOT_ORIGIN.Z + (PlotTemplate.GridHeight * PlotTemplate.CellSize) / 2
	)
	boundary.Color = Color3.fromRGB(30, 30, 30)
	boundary.Parent = Workspace

	for col = 0, PlotTemplate.GridWidth - 1 do
		for row = 0, PlotTemplate.GridHeight - 1 do
			local zone = PlotTemplate.GetZoneAt(col, row)
			local color = zone and ZONE_COLORS[zone] or UNBUILDABLE_COLOR

			local part = Instance.new("Part")
			part.Name = string.format("Cell_%d_%d", col, row)
			part.Anchored = true
			part.CanCollide = true
			part.Size = Vector3.new(PlotTemplate.CellSize - 0.2, 1, PlotTemplate.CellSize - 0.2)
			part.Position = cellPosition(col, row)
			part.Color = color
			part.Parent = Workspace

			local key = cellKey(col, row)
			cellData[key] = { Part = part, BaseColor = color, Col = col, Row = row, Zone = zone }

			if zone then
				local clickDetector = Instance.new("ClickDetector")
				clickDetector.Parent = part
				clickDetector.MouseClick:Connect(function()
					onCellClicked(key)
				end)
			end
		end
	end
end

local function setSelected(itemId: string)
	if selectedItemId == itemId then
		selectedItemId = nil
	else
		selectedItemId = itemId
	end
	refreshHighlights()
	return selectedItemId
end

local function buildUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildControllerUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(0, 160, 0, 90)
	frame.Position = UDim2.new(0, 10, 0, 10)
	frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	frame.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 4)
	padding.Parent = frame

	local buttons = {} -- [itemId] = TextButton

	local function refreshButtonColors()
		for itemId, button in buttons do
			button.BackgroundColor3 = (selectedItemId == itemId) and Color3.fromRGB(140, 120, 40) or Color3.fromRGB(70, 70, 70)
		end
	end

	local function addButton(label: string, itemId: string)
		local button = Instance.new("TextButton")
		button.Name = itemId
		button.Size = UDim2.new(1, -8, 0, 36)
		button.Text = label
		button.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = frame

		buttons[itemId] = button

		button.MouseButton1Click:Connect(function()
			setSelected(itemId)
			refreshButtonColors()
		end)
	end

	addButton("Crop Plot", "CropPlot")
	addButton("Sand Turret", "SandTurret")
end

function BuildController.Init()
	buildFloor()
	buildUI()
end

return BuildController
