-- Grid rendering + placement models + the Hoe tool. The floating catalog panel is gone;
-- placement entry points are physical tools instead. First one: a client-local Hoe in the
-- backpack at spawn -- equipping it highlights valid Farm cells, clicking one tills it,
-- which is just the same RequestPlaceBuild("CropPlot") flow the catalog used to trigger
-- (same server cost/validation; only the client trigger changed). Tilling renders furrow
-- ridges on the soil block so tilled ground reads instantly against raw Farm-zone sand.
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
	TradePost = { Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(150, 112, 72), Height = 3 },
	SpikeWall = { Material = Enum.Material.Slate, Color = Color3.fromRGB(140, 135, 125), Height = 2 },
	CraftingStation = { Material = Enum.Material.Wood, Color = Color3.fromRGB(122, 92, 62), Height = 2.5 },
	SandLantern = { Material = Enum.Material.Neon, Color = Color3.fromRGB(245, 205, 130), Height = 1.5 },
	ClothBanner = { Material = Enum.Material.Fabric, Color = Color3.fromRGB(172, 92, 80), Height = 4 },
}
local DEFAULT_PLACEMENT_STYLE = { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(150, 150, 150), Height = 3 }

local TILL_RANGE = 32 -- studs; matches default ClickDetector reach so tilling feels physical
local FURROW_COLOR = Color3.fromRGB(88, 70, 46) -- darker than the soil block: reads as dug rows

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

	local player = Players.LocalPlayer
	createHoe(player:WaitForChild("Backpack"))
	-- Backpack is rebuilt (empty) on every respawn; re-grant the Hoe each time.
	player.CharacterAdded:Connect(function()
		createHoe(player:WaitForChild("Backpack"))
	end)
end

return BuildController
