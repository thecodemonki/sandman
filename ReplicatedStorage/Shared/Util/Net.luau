-- Single registry for RemoteEvents/RemoteFunctions. Nothing creates remotes ad hoc elsewhere.
-- The rest of the eventual v1.1 list (RequestEnterGate, ...) gets added the same way as
-- those services land.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local REMOTE_FOLDER_NAME = "NetRemotes"

local function getRemoteFolder()
	local folder = ReplicatedStorage:FindFirstChild(REMOTE_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = REMOTE_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function getOrCreateRemoteFunction(name: string)
	local folder = getRemoteFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
	end
	return remote
end

local function getOrCreateRemoteEvent(name: string)
	local folder = getRemoteFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	return remote
end

local Net = {}

-- Client -> Server (RemoteFunctions: request/response)
Net.RequestPlaceBuild = getOrCreateRemoteFunction("RequestPlaceBuild")
Net.RequestRemoveBuild = getOrCreateRemoteFunction("RequestRemoveBuild")
Net.RequestUpgrade = getOrCreateRemoteFunction("RequestUpgrade")
Net.RequestPlantCrop = getOrCreateRemoteFunction("RequestPlantCrop")
Net.RequestHarvest = getOrCreateRemoteFunction("RequestHarvest")

-- Server -> Client (RemoteEvents: fire-and-forget)
Net.CropStageChanged = getOrCreateRemoteEvent("CropStageChanged")
Net.MonsterSpawned = getOrCreateRemoteEvent("MonsterSpawned")
Net.MonsterDied = getOrCreateRemoteEvent("MonsterDied") -- unused until DefenseService can kill something

return Net
