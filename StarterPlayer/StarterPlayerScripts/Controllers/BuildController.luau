-- Grid rendering + build catalog HUD. The player picks a buildable from the categorized
-- catalog panel and clicks an empty cell to place it. No preview ghost, no VFX -- that's a
-- later pass.
--
-- Zone tiles render as sand-material ground tinted around CampTerrace's color, with a thin
-- neon border strip per zone as the actual zone identifier (art brief: zones should read as
-- ground, not a board-game overlay).
--
-- ponytail: placements render as single material-styled blocks (no real models -- ServerStorage/
-- Assets/Buildables has no assets yet). Only renders what gets placed THIS session: there's
-- no cross-session persistence yet (BuildService's placement table is an in-memory stub that
-- resets every server restart), so there's nothing to "load in" and restore anyway. Once
-- BaseService/persistence exists and a real snapshot-on-join path is added, this is where
-- it plugs in.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Net = require(ReplicatedStorage.Shared.Util.Net)
local Enums = require(ReplicatedStorage.Shared.Enums)
local PlotTemplate = require(ReplicatedStorage.Shared.Config.PlotTemplate)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)
local GridUtil = require(ReplicatedStorage.Shared.Util.GridUtil)

local FarmController = require(script.Parent.FarmController)
local UIController = require(script.Parent.UIController)

-- One fixed plot position for now (brief §8 / skeleton §5: multi-plot instancing per
-- player is BaseService's future job, deliberately out of scope here).
local PLOT_ORIGIN = Vector3.new(0, 0, 0)

-- Matches Workspace.CampTerrace (Sand material, Burlap-ish color) so the grid reads as the
-- same ground the terrace established. Zone tints are deliberately faint -- the neon border
-- strips are what identifies a zone, not the fill color.
local TERRACE_SAND = Color3.fromRGB(199, 166, 118)
local ZONE_TINTS = {
	Protected = Color3.fromRGB(209, 163, 127), -- faint warm shift
	Farm = Color3.fromRGB(183, 172, 122), -- faint green shift
	Open = TERRACE_SAND,
}
local UNBUILDABLE_TINT = Color3.fromRGB(172, 146, 106) -- darker sand; not clickable
local HIGHLIGHT_COLOR = Color3.fromRGB(250, 238, 150) -- valid-cell tint while placing

-- Zone border strips + legend swatches share these accents.
local ZONE_ACCENTS = {
	Protected = Color3.fromRGB(255, 200, 100),
	Farm = Color3.fromRGB(140, 215, 110),
	Open = Color3.fromRGB(235, 220, 185),
}
local UNBUILDABLE_ACCENT = Color3.fromRGB(110, 100, 85)
local ZONE_LEGEND_ORDER = { "Protected", "Farm", "Open", "Unbuildable" }

-- Simple placeholder looks per buildable (single block, real material) until
-- ServerStorage/Assets/Buildables has actual models.
local PLACEMENT_STYLES = {
	CropPlot = { Material = Enum.Material.Ground, Color = Color3.fromRGB(120, 100, 70), Height = 1 },
	SandTurret = { Material = Enum.Material.Sandstone, Color = Color3.fromRGB(196, 168, 122), Height = 4 },
	SandTurret_Crystal = { Material = Enum.Material.Glass, Color = Color3.fromRGB(120, 200, 220), Height = 4 },
	StorageSilo = { Material = Enum.Material.Wood, Color = Color3.fromRGB(168, 130, 86), Height = 5 },
	TradePost = { Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(150, 112, 72), Height = 3 },
	SpikeWall = { Material = Enum.Material.Slate, Color = Color3.fromRGB(140, 135, 125), Height = 2 },
	CraftingStation = { Material = Enum.Material.Wood, Color = Color3.fromRGB(122, 92, 62), Height = 2.5 },
	SandLantern = { Material = Enum.Material.Neon, Color = Color3.fromRGB(245, 205, 130), Height = 1.5 },
	ClothBanner = { Material = Enum.Material.Fabric, Color = Color3.fromRGB(172, 92, 80), Height = 4 },
}
local DEFAULT_PLACEMENT_STYLE = { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(150, 150, 150), Height = 3 }

-- System-window UI identity (art brief §6): translucent cool navy + gold accents, kept
-- deliberately distinct from the warm world palette.
local PANEL_BG = Color3.fromRGB(16, 24, 44)
local PANEL_STROKE = Color3.fromRGB(95, 140, 215)
local GOLD = Color3.fromRGB(255, 210, 120)
local TAB_ACTIVE_BG = Color3.fromRGB(50, 80, 145)
local TAB_INACTIVE_BG = Color3.fromRGB(30, 42, 70)
local ENTRY_BG = Color3.fromRGB(36, 52, 88)
local ENTRY_BG_DIM = Color3.fromRGB(24, 32, 52)
local TEXT_BRIGHT = Color3.fromRGB(235, 240, 250)
local TEXT_DIM = Color3.fromRGB(140, 150, 170)
local DESC_COLOR = Color3.fromRGB(170, 185, 210)
local DESC_COLOR_DIM = Color3.fromRGB(110, 120, 140)
local SELECTED_STROKE_COLOR = Color3.fromRGB(250, 220, 90)

local CATEGORY_ORDER = { "Farming", "Defense", "Utility", "Cosmetic" }
local CATEGORY_LABELS = { Farming = "Farm", Defense = "Defense", Utility = "Utility", Cosmetic = "Decor" }

local BuildController = {}

local cellData = {} -- [key] = { Part, BaseColor, Col, Row, Zone }
local occupiedKeys = {} -- [key] = true, this-session-only (see ponytail note above)
local selectedItemId = nil
local currentCurrency: number? = nil -- seeded from UIController.GetCurrency() at Init(), see below
local buildButtons = {} -- [itemId] = { Button, Stroke, NameLabel, DescLabel, Cost }
local currencyLabel: TextLabel? = nil

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
		entry.Button.BackgroundColor3 = affordable and ENTRY_BG or ENTRY_BG_DIM
		entry.NameLabel.TextColor3 = affordable and TEXT_BRIGHT or TEXT_DIM
		entry.DescLabel.TextColor3 = affordable and DESC_COLOR or DESC_COLOR_DIM
		entry.Stroke.Thickness = (selectedItemId == itemId) and 2 or 0
	end
end

local function refreshCurrencyLabel()
	if currencyLabel then
		currencyLabel.Text = "Coins  " .. (currentCurrency and tostring(currentCurrency) or "--")
	end
end

local function spawnPlacementModel(placementId: string, itemId: string, key: string)
	local cell = cellData[key]
	local entry = BuildableConfig[itemId]
	local footprint = entry and entry.Footprint or { Width = 1, Height = 1 }
	local style = PLACEMENT_STYLES[itemId] or DEFAULT_PLACEMENT_STYLE

	for dx = 0, footprint.Width - 1 do
		for dy = 0, footprint.Height - 1 do
			occupiedKeys[cellKey(cell.Col + dx, cell.Row + dy)] = true
		end
	end

	local part = Instance.new("Part")
	part.Name = "Placement_" .. placementId
	part.Anchored = true
	part.CanCollide = true
	part.Material = style.Material
	part.Color = style.Color
	part.Size = Vector3.new(
		footprint.Width * PlotTemplate.CellSize - 1,
		style.Height,
		footprint.Height * PlotTemplate.CellSize - 1
	)
	-- Anchor cell center + half-footprint offset = footprint center; base sits on tile tops.
	part.CFrame = CFrame.new(cell.Part.Position + Vector3.new(
		(footprint.Width - 1) * PlotTemplate.CellSize / 2,
		0.5 + style.Height / 2,
		(footprint.Height - 1) * PlotTemplate.CellSize / 2
	))
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
	for col = 0, PlotTemplate.GridWidth - 1 do
		for row = 0, PlotTemplate.GridHeight - 1 do
			local zone = PlotTemplate.GetZoneAt(col, row)
			local color = zone and ZONE_TINTS[zone] or UNBUILDABLE_TINT

			local part = Instance.new("Part")
			part.Name = string.format("Cell_%d_%d", col, row)
			part.Anchored = true
			part.CanCollide = true
			part.Material = Enum.Material.Sand -- Ground/Slate render too dark: reads as overlay again
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

-- Thin glowing strip around each zone's perimeter -- the actual zone identifier now that
-- the tile fills are all near-terrace sand. Inset slightly so the Protected strip peeks out
-- from under the wall segments. Purely decorative: CanCollide AND CanQuery false.
local function buildZoneBorders()
	local inset = 0.5
	local stripHeight = 0.12
	local stripWidth = 0.45
	local stripY = PLOT_ORIGIN.Y + 0.55 -- just above tile tops (tiles span -0.5..0.5)

	local function addStrip(color: Color3, sizeX: number, sizeZ: number, centerX: number, centerZ: number)
		local strip = Instance.new("Part")
		strip.Name = "ZoneBorder"
		strip.Anchored = true
		strip.CanCollide = false
		strip.CanQuery = false
		strip.Material = Enum.Material.Neon
		strip.Color = color
		strip.Size = Vector3.new(sizeX, stripHeight, sizeZ)
		strip.Position = Vector3.new(centerX, stripY, centerZ)
		strip.Parent = Workspace
	end

	for _, zone in PlotTemplate.Zones do
		local color = ZONE_ACCENTS[zone.ZoneType]
		local minX = PLOT_ORIGIN.X + zone.ColMin * PlotTemplate.CellSize + inset
		local maxX = PLOT_ORIGIN.X + (zone.ColMax + 1) * PlotTemplate.CellSize - inset
		local minZ = PLOT_ORIGIN.Z + zone.RowMin * PlotTemplate.CellSize + inset
		local maxZ = PLOT_ORIGIN.Z + (zone.RowMax + 1) * PlotTemplate.CellSize - inset
		local spanX = maxX - minX
		local spanZ = maxZ - minZ

		addStrip(color, spanX, stripWidth, (minX + maxX) / 2, minZ) -- north
		addStrip(color, spanX, stripWidth, (minX + maxX) / 2, maxZ) -- south
		addStrip(color, stripWidth, spanZ, minX, (minZ + maxZ) / 2) -- west
		addStrip(color, stripWidth, spanZ, maxX, (minZ + maxZ) / 2) -- east
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

	-- Sparse cyan embers (art brief §2: one accent color, used sparingly -- a hint at the
	-- hidden-power theme, not a recolor of the fire).
	local embers = Instance.new("ParticleEmitter")
	embers.Color = ColorSequence.new(Color3.fromRGB(110, 230, 215))
	embers.LightEmission = 1
	embers.Size = NumberSequence.new(0.15, 0.05)
	embers.Transparency = NumberSequence.new(0.3, 1)
	embers.Lifetime = NumberRange.new(1.2, 2)
	embers.Rate = 3
	embers.Speed = NumberRange.new(3, 5)
	embers.SpreadAngle = Vector2.new(8, 8)
	embers.Parent = flameAnchor
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

-- Directly buildable catalog entries (crops and evolved forms have no CurrencyCost or
-- aren't ItemType.Build), sorted cheap-first for a stable order despite dict iteration.
local function catalogEntries()
	local list = {}
	for itemId, entry in BuildableConfig do
		if entry.ItemType == Enums.ItemType.Build and entry.CurrencyCost then
			table.insert(list, {
				ItemId = itemId,
				Category = entry.Category,
				Cost = entry.CurrencyCost,
				Name = (itemId:gsub("(%l)(%u)", "%1 %2")), -- "SandTurret" -> "Sand Turret"
				Description = entry.Description or "",
			})
		end
	end
	table.sort(list, function(a, b)
		if a.Cost ~= b.Cost then
			return a.Cost < b.Cost
		end
		return a.ItemId < b.ItemId
	end)
	return list
end

local function styleAsSystemWindow(frame: GuiObject)
	frame.BackgroundColor3 = PANEL_BG
	frame.BackgroundTransparency = 0.2

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = PANEL_STROKE
	stroke.Transparency = 0.4
	stroke.Thickness = 1
	stroke.Parent = frame
end

-- One consolidated system-window panel (art brief §6): currency on top (most prominent),
-- categorized build catalog in the middle, collapsible zone legend at the bottom.
-- Top-right, clear of Roblox's own top-left menu/chat icons.
local function buildUI()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "BuildControllerUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "SystemPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -12, 0, 12)
	panel.Size = UDim2.new(0, 250, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Parent = screenGui
	styleAsSystemWindow(panel)

	local panelPadding = Instance.new("UIPadding")
	panelPadding.PaddingTop = UDim.new(0, 8)
	panelPadding.PaddingBottom = UDim.new(0, 8)
	panelPadding.PaddingLeft = UDim.new(0, 8)
	panelPadding.PaddingRight = UDim.new(0, 8)
	panelPadding.Parent = panel

	local panelLayout = Instance.new("UIListLayout")
	panelLayout.Padding = UDim.new(0, 6)
	panelLayout.SortOrder = Enum.SortOrder.LayoutOrder
	panelLayout.Parent = panel

	-- Currency: the most prominent element (top-right HUD convention).
	currencyLabel = Instance.new("TextLabel")
	currencyLabel.Name = "CurrencyLabel"
	currencyLabel.LayoutOrder = 1
	currencyLabel.Size = UDim2.new(1, 0, 0, 30)
	currencyLabel.BackgroundTransparency = 1
	currencyLabel.Font = Enum.Font.GothamBold
	currencyLabel.TextSize = 22
	currencyLabel.TextColor3 = GOLD
	currencyLabel.TextXAlignment = Enum.TextXAlignment.Right
	currencyLabel.Text = "Coins  --"
	currencyLabel.Parent = panel

	-- Category tabs.
	local tabRow = Instance.new("Frame")
	tabRow.Name = "Tabs"
	tabRow.LayoutOrder = 2
	tabRow.Size = UDim2.new(1, 0, 0, 24)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = panel

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Padding = UDim.new(0, 4)
	tabLayout.Parent = tabRow

	local entryList = Instance.new("Frame")
	entryList.Name = "Entries"
	entryList.LayoutOrder = 3
	entryList.Size = UDim2.new(1, 0, 0, 0)
	entryList.AutomaticSize = Enum.AutomaticSize.Y
	entryList.BackgroundTransparency = 1
	entryList.Parent = panel

	local entryLayout = Instance.new("UIListLayout")
	entryLayout.Padding = UDim.new(0, 4)
	entryLayout.SortOrder = Enum.SortOrder.LayoutOrder
	entryLayout.Parent = entryList

	local tabButtons = {} -- [category] = TextButton
	local entryButtonsByCategory = {} -- [category] = { TextButton }
	local activeCategory = CATEGORY_ORDER[1]

	local function setActiveCategory(category: string)
		activeCategory = category
		for cat, tab in tabButtons do
			tab.BackgroundColor3 = (cat == category) and TAB_ACTIVE_BG or TAB_INACTIVE_BG
			tab.TextColor3 = (cat == category) and TEXT_BRIGHT or TEXT_DIM
		end
		for cat, buttons in entryButtonsByCategory do
			for _, button in buttons do
				button.Visible = (cat == category)
			end
		end
	end

	for i, category in CATEGORY_ORDER do
		local tab = Instance.new("TextButton")
		tab.Name = "Tab_" .. category
		tab.LayoutOrder = i
		tab.Size = UDim2.new(0.25, -3, 1, 0)
		tab.Font = Enum.Font.GothamMedium
		tab.TextSize = 12
		tab.Text = CATEGORY_LABELS[category]
		tab.BackgroundColor3 = TAB_INACTIVE_BG
		tab.TextColor3 = TEXT_DIM
		tab.Parent = tabRow

		local tabCorner = Instance.new("UICorner")
		tabCorner.CornerRadius = UDim.new(0, 4)
		tabCorner.Parent = tab

		tabButtons[category] = tab
		entryButtonsByCategory[category] = {}

		tab.MouseButton1Click:Connect(function()
			setActiveCategory(category)
		end)
	end

	for i, item in catalogEntries() do
		local button = Instance.new("TextButton")
		button.Name = item.ItemId
		button.LayoutOrder = i
		button.Size = UDim2.new(1, 0, 0, 40)
		button.Text = ""
		button.BackgroundColor3 = ENTRY_BG
		button.BackgroundTransparency = 0.15
		button.Parent = entryList

		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 4)
		buttonCorner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = SELECTED_STROKE_COLOR
		stroke.Thickness = 0
		stroke.Parent = button

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -12, 0, 18)
		nameLabel.Position = UDim2.new(0, 6, 0, 3)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamMedium
		nameLabel.TextSize = 14
		nameLabel.TextColor3 = TEXT_BRIGHT
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = string.format("%s \u{2014} %d", item.Name, item.Cost)
		nameLabel.Parent = button

		local descLabel = Instance.new("TextLabel")
		descLabel.Size = UDim2.new(1, -12, 0, 14)
		descLabel.Position = UDim2.new(0, 6, 0, 21)
		descLabel.BackgroundTransparency = 1
		descLabel.Font = Enum.Font.Gotham
		descLabel.TextSize = 11
		descLabel.TextColor3 = DESC_COLOR
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.TextTruncate = Enum.TextTruncate.AtEnd
		descLabel.Text = item.Description
		descLabel.Parent = button

		buildButtons[item.ItemId] = { Button = button, Stroke = stroke, NameLabel = nameLabel, DescLabel = descLabel, Cost = item.Cost }
		if entryButtonsByCategory[item.Category] then
			table.insert(entryButtonsByCategory[item.Category], button)
		end

		button.MouseButton1Click:Connect(function()
			setSelected(item.ItemId)
		end)
	end

	-- Zone legend: collapsible reference info, tucked under the catalog so it doesn't
	-- compete with it.
	local legendToggle = Instance.new("TextButton")
	legendToggle.Name = "LegendToggle"
	legendToggle.LayoutOrder = 4
	legendToggle.Size = UDim2.new(1, 0, 0, 20)
	legendToggle.BackgroundTransparency = 1
	legendToggle.Font = Enum.Font.Gotham
	legendToggle.TextSize = 12
	legendToggle.TextColor3 = TEXT_DIM
	legendToggle.TextXAlignment = Enum.TextXAlignment.Left
	legendToggle.Text = "> Zone legend" -- ASCII arrows: Gotham lacks the triangle glyphs
	legendToggle.Parent = panel

	local legendList = Instance.new("Frame")
	legendList.Name = "LegendList"
	legendList.LayoutOrder = 5
	legendList.Size = UDim2.new(1, 0, 0, 0)
	legendList.AutomaticSize = Enum.AutomaticSize.Y
	legendList.BackgroundTransparency = 1
	legendList.Visible = false
	legendList.Parent = panel

	local legendLayout = Instance.new("UIListLayout")
	legendLayout.Padding = UDim.new(0, 2)
	legendLayout.SortOrder = Enum.SortOrder.LayoutOrder
	legendLayout.Parent = legendList

	for i, zoneName in ZONE_LEGEND_ORDER do
		local row = Instance.new("Frame")
		row.LayoutOrder = i
		row.Size = UDim2.new(1, 0, 0, 16)
		row.BackgroundTransparency = 1
		row.Parent = legendList

		local swatch = Instance.new("Frame")
		swatch.Size = UDim2.new(0, 12, 0, 12)
		swatch.Position = UDim2.new(0, 4, 0, 2)
		swatch.BackgroundColor3 = ZONE_ACCENTS[zoneName] or UNBUILDABLE_ACCENT
		swatch.Parent = row

		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0, 3)
		swatchCorner.Parent = swatch

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -26, 1, 0)
		label.Position = UDim2.new(0, 22, 0, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Gotham
		label.TextSize = 12
		label.TextColor3 = DESC_COLOR
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = zoneName
		label.Parent = row
	end

	legendToggle.MouseButton1Click:Connect(function()
		legendList.Visible = not legendList.Visible
		legendToggle.Text = (legendList.Visible and "v" or ">") .. " Zone legend"
	end)

	setActiveCategory(activeCategory)
end

function BuildController.Init()
	buildFloor()
	buildZoneBorders()
	buildProtectedZoneWalls()
	buildCampfire()
	buildUI()

	-- UIController.Init() already fetched the real starting balance (Bootstrap.client runs
	-- UIController first) -- reuse that instead of making a second identical server round trip.
	currentCurrency = UIController.GetCurrency()
	refreshCurrencyLabel()
	refreshButtonAppearance()

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		currentCurrency = newCurrency
		refreshCurrencyLabel()
		refreshButtonAppearance()
	end)
end

return BuildController
