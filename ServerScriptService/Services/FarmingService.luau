-- Plant/grow/harvest on an existing CropPlot placement. No trample/monster interaction yet
-- (MonsterService's job later) and no real EconomyService yet either.
--
-- ponytail: reuses BuildService's stub PlayerBases/PlayerWallets via GetOrCreatePlayerState
-- instead of keeping a second copy of placement/currency state. Same stub-now-swap-later
-- deal as BuildService: when DataService/EconomyService exist, this goes through them instead.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BuildService = require(ServerScriptService.Services.BuildService)
local BuildableConfig = require(ReplicatedStorage.Shared.Config.BuildableConfig)
local Enums = require(ReplicatedStorage.Shared.Enums)

local CROP_PLOT_ITEM_ID = "CropPlot"

local FarmingService = {}

-- Set by Init(); handlers below are only ever invoked after Init() has wired the remotes.
local Net = nil

-- Stage is always recomputed from the PlantedAt timestamp, never advanced by a loop —
-- correct even if the server restarted since the crop was planted.
local function getCropStage(placement, cropEntry): string
	if not placement.State or not placement.State.CropId then
		return "Empty"
	end
	local elapsed = os.time() - placement.State.PlantedAt
	if elapsed >= cropEntry.GrowSeconds then
		return "Grown"
	end
	return "Growing"
end

local function requestPlantCrop(player: Player, plotPlacementId: string, cropId: string)
	if type(plotPlacementId) ~= "string" or type(cropId) ~= "string" then
		return false, "InvalidArgs"
	end

	local cropEntry = BuildableConfig[cropId]
	if not cropEntry or cropEntry.ItemType ~= Enums.ItemType.Crop then
		return false, "UnknownCrop"
	end

	-- Ownership/access: reuses BuildService's per-player placement table rather than a
	-- second store — a player can only ever plant into their own placements this way.
	local placements, wallet = BuildService.GetOrCreatePlayerState(player)
	local placement = placements[plotPlacementId]
	if not placement or placement.ItemId ~= CROP_PLOT_ITEM_ID then
		return false, "NotACropPlot"
	end
	if placement.State and placement.State.CropId then
		return false, "PlotOccupied"
	end

	local affordOk, affordErr = BuildService._CanAfford(cropEntry, wallet)
	if not affordOk then
		return false, affordErr
	end
	wallet.Currency -= cropEntry.CurrencyCost or 0

	local plantedAt = os.time()
	placement.State = { CropId = cropId, PlantedAt = plantedAt }

	Net.CropStageChanged:FireClient(player, plotPlacementId, "Growing")

	-- One-shot ping for eventual UI once the crop is ready. Not the source of truth —
	-- RequestHarvest always recomputes from PlantedAt — so a server restart just means
	-- this ping doesn't fire, not that harvesting breaks. Guarded against firing stale if
	-- the plot got harvested and replanted before this runs.
	task.delay(cropEntry.GrowSeconds, function()
		if placement.State and placement.State.CropId == cropId and placement.State.PlantedAt == plantedAt then
			Net.CropStageChanged:FireClient(player, plotPlacementId, "Grown")
		end
	end)

	return true, plotPlacementId
end

local function requestHarvest(player: Player, plotPlacementId: string)
	if type(plotPlacementId) ~= "string" then
		return false, "InvalidArgs"
	end

	local placements, wallet = BuildService.GetOrCreatePlayerState(player)
	local placement = placements[plotPlacementId]
	if not placement or placement.ItemId ~= CROP_PLOT_ITEM_ID then
		return false, "NotACropPlot"
	end
	if not placement.State or not placement.State.CropId then
		return false, "NothingPlanted"
	end

	local cropEntry = BuildableConfig[placement.State.CropId]
	if not cropEntry then
		return false, "UnknownCrop"
	end

	if getCropStage(placement, cropEntry) ~= "Grown" then
		return false, "NotGrownYet"
	end

	-- ponytail: EconomyService doesn't exist yet — crediting the wallet directly is its
	-- future job (single currency-mutation authority per the brief). Swap this line for an
	-- EconomyService call once that service lands.
	wallet.Currency += cropEntry.SellPrice or 0

	placement.State = nil

	Net.CropStageChanged:FireClient(player, plotPlacementId, "Empty")

	return true, cropEntry.SellPrice
end

function FarmingService.Init()
	Net = require(ReplicatedStorage.Shared.Util.Net)

	Net.RequestPlantCrop.OnServerInvoke = requestPlantCrop
	Net.RequestHarvest.OnServerInvoke = requestHarvest
end

return FarmingService
