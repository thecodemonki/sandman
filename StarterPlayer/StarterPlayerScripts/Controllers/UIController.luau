-- Currency data owner + shared toast. The visible currency readout lives in
-- BuildController's consolidated system panel now; this module still fetches the
-- authoritative starting balance (and tracks CurrencyChanged) so any controller can ask
-- via GetCurrency() without racing the server, and owns the toast label other controllers
-- use for player-visible failure messages.

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

	-- Bottom-center toast, system-window styling (art brief §6: cool-toned overlay,
	-- distinct from the warm world palette).
	messageLabel = Instance.new("TextLabel")
	messageLabel.Name = "MessageLabel"
	messageLabel.AnchorPoint = Vector2.new(0.5, 1)
	messageLabel.Size = UDim2.new(0, 320, 0, 34)
	messageLabel.Position = UDim2.new(0.5, 0, 1, -60)
	messageLabel.BackgroundColor3 = Color3.fromRGB(48, 24, 36)
	messageLabel.BackgroundTransparency = 0.15
	messageLabel.Font = Enum.Font.GothamMedium
	messageLabel.TextSize = 14
	messageLabel.TextColor3 = Color3.new(1, 1, 1)
	messageLabel.TextWrapped = true
	messageLabel.Visible = false
	messageLabel.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = messageLabel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(215, 100, 100)
	stroke.Transparency = 0.4
	stroke.Parent = messageLabel

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
	else
		warn("UIController: RequestCurrentCurrency failed: " .. tostring(startingCurrency))
	end

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		currentCurrency = newCurrency
	end)
end

return UIController
