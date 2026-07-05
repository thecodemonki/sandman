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
local GridUtil = require(ReplicatedStorage.Shared.Util.GridUtil)

local FarmController = require(script.Parent.FarmController)
local UIController = require(script.Parent.UIController)

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

local ZONE_LEGEND_ORDER = { "Protected", "Farm", "Open", "Unbuildable" }
local ZONE_LEGEND_COLORS = {
	Protected = ZONE_COLORS.Protected,
	Farm = ZONE_COLORS.Farm,
	Open = ZONE_COLORS.Open,
	Unbuildable = UNBUILDABLE_COLOR,
}

local PLACEMENT_COLORS = {
	CropPlot = Color3.fromRGB(90, 140, 60),
	SandTurret = Color3.fromRGB(140, 120, 90),
	SandTurret_Crystal = Color3.fromRGB(120, 200, 220),
}

local BUILD_BUTTONS = {
	{ Label = "Crop Plot", ItemId = "CropPlot" },
	{ Label = "Sand Turret", ItemId = "SandTurret" },
}

local SELECTED_STROKE_COLOR = Color3.fromRGB(250, 220, 90)
local AFFORDABLE_COLOR = Color3.fromRGB(70, 70, 70)
local UNAFFORDABLE_COLOR = Color3.fromRGB(45, 45, 45)
local UNAFFORDABLE_TEXT_COLOR = Color3.fromRGB(150, 150, 150)

local BuildController = {}

local cellData = {} -- [key] = { Part, BaseColor, Col, Row, Zone }
local occupiedKeys = {} -- [key] = true, this-session-only (see ponytail note above)
local selectedItemId = nil
local currentCurrency: number? = nil -- seeded from UIController.GetCurrency() at Init(), see below
local buildButtons = {} -- [itemId] = { Button, Stroke, Cost }

local function cellKey(col: number, row: number): string
	return col .. "_" .. row
end

-- Shared with BuildService (ReplicatedStorage/Shared/Util/GridUtil.luau) so client rendering
-- and server placement positions can never drift apart again.
local function cellPosition(col: number, row: number): Vector3
	return GridUtil.CellToWorldCenter(col, row, PlotTemplate.CellSize, PLOT_ORIGIN)
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

-- Affordability is a visual hint only (buttons stay clickable either way; the server is
-- still the real gate) -- greys out anything the player can't currently afford, and shows
-- which build type is selected via a border so it reads correctly even when a button is
-- both selected AND unaffordable (background color alone can't show both at once).
local function refreshButtonAppearance()
	for itemId, entry in buildButtons do
		local affordable = currentCurrency == nil or entry.Cost == nil or currentCurrency >= entry.Cost
		entry.Button.BackgroundColor3 = affordable and AFFORDABLE_COLOR or UNAFFORDABLE_COLOR
		entry.Button.TextColor3 = affordable and Color3.new(1, 1, 1) or UNAFFORDABLE_TEXT_COLOR
		entry.Stroke.Thickness = (selectedItemId == itemId) and 3 or 0
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
		UIController.ShowMessage("Can't build here: " .. tostring(placementIdOrErr))
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

-- Static decoration only (brief part 2): sand-colored wall segments around the Protected
-- zone boundary and a small campfire near spawn. Not the real Wall buildable (build
-- segments + global material-tier upgrade) -- that's future BuildService work. These parts
-- are never touched again after spawning: no gameplay effect, not placement data.
local function buildProtectedZoneWalls()
	local zone = PlotTemplate.Zones[1]
	for _, z in PlotTemplate.Zones do
		if z.ZoneType == "Protected" then
			zone = z
			break
		end
	end

	local minX = PLOT_ORIGIN.X + zone.ColMin * PlotTemplate.CellSize
	local maxX = PLOT_ORIGIN.X + (zone.ColMax + 1) * PlotTemplate.CellSize
	local minZ = PLOT_ORIGIN.Z + zone.RowMin * PlotTemplate.CellSize
	local maxZ = PLOT_ORIGIN.Z + (zone.RowMax + 1) * PlotTemplate.CellSize

	local wallColor = Color3.fromRGB(205, 175, 125) -- packed sand (brief's wall tier 1 flavor)
	local wallHeight = 4
	local wallThickness = 1

	local function addWallSegment(sizeX: number, sizeZ: number, centerX: number, centerZ: number)
		local wall = Instance.new("Part")
		wall.Name = "ProtectedZoneWall"
		wall.Anchored = true
		wall.CanCollide = false -- no gameplay effect: must not block movement
		wall.CanQuery = false -- must not intercept clicks meant for cells/placements behind it
		wall.Material = Enum.Material.Sand
		wall.Color = wallColor
		wall.Size = Vector3.new(sizeX, wallHeight, sizeZ)
		wall.Position = Vector3.new(centerX, PLOT_ORIGIN.Y + wallHeight / 2, centerZ)
		wall.Parent = Workspace
	end

	local spanX = maxX - minX
	local spanZ = maxZ - minZ

	addWallSegment(spanX, wallThickness, (minX + maxX) / 2, minZ) -- north
	addWallSegment(spanX, wallThickness, (minX + maxX) / 2, maxZ) -- south
	addWallSegment(wallThickness, spanZ, minX, (minZ + maxZ) / 2) -- west
	addWallSegment(wallThickness, spanZ, maxX, (minZ + maxZ) / 2) -- east
end

local function buildCampfire()
	-- Just outside the grid near the default spawn corner; a decorative centerpiece, not a
	-- buildable cell.
	local basePosition = Vector3.new(PLOT_ORIGIN.X - 8, PLOT_ORIGIN.Y, PLOT_ORIGIN.Z + 12)

	local pit = Instance.new("Part")
	pit.Name = "CampfirePit"
	pit.Shape = Enum.PartType.Cylinder
	pit.Anchored = true
	pit.CanCollide = false -- no gameplay effect
	pit.CanQuery = false -- must not intercept clicks
	pit.Material = Enum.Material.Slate
	pit.Color = Color3.fromRGB(70, 65, 60)
	pit.Size = Vector3.new(0.6, 3, 3)
	pit.CFrame = CFrame.new(basePosition + Vector3.new(0, 0.3, 0)) * CFrame.Angles(0, 0, math.rad(90))
	pit.Parent = Workspace

	local logColor = Color3.fromRGB(90, 60, 40)
	for i = 1, 3 do
		local log = Instance.new("Part")
		log.Name = "CampfireLog"
		log.Anchored = true
		log.CanCollide = false
		log.CanQuery = false
		log.Material = Enum.Material.Wood
		log.Color = logColor
		log.Size = Vector3.new(0.6, 0.6, 3.2)
		log.CFrame = CFrame.new(basePosition + Vector3.new(0, 0.7, 0)) * CFrame.Angles(0, math.rad(i * 60), 0)
		log.Parent = Workspace
	end

	local flameAnchor = Instance.new("Part")
	flameAnchor.Name = "CampfireFlame"
	flameAnchor.Anchored = true
	flameAnchor.CanCollide = false
	flameAnchor.CanQuery = false
	flameAnchor.Transparency = 1
	flameAnchor.Size = Vector3.new(1, 1, 1)
	flameAnchor.CFrame = CFrame.new(basePosition + Vector3.new(0, 1.2, 0))
	flameAnchor.Parent = Workspace

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Brightness = 2
	light.Range = 16
	light.Shadows = false
	light.Parent = flameAnchor

	local fire = Instance.new("ParticleEmitter")
	fire.Color = ColorSequence.new(Color3.fromRGB(255, 140, 20), Color3.fromRGB(200, 30, 0))
	fire.Size = NumberSequence.new(0.8, 0.2)
	fire.Transparency = NumberSequence.new(0.2, 1)
	fire.Lifetime = NumberRange.new(0.6, 1.1)
	fire.Rate = 20
	fire.Speed = NumberRange.new(2, 4)
	fire.SpreadAngle = Vector2.new(15, 15)
	fire.Parent = flameAnchor
end

local function setSelected(itemId: string)
	if selectedItemId == itemId then
		selectedItemId = nil
	else
		selectedItemId = itemId
	end
	refreshHighlights()
	refreshButtonAppearance()
	return selectedItemId
end

local function buildUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildControllerUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Frame"
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

	for _, def in BUILD_BUTTONS do
		local cost = BuildableConfig[def.ItemId] and BuildableConfig[def.ItemId].CurrencyCost

		local button = Instance.new("TextButton")
		button.Name = def.ItemId
		button.Size = UDim2.new(1, -8, 0, 36)
		button.Text = cost and string.format("%s \u{2014} %d", def.Label, cost) or def.Label
		button.BackgroundColor3 = AFFORDABLE_COLOR
		button.TextColor3 = Color3.new(1, 1, 1)
		button.Parent = frame

		local stroke = Instance.new("UIStroke")
		stroke.Color = SELECTED_STROKE_COLOR
		stroke.Thickness = 0
		stroke.Parent = button

		buildButtons[def.ItemId] = { Button = button, Stroke = stroke, Cost = cost }

		button.MouseButton1Click:Connect(function()
			setSelected(def.ItemId)
		end)
	end

	-- Zone legend: a simple corner label, not fancy, so the floor colors mean something.
	local legend = Instance.new("Frame")
	legend.Name = "ZoneLegend"
	legend.Size = UDim2.new(0, 160, 0, 26 * #ZONE_LEGEND_ORDER + 8)
	legend.Position = UDim2.new(0, 10, 0, 190)
	legend.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	legend.Parent = screenGui

	local legendLayout = Instance.new("UIListLayout")
	legendLayout.Padding = UDim.new(0, 2)
	legendLayout.Parent = legend

	local legendPadding = Instance.new("UIPadding")
	legendPadding.PaddingTop = UDim.new(0, 4)
	legendPadding.PaddingLeft = UDim.new(0, 4)
	legendPadding.Parent = legend

	for _, zoneName in ZONE_LEGEND_ORDER do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, -8, 0, 22)
		row.BackgroundTransparency = 1
		row.Parent = legend

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.new(0, 18, 0, 18)
		swatch.Position = UDim2.new(0, 0, 0, 2)
		swatch.BackgroundColor3 = ZONE_LEGEND_COLORS[zoneName]
		swatch.Parent = row

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -24, 1, 0)
		label.Position = UDim2.new(0, 24, 0, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.new(1, 1, 1)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = zoneName
		label.Parent = row
	end
end

function BuildController.Init()
	buildFloor()
	buildProtectedZoneWalls()
	buildCampfire()
	buildUI()

	-- UIController.Init() already fetched the real starting balance (Bootstrap.client runs
	-- UIController first) -- reuse that instead of making a second identical server round trip.
	currentCurrency = UIController.GetCurrency()
	refreshButtonAppearance()

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		currentCurrency = newCurrency
		refreshButtonAppearance()
	end)
end

return BuildController
