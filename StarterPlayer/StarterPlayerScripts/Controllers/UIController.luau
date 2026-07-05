-- Minimal always-visible currency readout. Bound to Net.CurrencyChanged, added this prompt
-- since BuildService/FarmingService weren't firing it yet (see repo history). No system-
-- window UI shell yet -- that's a later pass once there's something worth polishing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Util.Net)

local UIController = {}

function UIController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UIControllerUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0, 160, 0, 30)
	label.Position = UDim2.new(0, 10, 0, 110)
	label.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	label.TextColor3 = Color3.fromRGB(255, 220, 120)
	label.Text = "Currency: --"
	label.Parent = screenGui

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		label.Text = "Currency: " .. tostring(newCurrency)
	end)
end

return UIController
