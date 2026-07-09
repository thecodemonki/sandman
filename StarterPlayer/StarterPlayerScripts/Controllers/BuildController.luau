-- Grid rendering + placement models + physical buy points. The floating catalog panel is
-- gone; placement entry points are things in the world:
--   * The Hoe (client-local tool in the backpack at spawn): equip to highlight valid Farm
--     cells, click one to till it -- the same RequestPlaceBuild("CropPlot") flow the catalog
--     used (same server cost/validation; only the client trigger changed). Tilling renders
--     furrow ridges so tilled ground reads instantly against raw Farm-zone sand.
--   * Three market stalls near the Trade Post: walk up, ProximityPrompt opens a buy list
--     scoped to that stall's categories; picking an item sets selectedItemId and the
--     pre-existing cell-click -> RequestPlaceBuild -> render path takes it from there.
--
-- The Hoe is created ON THE CLIENT (Backpack is client-visible, the character is
-- client-owned, and the server never needs to see the tool -- RequestPlaceBuild is the
-- authority). Tilling uses Tool.Activated + mouse.Target because Roblox suppresses
-- ClickDetector clicks while any Tool is equipped.
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

local Enums = require(ReplicatedStorage.Shared.Enums)
local Net = require(ReplicatedStorage.Shared.Util.Net)
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

-- Zone border strip accents.
local ZONE_ACCENTS = {
	Protected = Color3.fromRGB(255, 200, 100),
	Farm = Color3.fromRGB(140, 215, 110),
	Open = Color3.fromRGB(235, 220, 185),
}

-- Simple placeholder looks per buildable (single block, real material) until
-- ServerStorage/Assets/Buildables has actual models.
local PLACEMENT_STYLES = {
	CropPlot = { Material = Enum.Material.Ground, Color = Color3.fromRGB(120, 100, 70), Height = 1 },
	SandTurret = { Material = Enum.Material.Sandstone, Color = Color3.fromRGB(196, 168, 122), Height = 4 },
	SandTurret_Crystal = { Material = Enum.Material.Glass, Color = Color3.fromRGB(120, 200, 220), Height = 4 },
	StorageSilo = { Material = Enum.Material.Wood, Color = Color3.fromRGB(168, 130, 86), Height = 5 },
	SpikeWall = { Material = Enum.Material.Slate, Color = Color3.fromRGB(140, 135, 125), Height = 2 },
	CraftingStation = { Material = Enum.Material.Wood, Color = Color3.fromRGB(122, 92, 62), Height = 2.5 },
	SandLantern = { Material = Enum.Material.Neon, Color = Color3.fromRGB(245, 205, 130), Height = 1.5 },
	ClothBanner = { Material = Enum.Material.Fabric, Color = Color3.fromRGB(172, 92, 80), Height = 4 },
}
local DEFAULT_PLACEMENT_STYLE = { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(150, 150, 150), Height = 3 }

local TILL_RANGE = 32 -- studs; matches default ClickDetector reach so tilling feels physical
local FURROW_COLOR = Color3.fromRGB(88, 70, 46) -- darker than the soil block: reads as dug rows

-- Market cluster: fixed world structures west of the grid, near spawn/campfire.
local MARKET_X = -18 -- structures face east (+x), toward the grid
local TRADE_POST_Z = 22
local STALL_DEFS = {
	{ Name = "Farming Stall", Categories = { "Farming" }, Accent = Color3.fromRGB(140, 215, 110), Z = 34 },
	{ Name = "Defense Stall", Categories = { "Defense" }, Accent = Color3.fromRGB(215, 130, 110), Z = 44 },
	{ Name = "Woodworking & Decor", Categories = { "Utility", "Cosmetic" }, Accent = Color3.fromRGB(235, 220, 185), Z = 54 },
}
-- Not stall-purchasable: CropPlot is created by the Hoe.
local STALL_EXCLUDED = { CropPlot = true }

-- Buy-list panel styling, carried over from the removed catalog panel (art brief §6:
-- cool-toned system window, distinct from the warm world palette).
local PANEL_BG = Color3.fromRGB(16, 24, 44)
local PANEL_STROKE = Color3.fromRGB(95, 140, 215)
local ENTRY_BG = Color3.fromRGB(36, 52, 88)
local ENTRY_BG_DIM = Color3.fromRGB(24, 32, 52)
local TEXT_BRIGHT = Color3.fromRGB(235, 240, 250)
local TEXT_DIM = Color3.fromRGB(140, 150, 170)
local DESC_COLOR = Color3.fromRGB(170, 185, 210)
local SELECTED_STROKE_COLOR = Color3.fromRGB(250, 220, 90)

local BuildController = {}

local cellData = {} -- [key] = { Part, BaseColor, Col, Row, Zone }
local occupiedKeys = {} -- [key] = true, this-session-only (see ponytail note above)
local selectedItemId = nil -- "CropPlot" while the Hoe is equipped, else nil
local placing = false -- one InvokeServer in flight at a time (tool + ClickDetector can race)

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
		-- Furrow ridges across the soil block's top: the "this got tilled" visual.
		-- Decorative only: CanCollide AND CanQuery false (must not eat plant/harvest clicks).
		for i = -1, 1 do
			local furrow = Instance.new("Part")
			furrow.Name = "Furrow"
			furrow.Anchored = true
			furrow.CanCollide = false
			furrow.CanQuery = false
			furrow.CastShadow = false
			furrow.Material = Enum.Material.Ground
			furrow.Color = FURROW_COLOR
			furrow.Size = Vector3.new(0.8, 0.18, part.Size.Z - 0.6)
			furrow.CFrame = part.CFrame * CFrame.new(i * 1.5, part.Size.Y / 2, 0)
			furrow.Parent = part
		end
		FarmController.RegisterCropPlot(placementId, part)
	end
end

local function attemptPlace(key: string, itemId: string)
	if placing or occupiedKeys[key] then
		return -- in flight, or built on; FarmController (etc.) owns clicks on placed models
	end

	local cell = cellData[key]
	local entry = BuildableConfig[itemId]
	if not entry or not cell.Zone or not table.find(entry.AllowedZones, cell.Zone) then
		return
	end

	placing = true
	local ok, placementIdOrErr = Net.RequestPlaceBuild:InvokeServer(itemId, { Col = cell.Col, Row = cell.Row }, 0)
	placing = false

	if ok then
		spawnPlacementModel(placementIdOrErr, itemId, key)
		refreshHighlights()
	else
		UIController.ShowMessage("Can't build here: " .. tostring(placementIdOrErr))
	end
end

local function onCellClicked(key: string)
	if selectedItemId then
		attemptPlace(key, selectedItemId)
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

-- Shared helper for the fixed market structures below (same category of object as the
-- campfire/walls: exists from the start, never player-placed, decorative unless noted).
local function marketPart(name: string, material: Enum.Material, color: Color3, size: Vector3, cframe: CFrame): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false -- decorative default; interactive parts override after creation
	part.Material = material
	part.Color = color
	part.Size = size
	part.CFrame = cframe
	part.Parent = Workspace
	return part
end

-- Fixed Trade Post near spawn: pure world flavor for now. It sells nothing TO the player;
-- crop selling already happens on the plot itself (FarmingService pays SellPrice on the
-- harvest click), so there's deliberately no interaction here -- it's the camp's "sell
-- goods to passing caravans" set dressing, matching its old config description.
local function buildTradePost()
	local base = Vector3.new(PLOT_ORIGIN.X + MARKET_X, PLOT_ORIGIN.Y, PLOT_ORIGIN.Z + TRADE_POST_Z)
	local wood = Color3.fromRGB(150, 112, 72)
	local planks = Enum.Material.WoodPlanks

	marketPart("TradePostDeck", planks, wood, Vector3.new(10, 0.6, 8), CFrame.new(base + Vector3.new(0, 0.3, 0)))
	for _, corner in { Vector3.new(-4.4, 0, -3.4), Vector3.new(-4.4, 0, 3.4), Vector3.new(4.4, 0, -3.4), Vector3.new(4.4, 0, 3.4) } do
		marketPart("TradePostPost", Enum.Material.Wood, Color3.fromRGB(120, 88, 56), Vector3.new(0.6, 6, 0.6), CFrame.new(base + corner + Vector3.new(0, 3, 0)))
	end
	marketPart("TradePostRoof", Enum.Material.Fabric, Color3.fromRGB(172, 92, 80), Vector3.new(11, 0.4, 9), CFrame.new(base + Vector3.new(0, 6.2, 0)))
	-- Counter facing the grid, with a couple of crates as caravan goods.
	marketPart("TradePostCounter", planks, wood, Vector3.new(1, 2, 6), CFrame.new(base + Vector3.new(4, 1.6, 0)))
	marketPart("TradePostCrate", Enum.Material.Wood, Color3.fromRGB(168, 130, 86), Vector3.new(2, 2, 2), CFrame.new(base + Vector3.new(-2, 1.6, -1.5)))
	marketPart("TradePostCrate", Enum.Material.Wood, Color3.fromRGB(140, 105, 66), Vector3.new(1.5, 1.5, 1.5), CFrame.new(base + Vector3.new(-2.2, 1.35, 1.2)))
end

-- Directly buyable entries for one stall, old-catalog filter scoped to its categories:
-- ItemType.Build with a CurrencyCost, minus STALL_EXCLUDED. Sorted cheap-first.
local function stallEntries(categories: { string })
	local list = {}
	for itemId, entry in BuildableConfig do
		if entry.ItemType == Enums.ItemType.Build and entry.CurrencyCost and not STALL_EXCLUDED[itemId] and table.find(categories, entry.Category) then
			table.insert(list, {
				ItemId = itemId,
				Cost = entry.CurrencyCost,
				Name = (itemId:gsub("(%l)(%u)", "%1 %2")), -- "StorageSilo" -> "Storage Silo"
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

-- One shared buy-list panel, repopulated per stall on prompt trigger. Entry rows reuse the
-- removed catalog panel's display (name -- cost, description), just scoped to one stall.
local stallPanel: Frame? = nil
local stallPanelTitle: TextLabel? = nil
local stallPanelEntries: Frame? = nil
local openStallName: string? = nil

local function closeStallPanel()
	openStallName = nil
	if stallPanel then
		stallPanel.Visible = false
	end
end

local function buildStallPanel()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "StallUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local panel = Instance.new("Frame")
	panel.Name = "StallPanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 260, 0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = PANEL_BG
	panel.BackgroundTransparency = 0.2
	panel.Visible = false
	panel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = PANEL_STROKE
	stroke.Transparency = 0.4
	stroke.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	stallPanelTitle = Instance.new("TextLabel")
	stallPanelTitle.Name = "Title"
	stallPanelTitle.LayoutOrder = 1
	stallPanelTitle.Size = UDim2.new(1, 0, 0, 22)
	stallPanelTitle.BackgroundTransparency = 1
	stallPanelTitle.Font = Enum.Font.GothamBold
	stallPanelTitle.TextSize = 16
	stallPanelTitle.TextColor3 = TEXT_BRIGHT
	stallPanelTitle.TextXAlignment = Enum.TextXAlignment.Left
	stallPanelTitle.Parent = panel

	stallPanelEntries = Instance.new("Frame")
	stallPanelEntries.Name = "Entries"
	stallPanelEntries.LayoutOrder = 2
	stallPanelEntries.Size = UDim2.new(1, 0, 0, 0)
	stallPanelEntries.AutomaticSize = Enum.AutomaticSize.Y
	stallPanelEntries.BackgroundTransparency = 1
	stallPanelEntries.Parent = panel

	local entryLayout = Instance.new("UIListLayout")
	entryLayout.Padding = UDim.new(0, 4)
	entryLayout.SortOrder = Enum.SortOrder.LayoutOrder
	entryLayout.Parent = stallPanelEntries

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.LayoutOrder = 3
	closeButton.Size = UDim2.new(1, 0, 0, 22)
	closeButton.BackgroundTransparency = 1
	closeButton.Font = Enum.Font.Gotham
	closeButton.TextSize = 12
	closeButton.TextColor3 = TEXT_DIM
	closeButton.Text = "close"
	closeButton.Parent = panel
	closeButton.MouseButton1Click:Connect(closeStallPanel)

	stallPanel = panel
end

local function openStallPanel(stallDef)
	if openStallName == stallDef.Name then -- prompt re-trigger toggles
		closeStallPanel()
		return
	end
	openStallName = stallDef.Name
	stallPanelTitle.Text = stallDef.Name
	stallPanelEntries:ClearAllChildren()

	local entryLayout = Instance.new("UIListLayout")
	entryLayout.Padding = UDim.new(0, 4)
	entryLayout.SortOrder = Enum.SortOrder.LayoutOrder
	entryLayout.Parent = stallPanelEntries

	for i, item in stallEntries(stallDef.Categories) do
		local affordable = (UIController.GetCurrency() or 0) >= item.Cost

		local button = Instance.new("TextButton")
		button.Name = item.ItemId
		button.LayoutOrder = i
		button.Size = UDim2.new(1, 0, 0, 40)
		button.Text = ""
		button.BackgroundColor3 = affordable and ENTRY_BG or ENTRY_BG_DIM
		button.BackgroundTransparency = 0.15
		button.Parent = stallPanelEntries

		local buttonCorner = Instance.new("UICorner")
		buttonCorner.CornerRadius = UDim.new(0, 4)
		buttonCorner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = SELECTED_STROKE_COLOR
		stroke.Thickness = (selectedItemId == item.ItemId) and 2 or 0
		stroke.Parent = button

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -12, 0, 18)
		nameLabel.Position = UDim2.new(0, 6, 0, 3)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = Enum.Font.GothamMedium
		nameLabel.TextSize = 14
		nameLabel.TextColor3 = affordable and TEXT_BRIGHT or TEXT_DIM
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

		button.MouseButton1Click:Connect(function()
			-- Toggle semantics, same as the old catalog's setSelected. Selecting closes the
			-- panel so the player can go click a highlighted cell (the dormant path's revival).
			selectedItemId = (selectedItemId ~= item.ItemId) and item.ItemId or nil
			refreshHighlights()
			closeStallPanel()
		end)
	end

	stallPanel.Visible = true
end

-- Three stalls in a row beside the Trade Post. The counter is the one physical/interactive
-- part (holds the ProximityPrompt); posts and awning are decorative (CanQuery false).
local function buildMarketStalls()
	for _, stallDef in STALL_DEFS do
		local base = Vector3.new(PLOT_ORIGIN.X + MARKET_X, PLOT_ORIGIN.Y, PLOT_ORIGIN.Z + stallDef.Z)

		local counter = marketPart("StallCounter_" .. stallDef.Name, Enum.Material.WoodPlanks, Color3.fromRGB(150, 112, 72), Vector3.new(2.5, 2.4, 7), CFrame.new(base + Vector3.new(0, 1.2, 0)))
		counter.CanCollide = true
		counter.CanQuery = true -- the interactive bit: carries the prompt

		for _, dz in { -3, 3 } do
			marketPart("StallPost", Enum.Material.Wood, Color3.fromRGB(120, 88, 56), Vector3.new(0.5, 5, 0.5), CFrame.new(base + Vector3.new(0, 2.5, dz)))
		end
		local awning = marketPart("StallAwning", Enum.Material.Fabric, stallDef.Accent, Vector3.new(4.5, 0.3, 7.5), CFrame.new(base + Vector3.new(0.5, 5.2, 0)) * CFrame.Angles(0, 0, math.rad(-8)))
		awning.CastShadow = false

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Browse"
		prompt.ObjectText = stallDef.Name
		prompt.RequiresLineOfSight = false
		prompt.Parent = counter
		prompt.Triggered:Connect(function()
			openStallPanel(stallDef)
		end)
	end
end

-- Client-local Hoe (see header). Wood shaft Handle + welded metal blade; equip to see
-- valid Farm cells highlight, click a cell within reach to till it into a Crop Plot.
local function createHoe(backpack: Backpack)
	if backpack:FindFirstChild("Hoe") then
		return
	end

	local tool = Instance.new("Tool")
	tool.Name = "Hoe"
	tool.ToolTip = "Till Farm soil (50 coins)"
	tool.Grip = CFrame.new(0, -0.6, 0) -- shaft vertical in hand, gripped below middle

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.35, 4, 0.35)
	handle.Material = Enum.Material.Wood
	handle.Color = Color3.fromRGB(133, 100, 62)
	handle.Parent = tool

	local blade = Instance.new("Part")
	blade.Name = "Blade"
	blade.Size = Vector3.new(1.3, 0.2, 0.6)
	blade.Material = Enum.Material.Metal
	blade.Color = Color3.fromRGB(150, 145, 135)
	blade.CFrame = handle.CFrame * CFrame.new(0.55, 1.9, 0) * CFrame.Angles(0, 0, math.rad(-25))
	blade.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = blade
	weld.Parent = handle

	local mouse = Players.LocalPlayer:GetMouse()

	tool.Activated:Connect(function()
		local target = mouse.Target
		if not target then
			return
		end
		local col, row = target.Name:match("^Cell_(%d+)_(%d+)$")
		if not col then
			return
		end

		local character = Players.LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if not rootPart or (rootPart.Position - target.Position).Magnitude > TILL_RANGE then
			return
		end

		attemptPlace(cellKey(tonumber(col) :: number, tonumber(row) :: number), "CropPlot")
	end)

	-- selectedItemId doubles as the highlight driver: equipping shows every valid Farm cell.
	tool.Equipped:Connect(function()
		selectedItemId = "CropPlot"
		refreshHighlights()
	end)
	tool.Unequipped:Connect(function()
		selectedItemId = nil
		refreshHighlights()
	end)

	tool.Parent = backpack
end

function BuildController.Init()
	buildFloor()
	buildZoneBorders()
	buildProtectedZoneWalls()
	buildCampfire()
	buildTradePost()
	buildStallPanel()
	buildMarketStalls()

	local player = Players.LocalPlayer
	createHoe(player:WaitForChild("Backpack"))
	-- Backpack is rebuilt (empty) on every respawn; re-grant the Hoe each time.
	player.CharacterAdded:Connect(function()
		createHoe(player:WaitForChild("Backpack"))
	end)
end

return BuildController
