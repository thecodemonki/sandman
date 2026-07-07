-- Currency data owner + HUD readout + shared toast. Owns the top-left coin counter
-- (Roblox HUD convention: compact, always visible), fetches the authoritative starting
-- balance (and tracks CurrencyChanged) so any controller can ask via GetCurrency()
-- without racing the server, and owns the toast label other controllers use for
-- player-visible failure messages.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Util.Net)

local MESSAGE_DISPLAY_SECONDS = 3

local UIController = {}

local currentCurrency: number? = nil
local coinLabel: TextLabel? = nil
local messageLabel: TextLabel? = nil
local messageToken = 0

local function refreshCoinLabel()
	if coinLabel then
		coinLabel.Text = currentCurrency and tostring(currentCurrency) or "--"
	end
end

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

	-- Top-left coin counter: gold disc + bare bold count, no panel (Roblox convention).
	-- Disc is a UICorner'd Frame, not a glyph -- Gotham renders coin/emoji chars as tofu.
	-- Sits just below the topbar (default gui inset applies).
	local coinIcon = Instance.new("Frame")
	coinIcon.Name = "CoinIcon"
	coinIcon.Position = UDim2.new(0, 14, 0, 15)
	coinIcon.Size = UDim2.new(0, 16, 0, 16)
	coinIcon.BackgroundColor3 = Color3.fromRGB(255, 210, 120)
	coinIcon.BorderSizePixel = 0
	coinIcon.Parent = screenGui

	local coinCircle = Instance.new("UICorner")
	coinCircle.CornerRadius = UDim.new(1, 0)
	coinCircle.Parent = coinIcon

	local coinRim = Instance.new("UIStroke")
	coinRim.Color = Color3.fromRGB(120, 85, 30)
	coinRim.Thickness = 2
	coinRim.Parent = coinIcon

	coinLabel = Instance.new("TextLabel")
	coinLabel.Name = "CoinLabel"
	coinLabel.Position = UDim2.new(0, 38, 0, 10)
	coinLabel.Size = UDim2.new(0, 200, 0, 26)
	coinLabel.BackgroundTransparency = 1
	coinLabel.Font = Enum.Font.GothamBold
	coinLabel.TextSize = 22
	coinLabel.TextColor3 = Color3.fromRGB(255, 210, 120)
	coinLabel.TextStrokeColor3 = Color3.fromRGB(30, 20, 5)
	coinLabel.TextStrokeTransparency = 0.4
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.Text = "--"
	coinLabel.Parent = screenGui

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
	refreshCoinLabel()

	Net.CurrencyChanged.OnClientEvent:Connect(function(newCurrency)
		currentCurrency = newCurrency
		refreshCoinLabel()
	end)
end

return UIController
