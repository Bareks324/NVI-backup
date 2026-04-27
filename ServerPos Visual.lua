local Players, RunService, Stats = game:GetService("Players"), game:GetService("RunService"), game:GetService("Stats")
local LocalPlayer, connections, serverpart, clientpart, cframehistory, isserverpartvisible, isclientpartvisible = Players.LocalPlayer, {}, nil, nil, {}, false, false
local PING_MULTIPLIER, DEALY = 2.05, 0.34

local function CleanUp()
    if serverpart and serverpart.Parent then
        serverpart:Destroy()
    end
    if clientpart and clientpart.Parent then
        clientpart:Destroy()
    end
    serverpart = nil
    clientpart = nil
    table.clear(cframehistory)
    isserverpartvisible = false
    isclientpartvisible = false
end

local function ClearConnections()
    for _, conn in pairs(connections) do
        if conn and conn.Connected then
            conn:Disconnect()
        end
    end
    table.clear(connections)
end

local function UpdateDelay()
    local dataping = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    DEALY = dataping * PING_MULTIPLIER * 0.001
    -- print("当前延迟：" .. dataping .. "ms, 碰撞箱延迟：" .. DEALY)
end

local function SetupCharacter(character)
    CleanUp()
    ClearConnections()
    
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 5)
    if not humanoidRootPart then
        warn("HumanoidRootPart 未找到，跳过设置")
        return
    end

    local sPart = Instance.new("Part")
    sPart.Name = "ServerPart"
    sPart.Size = Vector3.new(2.2, 2.2, 1.2)
    sPart.Color = Color3.fromRGB(100, 100, 255)
    sPart.Material = Enum.Material.SmoothPlastic
    sPart.Transparency = 1
    sPart.CanCollide = false
    sPart.Anchored = true
    sPart.Parent = character
    serverpart = sPart

    local cPart = Instance.new("Part")
    cPart.Name = "ClientPart"
    cPart.Size = Vector3.new(2.1, 2.1, 1.1)
    cPart.Color = Color3.fromRGB(100, 255, 100)
    cPart.Material = Enum.Material.SmoothPlastic
    cPart.Transparency = 1
    cPart.CanCollide = false
    cPart.Anchored = true
    cPart.Parent = character
    clientpart = cPart

    table.insert(connections, character.AncestryChanged:Connect(function()
        if not character:IsDescendantOf(game) then
            ancestryConn:Disconnect()
            CleanUp()
        end
    end))

    local lastpingupdate = 0
    table.insert(connections, RunService.Heartbeat:Connect(function()
        if not serverpart.Parent or not clientpart.Parent or not humanoidRootPart.Parent then
            ClearConnections()
            return
        end

        local currenttime = os.clock()
        if currenttime - lastpingupdate >= 1 then
            UpdateDelay()
            lastpingupdate = currenttime
        end
        local targettime = currenttime - DEALY
        table.insert(cframehistory, {
            time = currenttime,
            cframe = humanoidRootPart.CFrame
        })

        clientpart.CFrame = humanoidRootPart.CFrame
        if not isclientpartvisible then
            clientpart.Transparency = 0.7
            isclientpartvisible = true
        end

        local beforedata = nil
        while #cframehistory > 1 do
            local oldest = cframehistory[1]
            if oldest.time < currenttime - 1 then
                table.remove(cframehistory, 1)
            elseif oldest.time < targettime then
                beforedata = table.remove(cframehistory, 1)
            else
                break
            end
        end

        local targetcframe, afterdata = nil, cframehistory[1]

        if beforedata and afterdata then
            local totaltime = afterdata.time - beforedata.time
            if totaltime > 0 then
                local elapsedtime = targettime - beforedata.time
                local alpha = math.clamp(elapsedtime / totaltime, 0, 1)
                targetcframe = beforedata.cframe:Lerp(afterdata.cframe, alpha)
            end
        elseif beforedata then
            targetcframe = beforedata.cframe
        end

        if targetcframe then
            serverpart.CFrame = targetcframe
            if not isserverpartvisible then
                serverpart.Transparency = 0.7
                isserverpartvisible = true
            end
        else
            if isserverpartvisible then
                serverpart.Transparency = 1
                isserverpartvisible = false
            end
        end
    end))
end

LocalPlayer.CharacterAdded:Connect(SetupCharacter)
if LocalPlayer.Character then
    task.spawn(function()
        SetupCharacter(LocalPlayer.Character)
    end)
end
