local flashbackSeconds = 100
local maxFrames = flashbackSeconds * 60
local flashbackFramesPerStep = 1

local framesBuffer = table.create(maxFrames)
local writeIndex = 0
local frameCount = 0

local LP = game:GetService("Players").LocalPlayer
local RS = game:GetService("RunService")
local TS = game:GetService("TweenService")

local cachedParts = {}
local cachedMotors = {}
local wasActive = false

local function gethrp(c)
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("RootPart") or c.PrimaryPart or c:FindFirstChild("Torso") or c:FindFirstChild("UpperTorso") or c:FindFirstChildWhichIsA("BasePart")
end

local flashback = {lastinput = false, canrevert = true, active = false}

local screenGui = Instance.new("ScreenGui")
screenGui.Parent = LP:FindFirstChildOfClass("PlayerGui")
screenGui.ResetOnSpawn = false

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 250, 0, 100)
frame.Position = UDim2.new(0.5, -125, 0.3, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
frame.BorderSizePixel = 0
frame.Parent = screenGui
frame.Active = true
frame.Draggable = true

local uiCorner = Instance.new("UICorner")
uiCorner.CornerRadius = UDim.new(0, 10)
uiCorner.Parent = frame

local uiStroke = Instance.new("UIStroke")
uiStroke.Thickness = 3
uiStroke.Color = Color3.fromRGB(0, 255, 255)
uiStroke.Parent = frame

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 0, 30)
titleLabel.Position = UDim2.new(0, 0, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "Flashback System"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextSize = 18
titleLabel.Parent = frame

local flashbackButton = Instance.new("TextButton")
flashbackButton.Size = UDim2.new(0, 100, 0, 40)
flashbackButton.Position = UDim2.new(0, 10, 0, 50)
flashbackButton.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
flashbackButton.Text = "Flashback"
flashbackButton.TextColor3 = Color3.fromRGB(255, 255, 255)
flashbackButton.Font = Enum.Font.GothamBold
flashbackButton.TextSize = 16
flashbackButton.AutoButtonColor = false
flashbackButton.Parent = frame

local fbCorner = Instance.new("UICorner")
fbCorner.CornerRadius = UDim.new(0, 6)
fbCorner.Parent = flashbackButton

local fbStroke = Instance.new("UIStroke")
fbStroke.Thickness = 2
fbStroke.Color = Color3.fromRGB(0, 255, 255)
fbStroke.Parent = flashbackButton

flashbackButton.MouseEnter:Connect(function()
    TS:Create(flashbackButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(0, 100, 100)}):Play()
end)

flashbackButton.MouseLeave:Connect(function()
    TS:Create(flashbackButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(35, 35, 35)}):Play()
end)

local resetButton = Instance.new("TextButton")
resetButton.Size = UDim2.new(0, 100, 0, 40)
resetButton.Position = UDim2.new(0, 140, 0, 50)
resetButton.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
resetButton.Text = "Reset"
resetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
resetButton.Font = Enum.Font.GothamBold
resetButton.TextSize = 16
resetButton.AutoButtonColor = false
resetButton.Parent = frame

local rsCorner = Instance.new("UICorner")
rsCorner.CornerRadius = UDim.new(0, 6)
rsCorner.Parent = resetButton

local rsStroke = Instance.new("UIStroke")
rsStroke.Thickness = 2
rsStroke.Color = Color3.fromRGB(0, 255, 255)
rsStroke.Parent = resetButton

resetButton.MouseEnter:Connect(function()
    TS:Create(resetButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(0, 100, 100)}):Play()
end)

resetButton.MouseLeave:Connect(function()
    TS:Create(resetButton, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(35, 35, 35)}):Play()
end)

flashbackButton.MouseButton1Click:Connect(function()
    flashback.active = not flashback.active
    flashbackButton.Text = flashback.active and "Stop Flashback" or "Flashback"
end)

resetButton.MouseButton1Click:Connect(function()
    writeIndex = 0
    frameCount = 0
    flashback.active = false
    flashbackButton.Text = "Flashback"
end)

local function animateOutline()
    local colors = {Color3.fromRGB(0, 255, 255), Color3.fromRGB(255, 0, 255), Color3.fromRGB(255, 255, 0)}
    local index = 1
    while true do
        index = (index % #colors) + 1
        local tween = TS:Create(uiStroke, TweenInfo.new(1), {Color = colors[index]})
        tween:Play()
        tween.Completed:Wait()
    end
end

function flashback:Advance(char, hrp, hum, allowinput)
    if allowinput and not self.canrevert then
        self.canrevert = true
    end
    if self.lastinput then
        hum.PlatformStand = false
        self.lastinput = false
    end
    
    writeIndex = writeIndex + 1
    if writeIndex > maxFrames then writeIndex = 1 end
    
    local partsData = table.create(#cachedParts)
    for i, part in ipairs(cachedParts) do
        partsData[i] = part.CFrame
    end
    
    framesBuffer[writeIndex] = {
        hrp.CFrame,
        hrp.AssemblyLinearVelocity or hrp.Velocity,
        hum:GetState(),
        hum.PlatformStand,
        char:FindFirstChildOfClass("Tool"),
        partsData
    }
    
    if frameCount < maxFrames then
        frameCount = frameCount + 1
    end
end

function flashback:Revert(char, hrp, hum)
    if frameCount == 0 or not self.canrevert then
        writeIndex = 0
        frameCount = 0
        flashback.active = false
        flashbackButton.Text = "Flashback"
        self.canrevert = false
        self:Advance(char, hrp, hum, false)
        return
    end

    local framesToSkip = math.max(1, math.floor(flashbackFramesPerStep))
    local totalConsumed = math.min(framesToSkip + 1, frameCount)
    
    local targetIndex = writeIndex - totalConsumed + 1
    if targetIndex < 1 then targetIndex = targetIndex + maxFrames end
    
    local lastframe = framesBuffer[targetIndex]
    
    writeIndex = writeIndex - totalConsumed
    if writeIndex < 1 then writeIndex = writeIndex + maxFrames end
    frameCount = frameCount - totalConsumed

    self.lastinput = true
    
    hrp.CFrame = lastframe[1]
    
    if hrp.AssemblyLinearVelocity then
        hrp.AssemblyLinearVelocity = Vector3.zero
    else
        hrp.Velocity = Vector3.zero
    end

    local state = lastframe[3]
    if typeof(state) == "EnumItem" and state ~= Enum.HumanoidStateType.Dead then
        hum:ChangeState(state)
    end
    hum.PlatformStand = lastframe[4]

    local historyTool = lastframe[5]
    local currenttool = char:FindFirstChildOfClass("Tool")
    
    if currenttool ~= historyTool then
        hum:UnequipTools()
        if historyTool and historyTool.Parent then
            task.defer(function()
                if hum and historyTool.Parent then
                    hum:EquipTool(historyTool)
                end
            end)
        end
    end

    local partsData = lastframe[6]
    if partsData then
        for i, part in ipairs(cachedParts) do
            if partsData[i] then
                part.CFrame = partsData[i]
            end
        end
    end
end

local function step()
    local char = LP.Character
    if not char then return end
    
    if #cachedParts == 0 then
        for _, desc in ipairs(char:GetDescendants()) do
            if desc:IsA("BasePart") then
                table.insert(cachedParts, desc)
            elseif desc:IsA("Motor6D") then
                table.insert(cachedMotors, desc)
            end
        end
    end
    
    if flashback.active ~= wasActive then
        for _, motor in ipairs(cachedMotors) do
            motor.Enabled = not flashback.active
        end
        wasActive = flashback.active
    end
    
    local hrp = gethrp(char)
    if not hrp then return end
    
    local hum = char:FindFirstChildWhichIsA("Humanoid")
    if not hum then return end
    
    if flashback.active then
        flashback:Revert(char, hrp, hum)
    else
        flashback:Advance(char, hrp, hum, true)
    end
end

task.spawn(animateOutline)

LP.CharacterAdded:Connect(function()
    writeIndex = 0
    frameCount = 0
    cachedParts = {}
    cachedMotors = {}
    wasActive = false
    flashback.active = false
    flashbackButton.Text = "Flashback"
end)

RS.Heartbeat:Connect(step)
