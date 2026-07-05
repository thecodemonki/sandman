-- Minimal always-visible currency readout + a shared toast label other controllers use for
-- player-visible failure messages (e.g. "not enough currency"), instead of a server console
-- warn() the player never sees. No system-window UI shell yet -- that's a later pass once
-- there's something worth polishing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Util.Net)

local MESSAGE_DISPLAY_SECONDS = 3

local UIController = {}

local currentCurrency: number? = nil
local messageLabel: TextLabel? = nil
local messageToken = 0

-- Set from RequestCurrentCurrency at Init() and kept current via CurrencyChanged after
-- that, so this always reflects what the server believes, never a stale/guessed default.
function UIController.GetCurrency(): number?
	return currentCurrency
end

-- Shared toast, used by BuildController/FarmController for player-visible failure feedback.
function UIController.ShowMessage(text: string)
	if not messageLabel then
		return
	end
	messageToken += 1
	local myToken = messageToken

	messageLabel.Text = text
	messageLabel.Visible = true

	task.delay(MESSAGE_DISPLAY_SECONDS, function()
		if messageToken == myToken then
			messageLabel.Visible = false
		end
	end)
end

function UIController.Init()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UIControllerUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local currencyLabel = Instance.new("TextLabel")
	currencyLabel.Name = "CurrencyLabel"
	currencyLabel.Size = UDim2.new(0, 160, 0, 30)
	currencyLabel.Position = UDim2.new(0, 10, 0, 110)
	currencyLabel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
	currencyLabel.TextColor3 = Color3.fromRGB(255, 220, 120)
	currencyLabel.Text = "Currency: --"
	currencyLabel.Parent = screenGui

	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.Size = UDim2.new(0, 260, 0, 30)
	messageLabel.Position = UDim2.new(0, 10, 0, 145)
	messageLabel.BackgroundColor3 = Color3.fromRGB(90, 30, 30)
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.TextWrapped = true
	messageLabel.Visible = false
	messageLabel.Parent = screenGui

	-- Fetched once here rather than waiting for the first CurrencyChanged: PlayerAdded (and
	-- any fire-on-join) happens server-side before this LocalScript even starts running, so
	-- a fire-on-join risks the client missing it. Asking once our own listener is about to be
	-- ready avoids that race. pcall'd so a transient network hiccup here doesn't skip setting
	-- up the rest of Init() (the CurrencyChanged listener below still needs to run either way).
	local ok, startingCurrency = pcall(function()
		return Net.RequestCurrentCurrency:InvokeServer()
	end)
	if ok then
		currentCurrency = startingCurrency
		currencyLabel.Text = "Currency: " .. tostring(startingCurrency)
	else
		warn("UIController: RequestCurrentCurrency failed: " .. tostring(startingCurrency))
	end

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		currentCurrency = newCurrency
		currencyLabel.Text = "Currency: " .. tostring(newCurrency)
	end)
end

return UIController
