local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PADDING = 12
local TEXT_SIZE = 16

local report = ReplicatedStorage:WaitForChild("VaultRealTestReport")

local gui = Instance.new("ScreenGui")
gui.Name = "VaultRealTest"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 100

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.fromScale(1, 1)
scroll.BackgroundColor3 = Color3.fromRGB(16, 16, 20)
scroll.BackgroundTransparency = 0.1
scroll.BorderSizePixel = 0
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.fromScale(0, 0)
scroll.ScrollBarThickness = 8
scroll.Parent = gui

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, PADDING * 4)
padding.PaddingLeft = UDim.new(0, PADDING)
padding.PaddingRight = UDim.new(0, PADDING)
padding.PaddingBottom = UDim.new(0, PADDING)
padding.Parent = scroll

local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 0)
label.AutomaticSize = Enum.AutomaticSize.Y
label.BackgroundTransparency = 1
label.Font = Enum.Font.Code
label.TextSize = TEXT_SIZE
label.TextColor3 = Color3.fromRGB(235, 235, 235)
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextYAlignment = Enum.TextYAlignment.Top
label.TextWrapped = true
label.RichText = false
label.Parent = scroll

local function show()
	label.Text = report.Value
	scroll.CanvasPosition = Vector2.new(0, math.huge)
end

report:GetPropertyChangedSignal("Value"):Connect(show)
show()

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
