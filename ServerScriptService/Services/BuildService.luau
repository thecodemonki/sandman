-- Grid + placement + build/upgrade/evolve only. No farming/monster/combat logic (out of scope
-- for this prompt). RequestUpgrade here only ever takes a placementId — there is no base-wide
-- Upgrades track wired up yet, so the "or upgradeId" case from the skeleton has nothing to
-- route to until UpgradeConfig/a base-wide track exists.
--
-- ponytail: PlayerBases/PlayerWallets below are an in-memory stand-in for BaseService/
-- DataService, neither of which exist yet. Swap getOrCreatePlayerState for a real load and
-- delete the two tables when persistence lands.

local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local PlotTemplate = require(ServerStorage.BasePlots.PlotTemplate)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)
local BaseTypes = require(ReplicatedStorage.Shared.Types.BaseTypes)

type Placement = BaseTypes.Placement
type BuildableDef = BuildableConfig.BuildableDef
type Wallet = { Currency: number, Materials: { [string]: number } }

local STARTER_CURRENCY = 500 -- PLACEHOLDER (brief §8)

local BuildService = {}

-- ponytail: stub storage, see note above.
local PlayerBases: { [Player]: { [string]: Placement } } = {}
local PlayerWallets: { [Player]: Wallet } = {}

local function getOrCreatePlayerState(player: Player): ({ [string]: Placement }, Wallet)
	if not PlayerBases[player] then
		PlayerBases[player] = {}
	end
	if not PlayerWallets[player] then
		PlayerWallets[player] = { Currency = STARTER_CURRENCY, Materials = {} }
	end
	return PlayerBases[player], PlayerWallets[player]
end

-- ===== Pure grid/validation helpers (no Roblox state — easy to call from RunSelfCheck) =====

local function cellKey(col: number, row: number): string
	return col .. "," .. row
end

function BuildService._GetFootprintCells(col: number, row: number, footprint: { Width: number, Height: number })
	local cells = {}
	for dx = 0, footprint.Width - 1 do
		for dy = 0, footprint.Height - 1 do
			table.insert(cells, { Col = col + dx, Row = row + dy })
		end
	end
	return cells
end

function BuildService._BuildOccupiedSet(placements: { [string]: Placement })
	local occupied = {}
	for placementId, placement in placements do
		local formId = placement.State and placement.State.CurrentFormId or placement.ItemId
		local entry = BuildableConfig[formId]
		if entry then
			local anchorCol = math.floor(placement.Position.X / PlotTemplate.CellSize)
			local anchorRow = math.floor(placement.Position.Z / PlotTemplate.CellSize)
			for _, cell in BuildService._GetFootprintCells(anchorCol, anchorRow, entry.Footprint) do
				occupied[cellKey(cell.Col, cell.Row)] = placementId
			end
		end
	end
	return occupied
end

function BuildService._ValidatePlacement(col: number, row: number, entry: BuildableDef, occupiedSet: { [string]: string })
	for _, cell in BuildService._GetFootprintCells(col, row, entry.Footprint) do
		if not PlotTemplate.IsInBounds(cell.Col, cell.Row) then
			return false, "OutOfBounds"
		end
		if occupiedSet[cellKey(cell.Col, cell.Row)] then
			return false, "CellOccupied"
		end
		local zone = PlotTemplate.GetZoneAt(cell.Col, cell.Row)
		if not zone or not table.find(entry.AllowedZones, zone) then
			return false, "WrongZone"
		end
	end
	return true
end

function BuildService._CanAfford(entry: BuildableDef, wallet: Wallet)
	if entry.CurrencyCost and wallet.Currency < entry.CurrencyCost then
		return false, "NotEnoughCurrency"
	end
	if entry.IsMaterialGated then
		local have = wallet.Materials[entry.GatingMaterialId] or 0
		if have <= 0 then
			return false, "MissingGatingMaterial"
		end
	end
	return true
end

-- Decides what a RequestUpgrade call should do for a placement currently at currentLevel.
function BuildService._DecideUpgrade(entry: BuildableDef, currentLevel: number, wallet: Wallet)
	if not entry.MaxLevel then
		return "NotUpgradable"
	end
	if currentLevel < entry.MaxLevel then
		return "LevelUp"
	end
	if entry.EvolvesInto then
		for _, evolution in entry.EvolvesInto do
			local have = wallet.Materials[evolution.GatingMaterialId] or 0
			if have >= evolution.GatingMaterialCount then
				return "Evolve", evolution
			end
		end
		return "MissingEvolutionMaterial"
	end
	return "MaxedOut"
end

-- ===== Remote handlers (trust boundary: validate every client-supplied value) =====

local function requestPlaceBuild(player: Player, itemId: string, gridPos: { Col: number, Row: number }, rotation: number?)
	if type(itemId) ~= "string" then
		return false, "InvalidItemId"
	end
	if type(gridPos) ~= "table" or type(gridPos.Col) ~= "number" or type(gridPos.Row) ~= "number" then
		return false, "InvalidGridPos"
	end
	if rotation ~= nil and type(rotation) ~= "number" then
		return false, "InvalidRotation"
	end

	local entry = BuildableConfig[itemId]
	if not entry then
		return false, "UnknownItem"
	end

	local placements, wallet = getOrCreatePlayerState(player)
	local occupied = BuildService._BuildOccupiedSet(placements)

	local placeOk, placeErr = BuildService._ValidatePlacement(gridPos.Col, gridPos.Row, entry, occupied)
	if not placeOk then
		return false, placeErr
	end

	local affordOk, affordErr = BuildService._CanAfford(entry, wallet)
	if not affordOk then
		return false, affordErr
	end

	wallet.Currency -= entry.CurrencyCost or 0

	local placementId = HttpService:GenerateGUID(false)
	local placement: Placement = {
		Id = placementId,
		ItemId = itemId,
		Position = {
			X = gridPos.Col * PlotTemplate.CellSize,
			Y = 0,
			Z = gridPos.Row * PlotTemplate.CellSize,
		},
		Rotation = rotation or 0,
		State = entry.MaxLevel and { Level = 1, CurrentFormId = itemId } or nil,
	}
	placements[placementId] = placement

	return true, placementId
end

local function requestRemoveBuild(player: Player, placementId: string)
	if type(placementId) ~= "string" then
		return false, "InvalidPlacementId"
	end

	local placements = getOrCreatePlayerState(player)
	if not placements[placementId] then
		return false, "NotFound"
	end
	placements[placementId] = nil
	return true
end

local function requestUpgrade(player: Player, placementId: string)
	if type(placementId) ~= "string" then
		return false, "InvalidPlacementId"
	end

	local placements, wallet = getOrCreatePlayerState(player)
	local placement = placements[placementId]
	if not placement then
		return false, "NotFound"
	end
	if not placement.State then
		return false, "NotUpgradable"
	end

	local entry = BuildableConfig[placement.State.CurrentFormId]
	if not entry then
		return false, "UnknownItem"
	end

	local action, extra = BuildService._DecideUpgrade(entry, placement.State.Level, wallet)

	if action == "LevelUp" then
		placement.State.Level += 1
		return true, "LeveledUp", placement.State.Level
	elseif action == "Evolve" then
		local evolution = extra
		local materialId = evolution.GatingMaterialId
		wallet.Materials[materialId] = (wallet.Materials[materialId] or 0) - evolution.GatingMaterialCount
		placement.State.CurrentFormId = evolution.ToItemId
		placement.State.Level = 1
		return true, "Evolved", evolution.ToItemId
	else
		return false, action -- "NotUpgradable" | "MaxedOut" | "MissingEvolutionMaterial"
	end
end

-- ===== Wiring (all Roblox-service side effects live here, called once by Bootstrap) =====

function BuildService.Init()
	local Net = require(ReplicatedStorage.Shared.Util.Net)

	Net.RequestPlaceBuild.OnServerInvoke = requestPlaceBuild
	Net.RequestRemoveBuild.OnServerInvoke = requestRemoveBuild
	Net.RequestUpgrade.OnServerInvoke = requestUpgrade

	Players.PlayerAdded:Connect(function(player)
		getOrCreatePlayerState(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		PlayerBases[player] = nil
		PlayerWallets[player] = nil
	end)
end

-- ===== Self-check: run manually via the Studio command bar —
-- require(path.to.BuildService).RunSelfCheck() — no test runner in this repo yet. =====

function BuildService.RunSelfCheck()
	local cells = BuildService._GetFootprintCells(2, 3, { Width = 2, Height = 2 })
	assert(#cells == 4, "2x2 footprint should expand to 4 cells")

	local fakePlacements = {
		p1 = {
			Id = "p1",
			ItemId = "SandTurret",
			Position = { X = 8 * PlotTemplate.CellSize, Y = 0, Z = 8 * PlotTemplate.CellSize },
			Rotation = 0,
			State = { Level = 1, CurrentFormId = "SandTurret" },
		},
	}
	local occupied = BuildService._BuildOccupiedSet(fakePlacements)

	local blockedOk = BuildService._ValidatePlacement(8, 8, BuildableConfig.SandTurret, occupied)
	assert(blockedOk == false, "placing on an occupied cell should fail")

	local freeOk = BuildService._ValidatePlacement(9, 9, BuildableConfig.SandTurret, occupied)
	assert(freeOk == true, "adjacent free Protected-zone cell should be placeable")

	local wrongZoneOk = BuildService._ValidatePlacement(0, 0, BuildableConfig.SandTurret, {})
	assert(wrongZoneOk == false, "turret should be rejected outside its allowed zone (Farm != Protected)")

	local wallet: Wallet = { Currency = 0, Materials = { CrystalShard = 5 } }
	local action1 = BuildService._DecideUpgrade(BuildableConfig.SandTurret, 1, wallet)
	assert(action1 == "LevelUp", "below MaxLevel should level up")

	local action2, evolution = BuildService._DecideUpgrade(BuildableConfig.SandTurret, 3, wallet)
	assert(action2 == "Evolve" and evolution.ToItemId == "SandTurret_Crystal", "at MaxLevel with materials should evolve")

	wallet.Materials.CrystalShard = 0
	local action3 = BuildService._DecideUpgrade(BuildableConfig.SandTurret, 3, wallet)
	assert(action3 == "MissingEvolutionMaterial", "at MaxLevel without materials should block, not silently maxed-out")

	print("BuildService.RunSelfCheck: all assertions passed")
	return true
end

return BuildService
