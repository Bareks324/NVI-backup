print("\n\n\n")
VERSION_NUMBER = "00085"
VERSION_PREFIX = "i"
COLOR_GUI_BORDER = Color3.fromRGB(200, 0, 0)
COLOR_GUI_BACKGROUND = Color3.fromRGB(30, 30, 30)
COLOR_BUTTON_BACKGROUND = Color3.fromRGB(50, 50, 50)
COLOR_BUTTON_BORDER = Color3.fromRGB(10, 10, 10)
COLOR_TEXT_NORMAL = Color3.fromRGB(200, 200, 200)
COLOR_TEXT_OVERLAY = Color3.fromRGB(100, 100, 100)
COLOR_TEXT_ENABLE = Color3.fromRGB(255, 255, 0)
COLOR_TEXT_FULLWHITE = Color3.fromRGB(255, 255, 255)
COLOR_TEXT_RED = Color3.fromRGB(255, 100, 100)
COLOR_TEXT_GREEN = Color3.fromRGB(100, 255, 100)
COLOR_TEXT_YELLOW = Color3.fromRGB(255, 255, 100)
COLOR_TEXT_BLUE = Color3.fromRGB(0, 162, 255)

local Config = {
    Console = {      
        debuglogs = true,      
        showoutput = true,
        showwarn = true,
        showerror = true,
        showinfo = true,
        autoscroll = true,
        maxmessages = 500,       
        filterkeywords = {}     
    },
    NavigationHistory = {
        maxhistory = 50,
        nowindex = 0,
        history = {}
    },
}

guistatus, dragstauts, connections = "active", true, {}

local function log(text, messagetype)
    if not Config.Console or not Config.Console.debuglogs or guistatus ~= "active" then return end
    if messagetype == "out" and not Config.Console.showoutput then return end
    if messagetype == "warn" and not Config.Console.showwarn then return end
    if messagetype == "error" and not Config.Console.showerror then return end
    
    if messagetype == "error" then 
        error("[NVI] " .. text)
    elseif messagetype == "warn" then
        warn("[NVI]", text)
    elseif messagetype == "out" then
        print("[NVI]", text)
    else 
        warn("[NVI]", "此消息属于未知频道!", text)
    end
end

local function Missing(expectedtype: string, value: any, fallback: any)
    if guistatus ~= "active" then return end
    return (type(value) == expectedtype and value) or 
           (type(fallback) == expectedtype and fallback) or nil
end

local function CreateAPI(name: string, fallback: any, ...)
    if guistatus ~= "active" then return end

    local args, api = {...}, nil

    for _, candidate in ipairs(args) do
        if type(candidate) == "function" then
            api = candidate
            break
        end
    end

    if not api and type(fallback) == "function" then
        api = fallback
    end
    
    if not api then
        log("API 未就绪：" .. name .. " (后台重试中)", "warn")
        task.spawn(function()
            for retries = 1, 5 do
                task.wait(math.min(retries, 3))
                for _, candidate in ipairs(args) do
                    if type(candidate) == "function" then
                        api = candidate
                        break
                    end
                end
                if api then
                    log("API 已就绪：" .. name, "out")
                    break
                end
            end
            if not api then
                log("API 永久失败：" .. name, "error")
            end
        end)
    end
    
    return function(...)
        if not api then
            log("调用未就绪 API: " .. name .. " (丢弃调用)", "warn")
            return nil, "NOT_READY"
        end
        local success, result = pcall(api, ...)
        if not success then
            local cleanerror = tostring(result):gsub("stack traceback:.+", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            log("API 崩溃@" .. name .. ": " .. cleanerror, "error")
            return nil, "API_ERROR"
        end
        return result
    end
end

local function CreateAsyncValue(valuename, loader, timeout, basedelay, watchcharacter)
    if guistatus ~= "active" then return end

    timeout = timeout or 60
    basedelay = basedelay or 0.3
    local value = nil
    local connection_async = nil
    local starttime = os.clock() 
    local expired = false
    
    task.spawn(function()
        while not expired do
            local success, newvalue = pcall(loader)
            if success and newvalue ~= nil then
                value = newvalue
                break
            end
            
            if os.clock() - starttime >= timeout then 
                expired = true
                break
            end
            
            task.wait(basedelay)
        end
        
        if value == nil then
            log("值加载超时：" .. tostring(valuename) .. " (超过 " .. timeout .. "秒)", "warn")
        end
    end)
    
    if watchcharacter and Players and Players.LocalPlayer then
        connection_async = Players.LocalPlayer.CharacterAdded:Connect(function()
            task.wait(0.1)
            local success, newvalue = pcall(loader)
            if success and newvalue ~= nil then
                value = newvalue
                log("角色数据 " .. tostring(valuename) .. " 已更新", "out")
            end
        end)
        table.insert(connections, connection_async)
    end

    local proxy = { __value = function() return value end }
    return setmetatable(proxy, {
        __call = function() return value end,
        __index = function(_, key)
            return value and value[key]
        end
    }), connection_async
end

local serviceproxies = {}

Services = setmetatable({}, {
    __index = function(self, name: string)
        if rawget(self, name) then
            return rawget(self, name)
        end
        
        local success, service = pcall(function()
            return Cloneref(game:GetService(name))
        end)
        
        if success and service then
            rawset(self, name, service)
            return service
        end

        if serviceproxies[name] then
            return serviceproxies[name]
        end
        
        log("服务加载失败：" .. name .. " (后台重试)", "warn")
        
        local proxy = setmetatable({}, {
            __index = function(_, key)
                log("访问未就绪服务：" .. name .. "." .. key .. " (返回空函数)", "warn")
                return function() end
            end,
            __call = function()
                log("尝试调用未就绪服务：" .. name .. " (已丢弃)", "warn")
                return nil, "SERVICE_NOT_READY"
            end
        })

        serviceproxies[name] = proxy
        rawset(self, name, proxy)
        
        task.spawn(function()
            for retries = 1, 10 do
                task.wait(math.min(retries * 0.5, 2))
                success, service = pcall(function()
                    return game:GetService(name)
                end)
                if success and service then
                    service = Cloneref(service)
                    rawset(self, name, service)
                    log("服务已就绪：" .. name, "out")
                    break
                end
            end
            if not success then
                log("服务永久失败：" .. name, "error")
            end
        end)
        return proxy
    end
})

Cloneref = CreateAPI("Cloneref", function(v) return v end, cloneref)
Queueteleport = CreateAPI("Queueteleport", function() end,
    queue_on_teleport,
    getrenv and getrenv().queue_on_teleport,
    syn and syn.queue_on_teleport
)
Httprequest = CreateAPI("Httprequest", function() return {Body="", StatusCode=404} end,
    request,
    getrenv and getrenv().http_request,
    syn and syn.request,
    http and http.request,
    fluxus and fluxus.request
)
Everyclipboard = CreateAPI("Everyclipboard", function() end,
    setclipboard,
    toclipboard,
    set_clipboard,
    Clipboard and Clipboard.set
)
Waxwritefile, Waxreadfile = writefile, readfile
Waxisfile, Waxmakefolder, Waxisfolder = isfile, makefolder, isfolder
Writefile = Waxwritefile and function(file: string, data: string, safe: boolean?)
    local dir = file:match("(.-)[^\\/]+$")
    if dir and dir ~= "" and dir ~= "." and (not Waxisfolder or not Waxisfolder(dir)) then
        if Waxmakefolder then
            local ok = pcall(Waxmakefolder, dir)
            if not ok and Waxisfolder and not Waxisfolder(dir) then
                log("无法创建目录：" .. dir, "error")
            end
        end
    end
    if safe then
        return pcall(Waxwritefile, file, data)
    end
    Waxwritefile(file, data)
    return true
end or function() return false, "NO_WRITE_API" end
Readfile = Waxreadfile and function(file: string, safe: boolean?)
    if safe then
        return pcall(Waxreadfile, file)
    end
    return Waxreadfile(file)
end or function() return "", "NO_READ_API" end
Isfile = Waxisfile or function(file: string)
    if Waxreadfile then
        local success, content = pcall(Waxreadfile, file)
        return success and content ~= nil and content ~= ""
    end
    return false
end
Makefolder = Waxmakefolder and function(path: string)
    return pcall(Waxmakefolder, path)
end or function() return true, "NO_MAKEFOLDER_API" end
Isfolder = Waxisfolder or function(path)
    if Waxlistfiles then
        return table.find(Waxlistfiles(path:match("(.*/)") or "./"), "__dir_marker") ~= nil
    end
    return false
end
Waxgetcustomasset = CreateAPI("Waxgetcustomasset", function() return "" end,
    getcustomasset,
    getsynasset
)
Getconnections = CreateAPI("Getconnections", function() end,
    getconnections,
    get_signal_cons
)
Workspace = Services.Workspace
CoreGui = Services.CoreGui
Players = Services.Players
UserInputService = Services.UserInputService
TweenService = Services.TweenService
RunService = Services.RunService
TeleportService = Services.TeleportService
Lighting = Services.Lighting
ReplicatedStorage = Services.ReplicatedStorage
Teams = Services.Teams
TextService = Services.TextService
TextChatService = Services.TextChatService
VoiceChatService = Services.VoiceChatService
LogService = Services.LogService
Stats = Services.Stats
PlaceId = game.PlaceId
JobId = game.JobId
Localcam = Workspace.Camera
Localmouse = UserInputService:GetMouseLocation()
Localplayer = CreateAsyncValue("LocalPlayer", function()
    return Players and Players.LocalPlayer
end, nil, 0.1, false) 
Localchar = CreateAsyncValue("Character", function()
    local player = Players.LocalPlayer
    if not player then return nil end
    return player.Character
end, 60, 0.1, true)
Localhum = CreateAsyncValue("Humanoid", function()
    local player = Players.LocalPlayer
    if not player then return nil end
    local character = player.Character
    if not character then return nil end
    return character:FindFirstChildOfClass("Humanoid")
end, 60, 0.1, true) 
Localroot = CreateAsyncValue("HumanoidRootPart", function()
    local player = Players.LocalPlayer
    if not player then return nil end
    local character = player.Character
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return nil end
    return humanoid.RootPart
end, 60, 0.1, true) 

local NavigationHistory = Config.NavigationHistory

function NavigationHistory:Push(entry)
    if guistatus ~= "active" then return end

    if self.nowindex < #self.history then
        for i = #self.history, self.nowindex + 1, -1 do
            table.remove(self.history, i)
        end
    end
    if self.history[self.nowindex] == entry then return end
    table.insert(self.history, entry)
    self.nowindex = #self.history
end

function NavigationHistory:Back()
    if guistatus ~= "active" then return end

    if self.nowindex <= 1 then
        log("没有更早的导航历史了", "warn")
        return nil
    end
    self.nowindex -= 1
    return self.history[self.nowindex]
end

function NavigationHistory:Enter()
    if guistatus ~= "active" then return end

    if self.nowindex >= #self.history then
        log("没有更晚的导航历史了", "warn")
        return nil
    end
    self.nowindex += 1
    return self.history[self.nowindex]
end

local function DestroyNvi()
    if guistatus ~= "active" then return end

    log("开始销毁", "out")
    if CoreGui:FindFirstChild("NVIScreenGui") then
        CoreGui:FindFirstChild("NVIScreenGui"):Destroy()
    end

    for _, connection in ipairs(connections) do
		if connection and connection.Connected then connection:Disconnect() end
	end

    log("已销毁 :)", "out")
    guistatus = "destroy"
end

local function GetTextWidth(text, fontsize, font)
    if not text or text == "" or guistatus ~= "active" then return end
    local fontsize, font = fontsize or 14 ,font or Enum.Font.Code
    local size = TextService:GetTextSize(text, fontsize, font, Vector2.new(10000, 1000))
    return size.X
end

local cachedassetpaths, failedassets, assetsdownloaded = {}, {}, false

local function TryGetAsset(assetpath: string): string?
    if not Waxgetcustomasset then return nil end
    
    local success, result = pcall(Waxgetcustomasset, assetpath)
    if success and result and result ~= "" then
        cachedassetpaths[assetpath] = result
        return result
    end
    return nil
end

local function GetCustomAsset(assetpath: string): string?
    if guistatus ~= "active" or not assetpath or assetpath == "" then return end

    if cachedassetpaths[assetpath] then
        return cachedassetpaths[assetpath]
    end

    if failedassets[assetpath] then
        return nil
    end

    local result = TryGetAsset(assetpath)
    if result then
        return result
    end

    if assetsdownloaded then
        failedassets[assetpath] = true 
        log("资源获取失败：" .. assetpath, "warn")
        return nil
    end

    local waitstart = os.clock()
    while not assetsdownloaded do
        if os.clock() - waitstart > 10 then
            failedassets[assetpath] = true 
            log("资源等待超时：" .. assetpath, "error")
            return nil
        end
        task.wait(0.1)
    end

    result = TryGetAsset(assetpath)
    if result then
        return result
    end

    failedassets[assetpath] = true
    log("资源获取失败：" .. assetpath, "warn")
    return nil
end

if CoreGui:FindFirstChild("NVIScreenGui") then
    if guistatus ~= "active" then return end

    existversion = CoreGui:FindFirstChild("NVIScreenGui"):FindFirstChild("Version").Value or 99999
    existprefix = CoreGui:FindFirstChild("NVIScreenGui"):FindFirstChild("Version"):GetAttribute("Prefix") or "Unknown"
    existnumber = CoreGui:FindFirstChild("NVIScreenGui"):FindFirstChild("Version"):GetAttribute("Number") or "Unknown"
    if tonumber(VERSION_NUMBER) >= tonumber(existversion) then
        log("检测到旧版或错误版本 NVI (version-" .. tostring(existprefix) .. tostring(existnumber) .. ")，正在清理...", "warn")
        CoreGui:FindFirstChild("NVIScreenGui"):FindFirstChild("Version"):SetAttribute("Status", "destroy")
        task.wait(0.5)
        if CoreGui:FindFirstChild("NVIScreenGui") then
            log("旧版本似乎未检测到信号，强制销毁... NVI (version-" .. tostring(existprefix) .. tostring(existnumber) .. ")", "out")
            CoreGui:FindFirstChild("NVIScreenGui"):FindFirstChild("Version"):SetAttribute("Status", "destroy")
            task.wait(0.5)
            CoreGui:FindFirstChild("NVIScreenGui"):Destroy()
        else 
            log("已销毁，继续注入当前版本... NVI (version-" .. VERSION_PREFIX .. VERSION_NUMBER .. ")", "out")
        end
    else
        log("已存在相同或更新版本 (version-" .. tostring(existprefix) .. tostring(existnumber) .. ")，放弃注入当前版本 (version-" .. VERSION_PREFIX .. VERSION_NUMBER .. ")", "warn")
        return
    end
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "NVIScreenGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Global
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = CoreGui

local Version = Instance.new("NumberValue")
Version.Name = "Version"
Version.Value = VERSION_NUMBER
Version.Parent = ScreenGui
Version:SetAttribute("Prefix", VERSION_PREFIX)
Version:SetAttribute("Number", VERSION_NUMBER)
Version:SetAttribute("Status", guistatus)

local MainFrame = Instance.new("Frame")
MainFrame.Name = "GuiMainFrame"
MainFrame.BackgroundColor3 = COLOR_GUI_BACKGROUND
MainFrame.Size = UDim2.new(0, 900, 0, 600)
MainFrame.Position = UDim2.new(0.5, -450, 0.5, -300)
MainFrame.Visible = true
MainFrame.BackgroundTransparency = 0.15
MainFrame.ZIndex = 10
MainFrame.Parent = ScreenGui

local Corner_MainFrame = Instance.new("UICorner")
Corner_MainFrame.CornerRadius = UDim.new(0, 7)
Corner_MainFrame.Parent = MainFrame

local Stroke_MainFrame = Instance.new("UIStroke")
Stroke_MainFrame.Color = COLOR_GUI_BORDER
Stroke_MainFrame.Thickness = 3
Stroke_MainFrame.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Stroke_MainFrame.Parent = MainFrame

local CrossLine_1 = Instance.new("Frame")
CrossLine_1.Name = "CrossLine_1"
CrossLine_1.BackgroundColor3 = COLOR_GUI_BORDER
CrossLine_1.BorderSizePixel = 0
CrossLine_1.Size = UDim2.new(1, 0, 0, 3)
CrossLine_1.Position = UDim2.new(0, 0, 0, 29)
CrossLine_1.ZIndex = 11
CrossLine_1.Parent = MainFrame

local CrossLine_2 = Instance.new("Frame")
CrossLine_2.Name = "CrossLine_2"
CrossLine_2.BackgroundColor3 = COLOR_GUI_BORDER
CrossLine_2.BorderSizePixel = 0
CrossLine_2.Size = UDim2.new(0, 3, 1, -31)
CrossLine_2.Position = UDim2.new(0.2, 0, 0, 31)
CrossLine_2.ZIndex = 11
CrossLine_2.Parent = MainFrame

local CrossLine_3 = Instance.new("Frame")
CrossLine_3.Name = "CrossLine_3"
CrossLine_3.BackgroundColor3 = COLOR_GUI_BORDER
CrossLine_3.BorderSizePixel = 0
CrossLine_3.Size = UDim2.new(0.8, 0, 0, 3)
CrossLine_3.Position = UDim2.new(0.2, 0, 0, 55)
CrossLine_3.ZIndex = 11
CrossLine_3.Parent = MainFrame

local CrossLine_4 = Instance.new("Frame")
CrossLine_4.Name = "CrossLine_4"
CrossLine_4.BackgroundColor3 = COLOR_GUI_BORDER
CrossLine_4.BorderSizePixel = 0
CrossLine_4.Size = UDim2.new(0, 3, 0, 26)
CrossLine_4.Position = UDim2.new(0.7, 0, 0, 31)
CrossLine_4.ZIndex = 11
CrossLine_4.Parent = MainFrame

local CrossLine_5 = Instance.new("Frame")
CrossLine_5.Name = "CrossLine_5"
CrossLine_5.BackgroundColor3 = COLOR_GUI_BORDER
CrossLine_5.BorderSizePixel = 0
CrossLine_5.Size = UDim2.new(0.2, 0, 0, 3)
CrossLine_5.Position = UDim2.new(0, 0, 0, 55)
CrossLine_5.ZIndex = 11
CrossLine_5.Parent = MainFrame

local Area_MouseOverlay = Instance.new("Frame")
Area_MouseOverlay.Name = "Area_MouseOverlay"
Area_MouseOverlay.Size = UDim2.new(0, 100, 0, 30)
Area_MouseOverlay.Position = UDim2.new(0, 0, 0, 0)
Area_MouseOverlay.BackgroundColor3 = COLOR_GUI_BACKGROUND
Area_MouseOverlay.Visible = false
Area_MouseOverlay.Selectable = false
Area_MouseOverlay.ZIndex = 12
Area_MouseOverlay.Parent = MainFrame

local Area_Sidebar = Instance.new("Frame")
Area_Sidebar.Name = "Area_Sidebar"
Area_Sidebar.BackgroundTransparency = 1
Area_Sidebar.BorderSizePixel = 0
Area_Sidebar.Size = UDim2.new(0.2, 0, 0, 26)
Area_Sidebar.Position = UDim2.new(0, 0, 0, 30)
Area_Sidebar.ZIndex = 1
Area_Sidebar.Parent = MainFrame

local Button_Back = Instance.new("TextButton")
Button_Back.Name = "Button_Back"
Button_Back.Text = "<-"
Button_Back.Font = Enum.Font.Code
Button_Back.TextColor3 = COLOR_TEXT_NORMAL
Button_Back.TextSize = 14
Button_Back.BackgroundTransparency = 1
Button_Back.BorderSizePixel = 0
Button_Back.Size = UDim2.new(0, 90, 0.99, 0)
Button_Back.Position = UDim2.new(0, 0, 0, 1)
Button_Back.ZIndex = 13
Button_Back.Parent = Area_Sidebar

local Stroke_Button_Back = Instance.new("UIStroke")
Stroke_Button_Back.Color = COLOR_GUI_BORDER
Stroke_Button_Back.Thickness = 2
Stroke_Button_Back.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Stroke_Button_Back.Parent = Button_Back

local Button_Enter = Instance.new("TextButton")
Button_Enter.Name = "Button_Enter"
Button_Enter.Text = "->"
Button_Enter.Font = Enum.Font.Code
Button_Enter.TextColor3 = COLOR_TEXT_NORMAL
Button_Enter.TextSize = 14
Button_Enter.BackgroundTransparency = 1
Button_Enter.BorderSizePixel = 0
Button_Enter.Size = UDim2.new(0, 90, 0.99, 0)
Button_Enter.Position = UDim2.new(0, 90, 0, 1)
Button_Enter.ZIndex = 13
Button_Enter.Parent = Area_Sidebar

local Stroke_Button_Enter = Instance.new("UIStroke")
Stroke_Button_Enter.Color = COLOR_GUI_BORDER
Stroke_Button_Enter.Thickness = 2
Stroke_Button_Enter.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Stroke_Button_Enter.Parent = Button_Enter

local Area_Module = Instance.new("Frame")
Area_Module.Name = "Area_Module"
Area_Module.BackgroundTransparency = 1
Area_Module.BorderSizePixel = 0
Area_Module.Size = UDim2.new(0.2, 0, 1, -56)
Area_Module.Position = UDim2.new(0, 0, 0, 56)
Area_Module.ZIndex = 1
Area_Module.Parent = MainFrame

local Area_Config = Instance.new("Frame")
Area_Config.Name = "Area_Config"
Area_Config.BackgroundTransparency = 1
Area_Config.BorderSizePixel = 0
Area_Config.Size = UDim2.new(0.8, -3, 1, -57)
Area_Config.Position = UDim2.new(0.2, 3, 0, 57)
Area_Config.ZIndex = 1
Area_Config.Parent = MainFrame

local Area_Info = Instance.new("Frame")
Area_Info.Name = "Area_Info"
Area_Info.BackgroundTransparency = 1
Area_Info.BorderSizePixel = 0
Area_Info.Size = UDim2.new(1, 0, 1, 0)
Area_Info.Position = UDim2.new(0, 0, 0, 0)
Area_Info.Visible = false
Area_Info.ZIndex = 1
Area_Info.Parent = Area_Config

local Area_Console = Instance.new("Frame")
Area_Console.Name = "Area_Console"
Area_Console.BackgroundTransparency = 1
Area_Console.BorderSizePixel = 0
Area_Console.Size = UDim2.new(1, 0, 1, 0)
Area_Console.Position = UDim2.new(0, 0, 0, 0)
Area_Console.Visible = false
Area_Console.ZIndex = 1
Area_Console.Parent = Area_Config

local Area_ConsoleInput = Instance.new("Frame")
Area_ConsoleInput.Name = "Area_ConsoleInput"
Area_ConsoleInput.Size = UDim2.new(0.99, 0, 0, 25)
Area_ConsoleInput.Position = UDim2.new(0.005, 0, 0.95, 0)
Area_ConsoleInput.BackgroundColor3 = COLOR_GUI_BACKGROUND
Area_ConsoleInput.BackgroundTransparency = 0.8
Area_ConsoleInput.BorderColor3 = COLOR_BUTTON_BORDER
Area_ConsoleInput.ZIndex = 12
Area_ConsoleInput.Parent = Area_Console

table.insert(connections, Area_ConsoleInput.MouseEnter:Connect(function()
    if guistatus ~= "active" then return end
    dragstauts = false
end))

table.insert(connections, Area_ConsoleInput.MouseLeave:Connect(function()
    if guistatus ~= "active" then return end
    dragstauts = true
end))

local TextBox_ConsoleInput = Instance.new("TextBox")
TextBox_ConsoleInput.Name = "TextBox_ConsoleInput"
TextBox_ConsoleInput.Size = UDim2.new(0.95, 0, 0, 25)
TextBox_ConsoleInput.Position = UDim2.new(0.025, 0, 0, 0)
TextBox_ConsoleInput.BackgroundTransparency = 1
TextBox_ConsoleInput.BorderSizePixel = 0
TextBox_ConsoleInput.Font = Enum.Font.Code
TextBox_ConsoleInput.PlaceholderColor3 = COLOR_TEXT_NORMAL
TextBox_ConsoleInput.PlaceholderText = "> 在这里输入命令..."
TextBox_ConsoleInput.TextColor3 = COLOR_TEXT_NORMAL
TextBox_ConsoleInput.Text = ""
TextBox_ConsoleInput.TextSize = 12
TextBox_ConsoleInput.TextXAlignment = Enum.TextXAlignment.Left
TextBox_ConsoleInput.TextWrapped = false
TextBox_ConsoleInput.ClearTextOnFocus = false
TextBox_ConsoleInput.ClipsDescendants = true
TextBox_ConsoleInput.MaxVisibleGraphemes = 200
TextBox_ConsoleInput.ZIndex = 13
TextBox_ConsoleInput.Parent = Area_ConsoleInput

local Area_ConsoleInputHint = Instance.new("Frame")
Area_ConsoleInputHint.Name = "Area_ConsoleInputHint"
Area_ConsoleInputHint.Size = UDim2.new(0.99, 0, 0, 25)
Area_ConsoleInputHint.Position = UDim2.new(0.005, 0, 0, -30)
Area_ConsoleInputHint.BackgroundColor3 = COLOR_GUI_BACKGROUND
Area_ConsoleInputHint.BackgroundTransparency = 0.3
Area_ConsoleInputHint.BorderSizePixel = 0
Area_ConsoleInputHint.Visible = false
Area_ConsoleInputHint.ZIndex = 20
Area_ConsoleInputHint.Parent = Area_ConsoleInput

local Corner_ConsoleInputHint = Instance.new("UICorner")
Corner_ConsoleInputHint.CornerRadius = UDim.new(0, 3)
Corner_ConsoleInputHint.Parent = Area_ConsoleInputHint

local Stroke_ConsoleInputHint = Instance.new("UIStroke")
Stroke_ConsoleInputHint.Color = COLOR_GUI_BORDER
Stroke_ConsoleInputHint.Thickness = 2
Stroke_ConsoleInputHint.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Stroke_ConsoleInputHint.Parent = Area_ConsoleInputHint

Area_ConsoleOutput = Instance.new("Frame")
Area_ConsoleOutput.Name = "Area_ConsoleOutput"
Area_ConsoleOutput.BackgroundColor3 = COLOR_GUI_BACKGROUND
Area_ConsoleOutput.BackgroundTransparency = 0.8
Area_ConsoleOutput.BorderColor3 = COLOR_BUTTON_BORDER
Area_ConsoleOutput.Size = UDim2.new(0.99, 0, 0, 480)
Area_ConsoleOutput.Position = UDim2.new(0.005, 0, 0, 35)
Area_ConsoleOutput.ZIndex = 1
Area_ConsoleOutput.Parent = Area_Console

Scroll_ConsoleOutput = Instance.new("ScrollingFrame")
Scroll_ConsoleOutput.Name = "Scroll_ConsoleOutput"
Scroll_ConsoleOutput.Size = UDim2.new(1, 0, 0, 470)
Scroll_ConsoleOutput.Position = UDim2.new(0, 0, 0, 10)
Scroll_ConsoleOutput.BackgroundTransparency = 1
Scroll_ConsoleOutput.BorderSizePixel = 0
Scroll_ConsoleOutput.ScrollBarThickness = 9
Scroll_ConsoleOutput.ScrollBarImageTransparency = 0.5
Scroll_ConsoleOutput.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll_ConsoleOutput.CanvasSize = UDim2.new(0, 0, 0, 0)
Scroll_ConsoleOutput.ZIndex = 12
Scroll_ConsoleOutput.Parent = Area_ConsoleOutput

Area_ConsoleSettings = Instance.new("Frame")
Area_ConsoleSettings.Name = "Area_ConsoleSettings"
Area_ConsoleSettings.BackgroundColor3 = COLOR_GUI_BACKGROUND
Area_ConsoleSettings.BackgroundTransparency = 0.8
Area_ConsoleSettings.BorderColor3 = COLOR_BUTTON_BORDER
Area_ConsoleSettings.Size = UDim2.new(0.99, 0, 0, 30)
Area_ConsoleSettings.Position = UDim2.new(0.005, 0, 0, 5)
Area_ConsoleSettings.ZIndex = 1
Area_ConsoleSettings.Parent = Area_Console

local UIList_ConsoleSetting = Instance.new("UIListLayout")
UIList_ConsoleSetting.Name = "UIList_ConsoleSetting"
UIList_ConsoleSetting.SortOrder = Enum.SortOrder.LayoutOrder
UIList_ConsoleSetting.FillDirection = Enum.FillDirection.Horizontal
UIList_ConsoleSetting.HorizontalAlignment = Enum.HorizontalAlignment.Left
UIList_ConsoleSetting.VerticalAlignment = Enum.VerticalAlignment.Center
UIList_ConsoleSetting.Padding = UDim.new(0, 30)
UIList_ConsoleSetting.Parent = Area_ConsoleSettings

local PlaceHolder_ConsoleSetting = Instance.new("TextLabel")
PlaceHolder_ConsoleSetting.Name = "PlaceHolder_ConsoleSetting"
PlaceHolder_ConsoleSetting.Font = Enum.Font.Code
PlaceHolder_ConsoleSetting.TextColor3 = COLOR_TEXT_NORMAL
PlaceHolder_ConsoleSetting.TextSize = 14
PlaceHolder_ConsoleSetting.Text = ""
PlaceHolder_ConsoleSetting.TextTransparency = 1
PlaceHolder_ConsoleSetting.BackgroundTransparency = 1
PlaceHolder_ConsoleSetting.Size = UDim2.new(0, 0, 1, 0)
PlaceHolder_ConsoleSetting.LayoutOrder = 1
PlaceHolder_ConsoleSetting.ZIndex = 13
PlaceHolder_ConsoleSetting.Parent = Area_ConsoleSettings

local UIListLayout_Console = Instance.new("UIListLayout")
UIListLayout_Console.Name = "UIListLayout_Console"
UIListLayout_Console.Padding = UDim.new(0, 2)
UIListLayout_Console.HorizontalAlignment = Enum.HorizontalAlignment.Left
UIListLayout_Console.VerticalAlignment = Enum.VerticalAlignment.Top
UIListLayout_Console.Parent = Scroll_ConsoleOutput

table.insert(connections, Scroll_ConsoleOutput.MouseEnter:Connect(function()
    if guistatus ~= "active" then return end
    dragstauts = false
end))

table.insert(connections, Scroll_ConsoleOutput.MouseLeave:Connect(function()
    if guistatus ~= "active" then return end
    dragstauts = true
end))

local Area_Settings = Instance.new("Frame")
Area_Settings.Name = "Area_Settings"
Area_Settings.BackgroundTransparency = 1
Area_Settings.BorderSizePixel = 0
Area_Settings.Size = UDim2.new(1, 0, 1, 0)
Area_Settings.Position = UDim2.new(0, 0, 0, 0)
Area_Settings.Visible = false
Area_Settings.ZIndex = 1
Area_Settings.Parent = Area_Config

Scroll_Settings = Instance.new("ScrollingFrame")
Scroll_Settings.Name = "Scroll_Settings"
Scroll_Settings.Size = UDim2.new(1, 0, 1, 0)
Scroll_Settings.Position = UDim2.new(0, 0, 0, 0)
Scroll_Settings.BackgroundTransparency = 1
Scroll_Settings.BorderSizePixel = 0
Scroll_Settings.ScrollBarThickness = 9
Scroll_Settings.ScrollBarImageTransparency = 0.5
Scroll_Settings.AutomaticCanvasSize = Enum.AutomaticSize.Y
Scroll_Settings.CanvasSize = UDim2.new(0, 0, 0, 0)
Scroll_Settings.ZIndex = 12
Scroll_Settings.Parent = Area_Settings

local Area_Title = Instance.new("Frame")
Area_Title.Name = "Area_Title"
Area_Title.BackgroundTransparency = 1
Area_Title.BorderSizePixel = 0
Area_Title.Size = UDim2.new(1, 0, 0, 29)
Area_Title.Position = UDim2.new(0, 0, 0, 0)
Area_Title.Visible = true
Area_Title.ZIndex = 1
Area_Title.Parent = MainFrame

local Text_Info = Instance.new("TextLabel")
Text_Info.Name = "Info_Display"
Text_Info.Text = "FPS: -- | Ping: --ms | CPU: --% | Memory: --MB | Position: (X:? Y:? Z:?)"
Text_Info.RichText = true
Text_Info.TextColor3 = COLOR_TEXT_NORMAL
Text_Info.TextSize = 14
Text_Info.Font = Enum.Font.Code
Text_Info.BackgroundTransparency = 1
Text_Info.Size = UDim2.new(1, 0, 1, 0)
Text_Info.Position = UDim2.new(0, 0, 0, 0)
Text_Info.TextXAlignment = Enum.TextXAlignment.Center
Text_Info.TextYAlignment = Enum.TextYAlignment.Center
Text_Info.ZIndex = 13
Text_Info.Parent = Area_Title

local Area_ModuleList = Instance.new("Frame")
Area_ModuleList.Name = "Area_ModuleList"
Area_ModuleList.BackgroundTransparency = 1
Area_ModuleList.BorderSizePixel = 0
Area_ModuleList.Size = UDim2.new(0.5, 0, 0, 26)
Area_ModuleList.Position = UDim2.new(0.2, 0, 0, 31)
Area_ModuleList.ZIndex = 1
Area_ModuleList.Parent = MainFrame

local UIList_ModuleList = Instance.new("UIListLayout")
UIList_ModuleList.Name = "UIList_ModuleList"
UIList_ModuleList.SortOrder = Enum.SortOrder.LayoutOrder
UIList_ModuleList.FillDirection = Enum.FillDirection.Horizontal
UIList_ModuleList.HorizontalAlignment = Enum.HorizontalAlignment.Left
UIList_ModuleList.VerticalAlignment = Enum.VerticalAlignment.Center
UIList_ModuleList.Padding = UDim.new(0, 30)
UIList_ModuleList.Parent = Area_ModuleList

local PlaceHolder_ModuleList = Instance.new("TextLabel")
PlaceHolder_ModuleList.Name = "PlaceHolder_ModuleList"
PlaceHolder_ModuleList.Font = Enum.Font.Code
PlaceHolder_ModuleList.TextColor3 = COLOR_TEXT_NORMAL
PlaceHolder_ModuleList.TextSize = 14
PlaceHolder_ModuleList.Text = ""
PlaceHolder_ModuleList.TextTransparency = 1
PlaceHolder_ModuleList.BackgroundTransparency = 1
PlaceHolder_ModuleList.Size = UDim2.new(0, 10, 0, 24)
PlaceHolder_ModuleList.LayoutOrder = 1
PlaceHolder_ModuleList.ZIndex = 13
PlaceHolder_ModuleList.Parent = Area_ModuleList

local Area_SettingList = Instance.new("Frame")
Area_SettingList.Name = "Area_SettingList"
Area_SettingList.BackgroundTransparency = 1
Area_SettingList.BorderSizePixel = 0
Area_SettingList.Size = UDim2.new(0.3, 0, 0, 26)
Area_SettingList.Position = UDim2.new(0.7, 0, 0, 31)
Area_SettingList.ZIndex = 1
Area_SettingList.Parent = MainFrame

local UIList_SettingList = Instance.new("UIListLayout")
UIList_SettingList.Name = "UIList_SettingList"
UIList_SettingList.SortOrder = Enum.SortOrder.LayoutOrder
UIList_SettingList.FillDirection = Enum.FillDirection.Horizontal
UIList_SettingList.HorizontalAlignment = Enum.HorizontalAlignment.Right
UIList_SettingList.VerticalAlignment = Enum.VerticalAlignment.Center
UIList_SettingList.Padding = UDim.new(0, 30)
UIList_SettingList.Parent = Area_SettingList

local PlaceHolder_SettingList = Instance.new("TextLabel")
PlaceHolder_SettingList.Name = "PlaceHolder_SettingList"
PlaceHolder_SettingList.Font = Enum.Font.Code
PlaceHolder_SettingList.TextColor3 = COLOR_TEXT_NORMAL
PlaceHolder_SettingList.TextSize = 14
PlaceHolder_SettingList.Text = ""
PlaceHolder_SettingList.TextTransparency = 1
PlaceHolder_SettingList.BackgroundTransparency = 1
PlaceHolder_SettingList.Size = UDim2.new(0, 1, 0, 24)
PlaceHolder_SettingList.LayoutOrder = 999
PlaceHolder_SettingList.ZIndex = 13
PlaceHolder_SettingList.Parent = Area_SettingList

local showsettinglist, showmodulelist = nil, nil

local function UpdateAreaStats()
    if guistatus ~= "active" then return end

    log("目前 showsettinglist 状态为：" .. tostring(showsettinglist), "out")
    if showsettinglist ~= nil and
        showsettinglist ~= "console" and
        showsettinglist ~= "info" and
        showsettinglist ~= "settings" then
        log("无效的区域标识：" .. tostring(showsettinglist) .. "，已重置为 nil", "warn")
        showsettinglist = nil
    end
    if showsettinglist == nil then
        Area_Info.Visible = false
        Area_Console.Visible = false
        Area_Settings.Visible = false
    elseif showsettinglist == "info" then
        Area_Info.Visible = true
        Area_Console.Visible = false
        Area_Settings.Visible = false
    elseif showsettinglist == "console" then
        Area_Info.Visible = false
        Area_Console.Visible = true
        Area_Settings.Visible = false
    elseif showsettinglist == "settings" then
        Area_Info.Visible = false
        Area_Console.Visible = false
        Area_Settings.Visible = true
    else
        Area_Info.Visible = false
        Area_Console.Visible = false
        Area_Settings.Visible = false
        showsettinglist = nil
    end
end

showsettinglist = "console"
NavigationHistory:Push("console")
UpdateAreaStats()

table.insert(connections, Button_Enter.MouseButton1Click:Connect(function()
    if guistatus ~= "active" then return end
    local entry = NavigationHistory:Enter()
    if entry then
        showsettinglist = entry
        UpdateAreaStats() 
    end
end))

table.insert(connections, Button_Back.MouseButton1Click:Connect(function()
    if guistatus ~= "active" then return end
    local back = NavigationHistory:Back()
    if back then
        showsettinglist = back
        UpdateAreaStats() 
    end
end))

local function RefreshConsoleDisplay()
    if not Scroll_ConsoleOutput or guistatus ~= "active" then return end
    for _, child in ipairs(Scroll_ConsoleOutput:GetChildren()) do
        if child:IsA("TextLabel") then
            local messagetype = child:GetAttribute("MessageType") or "INFO"
            if messagetype == "ERROR" then
                child.Visible = Config.Console.showerror
            elseif messagetype == "WARN" then
                child.Visible = Config.Console.showwarn
            elseif messagetype == "OUT" then
                child.Visible = Config.Console.showoutput
            elseif messagetype == "INFO" then
                child.Visible = Config.Console.showinfo
            else
                log("未知的消息类型: " .. tostring(messagetype), "warn")
            end
        end
    end
end



local function CreateModuleListButton(text, codename, order)
    if guistatus ~= "active" then return end

    local Button = Instance.new("TextButton")
    Button.Name = "TextButton_ModuleList" .. codename
    Button.Text = text
    Button.BackgroundTransparency = 1
    Button.Font = Enum.Font.Code
    Button.TextColor3 = COLOR_TEXT_NORMAL
    Button.TextSize = 14
    Button.LayoutOrder = order
    Button.Size = UDim2.new(0, GetTextWidth(text, Button.TextSize, Button.Font), 0, 24)
    Button.ZIndex = 13
    Button.Parent = Area_ModuleList

    local Underline = Instance.new("Frame")
    Underline.Name = "Underline_ModuleList" .. codename
    Underline.BorderSizePixel = 0
    Underline.Size = UDim2.new(1, 0, 0, 1)
    Underline.Position = UDim2.new(0, 0, 0.9, -1)
    Underline.BackgroundColor3 = COLOR_TEXT_OVERLAY
    Underline.BackgroundTransparency = 1
    Underline.ZIndex = 13
    Underline.Parent = Button

    table.insert(connections, Button.MouseEnter:Connect(function()
        if guistatus ~= "active" then return end
        local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = TweenService:Create(Button, tweeninfo, {TextColor3 = COLOR_TEXT_OVERLAY})
        tween:Play()
        local tween = TweenService:Create(Underline, tweeninfo, {BackgroundTransparency = 0})
        tween:Play()
        dragstauts = false
    end))

    table.insert(connections, Button.MouseLeave:Connect(function()
        if guistatus ~= "active" then return end
        local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = TweenService:Create(Button, tweeninfo, {TextColor3 = COLOR_TEXT_NORMAL})
        tween:Play()
        local tween = TweenService:Create(Underline, tweeninfo, {BackgroundTransparency = 1})
        tween:Play()
        dragstauts = true
    end))

    table.insert(connections, Button.MouseButton1Click:Connect(function()
        if guistatus ~= "active" then return end
        showmodulelist = codename
    end))

    return Button
end

local function CreateSettingListButton(text, codename, order)
    if guistatus ~= "active" then return end

    local Button = Instance.new("TextButton")
    Button.Name = "TextButton_SettingList" .. codename
    Button.Text = text
    Button.BackgroundTransparency = 0.7
    Button.BackgroundColor3 = COLOR_BUTTON_BACKGROUND
    Button.BorderSizePixel = 1
    Button.BorderColor3 = COLOR_BUTTON_BORDER
    Button.Font = Enum.Font.Code
    Button.TextColor3 = COLOR_TEXT_NORMAL
    Button.TextSize = 14
    Button.LayoutOrder = order
    Button.Size = UDim2.new(0, GetTextWidth(text) + 5, 0, 20)
    Button.ZIndex = 13
    Button.Parent = Area_SettingList

    table.insert(connections, Button.MouseEnter:Connect(function()
        if guistatus ~= "active" then return end
        local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = TweenService:Create(Button, tweeninfo, {TextColor3 = COLOR_TEXT_FULLWHITE})
        tween:Play()
        dragstauts = false
    end))

    table.insert(connections, Button.MouseLeave:Connect(function()
        if guistatus ~= "active" then return end
        local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local tween = TweenService:Create(Button, tweeninfo, {TextColor3 = COLOR_TEXT_NORMAL})
        tween:Play()
        dragstauts = true
    end))

    table.insert(connections, Button.MouseButton1Click:Connect(function()
        if guistatus ~= "active" then return end
        if showsettinglist == codename then
            showsettinglist = nil
        else
            showsettinglist = codename
        end
        NavigationHistory:Push(showsettinglist) 
        UpdateAreaStats()
    end))

    return Button
end

local function CreateConsoleSettingButton(text, codename, order, defaultstauts, effect)
    if guistatus ~= "active" then return end

    local Container = Instance.new("Frame")
    Container.Name = "Container" .. codename
    Container.Size = UDim2.new(0, GetTextWidth(text, 14, Enum.Font.Code) + 30, 0, 24)
    Container.BackgroundTransparency = 1
    Container.LayoutOrder = order
    Container.ZIndex = 13
    Container.Parent = Area_ConsoleSettings

    local Label = Instance.new("TextLabel")
    Label.Name = "TextLabel_ButtonText" .. codename
    Label.Size = UDim2.new(0, GetTextWidth(text, 14, Enum.Font.Code), 0.9, 0)
    Label.Text = text
    Label.BackgroundTransparency = 1
    Label.TextColor3 = COLOR_TEXT_NORMAL
    Label.TextSize = 14
    Label.Font = Enum.Font.Code
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.ZIndex = 13
    Label.Parent = Container

    local ButtonFrame = Instance.new("TextButton")
    ButtonFrame.Name = "TextButton_ButtonFrame"
    ButtonFrame.Size = UDim2.new(0, 20, 0, 20)
    ButtonFrame.Position = UDim2.new(0, GetTextWidth(text, 14, Enum.Font.Code) + 5, 0.5, -10)
    ButtonFrame.BackgroundTransparency = 0.1 
    ButtonFrame.BackgroundColor3 = COLOR_BUTTON_BACKGROUND
    ButtonFrame.BorderColor3 = COLOR_BUTTON_BORDER
    ButtonFrame.BorderSizePixel = 1.5
    ButtonFrame.Text = ""  
    ButtonFrame.ZIndex = 13
    ButtonFrame.Parent = Container

    local ButtonCore = Instance.new("Frame")
    ButtonCore.Name = "Frame_ButtonCore"
    ButtonCore.Size = UDim2.new(0, 0, 0, 0) 
    ButtonCore.Position = UDim2.new(0.5, 0, 0.5, 0) 
    ButtonCore.BackgroundColor3 = COLOR_GUI_BORDER
    if defaultstauts then
        ButtonCore.Size = UDim2.new(0, 10, 0, 10)
        ButtonCore.Position = UDim2.new(0.5, -5, 0.5, -5)
        ButtonCore.BackgroundTransparency = 0
    else
        ButtonCore.Size = UDim2.new(0, 0, 0, 0)
        ButtonCore.Position = UDim2.new(0.5, 0, 0.5, 0)
        ButtonCore.BackgroundTransparency = 1
    end
    ButtonCore.ZIndex = 13
    ButtonCore.Parent = ButtonFrame

    local buttonstauts = defaultstauts

    table.insert(connections, Container.MouseEnter:Connect(function()
        if guistatus ~= "active" then return end
        dragstauts = false
    end))

    table.insert(connections, Container.MouseLeave:Connect(function()
        if guistatus ~= "active" then return end
        dragstauts = true
    end))

    table.insert(connections, ButtonFrame.MouseEnter:Connect(function()
        if guistatus ~= "active" then return end
        dragstauts = false
    end))

    table.insert(connections, ButtonFrame.MouseLeave:Connect(function()
        if guistatus ~= "active" then return end
        dragstauts = true
    end))

    table.insert(connections, ButtonFrame.MouseButton1Click:Connect(function()
        if guistatus ~= "active" then return end
        buttonstauts = not buttonstauts
        local newsize, newposition, newtransparency = buttonstauts and UDim2.new(0, 10, 0, 10) or UDim2.new(0, 0, 0, 0), buttonstauts and UDim2.new(0.5, -5, 0.5, -5) or UDim2.new(0.5, 0, 0.5, 0), buttonstauts and 0 or 1 

        TweenService:Create(ButtonCore, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = newsize,
            Position = newposition,
            BackgroundTransparency = newtransparency
        }):Play()
        
        if effect then
            effect(buttonstauts)
        end
    end))

    return {
        Active = function(active)
            buttonstauts = active
            local newsize, newposition, newtransparency = buttonstauts and UDim2.new(0, 10, 0, 10) or UDim2.new(0, 0, 0, 0), buttonstauts and UDim2.new(0.5, -5, 0.5, -5) or UDim2.new(0.5, 0, 0.5, 0), buttonstauts and 0 or 1 
            
            TweenService:Create(ButtonCore, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Size = newsize,
                Position = newposition,
                BackgroundTransparency = newtransparency
            }):Play()

            if effect then
                effect(buttonstauts)
            end
        end,
        ButtonStauts = function()
            return buttonstauts
        end,
        Destroy = function()
            Container:Destroy()
        end
    }
end

CreateSettingListButton("Info", "info", 1)
CreateSettingListButton("Console", "console", 2)
CreateSettingListButton("Settings", "settings", 3)
CreateModuleListButton("Render", "render", 2)
CreateModuleListButton("Player", "player", 3)
CreateModuleListButton("Misc", "misc", 4)
CreateModuleListButton("Scripts", "scripts", 5)
CreateConsoleSettingButton("Output", "output", 2, Config.Console.showoutput, function(status)
    Config.Console.showoutput = status
    RefreshConsoleDisplay() 
end)
CreateConsoleSettingButton("Warn", "warn", 3, Config.Console.showwarn, function(status)
    Config.Console.showwarn = status
    RefreshConsoleDisplay()
end)
CreateConsoleSettingButton("Error", "error", 4, Config.Console.showerror, function(status)
    Config.Console.showerror = status
    RefreshConsoleDisplay() 
end)

CreateConsoleSettingButton("Info", "info", 5, Config.Console.showinfo, function(status)
    Config.Console.showinfo = status
    RefreshConsoleDisplay() 
end)

CreateConsoleSettingButton("Auto Scroll", "autoscroll", 7, Config.Console.autoscroll, function(status)
    Config.Console.autoscroll = status
end)

local commandlist, commandmap, commandinputlist, commandhistoryindex = {}, {}, {}, 0

local function ExecuteCommand(rawinput: string): (boolean, string?)
    if guistatus ~= "active" then return end 
    
    local extra, extraset = {}, {}

    local bracketmatch = rawinput:match('%[(.-)%]')
    if bracketmatch then
        for part in bracketmatch:gmatch("([^,]+)") do
            local value = part:match("^%s*(.-)%s*$")
            if value ~= "" then
                table.insert(extra, value)
                extraset[value] = true 
            end
        end
    end

    local cleantext = rawinput:gsub("%s*%[.*%]$", ""):gsub("^%s*;?", "")
    local parts = {}
    for part in cleantext:gmatch("[^%s]+") do
        table.insert(parts, part)
    end

    local cmdname = parts[1]
    local args = {}
    for i = 2, #parts do
        if not extraset[parts[i]] then
            table.insert(args, parts[i])
        end
    end

    if not cmdname then
        log("无效命令输入", "warn")
        return false
    end

    local mainname = commandmap[cmdname]
    if not mainname then
        log("未知命令输入: " .. cmdname .. " 使用 ;help 查看可用命令", "warn")
        return false
    end

    local success, result1, result2 = pcall(commandlist[mainname].handler, args, rawinput, extra)
    if not success then
        log("命令执行时发生错误: " .. tostring(result1):gsub("^.+:%d+: ", ""), "error")
        log("命令输入: " .. rawinput .. " 参数: " .. table.concat(args, " ") .. " 配置:" .. table.concat(extra, " "), "out")
        return false, result1
    else 
        table.insert(commandinputlist, rawinput)
        log("增加命令历史记录: " .. rawinput, "out")
        commandhistoryindex = #commandinputlist + 1
        log("命令输入: " .. rawinput .. " 参数: " .. table.concat(args, " ") .. " 配置:" .. table.concat(extra, " "), "out")
        
        if not result1 then
            log("命令执行失败: " .. tostring(result2 or "未知错误"), "error")
            return false, result2
        else 
            log("执行成功: " .. tostring(result2 or "无返回值"), "out")
        end
    end

    return result1, result2
end

local function RegisterCommand(name: string, config: {
    aliases: {string}?,
    usage: {string}?,
    description: string,
    handler: (args: {string}, raw: string, extra: string?) -> (boolean, string?)
})
    if guistatus ~= "active" then return end

    if not config.description or not config.handler then
        log("命令注册失败: 缺少 描述 (description) 或 处理器 (handler) - " .. name, "error")
        return false
    end

    commandlist[name] = {
        main = name,
        aliases = config.aliases or {},
        usage = config.usage or {"无使用方法"},
        description = config.description,
        handler = config.handler
    }
    commandmap[name] = name
    for _, alias in ipairs(commandlist[name].aliases) do
        if commandmap[alias] then
            log(string.format("命令缩写冲突: '%s' 已被 '%s' 占用，跳过注册", alias, commandmap[alias]), "warn")
        else
            commandmap[alias] = name
        end
    end

    local aliasesstr = #config.aliases > 0 and table.concat(config.aliases, ", ") or "无别名"
    log("已注册命令: ;" .. name .. " (" .. aliasesstr .. ")", "out")

    return true
end

local function FindCommandMatches()
    if guistatus ~= "active" then return end

    local matches, inputtext = {}, TextBox_ConsoleInput.Text:sub(2)
    local spacepos = inputtext:find(" ")
    if spacepos then
        inputtext = inputtext:sub(1, spacepos - 1)
    end
    for cmdname, cmdinfo in pairs(commandlist) do
        local matched, options = false, {cmdname}
        for _, alias in ipairs(cmdinfo.aliases or {}) do
            table.insert(options, alias)
        end

        for _, commandname in pairs(options) do
            if commandname:sub(1, #inputtext) == inputtext then
                matched = true
                break
            end
        end

        if matched then
            table.insert(matches, {
                completename = cmdname,
                displayname = table.concat(options, " / ")
            })
        end
    end
    table.sort(matches, function(a, b)
        return a.completename < b.completename
    end)
    return matches
end

local hintpressed = false

local function UpdateHintDisplay()
    if guistatus ~= "active" then return end

    for _, child in ipairs(Area_ConsoleInputHint:GetChildren()) do
        if child:IsA("TextButton") or child:IsA("Frame") or child:IsA("TextLabel") then
            child:Destroy()
        end
    end

    local matches = FindCommandMatches()

    log("=== 匹配结果 ===", "out")
    log("匹配数量:" .. tostring(#matches), "out")
    for i, match in ipairs(matches) do
        log(string.format("[%d] 补全：%s | 显示：%s", i, match.completename, match.displayname), "out")
    end
    log("================", "out")

    if #matches == 0 then
        Area_ConsoleInputHint.Visible = false
        return
    elseif hintpressed then
        hintpressed = false
        Area_ConsoleInputHint.Visible = false
    elseif #matches > 0 then
        Area_ConsoleInputHint.Visible = true
    else
        Area_ConsoleInputHint.Visible = false
    end

    local displaycount = math.min(#matches, 12)
    local totalheight = displaycount * 20 + 5
    Area_ConsoleInputHint.Size = UDim2.new(0.99, 0, 0, totalheight)
    Area_ConsoleInputHint.Position = UDim2.new(0.005, 0, 0, -totalheight - 5)
    for i = 1, displaycount do
        if not matches[i] then break end

        local match = matches[i]
        local cmdinfo = commandlist[match.completename]
        local usage = cmdinfo and cmdinfo.usage and cmdinfo.usage[1] or "无使用方法"

        local HintButton = Instance.new("TextButton")
        HintButton.Font = Enum.Font.Code
        HintButton.TextSize = 14
        HintButton.Size = UDim2.new(0, GetTextWidth(matches[i].displayname, HintButton.TextSize, HintButton.Font), 0, 20)
        HintButton.Position = UDim2.new(0, 5, 0, 2 + (i - 1) * 20)
        HintButton.Name = "TextButton_CommandHint" .. i
        HintButton.BackgroundTransparency = 1
        HintButton.BorderSizePixel = 0
        HintButton.Text = matches[i].displayname
        HintButton.TextXAlignment = Enum.TextXAlignment.Left
        HintButton.TextColor3 = COLOR_TEXT_NORMAL
        HintButton.ZIndex = 21
        HintButton.Parent = Area_ConsoleInputHint

        local HintUnderline = Instance.new("Frame")
        HintUnderline.Name = "Underline_CommandHint" .. i
        HintUnderline.BorderSizePixel = 0
        HintUnderline.Size = UDim2.new(1, 0, 0, 1)
        HintUnderline.Position = UDim2.new(0, 0, 0.9, -1)
        HintUnderline.BackgroundColor3 = COLOR_TEXT_OVERLAY
        HintUnderline.BackgroundTransparency = 1
        HintUnderline.ZIndex = 21
        HintUnderline.Parent = HintButton

        table.insert(connections, HintButton.MouseEnter:Connect(function()
            if guistatus ~= "active" then return end
            local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local tween = TweenService:Create(HintButton, tweeninfo, {TextColor3 = COLOR_TEXT_OVERLAY})
            tween:Play()
            local tween = TweenService:Create(HintUnderline, tweeninfo, {BackgroundTransparency = 0})
            tween:Play()
            dragstauts = false
        end))

        table.insert(connections, HintButton.MouseLeave:Connect(function()
            if guistatus ~= "active" then return end
            local tweeninfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local tween = TweenService:Create(HintButton, tweeninfo, {TextColor3 = COLOR_TEXT_NORMAL})
            tween:Play()
            local tween = TweenService:Create(HintUnderline, tweeninfo, {BackgroundTransparency = 1})
            tween:Play()
            dragstauts = true
        end))

        table.insert(connections, HintButton.MouseButton1Click:Connect(function()
            if guistatus ~= "active" then return end
            local spacepos = TextBox_ConsoleInput.Text:find(" ", 1, true)
            if spacepos then 
                TextBox_ConsoleInput.Text = ";" .. matches[i].completename .. TextBox_ConsoleInput.Text:sub(spacepos)
            else
                TextBox_ConsoleInput.Text = ";" .. matches[i].completename
            end
            hintpressed = true
            TextBox_ConsoleInput:CaptureFocus() 
        end))
    end
end

RegisterCommand("leave", {
    aliases = {},
    usage = {";leave"},
    description = [[退出当前服务器

    此操作将立即断开与服务器的连接, 回到 Roblox 的服务器选择界面

    (不需要任何额外参数)

    使用实例:
    ;leave]],
    handler = function(args, _, _)
        if #args > 0 then
            return false, "多余的参数!"
        else
            game:Shutdown()
            return true, "已退出"
        end
        return false, "未知错误"
    end
})

RegisterCommand("unload", {
    aliases = {},
    usage = {";unload"},
    description = [[销毁Nvi脚本
    
    此操作将销毁Nvi的界面, 并停止所有功能的运行

    (不需要任何额外参数)
    
    使用实例:
    ;unload]],
    handler = function(args, _, _)
        if #args > 0 then
            return false, "多余的参数!"
        else
            DestroyNvi()
            return true, "已销毁"
        end
        return false, "未知错误"
    end
})

RegisterCommand("rejoin", {
    aliases = {"rj"},
    usage = {";rejoin"},
    description = [[重新加入当前服务器
    
    此操作将尝试重新加入当前服务器

    (不需要任何额外参数)
    
    使用实例:
    ;rejoin]],
    handler = function(args, _, _)
        local localplayer = Localplayer()
        if not TeleportService then
            return false, "无法访问 TeleportService"
        elseif #args > 0 then
            return false, "多余的参数!"
        else
            if #Players:GetPlayers() <= 1 then
                Players.LocalPlayer:Kick("\n正在重连... 如需中断请点击离开按钮")
                task.wait()
                TeleportService:Teleport(PlaceId, localplayer)
            else
                Players.LocalPlayer:Kick("\n正在重连... 如需中断请点击离开按钮")
                task.wait()
                TeleportService:TeleportToPlaceInstance(PlaceId, JobId, localplayer)
            end
            task.delay(1, DestroyNvi)
            return true, "已重连"
        end
        return false, "未知错误"
    end
})

RegisterCommand("suicide", {
    aliases = {"reset"},
    usage = {";suicide"},
    description = [[重置你的角色
    
    此操作将使你的角色死亡并重生

    (不需要任何额外参数)
    
    使用实例:
    ;suicide]],
    handler = function(args, _, _)
        local humanoid = Localhum()
        if not humanoid then
            return false, "无法获取 Humanoid"
        elseif #args > 0 then
            return false, "多余的参数!"
        else
            humanoid.Health = 0
            return true, "已重生"
        end
        return false, "未知错误"
    end
})

local sitstauts, sitconnections = nil, {}

RegisterCommand("sit", {
    aliases = {},
    usage = {";sit {状态} [<模式>]"},
    description = [[让你的角色坐下或站起

    此操作将使你的角色坐下或站起
    
    关于参数:
    {状态} - 必要参数, 角色坐下状态, 可选值如下:
    enabled 或 on - 开启坐下功能
    disabled 或 off - 关闭坐下功能
    
    
    关于配置: 
    <模式> - 可选配置, 坐下模式, 可选值如下:
    force 或 -f - 强制模式 (如果受到别的脚本干预导致角色被坐下或被站起, 将自动重新坐下或站起)
    
    使用实例:
    ;sit on [-f] - 启用坐下功能, 并开启强制模式]],
    handler = function(args, _, extra)
        local humanoid, character = Localhum(), Localchar()

        sitstauts = humanoid and humanoid.Sit
        for _, connection in ipairs(sitconnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end
        if not humanoid then
            return false, "无法获取 Humanoid"
        elseif #args == 0 then
            if #extra > 0 then
                if extra[1] == "force" or extra[1] == "-f" then
                    table.insert(sitconnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
                        if humanoid.Sit ~= sitstauts then   
                            humanoid.Sit = sitstauts
                        end
                    end))

                    for _, connection in ipairs(sitconnections) do
                        table.insert(connections, connection)
                    end
                else
                    return false, string.format("无法识别参数 '%s'", extra[1])
                end
            end
            humanoid.Sit = not sitstauts
            sitstauts = not sitstauts
            if sitstauts then    
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    table.insert(sitconnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
                        if humanoid.Sit ~= true then
                            humanoid.Sit = true
                        end
                    end))

                    for _, connection in ipairs(sitconnections) do
                        table.insert(connections, connection)
                    end
                    return true, "角色已坐下 (强制模式)"
                else
                    return true, "角色已坐下"
                end
                return false, "未知错误"
            else
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    table.insert(sitconnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
                        if humanoid.Sit ~= false then
                            humanoid.Sit = false
                        end
                    end))

                    for _, connection in ipairs(sitconnections) do
                        table.insert(connections, connection)
                    end
                    return true, "角色已站起 (强制模式)"
                else
                    return true, "角色已站起"
                end
                return false, "未知错误"
            end
            return false, "未知错误"
        elseif args[2] then
            return false, "参数过多!"
        else
            if args[1] == "enabled" or args[1] == "on" then
                if #extra > 0 then
                    for _, part in ipairs(extra) do
                        if extra[1] == "force" or extra[1] == "-f" then
                            table.insert(sitconnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
                                if humanoid.Sit ~= true then
                                    humanoid.Sit = true
                                end
                            end))

                            for _, connection in ipairs(sitconnections) do
                                table.insert(connections, connection)
                            end
                        else
                            return false, string.format("无法识别参数 '%s'", part)
                        end
                    end
                elseif #extra > 1 then
                    return false, "配置参数过多!"
                end
                sitstauts = true
                humanoid.Sit = true
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    return true, "角色已坐下 (强制模式)"
                else
                    return true, "角色已坐下"
                end
                return false, "未知错误"
            elseif args[1] == "disabled" or args[1] == "off" then
                if #extra > 0 then
                    for _, part in ipairs(extra) do
                        if extra[1] == "force" or extra[1] == "-f" then
                            table.insert(sitconnections, humanoid:GetPropertyChangedSignal("Sit"):Connect(function()
                                if humanoid.Sit ~= false then
                                    humanoid.Sit = false
                                end
                            end))

                            for _, connection in ipairs(sitconnections) do
                                table.insert(connections, connection)
                            end
                        else
                            return false, string.format("无法识别参数 '%s'", part)
                        end
                    end
                elseif #extra > 1 then
                    return false, "配置参数过多!"
                end
                sitstauts = false
                humanoid.Sit = false
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    return true, "角色已站起 (强制模式)"
                else
                    return true, "角色已站起"
                end
                return false, "未知错误"
            else
                return false, string.format("无法识别参数 '%s'", args[1])
            end
        end
        return false, "未知错误"
    end
})

local freezestauts, freezeconnections = nil, {}

local function FreezeCharacter(character, status)
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            part.Anchored = status
        end
    end
end

RegisterCommand("freeze", {
    aliases = {},
    usage = {";freeze {状态} [<模式>]"},
    description = [[冻结你自己!

    此操作将冻结你的角色, 使其无法移动
    
    关于参数:
    {状态} - 必要参数, 冻结状态, 可选值如下:
    enabled 或 on - 启用冻结功能
    disabled 或 off - 禁用冻结功能
    
    
    关于配置: 
    <模式> - 可选配置, 冻结模式, 可选值如下:
    force 或 -f - 强制模式 (如果受到别的脚本干预导致角色被冻结或被解冻, 将自动重新冻结或解冻角色)
    
    使用实例:
    ;freeze on [-f] - 启用冻结功能, 并开启强制模式]],
    handler = function(args, _, extra)
        local rootpart, character = Localroot(), Localchar()

        freezestauts = rootpart and rootpart.Anchored
        for _, connection in ipairs(freezeconnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end
        if not rootpart then
            return false, "无法获取 HumanoidRootPart"
        elseif #args == 0 then
            if #extra > 0 then
                if extra[1] == "force" or extra[1] == "-f" then
                    table.insert(freezeconnections, rootpart:GetPropertyChangedSignal("Anchored"):Connect(function()
                        if rootpart.Anchored ~= freezestauts then   
                            rootpart.Anchored = freezestauts
                        end
                    end))

                    for _, connection in ipairs(freezeconnections) do
                        table.insert(connections, connection)
                    end
                else
                    return false, string.format("无法识别参数 '%s'", extra[1])
                end
            end
            FreezeCharacter(character, not freezestauts)
            freezestauts = not freezestauts
            if freezestauts then    
                return true, "角色已冻结"
            else
                return true, "角色已解冻"
            end
            return true, freezestauts and "角色已冻结" or "角色已解冻"
        elseif args[2] then
            return false, "参数过多!"
        else
            if args[1] == "enabled" or args[1] == "on" then
                if #extra > 0 then
                    for _, part in ipairs(extra) do
                        if extra[1] == "force" or extra[1] == "-f" then
                            table.insert(freezeconnections, part:GetPropertyChangedSignal("Anchored"):Connect(function()
                                if part.Anchored ~= true then
                                    part.Anchored = true
                                end
                            end))
                            
                            for _, connection in ipairs(freezeconnections) do
                                table.insert(connections, connection)
                            end
                            return true, "角色已冻结 (强制模式)"
                        else
                            return false, string.format("无法识别参数 '%s'", part)
                        end
                    end
                elseif #extra > 1 then
                    return false, "配置参数过多!"
                end
                freezestauts = true
                FreezeCharacter(character, true)
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    return true, "角色已冻结 (强制模式)"
                else
                    return true, "角色已冻结"
                end
                return false, "未知错误"
            elseif args[1] == "disabled" or args[1] == "off" then
                if #extra > 0 then
                    for _, part in ipairs(extra) do
                        if extra[1] == "force" or extra[1] == "-f" then
                            table.insert(freezeconnections, part:GetPropertyChangedSignal("Anchored"):Connect(function()
                                if part.Anchored ~= false then
                                    part.Anchored = false
                                end
                            end))

                            for _, connection in ipairs(freezeconnections) do
                                table.insert(connections, connection)
                            end
                        else
                            return false, string.format("无法识别参数 '%s'", part)
                        end
                    end
                elseif #extra > 1 then
                    return false, "配置参数过多!"
                end
                freezestauts = false
                FreezeCharacter(character, false)
                if #extra > 0 and (extra[1] == "force" or extra[1] == "-f") then
                    return true, "角色已解冻 (强制模式)"
                else
                    return true, "角色已解冻"
                end
                return false, "未知错误"
            else
                return false, string.format("无法识别参数 '%s'", args[1])
            end
        end
        return false, "未知错误"
    end
})

RegisterCommand("print", {
    aliases = {"echo"},
    usage = {";print <文本> [<文本类型>]"},
    description = [[输出文本到控制台

     此操作将会将输入的参数输出到控制台, 使用 F9 打开控制台
    
    关于参数:
    <文本> - 必要参数, 需要输出的文本, 必须使用双引号包裹，例如 ;print "Hello World"
    
    关于配置:
    <文本类型> - 可选配置, 指定输出文本的类型，影响显示样式和是否受控制台设置影响
    messagetype == error / warn / out - 指定消息类型的长格式参数
    -e / -w / -o - 分别代表 error / warn / out 的短格式参数
    
    使用实例:
    ;print "Hello World" [messagetype == warn] ]],
    handler = function(args, raw, extra)
        if #args == 0 then
            return false, "参数不足"
        end
        local message = raw:match('"([^"]*)"')
        if not message or message == "" then
            return false, "请使用双引号包裹文本，例如 ;print \"Hello World\""
        end
        if #extra > 0 then
            local longmatched, shortmatched, messagetype = false, false, nil
            for _, part in ipairs(extra) do
                local longmatch, shortmatch = part:match("^messagetype%s*==%s*(%w+)$"), part:match("^%-([ewo])$")

                if longmatch then 
                    longmatched = true 
                    messagetype = longmatch
                end

                if shortmatch then
                    shortmatched = true
                    if longmatched then
                        return false, "同时使用了长格式和短格式的消息类型，请选择一种格式"
                    end
                    messagetype = shortmatch
                end
                
                if not longmatch and not shortmatch then
                    return false, string.format("无法识别 '%s'", part)
                end
            end
            if messagetype then
                if messagetype == "error" or messagetype == "e" then
                    error(message)
                    return true, "错误消息已发送"
                elseif messagetype == "warn" or messagetype == "w" then
                    warn(message)
                    return true, "警告消息已发送"
                elseif messagetype == "out" or messagetype == "o" then
                    print(message)                        
                    return true, "输出消息已发送 (配置指定)"
                else
                    return false, "无效的模式参数: " .. messagetype
                end
            end
        else
            print(message)
            return true, "输出消息已发送 (普通输出)"
        end
        return false, "未知错误"
    end
})

local originalwalkspeed, walkspeedconnections = nil, {}

RegisterCommand("walkspeed", {
    aliases = {"ws", "speed"},
    usage = {";walkspeed <操作> <数值> [<模式>]"},
    description = [[设置角色移动速度
    
    此操作将设置你角色的 WalkSpeed 属性, 影响角色的移动速度
    
    关于参数:
    <操作> - 必要参数, 操作类型, 可选值如下:
    set / s - 设置 WalkSpeed 数值
    get / g - 获取当前 WalkSpeed 数值
    reset / r - 重置 WalkSpeed 数值到首次设定前
    
    <数值> - 设置模式下的必要参数, 例如 50
    
    关于配置:
    <模式> - 可选配置, 设置模式:
    force / -f - 强制锁定模式, 抵抗其他脚本或游戏机制更改]],
    handler = function(args, _, extra)
        local humanoid = Localhum()
        if not humanoid then return false, "无法获取 Humanoid" end

        for _, connection in ipairs(walkspeedconnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end

        local mode = (args[1] or "")

        if mode == "get" or mode == "g" then
            if #args ~= 1 then return false, "获取模式仅需操作参数" end
            return true, "当前 WalkSpeed 数值为 " .. tostring(humanoid.WalkSpeed)

        elseif mode == "reset" or mode == "r" then
            if #args ~= 1 then return false, "重置模式仅需操作参数" end
            if not originalwalkspeed then return false, "尚未设置过 WalkSpeed, 无法重置" end
            humanoid.WalkSpeed = originalwalkspeed
            return true, "WalkSpeed 已重置为 " .. tostring(originalwalkspeed)

        elseif mode == "set" or mode == "s" then
            if #args < 2 then return false, "设置模式需提供数值参数" end
            if #args > 2 then return false, "参数过多" end

            local value = tonumber(args[2])
            if not value then return false, "输入的数值需要是数字!" end
            if value < 0 then return false, "WalkSpeed 数值不能为负数!" end

            if not originalwalkspeed then
                originalwalkspeed = humanoid.WalkSpeed
            end

            humanoid.WalkSpeed = value

            if #extra > 1 then
                return false, "配置参数过多!"
            elseif #extra == 1 then
                local flag = extra[1]
                if flag == "force" or flag == "-f" then
                    table.insert(walkspeedconnections, humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
                        if humanoid.WalkSpeed ~= value then
                            humanoid.WalkSpeed = value
                        end
                    end))
                    for _, conn in ipairs(walkspeedconnections) do
                        if conn and conn.Connected then table.insert(connections, conn) end
                    end
                    return true, string.format("WalkSpeed 已强制锁定为 %d", value)
                else
                    return false, string.format("无法识别配置 '%s'", extra[1])
                end
            end

            return true, "WalkSpeed 已设置为 " .. tostring(value)
        else
            return false, "未知的操作模式, 请使用 get/set/reset"
        end
    end
})

local originaljumppower, jumppowerconnections = nil, {}

RegisterCommand("jumppower", {
    aliases = {"jp"},
    usage = {";jumppower <操作> <数值> [<模式>]"},
    description = [[设置角色跳跃力

    此操作将设置你角色的 JumpPower 属性, 影响角色的基础跳跃高度

    关于参数:
    <操作> - 必要参数, 操作类型, 可选值如下:
    set / s - 设置 JumpPower 数值
    get / g - 获取当前 JumpPower 数值
    reset / r - 重置 JumpPower 数值到首次设定前

    <数值> - 设置模式下的必要参数, 例如 50

    关于配置:
    <模式> - 可选配置, 设置模式:
    force / -f - 强制锁定模式, 抵抗其他脚本或游戏机制更改]],
    handler = function(args, _, extra)
        local humanoid = Localhum()
        if not humanoid then return false, "无法获取 Humanoid" end

        for _, connection in ipairs(jumppowerconnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end

        local mode = (args[1] or "")

        if mode == "get" or mode == "g" then
            if #args ~= 1 then return false, "获取模式仅需操作参数" end
            return true, "当前 JumpPower 数值为 " .. tostring(humanoid.JumpPower)

        elseif mode == "reset" or mode == "r" then
            if #args ~= 1 then return false, "重置模式仅需操作参数" end
            if not originaljumppower then return false, "尚未设置过 JumpPower, 无法重置" end
            humanoid.JumpPower = originaljumppower
            return true, "JumpPower 已重置为 " .. tostring(originaljumppower)

        elseif mode == "set" or mode == "s" then
            if #args < 2 then return false, "设置模式需提供数值参数" end
            if #args > 2 then return false, "参数过多" end

            local value = tonumber(args[2])
            if not value then return false, "输入的数值需要是数字!" end
            if value < 0 then return false, "JumpPower 数值不能为负数!" end

            if not originaljumppower then
                originaljumppower = humanoid.JumpPower
            end

            humanoid.JumpPower = value

            if #extra > 1 then
                return false, "配置参数过多!"
            elseif #extra == 1 then
                local flag = extra[1]:lower()
                if flag == "force" or flag == "-f" then
                    table.insert(jumppowerconnections, humanoid:GetPropertyChangedSignal("JumpPower"):Connect(function()
                        if humanoid.JumpPower ~= value then
                            humanoid.JumpPower = value
                        end
                    end))
                    for _, conn in ipairs(jumppowerconnections) do
                        if conn and conn.Connected then table.insert(connections, conn) end
                    end
                    return true, string.format("JumpPower 已强制锁定为 %d", value)
                else
                    return false, string.format("无法识别配置 '%s'", extra[1])
                end
            end

            return true, "JumpPower 已设置为 " .. tostring(value)
        else
            return false, "未知的操作模式, 请使用 get/set/reset"
        end
    end
})

local originaljumpheight, jumpheightconnections = nil, {}

RegisterCommand("jumpheight", {
    aliases = {"jh"},
    usage = {";jumpheight <操作> <数值> [<模式>]"},
    description = [[设置角色跳跃高度

    此操作将设置你角色的 JumpHeight 属性, 影响角色的物理跳跃高度

    关于参数:
    <操作> - 必要参数, 操作类型, 可选值如下:
    set / s - 设置 JumpHeight 数值
    get / g - 获取当前 JumpHeight 数值
    reset / r - 重置 JumpHeight 数值到首次设定前

    <数值> - 设置模式下的必要参数, 例如 10

    关于配置:
    <模式> - 可选配置, 设置模式:
    force / -f - 强制锁定模式, 抵抗其他脚本或游戏机制更改]],
    handler = function(args, _, extra)
        local humanoid = Localhum()
        if not humanoid then return false, "无法获取 Humanoid" end

        for _, connection in ipairs(jumpheightconnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end

        local mode = (args[1] or "")

        if mode == "get" or mode == "g" then
            if #args ~= 1 then return false, "获取模式仅需操作参数" end
            return true, "当前 JumpHeight 数值为 " .. tostring(humanoid.JumpHeight)

        elseif mode == "reset" or mode == "r" then
            if #args ~= 1 then return false, "重置模式仅需操作参数" end
            if not originaljumpheight then return false, "尚未设置过 JumpHeight, 无法重置" end
            humanoid.JumpHeight = originaljumpheight
            return true, "JumpHeight 已重置为 " .. tostring(originaljumpheight)

        elseif mode == "set" or mode == "s" then
            if #args < 2 then return false, "设置模式需提供数值参数" end
            if #args > 2 then return false, "参数过多" end

            local value = tonumber(args[2])
            if not value then return false, "输入的数值需要是数字!" end
            if value < 0 then return false, "JumpHeight 数值不能为负数!" end

            if not originaljumpheight then
                originaljumpheight = humanoid.JumpHeight
            end

            humanoid.JumpHeight = value

            if #extra > 1 then
                return false, "配置参数过多!"
            elseif #extra == 1 then
                local flag = extra[1]:lower()
                if flag == "force" or flag == "-f" then
                    table.insert(jumpheightconnections, humanoid:GetPropertyChangedSignal("JumpHeight"):Connect(function()
                        if humanoid.JumpHeight ~= value then
                            humanoid.JumpHeight = value
                        end
                    end))
                    for _, conn in ipairs(jumpheightconnections) do
                        if conn and conn.Connected then table.insert(connections, conn) end
                    end
                    return true, string.format("JumpHeight 已强制锁定为 %.2f", value)
                else
                    return false, string.format("无法识别配置 '%s'", extra[1])
                end
            end

            return true, "JumpHeight 已设置为 " .. tostring(value)
        else
            return false, "未知的操作模式, 请使用 get/set/reset"
        end
    end
})

local l33tmap = {
    -- 英文/数字 (Leet Speak)
    ["a"] = "4", ["A"] = "4", ["b"] = "8", ["B"] = "8",
    ["e"] = "3", ["E"] = "3", ["g"] = "9", ["G"] = "9",
    ["i"] = "1", ["I"] = "1", ["l"] = "1", ["L"] = "1",
    ["o"] = "0", ["O"] = "0", ["s"] = "5", ["S"] = "5",
    ["t"] = "7", ["T"] = "7", ["z"] = "2", ["Z"] = "2",
    
    -- 中文形近/异体字映射
    ["大"] = "太", ["少"] = "尐", ["多"] = "夛",
    ["长"] = "镸", ["短"] = "矬", ["高"] = "髙",
    ["快"] = "夬", ["慢"] = "漫", ["坏"] = "孬",
    ["日"] = "曰", ["月"] = "曰", ["目"] = "且",
    ["木"] = "朩", ["水"] = "氺", ["火"] = "灬",
    ["土"] = "士", ["工"] = "土", ["王"] = "玉",
    ["天"] = "夭", ["夫"] = "失", ["未"] = "末",
    ["己"] = "已", ["已"] = "巳", ["子"] = "孑",
    ["刀"] = "刃", ["力"] = "办", ["又"] = "叉",
    ["田"] = "由", ["甲"] = "申", ["干"] = "于",
    ["八"] = "入", ["人"] = "入", ["个"] = "介",
    ["上"] = "丄", ["下"] = "丅", ["用"] = "甩",
    ["米"] = "来", ["半"] = "平", ["羊"] = "美",
    ["心"] = "必", ["思"] = "恩", ["想"] = "相",
    ["你"] = "伱", ["我"] = "莪", ["他"] = "牠",
    ["的"] = "旳", ["是"] = "昰", ["在"] = "洅",
    ["了"] = "ㄋ", ["和"] = "咊", ["与"] = "欤",
    ["为"] = "爲", ["什"] = "甚", ["么"] = "幺",
    ["去"] = "厾", ["回"] = "囘", ["出"] = "岀",
    ["门"] = "闁", ["开"] = "幵", ["关"] = "関",
    ["爱"] = "嗳", ["恨"] = "狠", ["情"] = "晴",
    ["谢"] = "榭", ["欢"] = "歓", ["光"] = "洸",
    ["临"] = "臨", ["游"] = "遊", ["戏"] = "戯",
    ["软"] = "軟", ["件"] = "伔", ["硬"] = "哽",
    ["进"] = "進", ["来"] = "來", ["同"] = "冋",
    ["主"] = "玉", ["口"] = "囗", ["低"] = "氐",
    ["好"] = "恏", ["坏"] = "壞", ["大"] = "夳",
    ["小"] = "尐", ["地"] = "坔", ["世"] = ""
}

RegisterCommand("chat", {
    aliases = {"say"},
    usage = {';chat <消息> [<频道>, <模式>]'},
    description = [[在聊天中输出内容

    此操作将会在聊天中输出指定的消息
    
    关于参数:
    <消息> - 必要参数, 需要发送的消息, 必须使用双引号包裹, 例如 ;chat "Hello World"

    关于配置:
    <频道> - 可选配置, 指定发送消息的频道, 可选值如下:
    channel == general / system  - 指定频道的长格式参数
    -g / -s - 分别代表 general / system 的短格式参数

    如果输入别的长格式参数, 将尝试识别频道是否存在并发送消息到该频道, 但不保证成功, 请确保频道名称正确且存在

    <模式> - 可选配置, 消息格式模式, 可选值如下:
    format == l33t - 指定使用 l33t 模式的长格式参数
    -l - 使用 l33t 模式的短格式参数]],
    handler = function(args, raw, extra)
        local message = raw:match('"([^"]*)"')
        if not message or message == "" then 
            return false, "请使用双引号包裹文本，例如 ;chat \"Hello World\"" 
        end

        local targetchannel, usel33t = "RBXGeneral", false

        for _, part in ipairs(extra) do
            local chlong, fmtlong, shortflag = part:match('^channel%s*==%s*(%S+)$'), part:match('^format%s*==%s*(%S+)$'), part:match('^%-(%w+)$')

            if chlong then
                targetchannel = chlong
            elseif fmtlong then
                if fmtlong == "l33t" then
                    usel33t = true
                else
                    return false, "不支持的格式: " .. fmtlong
                end
            elseif shortflag then
                if shortflag == "g" then targetchannel = "RBXGeneral"
                elseif shortflag == "s" then targetchannel = "RBXSystem"
                elseif shortflag == "l" then usel33t = true
                else return false, "无法识别的短参数: " .. part end
            else
                return false, "无法识别的配置: " .. part
            end
        end
        if usel33t then
            local result = {}
            for _, codepoint in utf8.codes(message) do
                local char = utf8.char(codepoint)
                if l33tmap[char] and math.random() < 0.7 then
                    table.insert(result, l33tmap[char])
                else
                    table.insert(result, char)
                end
            end
            message = table.concat(result)
        end

        if targetchannel == "general" or targetchannel == "g" then
            targetchannel = "RBXGeneral"
        elseif targetchannel == "system" or targetchannel == "s" then
            targetchannel = "RBXSystem"
        end

        local channelobj = TextChatService.TextChannels:FindFirstChild(targetchannel)

        if not channelobj then
            return false, string.format("频道 '%s' 不存在或不可用", targetchannel)
        end

        local success, err = pcall(function() channelobj:SendAsync(message) end)
        if success then
            local modestr = usel33t and " (l33t 模式)" or ""
            return true, string.format("消息已发送到频道 '%s'%s | 消息：%s", targetchannel, modestr, message)
        else
            return false, "发送失败: " .. tostring(err)
        end
    end
})

local flightstauts, flightconnections, lastrebuildtime, flightobjects = false, {}, 0, {
    LinearVelocity = nil,
    Attachment = nil,
    PlatformPart = nil,
    floatvalue = -31
}

local function StopFlight() 
    local rootpart = Localroot()
    
    if not rootpart then
        return false, "无法获取 HumanoidRootPart"
    end

    for _, connection in ipairs(flightconnections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end

    local LinearVelocity, Attachment, PlatformPart = rootpart:FindFirstChild("LinearVelocity_Flight"), rootpart:FindFirstChild("Attachment_Flight"), rootpart:FindFirstChild("PlatformPart_Flight")

    if LinearVelocity then 
        LinearVelocity:Destroy() 
        log("已销毁飞行用 LinearVelocity", "out")
    end
    if Attachment then 
        Attachment:Destroy()
        log("已销毁飞行用 Attachment", "out")
    end

    if rootpart.Anchored then
        rootpart.Anchored = false
        log("已取消飞行用 Anchored", "out")
    end

    if PlatformPart then 
        PlatformPart:Destroy() 
        log("已销毁飞行用 PlatformPart", "out")
    end

    flightstauts, flightconnections, flightobjects = false, {}, {
        LinearVelocity = nil,
        Attachment = nil,
        PlatformPart = nil,
        floatvalue = -31
    }
end

RegisterCommand("flight", {
    aliases = {"fly"},
    usage = {";flight {模式}/{状态} {速度, 单位: Studs}"},
    description = [[飞行!

    关于参数:
    
    参数1: 
    {模式} - 可选参数, 飞行模式或飞行状态, 可选值如下:

    velocity / tpcframe / platform - 指定飞行模式的长格式参数

    velocity 或 v 或 normal 或 n - 默认/速率飞行模式, 使用 LinearVelocity 实现飞行
    tpcframe 或 tc - 传送飞行模式, 通过不断传送角色来实现飞行
    platform 或 p - 平台飞行模式, 生成一个平台并将角色固定在平台上来实现飞行 !注意! 平台飞行模式不需要指定速度参数!

    {状态} - 可选参数, 飞行状态, 可选值如下:

    disabled - 立即停止飞行功能

    disabled 或 off - 停止飞行功能

    参数2: 
    {速度} - 可选参数, 指定飞行速度 (仅适用于普通飞行模式), 默认为 16 Studs/s]],
    handler = function(args, rawinput, _)
        local rootpart, camera, humanoid, move, flyspeed = Localroot(), Localcam, Localhum(), args[1] or "normal", args[2] or 16

        if not rootpart then
            return false, "无法获取 HumanoidRootPart, 请确保角色已加载"
        elseif #args > 2 then
            return false, "参数过多"
        elseif move ~= "normal" and move ~= "velocity" and move ~= "platform" and move ~= "tpcframe" and move ~= "v" and move ~= "n" and move ~= "v" and move ~= "p" and move ~= "tc" and move ~= "disabled" and move ~= "off" then
            return false, "错误的参数! 飞行模式必须是 normal / velocity / tpcframe / platform 或 n / v / tc / p, 如需关闭飞行, 第一个参数为 disabled 或 off"
        end

        StopFlight() 

        if move == "normal" or move == "velocity" or move == "n" or move == "v" then
            local control = { Forward = 0, Backward = 0, Left = 0, Right = 0, Up = 0, Down = 0, SpeedModifier = 1}

            flightobjects.Attachment = Instance.new("Attachment")
            flightobjects.Attachment.Name = "Attachment_Flight"
            flightobjects.Attachment.Parent = rootpart

            flightobjects.LinearVelocity = Instance.new("LinearVelocity")
            flightobjects.LinearVelocity.Name = "LinearVelocity_Flight"
            flightobjects.LinearVelocity.MaxForce = 1e9
            flightobjects.LinearVelocity.Attachment0 = flightobjects.Attachment
            flightobjects.LinearVelocity.Parent = rootpart

            table.insert(flightconnections, RunService.Heartbeat:Connect(function()
                if not rootpart then
                    flightstauts = false
                    StopFlight()
                    return false, "无法获取 HumanoidRootPart, 结束飞行 (速率飞行)"
                end
                
                local lv, at = flightobjects.LinearVelocity, flightobjects.Attachment
                
                if not at and at.Parent then
                    local nowtime = os.clock()
                    if nowtime - lastrebuildtime < 0.5 then return end
                    lastrebuildtime = nowtime
                    log("飞行组件丢失，正在重建...", "out")
                    
                    if at and not at.Parent then at:Destroy() end

                    flightobjects.Attachment = Instance.new("Attachment")
                    flightobjects.Attachment.Name = "Attachment_Flight"
                    flightobjects.Attachment.Parent = rootpart
                    flightobjects.LinearVelocity.Attachment0 = flightobjects.Attachment
                    return 
                end

                if not lv and lv.Parent then
                    local nowtime = os.clock()
                    if nowtime - lastrebuildtime < 0.5 then return end
                    lastrebuildtime = nowtime
                    log("飞行组件丢失，正在重建...", "out")
                    
                    if lv and not lv.Parent then lv:Destroy() end

                    flightobjects.LinearVelocity = Instance.new("LinearVelocity")
                    flightobjects.LinearVelocity.Name = "LinearVelocity_Flight"
                    flightobjects.LinearVelocity.MaxForce = 1e9
                    flightobjects.LinearVelocity.Attachment0 = flightobjects.Attachment
                    flightobjects.LinearVelocity.Parent = rootpart
                    return 
                end
                
                local look, right = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z).Unit, Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z).Unit
                if look.Magnitude == 0 then look = Vector3.new(1, 0, 0) end

                local hasinput = control.Forward ~= 0 or control.Backward ~= 0 or 
                    control.Left ~= 0 or control.Right ~= 0 or 
                    control.Up ~= 0 or control.Down ~= 0
                local forward, strafe, vertical, movedirection = control.Forward + control.Backward, control.Left + control.Right, control.Up + control.Down, Vector3.new()
                if forward ~= 0 or strafe ~= 0 then movedirection = (look * forward + right * strafe).Unit end

                if hasinput then
                    local velocity = Vector3.new()
                    if movedirection.Magnitude > 0 then velocity += movedirection.Unit * flyspeed * control.SpeedModifier end
                    velocity += Vector3.new(0, vertical * flyspeed * control.SpeedModifier, 0)
                    lv.VectorVelocity = velocity
                else
                    lv.VectorVelocity = Vector3.new(0, 0, 0)
                end
            end))

            table.insert(flightconnections, UserInputService.InputBegan:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
                if input.KeyCode == Enum.KeyCode.W then control.Forward = 1
				elseif input.KeyCode == Enum.KeyCode.S then control.Backward = -1
				elseif input.KeyCode == Enum.KeyCode.A then control.Left = -1
				elseif input.KeyCode == Enum.KeyCode.D then control.Right = 1
				elseif input.KeyCode == Enum.KeyCode.Space then control.Up = 1
				elseif input.KeyCode == Enum.KeyCode.LeftShift then control.Down = -1
				elseif input.KeyCode == Enum.KeyCode.LeftControl then 
					control.SpeedModifier = control.SpeedModifier == 1 and 2.5 or 1
					log("速度模式: " .. (control.SpeedModifier == 2.5 and "快" or "中"), "out")
				end
            end))

            table.insert(flightconnections, UserInputService.InputEnded:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
                if input.KeyCode == Enum.KeyCode.W then control.Forward = 0
				elseif input.KeyCode == Enum.KeyCode.S then control.Backward = 0
				elseif input.KeyCode == Enum.KeyCode.A then control.Left = 0
				elseif input.KeyCode == Enum.KeyCode.D then control.Right = 0
				elseif input.KeyCode == Enum.KeyCode.Space then control.Up = 0
				elseif input.KeyCode == Enum.KeyCode.LeftShift then control.Down = 0
                end
            end))

            table.insert(flightconnections, humanoid.Died:Connect(function()
                flightstauts = false
                StopFlight()
                log("角色已死亡，结束飞行 (速率飞行)", "out")
            end))
            for _, connection in ipairs(flightconnections) do table.insert(connections, connection) end
            
            flightstauts = true
            return true, "飞行(速率飞行)已打开, 速度: " .. flyspeed
        elseif move == "tpcframe" or move == "tc" then  
            local control = { Forward = 0, Backward = 0, Left = 0, Right = 0, Up = 0, Down = 0, SpeedModifier = 1}

            table.insert(flightconnections, RunService.Heartbeat:Connect(function()
                if not rootpart then
                    flightstauts = false
                    StopFlight()
                    return false, "无法获取 HumanoidRootPart, 结束飞行 (传送模式)"
                end
                
                local look, right, movedirection = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z).Unit, Vector3.new(camera.CFrame.RightVector.X, 0, camera.CFrame.RightVector.Z).Unit, Vector3.new()
			    if look.Magnitude == 0 then 
                    look = Vector3.new(1, 0, 0) 
                end

                local hasinput = control.Forward ~= 0 or control.Backward ~= 0 or 
                    control.Left ~= 0 or control.Right ~= 0 or 
                    control.Up ~= 0 or control.Down ~= 0
                local forward, strafe, vertical = control.Forward + control.Backward, control.Left + control.Right, control.Up + control.Down

                if forward ~= 0 or strafe ~= 0 then movedirection += look * forward + right * strafe end

                if hasinput then
                    local velocity = Vector3.new()
                    if movedirection.Magnitude > 0 then velocity += movedirection.Unit * flyspeed * control.SpeedModifier * 0.03 end
                    velocity += Vector3.new(0, vertical * flyspeed * control.SpeedModifier * 0.03, 0)
                    rootpart.CFrame += velocity
                end
            end))

            table.insert(flightconnections, UserInputService.InputBegan:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
                if input.KeyCode == Enum.KeyCode.W then control.Forward = 1
				elseif input.KeyCode == Enum.KeyCode.S then control.Backward = -1
				elseif input.KeyCode == Enum.KeyCode.A then control.Left = -1
				elseif input.KeyCode == Enum.KeyCode.D then control.Right = 1
				elseif input.KeyCode == Enum.KeyCode.Space then control.Up = 1
				elseif input.KeyCode == Enum.KeyCode.LeftShift then control.Down = -1
				elseif input.KeyCode == Enum.KeyCode.LeftControl then 
					control.SpeedModifier = control.SpeedModifier == 1 and 2.5 or 1
					log("速度模式: " .. (control.SpeedModifier == 2.5 and "快" or "中"), "out")
				end
            end))

            table.insert(flightconnections, UserInputService.InputEnded:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
                if input.KeyCode == Enum.KeyCode.W then control.Forward = 0
				elseif input.KeyCode == Enum.KeyCode.S then control.Backward = 0
				elseif input.KeyCode == Enum.KeyCode.A then control.Left = 0
				elseif input.KeyCode == Enum.KeyCode.D then control.Right = 0
				elseif input.KeyCode == Enum.KeyCode.Space then control.Up = 0
				elseif input.KeyCode == Enum.KeyCode.LeftShift then control.Down = 0
                end
            end))

            table.insert(flightconnections, humanoid.Died:Connect(function()
                flightstauts = false
                StopFlight()
                log("角色已死亡，结束飞行 (传送模式)", "out")
            end))

            table.insert(flightconnections, rootpart:GetPropertyChangedSignal("Anchored"):Connect(function()
                if not rootpart.Anchored then
                    rootpart.Anchored = true
                end
            end))

            for _, connection in ipairs(flightconnections) do
                table.insert(connections, connection)
            end

            rootpart.Anchored = true
            flightstauts = true
            return true, "飞行 (传送模式) 已打开, 速度: " .. flyspeed
        elseif move == "platform" or move == "p" then
            if args[2] then
                return false, "平台飞行模式不需要指定速度参数!"
            end

            flightobjects.PlatformPart = Instance.new("Part")
            flightobjects.PlatformPart.Name = "PlatformPart_Flight"
            flightobjects.PlatformPart.Size = Vector3.new(2, 0.2, 1.5)
            flightobjects.PlatformPart.Anchored = true
            flightobjects.PlatformPart.CanCollide = true 
            flightobjects.PlatformPart.Transparency = 0.9
            flightobjects.PlatformPart.CastShadow = false
            flightobjects.PlatformPart.CFrame = rootpart.CFrame * CFrame.new(0, flightobjects.floatvalue, 0)
            flightobjects.PlatformPart.Parent = rootpart

            table.insert(flightconnections, RunService.Heartbeat:Connect(function()
                if not rootpart then 
                    return false, "无法获取 HumanoidRootPart, 结束飞行 (平台模式)"
                end
                
                local pp = flightobjects.PlatformPart

                if not pp or not pp.Parent then
                    local nowtime = os.clock()
                    if nowtime - lastrebuildtime < 0.5 then return end
                    lastrebuildtime = nowtime
                    log("平台组件丢失，正在重建...", "out")

                    if pp then pp:Destroy() end

                    flightobjects.PlatformPart = Instance.new("Part")
                    flightobjects.PlatformPart.Name = "PlatformPart_Flight"
                    flightobjects.PlatformPart.Size = Vector3.new(2, 0.2, 1.5)
                    flightobjects.PlatformPart.Anchored = true
                    flightobjects.PlatformPart.CanCollide = true 
                    flightobjects.PlatformPart.Transparency = 0.9
                    flightobjects.PlatformPart.CastShadow = false
                    flightobjects.PlatformPart.CFrame = rootpart.CFrame * CFrame.new(0, flightobjects.floatvalue, 0)
                    flightobjects.PlatformPart.Parent = rootpart
                    return
                end

                flightobjects.PlatformPart.CFrame = rootpart.CFrame * CFrame.new(0, flightobjects.floatvalue / 10, 0)
            end))

            table.insert(flightconnections, UserInputService.InputBegan:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
				if input.KeyCode == Enum.KeyCode.Space then flightobjects.floatvalue += 5
				elseif input.KeyCode == Enum.KeyCode.LeftShift then flightobjects.floatvalue -= 5
                end
            end))

            table.insert(flightconnections, UserInputService.InputEnded:Connect(function(input)
                if UserInputService:GetFocusedTextBox() ~= nil or guistatus ~= "active" then return end
                if input.KeyCode == Enum.KeyCode.Space then flightobjects.floatvalue -= 5
				elseif input.KeyCode == Enum.KeyCode.LeftShift then flightobjects.floatvalue += 5
                end
            end))

            table.insert(flightconnections, humanoid.Died:Connect(function()
                flightstauts = false
                StopFlight()
                log("角色已死亡，结束飞行 (平台模式)", "out")
            end))

            for _, connection in ipairs(flightconnections) do
                table.insert(connections, connection)
            end

            flightstauts = true
            return true, "飞行 (平台模式) 已打开"
        elseif move == "disabled" or move == "off" then
            flightstauts = false
            StopFlight()
            return true, "飞行已关闭"
        end
        return false, "未知错误"
    end
})

RegisterCommand("help", {
    aliases = {"?"},
    usage = {";help [指令名]"},
    description = "显示所有指令或查看特定指令的详细信息",
    handler = function(args, _, _)
        if #args == 0 then
            log("命令格式: <>内为必填项 {}内为选填项 []内为配置项", "out")
            log("========== 可用指令列表 ==========", "out")
            for cmdname, cmdinfo in pairs(commandlist) do
                local usage = table.concat(cmdinfo.usage, " / ")
                log(string.format("%s - %s - %s", cmdname, usage, cmdinfo.description), "out")
            end
            log("==================================", "out")
            return true, "已显示所有指令"
        else
            local targetcmd = args[1]:lower()
            local mainname = commandmap[targetcmd]
            if not mainname then
                return false, "未知指令：" .. targetcmd
            end
            local cmd = commandlist[mainname]
            log("========== 指令详情 ==========", "out")
            log(string.format("指令名：%s", cmd.main), "out")
            log(string.format("别名：%s", table.concat(cmd.aliases, ", ")), "out")
            log(string.format("用法：%s", table.concat(cmd.usage, " / ")), "out")
            log(string.format("描述：%s", cmd.description), "out")
            log("==============================", "out")
            return true, "已显示指令详情"
        end
        return false, "未知错误"
    end
})

table.insert(connections, RunService.Heartbeat:Connect(function()
    if guistatus ~= "active" or not MainFrame.Visible then return end

    local fpstext, fpscolor = "--", COLOR_TEXT_NORMAL
    local success, fpsvalue = pcall(function()
        return math.floor(Stats.Workspace.FPS:GetValue())
    end)
    if success and fpsvalue then
        fpstext = fpsvalue
        if fpsvalue > 50 then
            fpscolor = COLOR_TEXT_GREEN
        elseif fpsvalue > 30 then
            fpscolor = COLOR_TEXT_YELLOW
        else
            fpscolor = COLOR_TEXT_RED
        end
    else
        fpstext = "--"
        fpscolor = COLOR_TEXT_NORMAL
    end

    local pingtext, pingcolor = "--ms", COLOR_TEXT_NORMAL
    local success, pingvalue = pcall(function()
        return math.floor(Stats.Network.ServerStatsItem["Data Ping"]:GetValue())
    end)
    if success and pingvalue then
        pingtext = pingvalue .. "ms"
        if pingvalue < 130 then
            pingcolor = COLOR_TEXT_GREEN
        elseif pingvalue < 200 then
            pingcolor = COLOR_TEXT_YELLOW
        else
            pingcolor = COLOR_TEXT_RED
        end
    else
        pingtext = "--ms"
        pingcolor = COLOR_TEXT_NORMAL
    end

    local cputext, cpucolor = "--%", COLOR_TEXT_NORMAL
    local success, cpuvalue = pcall(function()
        return math.floor(Stats.PerformanceStats.CPU:GetValue())
    end)
    if success and cpuvalue then
        cputext = cpuvalue .. "%"
        if cpuvalue < 50 then
            cpucolor = COLOR_TEXT_GREEN
        elseif cpuvalue < 70 then
            cpucolor = COLOR_TEXT_YELLOW
        else
            cpucolor = COLOR_TEXT_RED
        end
    else
        cputext = "--%"
        cpucolor = COLOR_TEXT_NORMAL
    end

    local memorytext, memorycolor = "--MB", COLOR_TEXT_NORMAL
    local success, memoryvalue = pcall(function()
        return math.floor(Stats.PerformanceStats.Memory:GetValue())
    end)
    if success and memoryvalue then
        memorytext = memoryvalue .. "MB"
    else
        memorytext = "--MB"
        memorycolor = COLOR_TEXT_NORMAL
    end

    local postext, poscolor = "(X:? Y:? Z:?)", COLOR_TEXT_OVERLAY
    if Localcam and Localcam.Focus then
        local pos = Localcam.Focus.Position
        postext = string.format("(X:%.1f Y:%.1f Z:%.1f)", pos.X, pos.Y, pos.Z)
        poscolor = COLOR_TEXT_NORMAL
    else 
        postext = "(X:? Y:? Z:?)"
        poscolor = COLOR_TEXT_NORMAL
    end

    local richtext = string.format(
        "FPS: <font color=\"#%02X%02X%02X\">%s</font> | Ping: <font color=\"#%02X%02X%02X\">%s</font> | CPU: <font color=\"#%02X%02X%02X\">%s</font> | Memory: <font color=\"#%02X%02X%02X\">%s</font> | Position: <font color=\"#%02X%02X%02X\">%s</font>",
        math.floor(fpscolor.R * 255), math.floor(fpscolor.G * 255), math.floor(fpscolor.B * 255), fpstext,
        math.floor(pingcolor.R * 255), math.floor(pingcolor.G * 255), math.floor(pingcolor.B * 255), pingtext,
        math.floor(cpucolor.R * 255), math.floor(cpucolor.G * 255), math.floor(cpucolor.B * 255), cputext,
        math.floor(memorycolor.R * 255), math.floor(memorycolor.G * 255), math.floor(memorycolor.B * 255), memorytext,
        math.floor(poscolor.R * 255), math.floor(poscolor.G * 255), math.floor(poscolor.B * 255), postext
    )
    Text_Info.Text = richtext
end))

table.insert(connections, Version:GetAttributeChangedSignal("Status"):Connect(function() 
    log("收到信号, 当前状态为：" .. tostring(Version:GetAttribute("Status")), "out")
    if Version:GetAttribute("Status") == "destroy" and not guistatus ~= "active" then 
        log("收到销毁信号，正在销毁 GUI...", "out")
        DestroyNvi() 
    end 
end))

table.insert(connections, LogService.MessageOut:Connect(function(message, messagetype)
    if messagetype == Enum.MessageType.MessageOutput and not Config.Console.showoutput then return end
    if messagetype == Enum.MessageType.MessageWarning and not Config.Console.showwarn then return end
    if messagetype == Enum.MessageType.MessageError and not Config.Console.showerror then return end
    if messagetype == Enum.MessageType.MessageInfo and not Config.Console.showinfo then return end
    if not Scroll_ConsoleOutput or guistatus ~= "active" then return end
    if not message then return "" end
    
    local logtype = "out"
    if messagetype == Enum.MessageType.MessageOutput then
        logtype = "out"
    elseif messagetype == Enum.MessageType.MessageInfo then
        logtype = "info"
    elseif messagetype == Enum.MessageType.MessageError then
        logtype = "error"
    elseif messagetype == Enum.MessageType.MessageWarning then
        logtype = "warning"
    else 
        logtype = "unknown"
    end
    
    for _, keyword in ipairs(Config.Console.filterkeywords) do
        if message:find(keyword, 1, true) then
            return
        end
    end
    local timestamp, escapedtext = os.date("%H:%M:%S"), message:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    local typelabel, timestampcolor, contentcolor = "OUT", "#C8C8C8", COLOR_TEXT_NORMAL
    if logtype == "out" then
        typelabel = "OUT"
        timestampcolor = "#C8C8C8"
        contentcolor = COLOR_TEXT_NORMAL
    elseif logtype == "info" then
        typelabel = "INFO"
        timestampcolor = "#00A2FF"
        contentcolor = COLOR_TEXT_BLUE
    elseif logtype == "error" then
        typelabel = "ERROR"
        timestampcolor = "#FF6464"
        contentcolor = COLOR_TEXT_RED
    elseif logtype == "warning" then
        typelabel = "WARN"
        timestampcolor = "#FFFF64"
        contentcolor = COLOR_TEXT_YELLOW
    end

    local children, labelcount, r, g, b, logprefix = Scroll_ConsoleOutput:GetChildren(), 0, math.floor(contentcolor.R * 255), math.floor(contentcolor.G * 255), math.floor(contentcolor.B * 255), string.format('<font color="%s">[%s/%s]</font>', timestampcolor, timestamp, typelabel)
    local colorhex = string.format("%02X%02X%02X", r, g, b)
    local messagetext = string.format('%s <font color="#%s">%s</font>', logprefix, colorhex, escapedtext)

    local TextLabel = Instance.new("TextLabel")
    TextLabel.RichText = true
    TextLabel.Text = messagetext
    TextLabel.TextSize = 14
    TextLabel.Font = Enum.Font.Code
    TextLabel.BackgroundTransparency = 1
    TextLabel.TextXAlignment = Enum.TextXAlignment.Left
    TextLabel.TextYAlignment = Enum.TextYAlignment.Top
    TextLabel.TextWrapped = true
    TextLabel.ClipsDescendants = false
    TextLabel.AutomaticSize = Enum.AutomaticSize.Y
    TextLabel.Size = UDim2.new(1, -10, 0, 15)
    TextLabel.ZIndex = 13
    TextLabel.Parent = Scroll_ConsoleOutput
    TextLabel:SetAttribute("MessageType", typelabel)

    for _, child in pairs(children) do
        if child:IsA("TextLabel") then
            labelcount += 1
        end
    end
    if labelcount > Config.Console.maxmessages then
        local oldestlabel = children[1]
        if oldestlabel and oldestlabel:IsA("TextLabel") then
            oldestlabel:Destroy()
        end
    end
    if Config.Console.autoscroll then
        Scroll_ConsoleOutput.CanvasPosition = Vector2.new(0, 9e9)
    end
end))

table.insert(connections, TextBox_ConsoleInput.FocusLost:Connect(function(enterpressed: boolean)
    if guistatus ~= "active" or not MainFrame.Visible or not enterpressed then return end
    local text = TextBox_ConsoleInput.Text:match("^%s*(.-)%s*$")
    if text:find("^;") then
        ExecuteCommand(text)
        TextBox_ConsoleInput.Text = ""
    elseif text == "" then 
        TextBox_ConsoleInput.Text = ""
        log("输入了空内容", "out") 
        return 
    else
        loadstring(TextBox_ConsoleInput.Text)()
        TextBox_ConsoleInput.Text = ""
        log("控制台输入：" .. text, "out")
    end
end))

local dragging, dragstartpos, framestartpos, arrowkeypressed = false, nil, nil, false

table.insert(connections, TextBox_ConsoleInput:GetPropertyChangedSignal("Text"):Connect(function()
    if guistatus ~= "active" then return end
    if arrowkeypressed and TextBox_ConsoleInput.Text:sub(-1) == ";" then
        TextBox_ConsoleInput.Text = TextBox_ConsoleInput.Text:sub(1, -2)
        arrowkeypressed = false
        return
    end
    if TextBox_ConsoleInput.Text:match("^;.+") and TextBox_ConsoleInput.Text:sub(2):match("%S") then
        UpdateHintDisplay()
    else
        if Area_ConsoleInputHint.Visible then 
            Area_ConsoleInputHint.Visible = false
        end
    end
end))

table.insert(connections, UserInputService.InputBegan:Connect(function(input)
    if guistatus ~= "active" then return end

    if input.KeyCode == Enum.KeyCode.RightShift and UserInputService:GetKeysPressed()[1].KeyCode == Enum.KeyCode.RightShift and not UserInputService:GetFocusedTextBox() then
        MainFrame.Visible = not MainFrame.Visible
        log("GUI 状态已变为：" .. tostring(MainFrame.Visible), "out")
    elseif input.KeyCode == Enum.KeyCode.Semicolon and UserInputService:GetKeysPressed()[1].KeyCode == Enum.KeyCode.Semicolon and not UserInputService:GetFocusedTextBox() and MainFrame.Visible and Area_Console.Visible then
        log("按下分号键，正在聚焦命令输入框...", "out")
        TextBox_ConsoleInput:CaptureFocus()
    elseif input.KeyCode == Enum.KeyCode.Up and #commandinputlist > 0 and commandhistoryindex > 1 and not UserInputService:GetFocusedTextBox() and MainFrame.Visible and Area_Console.Visible then
        log("查看上一条命令输入...", "out")
        arrowkeypressed = true
        commandhistoryindex -= 1
        TextBox_ConsoleInput.Text = commandinputlist[commandhistoryindex]
    elseif input.KeyCode == Enum.KeyCode.Down and not commandhistoryindex == #commandinputlist and commandhistoryindex < #commandinputlist and not UserInputService:GetFocusedTextBox() and MainFrame.Visible and Area_Console.Visible then
        log("查看下一条命令输入...", "out")
        arrowkeypressed = true
        commandhistoryindex += 1
        TextBox_ConsoleInput.Text = commandinputlist[commandhistoryindex]
        TextBox_ConsoleInput.CursorPosition = #TextBox_ConsoleInput.Text + 1
    elseif input.KeyCode == Enum.KeyCode.Delete and UserInputService:GetKeysPressed()[1].KeyCode == Enum.KeyCode.Delete and not UserInputService:GetFocusedTextBox() then 
        DestroyNvi()
    elseif input.UserInputType == Enum.UserInputType.MouseButton1 and dragstauts and MainFrame.Visible and guistatus == "active" then
        local mousepos, guipos, guisize = Vector2.new(input.Position.X, input.Position.Y), Vector2.new(MainFrame.AbsolutePosition.X, MainFrame.AbsolutePosition.Y), Vector2.new(MainFrame.AbsoluteSize.X, MainFrame.AbsoluteSize.Y)
        if mousepos.X >= guipos.X and mousepos.X <= guipos.X + guisize.X and
            mousepos.Y >= guipos.Y and mousepos.Y <= guipos.Y + guisize.Y then
            dragging = true
            dragstartpos = mousepos
            framestartpos = Vector2.new(MainFrame.AbsolutePosition.X, MainFrame.AbsolutePosition.Y)
        else
            dragging = false
        end
    end
end))

table.insert(connections, UserInputService.InputChanged:Connect(function(input)
    if guistatus ~= "active" then return end

    if input.UserInputType == Enum.UserInputType.MouseMovement then
        local mousepos = Vector2.new(input.Position.X, input.Position.Y)
        if MainFrame.Visible then
            local guipos, guisize = Vector2.new(MainFrame.AbsolutePosition.X, MainFrame.AbsolutePosition.Y), Vector2.new(MainFrame.AbsoluteSize.X, MainFrame.AbsoluteSize.Y)
            if dragging then
                local newpos = Vector2.new(
                    math.clamp(framestartpos.X + (mousepos.X - dragstartpos.X), 0, Localcam.ViewportSize.X - MainFrame.AbsoluteSize.X),
                    math.clamp(framestartpos.Y + (mousepos.Y - dragstartpos.Y), 0, Localcam.ViewportSize.Y - MainFrame.AbsoluteSize.Y)
                )
                MainFrame.Position = UDim2.new(0, newpos.X, 0, newpos.Y)
            end
        end
    end
end))

table.insert(connections, UserInputService.InputEnded:Connect(function(input)
    if guistatus ~= "active" then return end

    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end))

log("成功注入 NVI(version-" .. VERSION_PREFIX .. VERSION_NUMBER .. "), 使用 右 Shift 打开菜单.", "out")
ScreenGui.Destroying:Connect(DestroyNvi)
