-- Tower Macro v1.5.4
-- Client-only recorder/player: keys 1-6, T and left mouse clicks.
-- No RemoteEvents and no server-side calls.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local RunService = game:GetService("RunService")
local CoreGui = game:GetService("CoreGui")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local CONFIG_FILE = "TowerMacro_" .. player.Name .. ".json"
local GUI_NAME = "TowerMacro_v154"
local sharedEnv = (getgenv and getgenv()) or _G

-- Auto Queue and Auto Challenge used to register two loaders for the same
-- teleport.  Xeno then executed two Tower Macro copies which fought over the
-- selected profile and could destabilize the client.  Keep one owner per job.
if sharedEnv.__TowerMacroActiveJobId == game.JobId then
    warn("[TowerMacro] Duplicate launch ignored for this server")
    return
end
sharedEnv.__TowerMacroActiveJobId = game.JobId

if type(sharedEnv.__TowerMacroShutdown) == "function" then
    pcall(sharedEnv.__TowerMacroShutdown)
end

local state = {
    profiles = {},
    selected = nil,
    expeditionProfiles = {},
    selectedExpedition = nil,
    autoQueue = true,
    repeatEnabled = true,
    smartRunning = false,
    smartToken = 0,
    cameraOriginalType = nil,
    expeditionCameraBound = false,
    destroyed = false,
    expeditionMode = nil,
    expeditionToken = 0,
    expeditionTimeline = 0,
    expeditionStarted = false,
    expeditionBlocked = true,
    expeditionAwaitingResume = false,
    expeditionResumeAt = 0,
    expeditionIndex = 1,
    expeditionEvents = {},
    expeditionSuppressUntil = 0,
    expeditionSequenceToken = 0,
    expeditionSequenceRunning = false,
    expeditionEditSlot = 1,
    expeditionDraftPoint = nil,
    expeditionRuntimeSlots = {},
    expeditionCheckpointCount = 0,
    expeditionCheckpointLatched = false,
    expeditionMapNeeded = false,
    expeditionMapRunning = false,
    expeditionDefeatSeenAt = 0,
    expeditionEncounterRunning = false,
    expeditionEncounterNextScan = 0,
    expeditionEncounterCachedPrompt = nil,
    expeditionEncounterCooldownUntil = 0,
    macroResultTriggered = false,
    recording = false,
    playing = false,
    recordStarted = 0,
    currentEvents = {},
    playToken = 0,
    towerRunning = false,
    towerToken = 0,
    towerFloor = nil,
    towerMap = nil,
    towerProfile = nil,
    mapProfiles = {
        ["rose kingdom"] = "Rose_Kingdom",
        ["school grounds"] = "School Grounds_ch",
        ["flower forest"] = "Flower_forest",
        ["king's tomb"] = "Kings_Tomb",
        ["kings tomb"] = "Kings_Tomb",
        ["fairy king forest"] = "Fairy_King_Forest_ch",
        ["east town"] = "East_Town",
    },
}

sharedEnv.__TowerMacroShutdown = function()
    state.destroyed = true
    state.recording = false
    state.playing = false
    state.smartRunning = false
    state.expeditionMode = nil
    state.playToken += 1
    state.smartToken += 1
    state.expeditionToken += 1
    state.expeditionSequenceToken += 1
    state.towerRunning = false
    state.towerToken += 1
    pcall(function() RunService:UnbindFromRenderStep("TowerMacroExpeditionCamera") end)
    if sharedEnv.__TowerMacroActiveJobId == game.JobId then
        sharedEnv.__TowerMacroActiveJobId = nil
    end
end

local function log(message)
    local line = "[TowerMacro] " .. tostring(message)
    print(line)
    if _G.__TowerMacroStatusLabel then
        _G.__TowerMacroStatusLabel.Text = tostring(message)
    end
end

local function serializeCFrame(cf)
    return {cf:GetComponents()}
end

local function deserializeCFrame(data)
    if type(data) ~= "table" or #data ~= 12 then return nil end
    return CFrame.new(table.unpack(data))
end

local function saveConfig()
    local ok, err = pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode({
            version = 2,
            selected = state.selected,
            profiles = state.profiles,
            selectedExpedition = state.selectedExpedition,
            expeditionProfiles = state.expeditionProfiles,
            autoQueueEnabled = state.autoQueue,
            mapProfiles = state.mapProfiles,
        }))
    end)
    if not ok then
        warn("[TowerMacro] Save failed:", err)
        return false
    end
    log("Saved: " .. CONFIG_FILE)
    return true
end

local function loadConfig()
    local ok, result = pcall(function()
        if not isfile(CONFIG_FILE) then return nil end
        return HttpService:JSONDecode(readfile(CONFIG_FILE))
    end)
    if not ok then
        warn("[TowerMacro] Load failed:", result)
        return
    end
    if type(result) == "table" then
        state.profiles = type(result.profiles) == "table" and result.profiles or {}
        state.selected = result.selected
        state.expeditionProfiles = type(result.expeditionProfiles) == "table"
            and result.expeditionProfiles or {}
        state.selectedExpedition = result.selectedExpedition
        if type(result.mapProfiles) == "table" then
            for map, profile in pairs(result.mapProfiles) do
                if type(map) == "string" and type(profile) == "string" then
                    state.mapProfiles[map:lower()] = profile
                end
            end
        end
        if type(result.autoQueueEnabled) == "boolean" then
            state.autoQueue = result.autoQueueEnabled
        end

        -- v1 -> v2: copy meaningful Expedition data out of normal macro profiles.
        if next(state.expeditionProfiles) == nil then
            for name, profile in pairs(state.profiles) do
                local expedition = type(profile.expedition) == "table"
                    and profile.expedition or nil
                local steps = expedition and expedition.steps
                if type(steps) == "table" and #steps > 0 then
                    state.expeditionProfiles[name] = {
                        name = name,
                        placeId = profile.placeId,
                        expedition = expedition,
                    }
                end
            end
        end
        if state.selected and not state.profiles[state.selected] then
            state.selected = nil
        end
        if state.selectedExpedition
            and not state.expeditionProfiles[state.selectedExpedition] then
            state.selectedExpedition = nil
        end
        if not state.selectedExpedition then
            local names = {}
            for name in pairs(state.expeditionProfiles) do table.insert(names, name) end
            table.sort(names)
            state.selectedExpedition = names[1]
        end
    end
end

loadConfig()

-- Automatically select a saved profile for the current place.
do
    local selectedProfile = state.selected and state.profiles[state.selected]
    if not selectedProfile or tonumber(selectedProfile.placeId) ~= game.PlaceId then
        local matches = {}
        for name, profile in pairs(state.profiles) do
            if tonumber(profile.placeId) == game.PlaceId then
                table.insert(matches, name)
            end
        end
        table.sort(matches)
        state.selected = matches[1]
        if state.selected then saveConfig() end
    end
end

pcall(function()
    for _, child in ipairs(CoreGui:GetChildren()) do
        if child.Name == GUI_NAME or child.Name:match("^TowerMacro_v") then
            child:Destroy()
        end
    end
end)

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = CoreGui end)
if not gui.Parent then gui.Parent = player:WaitForChild("PlayerGui") end

local frame = Instance.new("Frame")
frame.Name = "Window"
frame.Size = UDim2.fromOffset(360, 440)
frame.Position = UDim2.new(0, 24, 0.5, -220)
frame.BackgroundColor3 = Color3.fromRGB(15, 17, 25)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
local frameStroke = Instance.new("UIStroke", frame)
frameStroke.Color = Color3.fromRGB(72, 85, 135)
frameStroke.Thickness = 1

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -24, 0, 38)
title.Position = UDim2.fromOffset(12, 0)
title.BackgroundTransparency = 1
title.Text = "TOWER MACRO  ·  v1.5.2"
title.TextColor3 = Color3.fromRGB(225, 230, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(24, 24)
closeButton.Position = UDim2.new(1, -32, 0, 7)
closeButton.BackgroundColor3 = Color3.fromRGB(62, 31, 40)
closeButton.Text = "×"
closeButton.TextColor3 = Color3.fromRGB(255, 205, 215)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.AutoButtonColor = true
closeButton.Parent = frame
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 6)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -24, 0, 30)
status.Position = UDim2.fromOffset(12, 0)
status.BackgroundColor3 = Color3.fromRGB(21, 24, 35)
status.Text = "Ready"
status.TextColor3 = Color3.fromRGB(145, 160, 205)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextWrapped = true
status.Parent = frame
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 7)
_G.__TowerMacroStatusLabel = status

local function makeButton(text, x, y, w, color)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(w, 30)
    button.Position = UDim2.fromOffset(x, y)
    button.BackgroundColor3 = color or Color3.fromRGB(33, 38, 57)
    button.Text = text
    button.TextColor3 = Color3.fromRGB(230, 234, 255)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 11
    button.AutoButtonColor = true
    button.Parent = frame
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 7)
    return button
end

local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.fromOffset(210, 30)
nameBox.Position = UDim2.fromOffset(12, 43)
nameBox.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
nameBox.PlaceholderText = "Macro name"
nameBox.Text = state.selected or ""
nameBox.TextColor3 = Color3.fromRGB(235, 238, 255)
nameBox.PlaceholderColor3 = Color3.fromRGB(95, 105, 140)
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 12
nameBox.ClearTextOnFocus = false
nameBox.Parent = frame
Instance.new("UICorner", nameBox).CornerRadius = UDim.new(0, 7)

local selectButton = makeButton("CHOOSE ▼", 228, 43, 90)
local cameraButton = makeButton("SAVE START", 12, 81, 150)
local deleteButton = makeButton("DELETE", 168, 81, 150, Color3.fromRGB(57, 31, 40))
local recordButton = makeButton("RECORD", 12, 127, 98, Color3.fromRGB(65, 31, 41))
local stopButton = makeButton("STOP", 116, 127, 98)
local playButton = makeButton("PLAY", 220, 127, 98, Color3.fromRGB(28, 62, 49))
local autoQueueButton = makeButton("QUEUE NEXT TP", 12, 165, 150)
local testButton = makeButton("TEST INPUT", 168, 165, 150)
local listButton = makeButton("PRINT PROFILES", 12, 203, 150)
local restoreButton = makeButton("RESTORE START", 168, 203, 150)
local repeatButton = makeButton("REPEAT: OFF", 12, 241, 150)
state.raidPopupButton = makeButton("RAID REWARD DISMISS: OFF", 12, 241, 150)
local addKeyButton = makeButton("ADD KEY EVENT", 168, 279, 150)
local runProfileButton = makeButton("RUN PROFILE", 12, 317, 306, Color3.fromRGB(32, 77, 59))
challengeSettingsButton = makeButton("AUTO CHALLENGE SETTINGS", 12, 355, 306,
    Color3.fromRGB(42, 57, 86))
local function setRunProfileActive(active)
    runProfileButton.Text = active and "STOP PROFILE" or "RUN PROFILE"
    runProfileButton.BackgroundColor3 = active
        and Color3.fromRGB(105, 37, 48) or Color3.fromRGB(32, 77, 59)
end

local timeBox = Instance.new("TextBox")
timeBox.Size = UDim2.fromOffset(72, 30)
timeBox.Position = UDim2.fromOffset(12, 279)
timeBox.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
timeBox.PlaceholderText = "sec"
timeBox.Text = "1.0"
timeBox.TextColor3 = Color3.fromRGB(235, 238, 255)
timeBox.PlaceholderColor3 = Color3.fromRGB(95, 105, 140)
timeBox.Font = Enum.Font.Gotham
timeBox.TextSize = 11
timeBox.ClearTextOnFocus = false
timeBox.Parent = frame
Instance.new("UICorner", timeBox).CornerRadius = UDim.new(0, 7)

local keyBox = Instance.new("TextBox")
keyBox.Size = UDim2.fromOffset(72, 30)
keyBox.Position = UDim2.fromOffset(90, 279)
keyBox.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
keyBox.PlaceholderText = "key"
keyBox.Text = "F"
keyBox.TextColor3 = Color3.fromRGB(235, 238, 255)
keyBox.PlaceholderColor3 = Color3.fromRGB(95, 105, 140)
keyBox.Font = Enum.Font.Gotham
keyBox.TextSize = 11
keyBox.ClearTextOnFocus = false
keyBox.Parent = frame
Instance.new("UICorner", keyBox).CornerRadius = UDim.new(0, 7)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -24, 0, 32)
hint.Position = UDim2.fromOffset(12, 315)
hint.BackgroundTransparency = 1
hint.Text = "Editor: time + key inserts one press  |  Right Ctrl: hide/show"
hint.TextColor3 = Color3.fromRGB(105, 115, 150)
hint.Font = Enum.Font.Gotham
hint.TextSize = 10
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Parent = frame

local smartTitle = Instance.new("TextLabel")
smartTitle.Size = UDim2.new(1, -24, 0, 20)
smartTitle.Position = UDim2.fromOffset(12, 343)
smartTitle.BackgroundTransparency = 1
smartTitle.Text = "SMART EXTRA UNITS"
smartTitle.TextColor3 = Color3.fromRGB(120, 205, 175)
smartTitle.Font = Enum.Font.GothamBold
smartTitle.TextSize = 11
smartTitle.TextXAlignment = Enum.TextXAlignment.Left
smartTitle.Parent = frame

local function makeSmallBox(x, placeholder, value)
    local box = Instance.new("TextBox")
    box.Size = UDim2.fromOffset(94, 28)
    box.Position = UDim2.fromOffset(x, 367)
    box.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
    box.PlaceholderText = placeholder
    box.Text = value
    box.TextColor3 = Color3.fromRGB(235, 238, 255)
    box.PlaceholderColor3 = Color3.fromRGB(95, 105, 140)
    box.Font = Enum.Font.Gotham
    box.TextSize = 10
    box.ClearTextOnFocus = false
    box.Parent = frame
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 7)
    return box
end

local smartWaveBox = makeSmallBox(12, "wave", "8")
local smartReserveBox = makeSmallBox(118, "reserve", "5000")
local smartSlotBox = makeSmallBox(224, "slot 1-6", "6")
local smartPointButton = makeButton("F7: ADD POINT", 12, 403, 98)
local smartClearButton = makeButton("CLEAR POINTS", 116, 403, 98)
local smartRunButton = makeButton("SMART START", 220, 403, 98, Color3.fromRGB(28, 62, 49))

local smartInfo = Instance.new("TextLabel")
smartInfo.Size = UDim2.new(1, -24, 0, 28)
smartInfo.Position = UDim2.fromOffset(12, 438)
smartInfo.BackgroundTransparency = 1
smartInfo.Text = "Points: 0  |  waiting for configuration"
smartInfo.TextColor3 = Color3.fromRGB(105, 125, 155)
smartInfo.Font = Enum.Font.Gotham
smartInfo.TextSize = 10
smartInfo.TextXAlignment = Enum.TextXAlignment.Left
smartInfo.Parent = frame

local smartEnabledButton = makeButton("SMART: ENABLED", 12, 470, 150, Color3.fromRGB(28, 62, 49))
local smartSlotButtons = {}
for slot = 1, 6 do
    local button = makeButton(tostring(slot), 12, 470, 48)
    button.TextSize = 12
    smartSlotButtons[slot] = button
end

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -24, 0, 30)
tabBar.Position = UDim2.fromOffset(12, 38)
tabBar.BackgroundTransparency = 1
tabBar.Parent = frame

local function makeTab(text, x, width)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(width or 78, 28)
    button.Position = UDim2.fromOffset(x, 0)
    button.BackgroundColor3 = Color3.fromRGB(27, 31, 46)
    button.Text = text
    button.TextColor3 = Color3.fromRGB(130, 140, 175)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 10
    button.Parent = tabBar
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    return button
end

local macroTabButton = makeTab("MACRO", 0, 64)
local expeditionTabButton = makeTab("EXPED.", 68, 64)
local towerTabButton = makeTab("TOWER", 136, 64)
local dpsTabButton = makeTab("DPS", 204, 64)
local statusTabButton = makeTab("STATUS", 272, 64)

local function makePage(name)
    local page = Instance.new("Frame")
    page.Name = name
    page.Size = UDim2.new(1, -24, 1, -80)
    page.Position = UDim2.fromOffset(12, 76)
    page.BackgroundTransparency = 1
    page.Parent = frame
    return page
end

local macroPage = makePage("MacroPage")
local smartPage = makePage("SmartPage")
smartPage.Visible = false
local expeditionPage = makePage("ExpeditionPage")
local towerPage = makePage("TowerPage")
local dpsPage = makePage("DPSPage")
local statusPage = makePage("StatusPage")

local function move(object, parent, x, y, w, h)
    object.Parent = parent
    object.Position = UDim2.fromOffset(x, y)
    if w and h then object.Size = UDim2.fromOffset(w, h) end
end

move(nameBox, macroPage, 0, 0, 216, 30)
move(selectButton, macroPage, 222, 0, 114, 30)
move(runProfileButton, macroPage, 0, 42, 336, 36)
move(autoQueueButton, macroPage, 0, 88, 336, 32)

local towerUI = {}
towerUI.toggle = makeButton("START TOWER AUTO", 0, 0, 336, Color3.fromRGB(28, 73, 54))
move(towerUI.toggle, towerPage, 0, 0, 336, 38)

towerUI.status = Instance.new("TextLabel")
towerUI.status.Size = UDim2.fromOffset(336, 82)
towerUI.status.Position = UDim2.fromOffset(0, 50)
towerUI.status.BackgroundColor3 = Color3.fromRGB(20, 25, 38)
towerUI.status.Text = "Ready\nStart on a floor, Start Game window, or result screen."
towerUI.status.TextColor3 = Color3.fromRGB(182, 198, 228)
towerUI.status.Font = Enum.Font.Gotham
towerUI.status.TextSize = 10
towerUI.status.TextWrapped = true
towerUI.status.Parent = towerPage
Instance.new("UICorner", towerUI.status).CornerRadius = UDim.new(0, 7)

towerUI.help = Instance.new("TextLabel")
towerUI.help.Size = UDim2.fromOffset(336, 86)
towerUI.help.Position = UDim2.fromOffset(0, 144)
towerUI.help.BackgroundColor3 = Color3.fromRGB(18, 22, 33)
towerUI.help.Text = "MAP PROFILE · TOWER + CHALLENGE\nSelect a map, choose a normal macro on the MACRO tab,\nthen assign that profile here. Settings are saved locally."
towerUI.help.TextColor3 = Color3.fromRGB(145, 163, 198)
towerUI.help.Font = Enum.Font.Code
towerUI.help.TextSize = 10
towerUI.help.TextXAlignment = Enum.TextXAlignment.Left
towerUI.help.TextYAlignment = Enum.TextYAlignment.Top
towerUI.help.Parent = towerPage
Instance.new("UICorner", towerUI.help).CornerRadius = UDim.new(0, 7)
towerUI.map = makeButton("MAP: ROSE KINGDOM", 0, 240, 336, Color3.fromRGB(40, 49, 75))
move(towerUI.map, towerPage, 0, 240, 336, 32)
towerUI.assign = makeButton("ASSIGN SELECTED MACRO", 0, 282, 336, Color3.fromRGB(45, 62, 91))
move(towerUI.assign, towerPage, 0, 282, 336, 32)
towerUI.mapping = Instance.new("TextLabel")
towerUI.mapping.Size = UDim2.fromOffset(336, 34)
towerUI.mapping.Position = UDim2.fromOffset(0, 324)
towerUI.mapping.BackgroundColor3 = Color3.fromRGB(20, 25, 38)
towerUI.mapping.TextColor3 = Color3.fromRGB(160, 180, 218)
towerUI.mapping.Font = Enum.Font.Gotham
towerUI.mapping.TextSize = 9
towerUI.mapping.Parent = towerPage
Instance.new("UICorner", towerUI.mapping).CornerRadius = UDim.new(0, 6)
move(playButton, macroPage, 0, 130, 336, 32)
playButton.Text = "OPEN MACRO SETTINGS"
playButton.BackgroundColor3 = Color3.fromRGB(40, 48, 73)
move(challengeSettingsButton, macroPage, 0, 172, 336, 32)

-- The normal Macro tab only keeps everyday controls visible. Recording and
-- editing tools are moved into an occasional-use side panel.
;(function()
    local settingsFrame = Instance.new("Frame")
    settingsFrame.Name = "MacroSettings"
    settingsFrame.Size = UDim2.fromOffset(360, 338)
    settingsFrame.Position = UDim2.new(1, 8, 0, 38)
    settingsFrame.BackgroundColor3 = Color3.fromRGB(16, 19, 29)
    settingsFrame.BorderSizePixel = 0
    settingsFrame.Visible = false
    settingsFrame.ZIndex = 20
    settingsFrame.Parent = frame
    Instance.new("UICorner", settingsFrame).CornerRadius = UDim.new(0, 10)
    local stroke = Instance.new("UIStroke", settingsFrame)
    stroke.Color = Color3.fromRGB(67, 82, 126)

    local settingsTitle = Instance.new("TextLabel")
    settingsTitle.Size = UDim2.new(1, -52, 0, 38)
    settingsTitle.Position = UDim2.fromOffset(14, 0)
    settingsTitle.BackgroundTransparency = 1
    settingsTitle.Text = "MACRO SETTINGS"
    settingsTitle.TextColor3 = Color3.fromRGB(225, 232, 255)
    settingsTitle.Font = Enum.Font.GothamBold
    settingsTitle.TextSize = 13
    settingsTitle.TextXAlignment = Enum.TextXAlignment.Left
    settingsTitle.ZIndex = 21
    settingsTitle.Parent = settingsFrame

    local settingsClose = Instance.new("TextButton")
    settingsClose.Size = UDim2.fromOffset(26, 26)
    settingsClose.Position = UDim2.new(1, -35, 0, 6)
    settingsClose.BackgroundColor3 = Color3.fromRGB(58, 34, 45)
    settingsClose.Text = "X"
    settingsClose.TextColor3 = Color3.fromRGB(255, 215, 225)
    settingsClose.Font = Enum.Font.GothamBold
    settingsClose.TextSize = 13
    settingsClose.ZIndex = 22
    settingsClose.Parent = settingsFrame
    Instance.new("UICorner", settingsClose).CornerRadius = UDim.new(0, 6)

    move(cameraButton, settingsFrame, 12, 44, 164, 30)
    move(deleteButton, settingsFrame, 184, 44, 164, 30)
    move(recordButton, settingsFrame, 12, 82, 106, 30)
    move(stopButton, settingsFrame, 127, 82, 106, 30)
    move(restoreButton, settingsFrame, 242, 82, 106, 30)
    move(repeatButton, settingsFrame, 12, 120, 336, 30)
    move(state.raidPopupButton, settingsFrame, 12, 158, 336, 30)
    move(timeBox, settingsFrame, 12, 198, 74, 30)
    move(keyBox, settingsFrame, 94, 198, 74, 30)
    move(addKeyButton, settingsFrame, 176, 198, 172, 30)
    move(hint, settingsFrame, 12, 240, 336, 48)

    for _, control in ipairs({
        cameraButton, deleteButton, recordButton, stopButton, restoreButton,
        repeatButton, state.raidPopupButton, timeBox, keyBox, addKeyButton, hint,
    }) do
        control.ZIndex = 21
    end

    local function closeSettings()
        settingsFrame.Visible = false
        playButton.Text = "OPEN MACRO SETTINGS"
    end
    playButton.MouseButton1Click:Connect(function()
        settingsFrame.Visible = not settingsFrame.Visible
        playButton.Text = settingsFrame.Visible
            and "CLOSE MACRO SETTINGS" or "OPEN MACRO SETTINGS"
    end)
    settingsClose.MouseButton1Click:Connect(closeSettings)
    macroPage:GetPropertyChangedSignal("Visible"):Connect(function()
        if not macroPage.Visible then closeSettings() end
    end)
end)()
listButton.Visible = false
testButton.Visible = false

move(smartEnabledButton, smartPage, 0, 0, 164, 30)
move(smartRunButton, smartPage, 172, 0, 164, 30)
for slot, button in ipairs(smartSlotButtons) do
    move(button, smartPage, (slot - 1) * 56, 40, 50, 36)
end
move(smartWaveBox, smartPage, 0, 86, 104, 30)
move(smartReserveBox, smartPage, 116, 86, 104, 30)
move(smartSlotBox, smartPage, 232, 86, 104, 30)
smartSlotBox.Visible = false
move(smartPointButton, smartPage, 0, 126, 106, 30)
move(smartClearButton, smartPage, 115, 126, 106, 30)
move(smartTitle, smartPage, 230, 126, 106, 30)
smartTitle.Text = "F7 ON MAP"
smartTitle.TextXAlignment = Enum.TextXAlignment.Center
move(smartInfo, smartPage, 0, 166, 336, 44)

move(status, statusPage, 0, 0, 336, 66)
local statusDetails = Instance.new("TextLabel")
statusDetails.Size = UDim2.new(1, 0, 0, 190)
statusDetails.Position = UDim2.fromOffset(0, 78)
statusDetails.BackgroundColor3 = Color3.fromRGB(21, 24, 35)
statusDetails.Text = "Waiting for game UI..."
statusDetails.TextColor3 = Color3.fromRGB(185, 195, 225)
statusDetails.Font = Enum.Font.Code
statusDetails.TextSize = 12
statusDetails.TextWrapped = true
statusDetails.TextXAlignment = Enum.TextXAlignment.Left
statusDetails.TextYAlignment = Enum.TextYAlignment.Top
statusDetails.Parent = statusPage
Instance.new("UICorner", statusDetails).CornerRadius = UDim.new(0, 7)

local expeditionRecordButton = makeButton("RECORD RUN", 0, 0, 106, Color3.fromRGB(75, 34, 45))
local expeditionStopButton = makeButton("STOP", 0, 0, 106, Color3.fromRGB(52, 40, 55))
local expeditionAutoButton = makeButton("AUTO RUN", 0, 0, 106, Color3.fromRGB(31, 72, 54))
local expeditionSaveStartButton = makeButton("SAVE EXP START", 0, 0, 164)
local expeditionClearButton = makeButton("CLEAR TIMELINE", 0, 0, 164, Color3.fromRGB(58, 35, 42))
move(expeditionRecordButton, expeditionPage, 0, 0, 106, 32)
move(expeditionStopButton, expeditionPage, 115, 0, 106, 32)
move(expeditionAutoButton, expeditionPage, 230, 0, 106, 32)
move(expeditionSaveStartButton, expeditionPage, 0, 42, 164, 30)
move(expeditionClearButton, expeditionPage, 172, 42, 164, 30)

local expeditionStatus = Instance.new("TextLabel")
expeditionStatus.Size = UDim2.new(1, 0, 0, 72)
expeditionStatus.Position = UDim2.fromOffset(0, 84)
expeditionStatus.BackgroundColor3 = Color3.fromRGB(21, 25, 36)
expeditionStatus.Text = "Idle · waiting for configuration"
expeditionStatus.TextColor3 = Color3.fromRGB(155, 180, 210)
expeditionStatus.Font = Enum.Font.Gotham
expeditionStatus.TextSize = 11
expeditionStatus.TextWrapped = true
expeditionStatus.Parent = expeditionPage
Instance.new("UICorner", expeditionStatus).CornerRadius = UDim.new(0, 7)

local expeditionHint = Instance.new("TextLabel")
expeditionHint.Size = UDim2.new(1, 0, 0, 94)
expeditionHint.Position = UDim2.fromOffset(0, 168)
expeditionHint.BackgroundTransparency = 1
expeditionHint.Text = "RECORD RUN automatically presses the first checkpoint.\n"
    .. "Timeline pauses on Continue and upgrade prompts.\n"
    .. "AUTO RUN repeats forever after Defeat → Repeat Stage."
expeditionHint.TextColor3 = Color3.fromRGB(105, 120, 150)
expeditionHint.Font = Enum.Font.Gotham
expeditionHint.TextSize = 10
expeditionHint.TextWrapped = true
expeditionHint.TextXAlignment = Enum.TextXAlignment.Left
expeditionHint.TextYAlignment = Enum.TextYAlignment.Top
expeditionHint.Parent = expeditionPage

-- Conditional Expedition sequence editor (v0.8).
-- The old timeline controls remain in the file for config compatibility,
-- but the page now exposes money-driven PLACE / UPGRADE / AUTO steps.
expeditionRecordButton.Visible = false
expeditionSaveStartButton.Visible = false
expeditionClearButton.Visible = false
expeditionHint.Visible = false

local expeditionNameBox = Instance.new("TextBox")
expeditionNameBox.Size = UDim2.fromOffset(216, 30)
expeditionNameBox.BackgroundColor3 = Color3.fromRGB(24, 28, 42)
expeditionNameBox.Text = ""
expeditionNameBox.PlaceholderText = "Expedition profile name"
expeditionNameBox.PlaceholderColor3 = Color3.fromRGB(95, 105, 140)
expeditionNameBox.TextColor3 = Color3.fromRGB(230, 235, 255)
expeditionNameBox.Font = Enum.Font.Gotham
expeditionNameBox.TextSize = 11
expeditionNameBox.ClearTextOnFocus = false
expeditionNameBox.Parent = expeditionPage
Instance.new("UICorner", expeditionNameBox).CornerRadius = UDim.new(0, 6)
move(expeditionNameBox, expeditionPage, 0, 0, 216, 30)

local expeditionSelectButton = makeButton("CHOOSE", 0, 0, 114)
move(expeditionSelectButton, expeditionPage, 222, 0, 114, 30)

local expeditionSlotButtons = {}
for slot = 1, 6 do
    local button = makeButton(tostring(slot), 0, 0, 50)
    button.TextSize = 12
    move(button, expeditionPage, (slot - 1) * 56, 38, 50, 30)
    expeditionSlotButtons[slot] = button
end

local expeditionPointButton = makeButton("SAVE CAMERA", 0, 0, 106)
local expeditionAddPlaceButton = makeButton("ADD PLACE", 0, 0, 106, Color3.fromRGB(31, 65, 52))
local expeditionAddUpgradeButton = makeButton("ADD UPGRADE", 0, 0, 106, Color3.fromRGB(50, 43, 75))
move(expeditionPointButton, expeditionPage, 0, 76, 106, 30)
move(expeditionAddPlaceButton, expeditionPage, 115, 76, 106, 30)
move(expeditionAddUpgradeButton, expeditionPage, 230, 76, 106, 30)

local expeditionAddMaxButton = makeButton("UPGRADE MAX", 0, 0, 106, Color3.fromRGB(54, 44, 76))
local expeditionAddAutoButton = makeButton("ADD AUTO", 0, 0, 106, Color3.fromRGB(41, 62, 75))
local expeditionUndoButton = makeButton("UNDO LAST", 0, 0, 106, Color3.fromRGB(67, 42, 43))
move(expeditionAddMaxButton, expeditionPage, 0, 114, 106, 30)
move(expeditionAddAutoButton, expeditionPage, 115, 114, 106, 30)
move(expeditionUndoButton, expeditionPage, 230, 114, 106, 30)

move(expeditionAutoButton, expeditionPage, 0, 152, 164, 32)
expeditionAutoButton.Text = "RUN SEQUENCE"
move(expeditionStopButton, expeditionPage, 172, 152, 164, 32)

move(expeditionStatus, expeditionPage, 0, 192, 336, 44)

local expeditionStepList = Instance.new("TextLabel")
expeditionStepList.Size = UDim2.new(1, 0, 0, 72)
expeditionStepList.Position = UDim2.fromOffset(0, 244)
expeditionStepList.BackgroundColor3 = Color3.fromRGB(21, 25, 36)
expeditionStepList.Text = "No conditional steps"
expeditionStepList.TextColor3 = Color3.fromRGB(170, 185, 215)
expeditionStepList.Font = Enum.Font.Code
expeditionStepList.TextSize = 10
expeditionStepList.TextWrapped = false
expeditionStepList.TextXAlignment = Enum.TextXAlignment.Left
expeditionStepList.TextYAlignment = Enum.TextYAlignment.Top
expeditionStepList.Parent = expeditionPage
Instance.new("UICorner", expeditionStepList).CornerRadius = UDim.new(0, 7)

local refreshExpeditionSequenceVisual

local expeditionRouteButton = makeButton(
    "ROUTE: CURSED",
    0,
    0,
    336,
    Color3.fromRGB(43, 58, 92)
)
move(expeditionRouteButton, expeditionPage, 0, 324, 336, 30)

-- Keep the everyday Expedition page compact. Editing controls live in a
-- separate panel that follows the main window and is opened only when needed.
move(expeditionAutoButton, expeditionPage, 0, 42, 164, 34)
move(expeditionStopButton, expeditionPage, 172, 42, 164, 34)
move(expeditionStatus, expeditionPage, 0, 86, 336, 78)

local expeditionSettingsButton = makeButton(
    "OPEN EXPEDITION SETTINGS",
    0,
    0,
    336,
    Color3.fromRGB(40, 48, 73)
)
move(expeditionSettingsButton, expeditionPage, 0, 174, 336, 32)

local expeditionSettingsFrame = Instance.new("Frame")
expeditionSettingsFrame.Name = "ExpeditionSettings"
expeditionSettingsFrame.Size = UDim2.fromOffset(360, 366)
expeditionSettingsFrame.Position = UDim2.new(1, 8, 0, 38)
expeditionSettingsFrame.BackgroundColor3 = Color3.fromRGB(16, 19, 29)
expeditionSettingsFrame.BorderSizePixel = 0
expeditionSettingsFrame.Visible = false
expeditionSettingsFrame.ZIndex = 20
expeditionSettingsFrame.Parent = frame
Instance.new("UICorner", expeditionSettingsFrame).CornerRadius = UDim.new(0, 10)
local expeditionSettingsStroke = Instance.new("UIStroke", expeditionSettingsFrame)
expeditionSettingsStroke.Color = Color3.fromRGB(67, 82, 126)

local expeditionSettingsTitle = Instance.new("TextLabel")
expeditionSettingsTitle.Size = UDim2.new(1, -52, 0, 38)
expeditionSettingsTitle.Position = UDim2.fromOffset(14, 0)
expeditionSettingsTitle.BackgroundTransparency = 1
expeditionSettingsTitle.Text = "EXPEDITION SETTINGS"
expeditionSettingsTitle.TextColor3 = Color3.fromRGB(225, 232, 255)
expeditionSettingsTitle.Font = Enum.Font.GothamBold
expeditionSettingsTitle.TextSize = 13
expeditionSettingsTitle.TextXAlignment = Enum.TextXAlignment.Left
expeditionSettingsTitle.ZIndex = 21
expeditionSettingsTitle.Parent = expeditionSettingsFrame

local expeditionSettingsClose = Instance.new("TextButton")
expeditionSettingsClose.Size = UDim2.fromOffset(26, 26)
expeditionSettingsClose.Position = UDim2.new(1, -35, 0, 6)
expeditionSettingsClose.BackgroundColor3 = Color3.fromRGB(58, 34, 45)
expeditionSettingsClose.Text = "×"
expeditionSettingsClose.TextColor3 = Color3.fromRGB(255, 215, 225)
expeditionSettingsClose.Font = Enum.Font.GothamBold
expeditionSettingsClose.TextSize = 15
expeditionSettingsClose.ZIndex = 22
expeditionSettingsClose.Parent = expeditionSettingsFrame
Instance.new("UICorner", expeditionSettingsClose).CornerRadius = UDim.new(0, 6)

for slot, button in ipairs(expeditionSlotButtons) do
    move(button, expeditionSettingsFrame, 12 + (slot - 1) * 56, 44, 50, 30)
    button.ZIndex = 21
end
move(expeditionPointButton, expeditionSettingsFrame, 12, 82, 106, 30)
move(expeditionAddPlaceButton, expeditionSettingsFrame, 127, 82, 106, 30)
move(expeditionAddUpgradeButton, expeditionSettingsFrame, 242, 82, 106, 30)
move(expeditionAddMaxButton, expeditionSettingsFrame, 12, 120, 106, 30)
move(expeditionAddAutoButton, expeditionSettingsFrame, 127, 120, 106, 30)
move(expeditionUndoButton, expeditionSettingsFrame, 242, 120, 106, 30)
move(expeditionStepList, expeditionSettingsFrame, 12, 160, 336, 112)
move(expeditionRouteButton, expeditionSettingsFrame, 12, 322, 336, 30)

for _, control in ipairs({
    expeditionPointButton, expeditionAddPlaceButton, expeditionAddUpgradeButton,
    expeditionAddMaxButton, expeditionAddAutoButton, expeditionUndoButton,
    expeditionStepList, expeditionRouteButton,
}) do
    control.ZIndex = 21
end

local expeditionRouteLabel = Instance.new("TextLabel")
expeditionRouteLabel.Size = UDim2.fromOffset(336, 28)
expeditionRouteLabel.Position = UDim2.fromOffset(12, 286)
expeditionRouteLabel.BackgroundTransparency = 1
expeditionRouteLabel.Text = "MAP REWARD PRIORITY"
expeditionRouteLabel.TextColor3 = Color3.fromRGB(115, 132, 170)
expeditionRouteLabel.Font = Enum.Font.GothamBold
expeditionRouteLabel.TextSize = 10
expeditionRouteLabel.TextXAlignment = Enum.TextXAlignment.Left
expeditionRouteLabel.ZIndex = 21
expeditionRouteLabel.Parent = expeditionSettingsFrame

local expeditionRouteDropdown = Instance.new("Frame")
expeditionRouteDropdown.Size = UDim2.fromOffset(336, 102)
expeditionRouteDropdown.Position = UDim2.fromOffset(12, 214)
expeditionRouteDropdown.BackgroundColor3 = Color3.fromRGB(21, 25, 38)
expeditionRouteDropdown.BorderSizePixel = 0
expeditionRouteDropdown.Visible = false
expeditionRouteDropdown.ZIndex = 40
expeditionRouteDropdown.Parent = expeditionSettingsFrame
Instance.new("UICorner", expeditionRouteDropdown).CornerRadius = UDim.new(0, 7)
local routeDropStroke = Instance.new("UIStroke", expeditionRouteDropdown)
routeDropStroke.Color = Color3.fromRGB(72, 87, 132)

local routeOptions = {
    {value = "Material", label = "EXPEDITION MATERIAL", color = Color3.fromRGB(45, 61, 101)},
    {value = "Fuel", label = "FUEL CELL", color = Color3.fromRGB(88, 63, 31)},
    {value = "Off", label = "DISABLED", color = Color3.fromRGB(54, 38, 45)},
}
for index, option in ipairs(routeOptions) do
    local item = Instance.new("TextButton")
    item.Size = UDim2.fromOffset(324, 28)
    item.Position = UDim2.fromOffset(6, 5 + (index - 1) * 32)
    item.BackgroundColor3 = option.color
    item.Text = option.label
    item.TextColor3 = Color3.fromRGB(232, 238, 255)
    item.Font = Enum.Font.GothamBold
    item.TextSize = 10
    item.ZIndex = 41
    item.Parent = expeditionRouteDropdown
    Instance.new("UICorner", item).CornerRadius = UDim.new(0, 5)
    item.MouseButton1Click:Connect(function()
        local profile = state.selectedExpedition
            and state.expeditionProfiles[state.selectedExpedition]
        if not profile or state.expeditionMode then return end
        profile.expedition = type(profile.expedition) == "table"
            and profile.expedition or {events = {}, steps = {}}
        profile.expedition.routePriority = option.value
        expeditionRouteDropdown.Visible = false
        refreshExpeditionSequenceVisual(profile)
        saveConfig()
        log("[Expedition] Route priority: " .. option.value)
    end)
end

expeditionSettingsButton.MouseButton1Click:Connect(function()
    expeditionSettingsFrame.Visible = not expeditionSettingsFrame.Visible
    expeditionRouteDropdown.Visible = false
    expeditionSettingsButton.Text = expeditionSettingsFrame.Visible
        and "CLOSE EXPEDITION SETTINGS" or "OPEN EXPEDITION SETTINGS"
end)
expeditionSettingsClose.MouseButton1Click:Connect(function()
    expeditionSettingsFrame.Visible = false
    expeditionRouteDropdown.Visible = false
    expeditionSettingsButton.Text = "OPEN EXPEDITION SETTINGS"
end)

-- Equipment DPS calculator -------------------------------------------------
local dpsController = (function()
local DPS_DATABASE_FILE = "EquipmentDatabase_v3_" .. tostring(game.PlaceId) .. ".json"
local dpsUnitType = "Physical"
local dpsSlots = 3
local dpsDatabase = nil
local dpsInputs = {}
local dpsTypeDropdown
local dpsTypeButton
local dpsSlotsButton
local dpsStatus
local dpsResults
local DPS_PASSIVE_DAMAGE = { ["Shinigami Sword"] = 7.5 }

local function dpsNumber(value)
    local normalized = tostring(value or ""):gsub(",", ".")
    return tonumber(normalized) or 0
end

local function dpsLoadDatabase()
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(readfile(DPS_DATABASE_FILE))
    end)
    if ok and type(decoded) == "table" and type(decoded.items) == "table" then
        dpsDatabase = decoded
        return true
    end
    return false
end

local function dpsPool()
    local rows = {}
    if not dpsDatabase then return rows end
    for name, item in pairs(dpsDatabase.items) do
        if tostring(item.category):lower() == "standard equipment" then
            table.insert(rows, {name = name, item = item})
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

local function dpsEvaluate(required, selected)
    local damage = required.damage + required.passive
    local physical, magical, spa = required.physical, required.magical, required.spa
    for _, row in ipairs(selected) do
        local item = row.item
        damage += dpsNumber(item.maxDamage) + (DPS_PASSIVE_DAMAGE[row.name] or 0)
        physical += dpsNumber(item.maxPhysicalDamage)
        magical += dpsNumber(item.maxMagicalDamage)
        spa += dpsNumber(item.maxSpaReduction)
    end
    local typed = dpsUnitType == "Physical" and physical
        or (dpsUnitType == "Magical" and magical or 0)
    local value = (1 + damage / 100) * (1 + typed / 100)
        / math.max(0.05, 1 - spa / 100)
    return value, damage, typed, spa
end

local function dpsCalculate()
    if not dpsDatabase and not dpsLoadDatabase() then
        dpsStatus.Text = "Database missing · run Equipment Forge Probe v0.3"
        dpsResults.Text = DPS_DATABASE_FILE
        return
    end
    local required = {
        damage = dpsNumber(dpsInputs.damage.Text),
        physical = dpsNumber(dpsInputs.physical.Text),
        magical = dpsNumber(dpsInputs.magical.Text),
        spa = math.abs(dpsNumber(dpsInputs.spa.Text)),
        passive = dpsNumber(dpsInputs.passive.Text),
    }
    local pool, results = dpsPool(), {}
    if dpsSlots == 2 then
        for _, first in ipairs(pool) do
            local value, damage, typed, spa = dpsEvaluate(required, {first})
            table.insert(results, {
                names = first.name, value = value, damage = damage, typed = typed, spa = spa,
            })
        end
    else
        for first = 1, #pool - 1 do
            for second = first + 1, #pool do
                local value, damage, typed, spa = dpsEvaluate(
                    required, {pool[first], pool[second]}
                )
                table.insert(results, {
                    names = pool[first].name .. " + " .. pool[second].name,
                    value = value, damage = damage, typed = typed, spa = spa,
                })
            end
        end
    end
    table.sort(results, function(a, b) return a.value > b.value end)
    local lines = {}
    for index = 1, math.min(6, #results) do
        local row = results[index]
        table.insert(lines, ("%d. %s\n   +%.2f%% DPS  · D%.1f T%.1f S%.1f"):format(
            index, row.names, (row.value - 1) * 100,
            row.damage, row.typed, row.spa
        ))
    end
    dpsResults.Text = table.concat(lines, "\n")
    dpsStatus.Text = ("%s · %d slots · %d combinations"):format(
        dpsUnitType, dpsSlots, #results
    )
end

local function dpsLabel(text, x, y, width)
    local object = Instance.new("TextLabel")
    object.Size = UDim2.fromOffset(width, 18)
    object.Position = UDim2.fromOffset(x, y)
    object.BackgroundTransparency = 1
    object.Text = text
    object.TextColor3 = Color3.fromRGB(112, 130, 168)
    object.Font = Enum.Font.GothamBold
    object.TextSize = 9
    object.TextXAlignment = Enum.TextXAlignment.Left
    object.Parent = dpsPage
    return object
end

local function dpsButton(text, x, y, width, color)
    local object = makeButton(text, 0, 0, width, color or Color3.fromRGB(33, 39, 58))
    move(object, dpsPage, x, y, width, 30)
    return object
end

dpsLabel("UNIT TYPE", 0, 0, 164)
dpsLabel("TOTAL SLOTS", 172, 0, 164)
dpsTypeButton = dpsButton("PHYSICAL  ▾", 0, 20, 164, Color3.fromRGB(43, 57, 91))
dpsSlotsButton = dpsButton("3 SLOTS", 172, 20, 164, Color3.fromRGB(38, 68, 56))

dpsTypeDropdown = Instance.new("Frame")
dpsTypeDropdown.Size = UDim2.fromOffset(164, 100)
dpsTypeDropdown.Position = UDim2.fromOffset(0, 53)
dpsTypeDropdown.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
dpsTypeDropdown.BorderSizePixel = 0
dpsTypeDropdown.Visible = false
dpsTypeDropdown.ZIndex = 40
dpsTypeDropdown.Parent = dpsPage
Instance.new("UICorner", dpsTypeDropdown).CornerRadius = UDim.new(0, 7)

for index, name in ipairs({"Physical", "Magical", "Neutral"}) do
    local option = Instance.new("TextButton")
    option.Size = UDim2.fromOffset(152, 27)
    option.Position = UDim2.fromOffset(6, 5 + (index - 1) * 31)
    option.BackgroundColor3 = Color3.fromRGB(39, 47, 70)
    option.Text = string.upper(name)
    option.TextColor3 = Color3.fromRGB(232, 238, 255)
    option.Font = Enum.Font.GothamBold
    option.TextSize = 10
    option.ZIndex = 41
    option.Parent = dpsTypeDropdown
    Instance.new("UICorner", option).CornerRadius = UDim.new(0, 5)
    option.MouseButton1Click:Connect(function()
        dpsUnitType = name
        dpsTypeButton.Text = string.upper(name) .. "  ▾"
        dpsTypeDropdown.Visible = false
        dpsCalculate()
    end)
end

dpsTypeButton.MouseButton1Click:Connect(function()
    dpsTypeDropdown.Visible = not dpsTypeDropdown.Visible
end)
dpsSlotsButton.MouseButton1Click:Connect(function()
    dpsSlots = dpsSlots == 3 and 2 or 3
    dpsSlotsButton.Text = tostring(dpsSlots) .. " SLOTS"
    dpsCalculate()
end)

dpsLabel("REQUIRED UNIT EQUIPMENT BONUSES", 0, 60, 336)
local dpsFields = {
    {key="damage", label="DMG", x=0},
    {key="physical", label="PHYS", x=69},
    {key="magical", label="MAG", x=138},
    {key="spa", label="SPA-", x=207},
    {key="passive", label="PASSIVE", x=276},
}
for _, field in ipairs(dpsFields) do
    dpsLabel(field.label, field.x, 80, 60)
    local box = Instance.new("TextBox")
    box.Size = UDim2.fromOffset(60, 28)
    box.Position = UDim2.fromOffset(field.x, 99)
    box.BackgroundColor3 = Color3.fromRGB(24, 29, 43)
    box.Text = "0"
    box.PlaceholderText = "0"
    box.TextColor3 = Color3.fromRGB(235, 240, 255)
    box.Font = Enum.Font.Gotham
    box.TextSize = 10
    box.ClearTextOnFocus = false
    box.Parent = dpsPage
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
    dpsInputs[field.key] = box
    box.FocusLost:Connect(dpsCalculate)
end

local dpsCalculateButton = dpsButton(
    "CALCULATE BEST EQUIPMENT", 0, 137, 336, Color3.fromRGB(32, 77, 58)
)
dpsCalculateButton.MouseButton1Click:Connect(dpsCalculate)

dpsStatus = Instance.new("TextLabel")
dpsStatus.Size = UDim2.fromOffset(336, 28)
dpsStatus.Position = UDim2.fromOffset(0, 175)
dpsStatus.BackgroundColor3 = Color3.fromRGB(21, 25, 37)
dpsStatus.Text = "Loading equipment database..."
dpsStatus.TextColor3 = Color3.fromRGB(145, 165, 205)
dpsStatus.Font = Enum.Font.Gotham
dpsStatus.TextSize = 9
dpsStatus.Parent = dpsPage
Instance.new("UICorner", dpsStatus).CornerRadius = UDim.new(0, 6)

dpsResults = Instance.new("TextLabel")
dpsResults.Size = UDim2.fromOffset(336, 148)
dpsResults.Position = UDim2.fromOffset(0, 211)
dpsResults.BackgroundColor3 = Color3.fromRGB(19, 23, 34)
dpsResults.Text = ""
dpsResults.TextColor3 = Color3.fromRGB(188, 204, 234)
dpsResults.Font = Enum.Font.Code
dpsResults.TextSize = 9
dpsResults.TextXAlignment = Enum.TextXAlignment.Left
dpsResults.TextYAlignment = Enum.TextYAlignment.Top
dpsResults.TextWrapped = false
dpsResults.Parent = dpsPage
Instance.new("UICorner", dpsResults).CornerRadius = UDim.new(0, 7)

    return {
        open = function()
            dpsTypeDropdown.Visible = false
            dpsCalculate()
        end,
        close = function()
            dpsTypeDropdown.Visible = false
        end,
    }
end)()

local pages = {
    MACRO = {page = macroPage, button = macroTabButton},
    EXPEDITION = {page = expeditionPage, button = expeditionTabButton},
    TOWER = {page = towerPage, button = towerTabButton},
    DPS = {page = dpsPage, button = dpsTabButton},
    STATUS = {page = statusPage, button = statusTabButton},
}
local function showTab(name)
    for key, item in pairs(pages) do
        local active = key == name
        item.page.Visible = active
        item.button.BackgroundColor3 = active
            and Color3.fromRGB(48, 59, 88) or Color3.fromRGB(27, 31, 46)
        item.button.TextColor3 = active
            and Color3.fromRGB(230, 235, 255) or Color3.fromRGB(130, 140, 175)
    end
    if name ~= "EXPEDITION" then
        expeditionSettingsFrame.Visible = false
        expeditionRouteDropdown.Visible = false
        expeditionSettingsButton.Text = "OPEN EXPEDITION SETTINGS"
    end
    if name ~= "DPS" then dpsController.close() end
end
macroTabButton.MouseButton1Click:Connect(function() showTab("MACRO") end)
expeditionTabButton.MouseButton1Click:Connect(function() showTab("EXPEDITION") end)
towerTabButton.MouseButton1Click:Connect(function() showTab("TOWER") end)
dpsTabButton.MouseButton1Click:Connect(function()
    showTab("DPS")
    dpsController.open()
end)
statusTabButton.MouseButton1Click:Connect(function() showTab("STATUS") end)
showTab("MACRO")

local function refreshSmartVisual(profile, selectedSlot)
    if not profile then return end
    profile.smart = type(profile.smart) == "table" and profile.smart or {}
    profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
    selectedSlot = selectedSlot or math.floor(tonumber(profile.smart.slot) or 6)
    local enabled = profile.smart.enabled == true
    smartEnabledButton.Text = enabled and "SMART: ENABLED" or "SMART: DISABLED"
    smartEnabledButton.BackgroundColor3 = enabled
        and Color3.fromRGB(28, 62, 49) or Color3.fromRGB(57, 31, 40)
    for slot, button in ipairs(smartSlotButtons) do
        local job = profile.smart.jobs[tostring(slot)]
        local pointCount = job and type(job.points) == "table" and #job.points or 0
        button.Text = pointCount > 0 and ("%d\n• %d"):format(slot, pointCount) or tostring(slot)
        button.TextWrapped = true
        button.BackgroundColor3 = slot == selectedSlot
            and Color3.fromRGB(58, 73, 112)
            or (pointCount > 0 and Color3.fromRGB(31, 60, 52) or Color3.fromRGB(33, 38, 57))
    end
end

refreshExpeditionSequenceVisual = function(profile)
    local slot = math.clamp(math.floor(tonumber(state.expeditionEditSlot) or 1), 1, 6)
    state.expeditionEditSlot = slot
    for index, button in ipairs(expeditionSlotButtons) do
        button.BackgroundColor3 = index == slot
            and Color3.fromRGB(58, 73, 112) or Color3.fromRGB(33, 38, 57)
    end
    if not profile then
        expeditionStepList.Text = "No profile selected"
        return
    end
    profile.expedition = type(profile.expedition) == "table"
        and profile.expedition or {events = {}, steps = {}}
    profile.expedition.steps = type(profile.expedition.steps) == "table"
        and profile.expedition.steps or {}
    local routePriority = profile.expedition.routePriority
    if routePriority == "Cursed" then
        routePriority = "Material"
        profile.expedition.routePriority = routePriority
    end
    if routePriority ~= "Material" and routePriority ~= "Fuel"
        and routePriority ~= "Off" then
        routePriority = "Material"
        profile.expedition.routePriority = routePriority
    end
    expeditionRouteButton.Text = routePriority == "Material" and "EXPEDITION MATERIAL  ▾"
        or (routePriority == "Fuel" and "FUEL CELL  ▾" or "DISABLED  ▾")
    expeditionRouteButton.BackgroundColor3 = routePriority == "Off"
        and Color3.fromRGB(55, 38, 45)
        or (routePriority == "Fuel"
            and Color3.fromRGB(91, 65, 31)
            or Color3.fromRGB(43, 58, 92))
    local lines = {}
    local first = math.max(1, #profile.expedition.steps - 5)
    for index = first, #profile.expedition.steps do
        local step = profile.expedition.steps[index]
        local suffix = ""
        if step.type == "PLACE" and step.point then
            suffix = (" @ %.3f,%.3f"):format(step.point.nx or 0, step.point.ny or 0)
        elseif step.type == "UPGRADE" then
            suffix = step.toMax and " TO MAX" or " +1"
        end
        table.insert(lines, ("%02d  %-7s S%d%s"):format(
            index, tostring(step.type or "?"), tonumber(step.slot) or 0, suffix
        ))
    end
    expeditionStepList.Text = #lines > 0 and table.concat(lines, "\n")
        or "No conditional steps\nSelect slot · F7 point · ADD PLACE"
    expeditionStatus.Text = ("Idle · %d steps · edit slot %d%s"):format(
        #profile.expedition.steps, slot,
        state.expeditionDraftPoint and " · point ready" or ""
    )
end

expeditionRouteButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        expeditionStatus.Text = "Stop Expedition before changing route priority"
        return
    end
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    if not profile then log("Select an Expedition profile first") return end
    expeditionRouteDropdown.Visible = not expeditionRouteDropdown.Visible
end)

for slot, button in ipairs(smartSlotButtons) do
    button.MouseButton1Click:Connect(function()
        local profile = state.selected and state.profiles[state.selected]
        if not profile then log("Select a profile first") return end
        profile.smart = type(profile.smart) == "table" and profile.smart or {}
        profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
        profile.smart.slot = slot
        smartSlotBox.Text = tostring(slot)
        local job = profile.smart.jobs[tostring(slot)]
        smartWaveBox.Text = tostring(job and job.wave or 8)
        smartReserveBox.Text = tostring(job and job.reserve or 5000)
        smartInfo.Text = job
            and ("Slot %d points: %d"):format(slot, #(job.points or {}))
            or ("Slot %d is not configured"):format(slot)
        refreshSmartVisual(profile, slot)
        saveConfig()
    end)
end

-- Drag window by its title area.
local dragging, dragStart, frameStart
title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        frameStart = frame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            frameStart.X.Scale, frameStart.X.Offset + delta.X,
            frameStart.Y.Scale, frameStart.Y.Offset + delta.Y
        )
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

local function trimmedName()
    return nameBox.Text:match("^%s*(.-)%s*$")
end

local function selectProfile(name, create)
    if name == "" then
        log("Enter a macro name")
        return nil
    end
    if not state.profiles[name] and create then
        state.profiles[name] = {
            name = name,
            events = {},
            camera = serializeCFrame(camera.CFrame),
            placeId = game.PlaceId,
            viewport = {x = camera.ViewportSize.X, y = camera.ViewportSize.Y},
            smart = {enabled = false, wave = 8, reserve = 5000, slot = 6, points = {}, jobs = {}},
        }
    end
    if not state.profiles[name] then
        log("Profile not found: " .. name)
        return nil
    end
    state.selected = name
    nameBox.Text = name
    local profile = state.profiles[name]
    state.raidPopupButton.Text = profile.raidRewardDismiss
        and "RAID REWARD DISMISS: ON" or "RAID REWARD DISMISS: OFF"
    state.raidPopupButton.BackgroundColor3 = profile.raidRewardDismiss
        and Color3.fromRGB(28, 62, 49) or Color3.fromRGB(33, 38, 57)
    profile.smart = type(profile.smart) == "table" and profile.smart
        or {wave = 8, reserve = 5000, slot = 6, points = {}}
    profile.smart.points = type(profile.smart.points) == "table" and profile.smart.points or {}
    profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
    if profile.smart.enabled == nil then
        profile.smart.enabled = #profile.smart.points > 0 or next(profile.smart.jobs) ~= nil
    end
    local selectedSmartSlot = math.clamp(math.floor(tonumber(profile.smart.slot) or 6), 1, 6)
    local selectedJob = profile.smart.jobs[tostring(selectedSmartSlot)]
    smartWaveBox.Text = tostring(selectedJob and selectedJob.wave or profile.smart.wave or 8)
    smartReserveBox.Text = tostring(selectedJob and selectedJob.reserve or profile.smart.reserve or 5000)
    smartSlotBox.Text = tostring(selectedSmartSlot)
    local configuredJobs = 0
    for _, job in pairs(profile.smart.jobs) do
        if type(job.points) == "table" and #job.points > 0 then configuredJobs += 1 end
    end
    local selectedPoints = selectedJob and selectedJob.points or profile.smart.points
    smartInfo.Text = ("Slot %d points: %d  |  jobs: %d"):format(
        selectedSmartSlot, #selectedPoints, configuredJobs
    )
    refreshSmartVisual(profile, selectedSmartSlot)
    saveConfig()
    local placeNote = profile.placeId and (" · PlaceId " .. tostring(profile.placeId)) or ""
    log(("Selected '%s' (%d events%s)"):format(name, #(profile.events or {}), placeNote))
    return state.profiles[name]
end

-- Internal API for the embedded Auto Challenge controller.  Updating the
-- already loaded state directly avoids a race where rewriting the JSON file
-- leaves this running Tower Macro instance on the old farm profile (event1).
sharedEnv.__TowerMacroSelectProfile = function(name)
    local profile = selectProfile(tostring(name or ""), false)
    return profile ~= nil and state.selected == name
end

sharedEnv.__TowerMacroSelectedProfile = function()
    return state.selected
end

local dropdown = Instance.new("ScrollingFrame")
dropdown.Name = "ProfileDropdown"
dropdown.Size = UDim2.fromOffset(306, 0)
dropdown.Position = UDim2.fromOffset(12, 76)
dropdown.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
dropdown.BorderSizePixel = 0
dropdown.ScrollBarThickness = 3
dropdown.ScrollBarImageColor3 = Color3.fromRGB(90, 105, 160)
dropdown.Visible = false
dropdown.ZIndex = 20
dropdown.Parent = frame
Instance.new("UICorner", dropdown).CornerRadius = UDim.new(0, 7)
local dropdownLayout = Instance.new("UIListLayout", dropdown)
dropdownLayout.Padding = UDim.new(0, 3)
dropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function rebuildDropdown()
    for _, child in ipairs(dropdown:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    local names = {}
    for name in pairs(state.profiles) do table.insert(names, name) end
    table.sort(names)

    if #names == 0 then
        dropdown.Visible = false
        log("No saved profiles; type a new name and press RECORD")
        return
    end
    local height = math.min(#names * 31 + 6, 130)
    dropdown.Size = UDim2.fromOffset(306, height)
    dropdown.CanvasSize = UDim2.fromOffset(0, #names * 31 + 6)
    for index, name in ipairs(names) do
        local profile = state.profiles[name]
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, -6, 0, 28)
        item.BackgroundColor3 = name == state.selected
            and Color3.fromRGB(49, 59, 91) or Color3.fromRGB(29, 33, 49)
        item.Text = ("  %s  ·  %d events"):format(name, #(profile.events or {}))
        item.TextColor3 = Color3.fromRGB(225, 230, 255)
        item.Font = Enum.Font.Gotham
        item.TextSize = 11
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.ZIndex = 21
        item.LayoutOrder = index
        item.Parent = dropdown
        Instance.new("UICorner", item).CornerRadius = UDim.new(0, 5)
        item.MouseButton1Click:Connect(function()
            selectProfile(name, false)
            dropdown.Visible = false
        end)
    end
    dropdown.Visible = true
end

local expeditionDropdown = Instance.new("ScrollingFrame")
expeditionDropdown.Name = "ExpeditionProfileDropdown"
expeditionDropdown.Size = UDim2.fromOffset(306, 0)
expeditionDropdown.Position = UDim2.fromOffset(12, 114)
expeditionDropdown.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
expeditionDropdown.BorderSizePixel = 0
expeditionDropdown.ScrollBarThickness = 3
expeditionDropdown.Visible = false
expeditionDropdown.ZIndex = 30
expeditionDropdown.Parent = frame
Instance.new("UICorner", expeditionDropdown).CornerRadius = UDim.new(0, 7)
local expeditionDropdownLayout = Instance.new("UIListLayout", expeditionDropdown)
expeditionDropdownLayout.Padding = UDim.new(0, 3)
expeditionDropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function selectExpeditionProfile(name, create)
    name = tostring(name or ""):match("^%s*(.-)%s*$")
    if name == "" then
        log("Enter an Expedition profile name")
        return nil
    end
    if not state.expeditionProfiles[name] and create then
        state.expeditionProfiles[name] = {
            name = name,
            placeId = game.PlaceId,
            expedition = {events = {}, steps = {}},
        }
    end
    local profile = state.expeditionProfiles[name]
    if not profile then
        log("Expedition profile not found: " .. name)
        return nil
    end
    profile.expedition = type(profile.expedition) == "table"
        and profile.expedition or {events = {}, steps = {}}
    profile.expedition.steps = type(profile.expedition.steps) == "table"
        and profile.expedition.steps or {}
    profile.expedition.events = type(profile.expedition.events) == "table"
        and profile.expedition.events or {}
    state.selectedExpedition = name
    expeditionNameBox.Text = name
    refreshExpeditionSequenceVisual(profile)
    saveConfig()
    log(("[Expedition] Selected '%s' · %d steps"):format(
        name, #profile.expedition.steps
    ))
    return profile
end

local function rebuildExpeditionDropdown()
    for _, child in ipairs(expeditionDropdown:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    local names = {}
    for name in pairs(state.expeditionProfiles) do table.insert(names, name) end
    table.sort(names)
    if #names == 0 then
        expeditionDropdown.Visible = false
        log("Type a new Expedition profile name, then add a step")
        return
    end
    local height = math.min(#names * 31 + 6, 130)
    expeditionDropdown.Size = UDim2.fromOffset(306, height)
    expeditionDropdown.CanvasSize = UDim2.fromOffset(0, #names * 31 + 6)
    for index, name in ipairs(names) do
        local profile = state.expeditionProfiles[name]
        local steps = profile.expedition and profile.expedition.steps or {}
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, -6, 0, 28)
        item.BackgroundColor3 = name == state.selectedExpedition
            and Color3.fromRGB(49, 59, 91) or Color3.fromRGB(29, 33, 49)
        item.Text = ("  %s  ·  %d steps"):format(name, #steps)
        item.TextColor3 = Color3.fromRGB(225, 230, 255)
        item.Font = Enum.Font.Gotham
        item.TextSize = 11
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.ZIndex = 31
        item.LayoutOrder = index
        item.Parent = expeditionDropdown
        Instance.new("UICorner", item).CornerRadius = UDim.new(0, 5)
        item.MouseButton1Click:Connect(function()
            selectExpeditionProfile(name, false)
            expeditionDropdown.Visible = false
        end)
    end
    expeditionDropdown.Visible = true
end

expeditionSelectButton.MouseButton1Click:Connect(function()
    if expeditionDropdown.Visible then
        expeditionDropdown.Visible = false
    else
        rebuildExpeditionDropdown()
    end
end)

if state.selectedExpedition then
    selectExpeditionProfile(state.selectedExpedition, false)
else
    refreshExpeditionSequenceVisual(nil)
end

local function pointerInsideWindow(pos)
    if not frame.Visible then return false end
    local p, s = frame.AbsolutePosition, frame.AbsoluteSize
    return pos.X >= p.X and pos.X <= p.X + s.X
        and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

local allowedKeys = {
    [Enum.KeyCode.One] = true, [Enum.KeyCode.Two] = true,
    [Enum.KeyCode.Three] = true, [Enum.KeyCode.Four] = true,
    [Enum.KeyCode.Five] = true, [Enum.KeyCode.Six] = true,
    [Enum.KeyCode.T] = true, [Enum.KeyCode.F] = true,
}

local function addEvent(event)
    event.t = math.max(0, os.clock() - state.recordStarted)
    table.insert(state.currentEvents, event)
    log(("#%d  %.3fs  %s"):format(#state.currentEvents, event.t, event.type))
end

UserInputService.InputBegan:Connect(function(input)
    if state.destroyed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        frame.Visible = not frame.Visible
        return
    end
    if input.KeyCode == Enum.KeyCode.F7 then
        if expeditionPage.Visible and not state.expeditionMode then
            local pos = UserInputService:GetMouseLocation()
            local vp = camera.ViewportSize
            state.expeditionDraftPoint = {
                x = math.floor(pos.X + 0.5),
                y = math.floor(pos.Y + 0.5),
                nx = vp.X > 0 and pos.X / vp.X or 0,
                ny = vp.Y > 0 and pos.Y / vp.Y or 0,
            }
            local profile = state.selectedExpedition
                and state.expeditionProfiles[state.selectedExpedition]
            refreshExpeditionSequenceVisual(profile)
            log(("[Expedition] Point saved for slot %d at %d,%d"):format(
                state.expeditionEditSlot, pos.X, pos.Y
            ))
            return
        end
        if state.recording or state.playing or state.smartRunning or state.expeditionMode then
            log("Stop active operations before adding a smart point")
            return
        end
        local profile = state.selected and state.profiles[state.selected]
        if not profile then
            log("Select a profile before adding points")
            return
        end
        profile.smart = type(profile.smart) == "table" and profile.smart
            or {wave = 8, reserve = 5000, slot = 6, points = {}}
        profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
        local slot = math.clamp(math.floor(tonumber(smartSlotBox.Text) or 6), 1, 6)
        local slotKey = tostring(slot)
        local job = profile.smart.jobs[slotKey] or {
            wave = math.max(1, math.floor(tonumber(smartWaveBox.Text) or 8)),
            reserve = math.max(0, math.floor(tonumber(smartReserveBox.Text) or 5000)),
            slot = slot,
            points = {},
        }
        profile.smart.jobs[slotKey] = job
        job.wave = math.max(1, math.floor(tonumber(smartWaveBox.Text) or job.wave or 8))
        job.reserve = math.max(0, math.floor(tonumber(smartReserveBox.Text) or job.reserve or 5000))
        job.points = type(job.points) == "table" and job.points or {}
        local pos = UserInputService:GetMouseLocation()
        local vp = camera.ViewportSize
        table.insert(job.points, {
            x = math.floor(pos.X + 0.5),
            y = math.floor(pos.Y + 0.5),
            nx = vp.X > 0 and pos.X / vp.X or 0,
            ny = vp.Y > 0 and pos.Y / vp.Y or 0,
        })
        saveConfig()
        smartInfo.Text = ("Slot %d points: %d  |  last: %d,%d"):format(
            slot, #job.points, pos.X, pos.Y
        )
        log(("Slot %d point #%d saved at %d,%d"):format(
            slot, #job.points, pos.X, pos.Y
        ))
        refreshSmartVisual(profile, slot)
        return
    end
    if state.expeditionMode == "record" and state.expeditionStarted
        and not state.expeditionBlocked and os.clock() >= state.expeditionSuppressUntil then
        local event
        if allowedKeys[input.KeyCode] then
            event = {type = "key", key = input.KeyCode.Name, t = state.expeditionTimeline}
        elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
            local pos = UserInputService:GetMouseLocation()
            if not pointerInsideWindow(pos) then
                local vp = camera.ViewportSize
                event = {
                    type = "click",
                    x = math.floor(pos.X + 0.5),
                    y = math.floor(pos.Y + 0.5),
                    nx = vp.X > 0 and pos.X / vp.X or 0,
                    ny = vp.Y > 0 and pos.Y / vp.Y or 0,
                    t = state.expeditionTimeline,
                }
            end
        end
        if event then
            table.insert(state.expeditionEvents, event)
            expeditionStatus.Text = ("Recording · %.2fs · %d events"):format(
                state.expeditionTimeline, #state.expeditionEvents
            )
            return
        end
    end
    if not state.recording or state.playing then return end

    if allowedKeys[input.KeyCode] then
        addEvent({type = "key", key = input.KeyCode.Name})
    elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
        local pos = UserInputService:GetMouseLocation()
        if pointerInsideWindow(pos) then return end
        local vp = camera.ViewportSize
        addEvent({
            type = "click",
            x = math.floor(pos.X + 0.5),
            y = math.floor(pos.Y + 0.5),
            nx = vp.X > 0 and pos.X / vp.X or 0,
            ny = vp.Y > 0 and pos.Y / vp.Y or 0,
        })
    end
end)

local function restoreCamera(profile)
    local cf = deserializeCFrame(profile and profile.camera)
    local focus = deserializeCFrame(profile and profile.cameraFocus)
    if cf and workspace.CurrentCamera then
        if focus then workspace.CurrentCamera.Focus = focus end
        workspace.CurrentCamera.CFrame = cf
        return true
    end
    return false
end

local function lockAutomationCamera(profile)
    local currentCamera = workspace.CurrentCamera
    if not currentCamera then return false end
    if not state.cameraOriginalType then
        state.cameraOriginalType = currentCamera.CameraType
    end
    currentCamera.CameraType = Enum.CameraType.Scriptable
    return restoreCamera(profile)
end

local function unlockAutomationCamera()
    if state.expeditionCameraBound then
        pcall(function() RunService:UnbindFromRenderStep("TowerMacroExpeditionCamera") end)
        state.expeditionCameraBound = false
    end
    local currentCamera = workspace.CurrentCamera
    if currentCamera and state.cameraOriginalType then
        currentCamera.CameraType = state.cameraOriginalType
    end
    state.cameraOriginalType = nil
end

local function getRootPart()
    local character = player.Character
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function saveStartState(profile)
    profile.camera = serializeCFrame(camera.CFrame)
    profile.cameraFocus = serializeCFrame(camera.Focus)
    profile.zoomDistance = (camera.CFrame.Position - camera.Focus.Position).Magnitude
    profile.placeId = game.PlaceId
    profile.viewport = {x = camera.ViewportSize.X, y = camera.ViewportSize.Y}
    local root = getRootPart()
    if root then
        profile.character = serializeCFrame(root.CFrame)
        return true
    end
    return false
end

local function restoreCharacter(profile)
    local target = deserializeCFrame(profile and profile.character)
    local root = getRootPart()
    if not target or not root then return false end
    root.CFrame = target
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
    return true
end

local function restoreStart(profile)
    local moved = false
    local cameraSet = false
    local ok = pcall(function()
        moved = restoreCharacter(profile)
        cameraSet = restoreCamera(profile)
    end)
    return ok, moved, cameraSet
end

local function saveExpeditionCamera(profile)
    profile.expedition = type(profile.expedition) == "table"
        and profile.expedition or {events = {}, steps = {}}
    profile.expedition.camera = serializeCFrame(camera.CFrame)
    profile.expedition.cameraFocus = serializeCFrame(camera.Focus)
    local root = getRootPart()
    if root then
        profile.expedition.cameraRelative = serializeCFrame(
            root.CFrame:ToObjectSpace(camera.CFrame)
        )
        profile.expedition.focusRelative = serializeCFrame(
            root.CFrame:ToObjectSpace(camera.Focus)
        )
    end
    profile.expedition.viewport = {
        x = camera.ViewportSize.X,
        y = camera.ViewportSize.Y,
    }
end

local function restoreExpeditionCamera(profile)
    local expedition = profile and profile.expedition
    local root = getRootPart()
    local relative = expedition and deserializeCFrame(expedition.cameraRelative)
    local relativeFocus = expedition and deserializeCFrame(expedition.focusRelative)
    local cf = root and relative and (root.CFrame * relative)
        or (expedition and deserializeCFrame(expedition.camera))
    local focus = root and relativeFocus and (root.CFrame * relativeFocus)
        or (expedition and deserializeCFrame(expedition.cameraFocus))
    if not cf or not workspace.CurrentCamera then return false end
    workspace.CurrentCamera.CFrame = cf
    if focus then workspace.CurrentCamera.Focus = focus end
    return true
end

local function lockExpeditionCamera(profile)
    local currentCamera = workspace.CurrentCamera
    if not currentCamera then return false end
    if not state.cameraOriginalType then
        state.cameraOriginalType = currentCamera.CameraType
    end
    currentCamera.CameraType = Enum.CameraType.Scriptable
    local restored = restoreExpeditionCamera(profile)
    pcall(function() RunService:UnbindFromRenderStep("TowerMacroExpeditionCamera") end)
    local nextCameraUpdate = 0
    RunService:BindToRenderStep(
        "TowerMacroExpeditionCamera",
        Enum.RenderPriority.Camera.Value + 100,
        function()
            local now = os.clock()
            if state.expeditionMode and not state.destroyed
                and now >= nextCameraUpdate then
                nextCameraUpdate = now + 0.05
                local activeCamera = workspace.CurrentCamera
                if activeCamera then activeCamera.CameraType = Enum.CameraType.Scriptable end
                restoreExpeditionCamera(profile)
            end
        end
    )
    state.expeditionCameraBound = true
    return restored
end

local function findQueueFunction()
    local env = (getgenv and getgenv()) or _G
    if type(env.queue_on_teleport) == "function" then return env.queue_on_teleport end
    if type(env.queueonteleport) == "function" then return env.queueonteleport end
    if type(env.syn) == "table" and type(env.syn.queue_on_teleport) == "function" then
        return env.syn.queue_on_teleport
    end
    if type(env.fluxus) == "table" and type(env.fluxus.queue_on_teleport) == "function" then
        return env.fluxus.queue_on_teleport
    end
    return nil
end

local function updateAutoQueueButton()
    autoQueueButton.Text = state.autoQueue and "AUTO TP: ON" or "AUTO TP: OFF"
    autoQueueButton.BackgroundColor3 = state.autoQueue
        and Color3.fromRGB(28, 62, 49) or Color3.fromRGB(33, 38, 57)
end

local function updateRepeatButton()
    repeatButton.Text = state.repeatEnabled and "REPEAT: ON" or "REPEAT: OFF"
    repeatButton.BackgroundColor3 = state.repeatEnabled
        and Color3.fromRGB(28, 62, 49) or Color3.fromRGB(33, 38, 57)
end

local function queueForNextTeleport(silent)
    if not state.autoQueue then return false end
    if sharedEnv.__TowerMacroQueuedJobId == game.JobId then return true end
    local queueFunction = findQueueFunction()
    if not queueFunction then
        if not silent then log("Xeno has no supported queue_on_teleport function") end
        return false
    end
local loader = [[
repeat task.wait() until game:IsLoaded()
task.wait(1)
local players = game:GetService("Players")
local http = game:GetService("HttpService")
local localPlayer = players.LocalPlayer
local configFile = localPlayer and ("TowerMacro_" .. localPlayer.Name .. ".json")
if configFile then
    local configOk, config = pcall(function()
        if not isfile(configFile) then return nil end
        return http:JSONDecode(readfile(configFile))
    end)
    if configOk and type(config) == "table"
        and config.autoQueueEnabled == false then
        return
    end
end
local ok, source = pcall(readfile, "tower_macro.lua")
if ok and source then
    local compiled, compileError = loadstring(source)
    if compiled then compiled()
    else warn("[TowerMacro] Auto-queue compile failed:", compileError) end
else
    warn("[TowerMacro] Auto-queue cannot read tower_macro.lua")
end
]]
    local ok, err = pcall(queueFunction, loader)
    if not ok then
        if not silent then log("Auto-queue failed: " .. tostring(err)) end
        return false
    end
    sharedEnv.__TowerMacroQueuedJobId = game.JobId
    if not silent then log("Script queued for the next teleport") end
    return true
end

local function stopAll(reason)
    if state.expeditionMode == "record" and state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition] then
        local profile = state.expeditionProfiles[state.selectedExpedition]
        profile.expedition = profile.expedition or {}
        profile.expedition.events = state.expeditionEvents
        saveConfig()
    end
    state.recording = false
    state.playing = false
    state.smartRunning = false
    state.towerRunning = false
    state.towerToken += 1
    state.expeditionMode = nil
    state.expeditionToken += 1
    state.expeditionStarted = false
    state.expeditionBlocked = true
    state.playToken += 1
    state.smartToken += 1
    unlockAutomationCamera()
    recordButton.Text = "RECORD"
    smartRunButton.Text = "SMART START"
    expeditionRecordButton.Text = "RECORD RUN"
    expeditionAutoButton.Text = "RUN SEQUENCE"
    setRunProfileActive(false)
    if reason then log(reason) end
end

closeButton.MouseButton1Click:Connect(function()
    if state.destroyed then return end
    if type(sharedEnv.__TowerChallengeDisable) == "function" then
        pcall(sharedEnv.__TowerChallengeDisable)
    end
    state.autoQueue = false
    saveConfig()
    stopAll("Tower Macro closed")
    state.destroyed = true
    if sharedEnv.__TowerMacroActiveJobId == game.JobId then
        sharedEnv.__TowerMacroActiveJobId = nil
    end
    if _G.__TowerMacroStatusLabel == status then
        _G.__TowerMacroStatusLabel = nil
    end
    gui:Destroy()
end)

selectButton.MouseButton1Click:Connect(function()
    if dropdown.Visible then
        dropdown.Visible = false
    else
        rebuildDropdown()
    end
end)

cameraButton.MouseButton1Click:Connect(function()
    local profile = selectProfile(trimmedName(), true)
    if not profile then return end
    local hasCharacter = saveStartState(profile)
    saveConfig()
    log(hasCharacter and ("Start saved for '" .. state.selected .. "'")
        or "Camera saved, but HumanoidRootPart was not found")
end)

recordButton.MouseButton1Click:Connect(function()
    if state.playing or state.expeditionMode then
        log("Stop playback first")
        return
    end
    local profile = selectProfile(trimmedName(), true)
    if not profile then return end
    state.currentEvents = {}
    profile.placeId = game.PlaceId
    if not profile.camera or not profile.character then
        saveStartState(profile)
    end
    state.recordStarted = os.clock()
    state.recording = true
    recordButton.Text = "RECORDING..."
    log("Recording started; GUI clicks are ignored")
end)

stopButton.MouseButton1Click:Connect(function()
    if state.recording then
        local profile = state.profiles[state.selected]
        state.recording = false
        profile.events = state.currentEvents
        profile.viewport = {x = camera.ViewportSize.X, y = camera.ViewportSize.Y}
        saveConfig()
        recordButton.Text = "RECORD"
        log(("Recording saved: %d events, %.2fs"):format(
            #profile.events,
            profile.events[#profile.events] and profile.events[#profile.events].t or 0
        ))
    elseif state.playing then
        stopAll("Playback stopped")
    elseif state.smartRunning then
        stopAll("Smart placement stopped")
        smartRunButton.Text = "SMART START"
    elseif state.expeditionMode then
        stopAll("Expedition stopped")
    else
        log("Nothing is running")
    end
end)

local function sendKey(keyName)
    local key = Enum.KeyCode[keyName]
    if not key then return false, "unknown key " .. tostring(keyName) end
    VirtualInputManager:SendKeyEvent(true, key, false, game)
    task.wait(0.035)
    VirtualInputManager:SendKeyEvent(false, key, false, game)
    return true
end

local function sendClick(event, profile)
    local vp = camera.ViewportSize
    local savedVp = profile.viewport or {}
    local sameViewport = math.abs((savedVp.x or 0) - vp.X) < 2
        and math.abs((savedVp.y or 0) - vp.Y) < 2
    local x = sameViewport and event.x or math.floor((event.nx or 0) * vp.X + 0.5)
    local y = sameViewport and event.y or math.floor((event.ny or 0) * vp.Y + 0.5)
    VirtualInputManager:SendMouseMoveEvent(x, y, game)
    task.wait(0.025)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
    task.wait(0.035)
    VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    return true
end

local function expeditionClean(text)
    return tostring(text or ""):gsub("<.->", ""):gsub("%s+", " ")
        :match("^%s*(.-)%s*$")
end

local function expeditionVisible(object)
    if not object then return false end
    local cursor = object
    while cursor and cursor ~= player.PlayerGui do
        if cursor:IsA("LayerCollector") and not cursor.Enabled then return false end
        if cursor:IsA("GuiObject") and not cursor.Visible then return false end
        if cursor:IsA("CanvasGroup") and cursor.GroupTransparency >= 0.98 then
            return false
        end
        cursor = cursor.Parent
    end
    local position, size = object.AbsolutePosition, object.AbsoluteSize
    local viewport = camera.ViewportSize
    return size.X > 0 and size.Y > 0
        and position.X + size.X > 0 and position.Y + size.Y > 0
        and position.X < viewport.X and position.Y < viewport.Y
end

local function expeditionFindText(root, expected)
    if not root then return nil end
    expected = expected:lower()
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and expeditionVisible(object)
            and expeditionClean(object.Text):lower() == expected then
            return object
        end
    end
    return nil
end

local function expeditionButtonOf(object)
    local cursor = object
    while cursor and cursor ~= player.PlayerGui do
        if cursor:IsA("TextButton") or cursor:IsA("ImageButton") then return cursor end
        cursor = cursor.Parent
    end
    return nil
end

local function expeditionClick(button)
    if not button or not expeditionVisible(button) then return false end
    local center = button.AbsolutePosition + button.AbsoluteSize / 2
    local inset = GuiService:GetGuiInset()
    local x = math.floor(center.X + 0.5)
    local y = math.floor(center.Y + inset.Y + 0.5)
    state.expeditionSuppressUntil = os.clock() + 0.65

    pcall(function()
        mousemove(x, y)
        task.wait(0.10)
        mouse1click()
    end)
    task.wait(0.06)
    pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.04)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    return true
end

-- Expedition Encounter -----------------------------------------------------
-- Encounter nodes pause the payload until the nearby NPC conversation is
-- completed. Store the namespace on state so the already-large main chunk
-- does not consume another long-lived local register.
state.expeditionEncounter = {}

function state.expeditionEncounter.modelPosition(model)
    local ok, pivot = pcall(function() return model:GetPivot() end)
    return ok and pivot.Position or nil
end

function state.expeditionEncounter.findPrompt()
    local now = os.clock()
    local cached = state.expeditionEncounterCachedPrompt
    if cached and cached.Parent and cached.Enabled then
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local model = cached.Parent:IsA("Model") and cached.Parent
            or cached:FindFirstAncestorWhichIsA("Model")
        local position = model and state.expeditionEncounter.modelPosition(model)
        if root and position and (root.Position - position).Magnitude <= 150 then
            return cached
        end
    end
    if now < state.expeditionEncounterNextScan
        or now < state.expeditionEncounterCooldownUntil then
        return nil
    end
    state.expeditionEncounterNextScan = now + 0.8
    state.expeditionEncounterCachedPrompt = nil

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local npcRoot = workspace:FindFirstChild("NPCS")
    if not root or not npcRoot then return nil end

    local best, bestDistance
    for _, prompt in ipairs(npcRoot:GetDescendants()) do
        if prompt:IsA("ProximityPrompt") and prompt.Enabled then
            local model = prompt.Parent:IsA("Model") and prompt.Parent
                or prompt:FindFirstAncestorWhichIsA("Model")
            local subText = model and expeditionClean(model:GetAttribute("SubText")):lower() or ""
            local position = model and state.expeditionEncounter.modelPosition(model)
            local distance = position and (root.Position - position).Magnitude or math.huge
            if subText == "encounter" and distance <= 150
                and (not bestDistance or distance < bestDistance) then
                best, bestDistance = prompt, distance
            end
        end
    end
    state.expeditionEncounterCachedPrompt = best
    return best
end

function state.expeditionEncounter.buttonLabel(button)
    local pieces = {}
    if button:IsA("TextButton") then
        local own = expeditionClean(button.Text)
        if own ~= "" then table.insert(pieces, own) end
    end
    for _, object in ipairs(button:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and expeditionVisible(object) then
            local text = expeditionClean(object.Text)
            if text ~= "" then table.insert(pieces, text) end
        end
    end
    return expeditionClean(table.concat(pieces, " | "))
end

function state.expeditionEncounter.buttons()
    local promptGui = player.PlayerGui:FindFirstChild("Prompt")
    if not promptGui then return {} end
    if promptGui:IsA("LayerCollector") and not promptGui.Enabled then return {} end

    local rows = {}
    for _, object in ipairs(promptGui:GetDescendants()) do
        if (object:IsA("TextButton") or object:IsA("ImageButton"))
            and expeditionVisible(object) then
            local interactable = true
            pcall(function() interactable = object.Interactable end)
            if object.Active and interactable then
                table.insert(rows, {
                    button = object,
                    label = state.expeditionEncounter.buttonLabel(object),
                    x = object.AbsolutePosition.X,
                    y = object.AbsolutePosition.Y,
                    width = object.AbsoluteSize.X,
                    height = object.AbsoluteSize.Y,
                    area = object.AbsoluteSize.X * object.AbsoluteSize.Y,
                })
            end
        end
    end
    return rows
end

function state.expeditionEncounter.chooseButton(rows)
    if #rows == 0 then return nil, "none" end

    -- Confirmation screens always accept the positive answer.
    for _, row in ipairs(rows) do
        local label = row.label:lower()
        if label == "yes" or label:match("^yes%s") then
            return row.button, "Yes"
        end
    end

    -- Initial offers and multi-answer screens use the leftmost answer.
    local choices = {}
    for _, row in ipairs(rows) do
        if row.width >= 120 and row.height >= 34 and row.y >= 350
            and row.area < 500000 then
            table.insert(choices, row)
        end
    end
    table.sort(choices, function(a, b)
        if math.abs(a.y - b.y) <= 12 then return a.x < b.x end
        return a.y > b.y
    end)
    if #choices >= 2 and math.abs(choices[1].y - choices[2].y) <= 20 then
        local first = choices[1].x < choices[2].x and choices[1] or choices[2]
        return first.button, first.label ~= "" and first.label or "first choice"
    end

    -- A normal speech page is one active 960x240 TextButton. The inactive
    -- fullscreen backdrop is filtered by buttons().
    table.sort(rows, function(a, b) return a.area > b.area end)
    return rows[1].button, rows[1].label ~= "" and rows[1].label or "dialogue"
end

function state.expeditionEncounter.run(mode, token, prompt)
    local function valid()
        return state.expeditionMode == mode and state.expeditionToken == token
    end
    local model = prompt and (prompt.Parent:IsA("Model") and prompt.Parent
        or prompt:FindFirstAncestorWhichIsA("Model"))
    local destination = model and state.expeditionEncounter.modelPosition(model)
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not destination or not humanoid or not root then
        return false, "character or NPC position unavailable"
    end

    local distance = (root.Position - destination).Magnitude
    log(("[Expedition] Encounter found: %s at %.1f studs"):format(
        expeditionClean(prompt.ObjectText), distance
    ))
    expeditionStatus.Text = "Encounter - walking to NPC"
    humanoid:MoveTo(destination)
    local moveDeadline = os.clock() + 18
    while valid() and os.clock() < moveDeadline do
        if (root.Position - destination).Magnitude <= 8 then break end
        humanoid:MoveTo(destination)
        task.wait(0.25)
    end
    if not valid() then return false, "controller stopped" end
    if (root.Position - destination).Magnitude > 10 then
        return false, "NPC could not be reached"
    end

    humanoid:MoveTo(root.Position)
    expeditionStatus.Text = "Encounter - interacting"
    local fired = false
    if fireproximityprompt then
        fired = pcall(function() fireproximityprompt(prompt, 0) end)
    end
    if not fired then sendKey("E") end

    local openDeadline = os.clock() + 8
    local firstRows = {}
    while valid() and os.clock() < openDeadline do
        firstRows = state.expeditionEncounter.buttons()
        if #firstRows > 0 then break end
        task.wait(0.20)
    end
    if #firstRows == 0 then return false, "dialogue did not open" end

    local firstButton, firstLabel = state.expeditionEncounter.chooseButton(firstRows)
    if not firstButton then return false, "first offer not found" end
    expeditionStatus.Text = "Encounter - first option"
    expeditionClick(firstButton)
    log("[Expedition] Encounter first option: " .. tostring(firstLabel))
    task.wait(0.60)

    local clicks = 0
    local missingPasses = 0
    local dialogDeadline = os.clock() + 30
    while valid() and os.clock() < dialogDeadline do
        local rows = state.expeditionEncounter.buttons()
        if #rows == 0 then
            missingPasses += 1
            if missingPasses >= 3 then
                task.wait(2.0)
                return true, ("completed after %d dialogue clicks"):format(clicks)
            end
            task.wait(0.25)
        else
            missingPasses = 0
            local button, label = state.expeditionEncounter.chooseButton(rows)
            if button then
                clicks += 1
                expeditionStatus.Text = ("Encounter - %s (%d)"):format(
                    tostring(label), clicks
                )
                expeditionClick(button)
                task.wait(0.55)
            else
                task.wait(0.20)
            end
        end
    end
    return false, ("dialogue timeout after %d clicks"):format(clicks)
end

-- Expedition route graph ----------------------------------------------------
-- The map exposes every connection as a separate thin ImageLabel. Its center,
-- length and Rotation give exact endpoints, which are matched to node buttons.
local EXPEDITION_LINE_ASSET = "104502633686062"
local EXPEDITION_REWARD_ASSETS = {
    MaterialFallback = "136417792145357",
    Fuel = "104121621042535",
}
local EXPEDITION_MATERIAL_NAMES = {
    "cursed timber",
    "lush dirt",
    "aqua shard",
    "mechanical scrap",
}
local EXPEDITION_REWARD_FRAME_ASSET = "106177749732532"

local function expeditionGraphCenter(object)
    return object.AbsolutePosition + object.AbsoluteSize / 2
end

local function expeditionGraphDistance(a, b)
    local dx, dy = a.X - b.X, a.Y - b.Y
    return math.sqrt(dx * dx + dy * dy)
end

local function expeditionGraphText(root)
    local parts = {}
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and tostring(object.Text) ~= "" then
            local cleaned = tostring(object.Text):gsub("<.->", "")
            table.insert(parts, cleaned)
        end
    end
    return table.concat(parts, " ")
end

local function expeditionGraphAmount(root)
    local value = expeditionGraphText(root):gsub(",", ""):match("(%d+)%s*x")
    return tonumber(value) or 0
end

local function expeditionGraphHasAsset(root, asset)
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("ImageLabel") or object:IsA("ImageButton"))
            and tostring(object.Image):find(asset, 1, true) then
            return true
        end
    end
    return false
end

local function expeditionGraphNodes(root)
    local nodes = {}
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("TextButton") or object:IsA("ImageButton"))
            and expeditionVisible(object) then
            local size = object.AbsoluteSize
            local point = expeditionGraphCenter(object)
            local ny = point.Y / camera.ViewportSize.Y
            local ownText = object:IsA("TextButton") and tostring(object.Text) or ""
            if ny < 0.75 and size.X >= 35 and size.X <= 75
                and size.Y >= 35 and size.Y <= 75 and ownText == ""
                and expeditionGraphText(object) == "" then
                table.insert(nodes, {
                    button = object,
                    point = point,
                    Material = 0,
                    Fuel = 0,
                    next = {},
                    previous = {},
                })
            end
        end
    end
    table.sort(nodes, function(a, b)
        if math.abs(a.point.X - b.point.X) < 4 then return a.point.Y < b.point.Y end
        return a.point.X < b.point.X
    end)
    for index, node in ipairs(nodes) do node.id = index end
    return nodes
end

local function expeditionGraphMaterialAssets(root)
    local assets = {[EXPEDITION_REWARD_ASSETS.MaterialFallback] = true}
    for _, object in ipairs(root:GetDescendants()) do
        if (object:IsA("TextButton") or object:IsA("ImageButton"))
            and expeditionVisible(object) then
            local text = expeditionGraphText(object):lower()
            local materialFound = false
            for _, name in ipairs(EXPEDITION_MATERIAL_NAMES) do
                if text:find(name, 1, true) then
                    materialFound = true
                    break
                end
            end
            if materialFound then
                for _, image in ipairs(object:GetDescendants()) do
                    if image:IsA("ImageLabel") or image:IsA("ImageButton") then
                        local id = tostring(image.Image):match("(%d+)")
                        if id and id ~= EXPEDITION_REWARD_FRAME_ASSET then
                            assets[id] = true
                        end
                    end
                end
            end
        end
    end
    return assets
end

local function expeditionGraphHasAnyAsset(root, assets)
    for asset in pairs(assets) do
        if expeditionGraphHasAsset(root, asset) then return true end
    end
    return false
end

local function expeditionGraphAttachRewards(root, nodes)
    local materialAssets = expeditionGraphMaterialAssets(root)
    for _, reward in ipairs(root:GetDescendants()) do
        if (reward:IsA("TextButton") or reward:IsA("ImageButton"))
            and expeditionVisible(reward) then
            local point = expeditionGraphCenter(reward)
            local ny = point.Y / camera.ViewportSize.Y
            local amount = expeditionGraphAmount(reward)
            if ny < 0.75 and amount > 0 then
                local kind
                if expeditionGraphHasAnyAsset(reward, materialAssets) then
                    kind = "Material"
                elseif expeditionGraphHasAsset(reward, EXPEDITION_REWARD_ASSETS.Fuel) then
                    kind = "Fuel"
                end
                if kind then
                    local best, bestScore
                    for _, node in ipairs(nodes) do
                        local dx = math.abs(node.point.X - point.X)
                        local dy = math.abs(node.point.Y - point.Y)
                        if dx <= 60 and dy >= 18 and dy <= 155 then
                            local score = dx * 4 + dy
                            if not bestScore or score < bestScore then
                                best, bestScore = node, score
                            end
                        end
                    end
                    if best then best[kind] = math.max(best[kind], amount) end
                end
            end
        end
    end
end

local function expeditionGraphNearest(nodes, point, maximum)
    local best, bestDistance
    for _, node in ipairs(nodes) do
        local distance = expeditionGraphDistance(node.point, point)
        if distance <= maximum and (not bestDistance or distance < bestDistance) then
            best, bestDistance = node, distance
        end
    end
    return best
end

local function expeditionGraphAttachEdges(root, nodes)
    local seen = {}
    for _, line in ipairs(root:GetDescendants()) do
        if line:IsA("ImageLabel") and expeditionVisible(line)
            and tostring(line.Image):find(EXPEDITION_LINE_ASSET, 1, true)
            and line.AbsoluteSize.X >= 80 and line.AbsoluteSize.Y <= 5 then
            local middle = expeditionGraphCenter(line)
            local radians = math.rad(line.Rotation)
            local half = line.AbsoluteSize.X / 2
            local vector = Vector2.new(
                math.cos(radians) * half,
                math.sin(radians) * half
            )
            local a = expeditionGraphNearest(nodes, middle - vector, 70)
            local b = expeditionGraphNearest(nodes, middle + vector, 70)
            if a and b and a ~= b then
                if a.point.X > b.point.X then a, b = b, a end
                local key = tostring(a.id) .. ">" .. tostring(b.id)
                if not seen[key] then
                    seen[key] = true
                    table.insert(a.next, b)
                    table.insert(b.previous, a)
                end
            end
        end
    end
end

local function expeditionGraphBetter(a, b, priority)
    if not b then return true end
    local secondary = priority == "Material" and "Fuel" or "Material"
    if a[priority] ~= b[priority] then return a[priority] > b[priority] end
    return a[secondary] > b[secondary]
end

local function expeditionGraphSolve(nodes, priority)
    local bestAt = {}
    for _, node in ipairs(nodes) do
        local bestParent
        for _, parent in ipairs(node.previous) do
            local candidate = bestAt[parent]
            if candidate and expeditionGraphBetter(candidate, bestParent, priority) then
                bestParent = candidate
            end
        end
        if bestParent then
            local path = {}
            for _, old in ipairs(bestParent.path) do table.insert(path, old) end
            table.insert(path, node)
            bestAt[node] = {
                Material = bestParent.Material + node.Material,
                Fuel = bestParent.Fuel + node.Fuel,
                path = path,
            }
        elseif #node.previous == 0 then
            bestAt[node] = {
                Material = node.Material,
                Fuel = node.Fuel,
                path = {node},
            }
        end
    end
    local best
    for _, node in ipairs(nodes) do
        local result = bestAt[node]
        if #node.next == 0 and result
            and expeditionGraphBetter(result, best, priority) then
            best = result
        end
    end
    return best
end

local function expeditionApplyBestRoute(profile)
    local root = player.PlayerGui:FindFirstChild("Prompt")
    local priority = profile.expedition and profile.expedition.routePriority or "Off"
    if not root or priority == "Off" then return false, "route disabled or map missing" end

    local nodes = expeditionGraphNodes(root)
    expeditionGraphAttachRewards(root, nodes)
    expeditionGraphAttachEdges(root, nodes)
    local result = expeditionGraphSolve(nodes, priority)
    if not result or #result.path < 3 then
        return false, ("graph incomplete: nodes=%d"):format(#nodes)
    end

    local edges = 0
    for _, node in ipairs(nodes) do edges += #node.next end
    log(("[ExpeditionMap] %s best · Material=%d Fuel=%d · nodes=%d edges=%d"):format(
        priority, result.Material, result.Fuel, #nodes, edges
    ))

    -- Start and boss are mandatory. Intermediate nodes fix every branch.
    for index = 2, #result.path - 1 do
        if not expeditionClick(result.path[index].button) then
            return false, "node click failed: N" .. tostring(result.path[index].id)
        end
        task.wait(0.18)
    end
    return true, ("Material=%d Fuel=%d"):format(result.Material, result.Fuel)
end

local function expeditionUpgradeButtons(prompt)
    if not prompt or not expeditionFindText(prompt, "Select an upgrade!") then return {} end
    local buttons, seen = {}, {}
    for _, object in ipairs(prompt:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and expeditionVisible(object)
            and expeditionClean(object.Text):lower() == "select upgrade" then
            local button = expeditionButtonOf(object)
            if button and expeditionVisible(button) and not seen[button] then
                seen[button] = true
                table.insert(buttons, button)
            end
        end
    end
    table.sort(buttons, function(a, b)
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)
    return buttons
end

local anvilNextFullScan = 0
local anvilCachedButtons = {}

local function expeditionAnvilButtons()
    local now = os.clock()
    if now < anvilNextFullScan then
        local visibleCached = {}
        for _, button in ipairs(anvilCachedButtons) do
            if button and button.Parent and expeditionVisible(button) then
                table.insert(visibleCached, button)
            end
        end
        return visibleCached
    end
    anvilNextFullScan = now + 0.75

    local titleFound = false
    local buttons, seen = {}, {}
    for _, object in ipairs(player.PlayerGui:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and expeditionVisible(object) then
            local lower = expeditionClean(object.Text):lower()
            if lower == "stat anvil" or lower == "select a stat upgrade!" then
                titleFound = true
            elseif lower == "select upgrade" then
                local button = expeditionButtonOf(object)
                if button and expeditionVisible(button) and not seen[button] then
                    seen[button] = true
                    table.insert(buttons, button)
                end
            end
        end
    end
    if not titleFound then
        anvilCachedButtons = {}
        return {}
    end
    table.sort(buttons, function(a, b)
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)
    anvilCachedButtons = buttons
    return buttons
end

local expeditionMapLaunchCache = nil
local expeditionMapLaunchNextScan = 0

local function expeditionMapLaunchButton()
    if expeditionMapLaunchCache and expeditionMapLaunchCache.Parent
        and expeditionVisible(expeditionMapLaunchCache) then
        return expeditionMapLaunchCache
    end
    local now = os.clock()
    if now < expeditionMapLaunchNextScan then return nil end
    expeditionMapLaunchNextScan = now + 1.0

    -- This lookup is only called while waiting at an odd checkpoint. Prefer
    -- the known small HUD roots and use PlayerGui only as a rare fallback.
    local roots = {
        player.PlayerGui:FindFirstChild("RightGameHUD"),
        player.PlayerGui:FindFirstChild("RightHUD"),
        player.PlayerGui:FindFirstChild("GameHUD"),
    }
    for _, root in ipairs(roots) do
        if root then
            local text = expeditionFindText(root, "Expedition Map")
            local button = expeditionButtonOf(text)
            if button and expeditionVisible(button) then
                expeditionMapLaunchCache = button
                return button
            end
        end
    end

    local text = expeditionFindText(player.PlayerGui, "Expedition Map")
    local button = expeditionButtonOf(text)
    if button and expeditionVisible(button) then
        expeditionMapLaunchCache = button
        return button
    end
    return nil
end

local function expeditionSnapshot()
    local prompt = player.PlayerGui:FindFirstChild("Prompt")
    local bottom = player.PlayerGui:FindFirstChild("BottomHUD")
    local defeat = expeditionFindText(prompt, "Defeat")
    local repeatStage = expeditionFindText(prompt, "Repeat Stage")
    local confirmTitle = expeditionFindText(prompt, "Continue Expedition")
    local promptContinue = expeditionFindText(prompt, "Continue")
    local confirmVisible = confirmTitle or (promptContinue and not defeat)
    local mainContinue = expeditionFindText(bottom, "Continue")
    local upgrades = expeditionUpgradeButtons(prompt)
    local anvils = expeditionAnvilButtons()
    local mapTitle = expeditionFindText(prompt, "Expedition Map")
    local mapBack = mapTitle and expeditionFindText(prompt, "Back") or nil
    local encounterPrompt = state.expeditionEncounterRunning and nil
        or state.expeditionEncounter.findPrompt()
    return {
        defeat = defeat,
        repeatButton = expeditionButtonOf(repeatStage),
        confirm = confirmVisible,
        confirmButton = confirmVisible and expeditionButtonOf(promptContinue) or nil,
        mainButton = expeditionButtonOf(mainContinue),
        upgrades = upgrades,
        anvils = anvils,
        mapOpen = mapTitle ~= nil,
        mapBackButton = expeditionButtonOf(mapBack),
        encounterPrompt = encounterPrompt,
    }
end

local function saveExpeditionRecording()
    if not state.selectedExpedition
        or not state.expeditionProfiles[state.selectedExpedition] then return end
    local profile = state.expeditionProfiles[state.selectedExpedition]
    profile.expedition = profile.expedition or {}
    profile.expedition.events = state.expeditionEvents
    saveConfig()
end

local startExpeditionSequenceWorker
local expeditionManagerOpen

local function startExpeditionController(mode)
    if state.recording or state.playing or state.smartRunning or state.expeditionMode then
        log("Stop other operations before starting Expedition")
        return false
    end
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    if not profile then log("Select an Expedition profile first") return false end
    profile.expedition = type(profile.expedition) == "table"
        and profile.expedition or {events = {}}
    profile.expedition.events = type(profile.expedition.events) == "table"
        and profile.expedition.events or {}
    profile.expedition.steps = type(profile.expedition.steps) == "table"
        and profile.expedition.steps or {}
    if mode == "auto" and #profile.expedition.events == 0
        and #profile.expedition.steps == 0 then
        log("Add at least one Expedition sequence step")
        return false
    end

    state.expeditionMode = mode
    state.expeditionToken += 1
    state.expeditionTimeline = 0
    state.expeditionStarted = false
    state.expeditionBlocked = true
    state.expeditionIndex = 1
    state.expeditionAwaitingResume = false
    state.expeditionEvents = mode == "record" and {} or profile.expedition.events
    state.expeditionRuntimeSlots = {}
    state.expeditionCheckpointCount = 0
    state.expeditionCheckpointLatched = false
    state.expeditionMapNeeded = false
    state.expeditionMapRunning = false
    state.expeditionDefeatSeenAt = 0
    state.expeditionEncounterRunning = false
    state.expeditionEncounterCachedPrompt = nil
    state.expeditionEncounterNextScan = 0
    state.expeditionEncounterCooldownUntil = 0
    state.expeditionSequenceToken += 1
    local token = state.expeditionToken
    expeditionRecordButton.Text = mode == "record" and "RECORDING..." or "RECORD RUN"
    expeditionAutoButton.Text = mode == "auto" and "SEQUENCE: RUNNING" or "RUN SEQUENCE"

    task.spawn(function()
        local lastClock = os.clock()
        local actionCooldown = 0
        local lastState = ""

        while state.expeditionMode == mode and state.expeditionToken == token do
            local now = os.clock()
            local delta = math.min(now - lastClock, 0.25)
            lastClock = now
            local snapshot = expeditionSnapshot()
            local stateName = "BATTLE"
            local blocked = false

            if not snapshot.defeat then
                state.expeditionDefeatSeenAt = 0
            end

            if snapshot.defeat then
                stateName = "DEFEAT"
                blocked = true
                if state.expeditionDefeatSeenAt == 0 then
                    state.expeditionDefeatSeenAt = now
                    expeditionStatus.Text = "Defeat · waiting for result UI"
                    log("[Expedition] Defeat detected; waiting for stable Repeat Stage")
                end
                if mode == "auto" and now - state.expeditionDefeatSeenAt >= 0.8
                    and now >= actionCooldown then
                    if type(sharedEnv.__TowerChallengeShouldExit) == "function" then
                        local hookOk, shouldExit = pcall(sharedEnv.__TowerChallengeShouldExit)
                        if hookOk and shouldExit then
                            actionCooldown = os.clock() + 0.5
                            continue
                        end
                    end
                    local currentPrompt = player.PlayerGui:FindFirstChild("Prompt")
                    local freshRepeatText = expeditionFindText(currentPrompt, "Repeat Stage")
                    local freshRepeatButton = expeditionButtonOf(freshRepeatText)
                    if not freshRepeatButton then
                        actionCooldown = os.clock() + 0.25
                        continue
                    end
                    expeditionStatus.Text = "Defeat · clicking Repeat Stage"
                    expeditionClick(freshRepeatButton)
                    actionCooldown = os.clock() + 2.0
                    state.expeditionStarted = false
                    state.expeditionTimeline = 0
                    state.expeditionIndex = 1
                    state.expeditionAwaitingResume = false
                    state.expeditionSequenceToken += 1
                    state.expeditionSequenceRunning = false
                    state.expeditionCheckpointCount = 0
                    state.expeditionCheckpointLatched = false
                    state.expeditionMapNeeded = false
                    state.expeditionMapRunning = false
                    state.expeditionDefeatSeenAt = 0
                    state.expeditionEncounterRunning = false
                    state.expeditionEncounterCachedPrompt = nil
                    state.expeditionEncounterCooldownUntil = os.clock() + 2.0
                    unlockAutomationCamera()
                    log("[Expedition] Defeat -> Repeat Stage")
                end
            elseif state.expeditionEncounterRunning or snapshot.encounterPrompt then
                stateName = "ENCOUNTER"
                blocked = true
                if snapshot.encounterPrompt and not state.expeditionEncounterRunning
                    and now >= actionCooldown then
                    state.expeditionEncounterRunning = true
                    actionCooldown = now + 1.0
                    local activeEncounterPrompt = snapshot.encounterPrompt
                    task.spawn(function()
                        local ok, success, detail = pcall(
                            state.expeditionEncounter.run,
                            mode,
                            token,
                            activeEncounterPrompt
                        )
                        if state.expeditionMode == mode
                            and state.expeditionToken == token then
                            state.expeditionEncounterRunning = false
                            state.expeditionEncounterCachedPrompt = nil
                            state.expeditionEncounterNextScan = os.clock() + 1.0
                            state.expeditionEncounterCooldownUntil = os.clock() + 4.0
                            actionCooldown = os.clock() + 1.0
                            local message = ok and tostring(detail)
                                or ("worker error: " .. tostring(success))
                            log(("[Expedition] Encounter %s - %s"):format(
                                ok and success and "completed" or "failed",
                                message
                            ))
                            expeditionStatus.Text = ok and success
                                and "Encounter completed - waiting for return"
                                or "Encounter failed - retry scheduled"
                        end
                    end)
                end
            elseif snapshot.mapOpen then
                stateName = "MAP"
                blocked = true
                if not state.expeditionMapRunning and now >= actionCooldown then
                    state.expeditionMapRunning = true
                    expeditionStatus.Text = "Expedition Map · calculating route"
                    task.spawn(function()
                        task.wait(0.25)
                        local ok, detail = expeditionApplyBestRoute(profile)
                        if state.expeditionMode == mode
                            and state.expeditionToken == token then
                            log(("[ExpeditionMap] %s · %s"):format(
                                ok and "Applied" or "Failed", tostring(detail)
                            ))
                            task.wait(0.25)
                            local currentPrompt = player.PlayerGui:FindFirstChild("Prompt")
                            local backText = expeditionFindText(currentPrompt, "Back")
                            local backButton = expeditionButtonOf(backText)
                            if backButton then
                                expeditionClick(backButton)
                                log("[ExpeditionMap] Back")
                            else
                                log("[ExpeditionMap] Back button was not found")
                            end
                            state.expeditionMapNeeded = false
                            state.expeditionMapRunning = false
                            actionCooldown = os.clock() + 0.8
                        end
                    end)
                end
            elseif #snapshot.anvils > 0 then
                stateName = "ANVIL"
                blocked = true
                if now >= actionCooldown then
                    local choice = math.random(1, #snapshot.anvils)
                    expeditionStatus.Text = ("Stat Anvil · random choice %d/%d"):format(
                        choice, #snapshot.anvils
                    )
                    expeditionClick(snapshot.anvils[choice])
                    actionCooldown = os.clock() + 0.75
                    log(("[Expedition] Stat Anvil random upgrade %d/%d"):format(
                        choice, #snapshot.anvils
                    ))
                end
            elseif #snapshot.upgrades > 0 then
                stateName = "UPGRADE"
                blocked = true
                if now >= actionCooldown then
                    local choice = math.random(1, #snapshot.upgrades)
                    expeditionStatus.Text = ("Upgrade · random choice %d/%d"):format(
                        choice, #snapshot.upgrades
                    )
                    expeditionClick(snapshot.upgrades[choice])
                    actionCooldown = os.clock() + 1.0
                    log(("[Expedition] Random upgrade %d/%d"):format(
                        choice, #snapshot.upgrades
                    ))
                end
            elseif snapshot.confirm then
                stateName = "CONFIRM"
                blocked = true
                if snapshot.confirmButton and now >= actionCooldown then
                    expeditionStatus.Text = "Checkpoint · confirming Continue"
                    expeditionClick(snapshot.confirmButton)
                    state.expeditionAwaitingResume = true
                    state.expeditionResumeAt = os.clock() + 1.25
                    actionCooldown = os.clock() + 0.8
                end
            elseif state.expeditionAwaitingResume then
                stateName = "SYNC"
                blocked = true
                if not snapshot.confirm and now >= state.expeditionResumeAt then
                    state.expeditionAwaitingResume = false
                    state.expeditionCheckpointLatched = false
                    if not state.expeditionStarted then
                        state.expeditionStarted = true
                        state.expeditionTimeline = 0
                        state.expeditionIndex = 1
                        lockExpeditionCamera(profile)
                        log("[Expedition] Sequence synchronized; character position unchanged")
                        if mode == "auto" and #profile.expedition.steps > 0
                            and startExpeditionSequenceWorker then
                            startExpeditionSequenceWorker(profile, token)
                        end
                    end
                end
            elseif snapshot.mainButton then
                stateName = "CHECKPOINT"
                blocked = true
                if not state.expeditionCheckpointLatched then
                    state.expeditionCheckpointLatched = true
                    state.expeditionCheckpointCount += 1
                    local priority = profile.expedition.routePriority or "Off"
                    state.expeditionMapNeeded = priority ~= "Off"
                        and state.expeditionCheckpointCount % 2 == 1
                    log(("[Expedition] Checkpoint %d · route=%s%s"):format(
                        state.expeditionCheckpointCount,
                        tostring(priority),
                        state.expeditionMapNeeded and " · map scheduled" or ""
                    ))
                end
                if state.expeditionMapNeeded then
                    if expeditionManagerOpen and expeditionManagerOpen() then
                        if now >= actionCooldown then
                            expeditionStatus.Text = "Checkpoint · closing Unit Manager"
                            sendKey("F")
                            actionCooldown = os.clock() + 0.65
                            log("[ExpeditionMap] Unit Manager closed before opening map")
                        end
                    else
                        local mapLaunchButton = now >= actionCooldown
                            and expeditionMapLaunchButton() or nil
                        if mapLaunchButton and now >= actionCooldown then
                            expeditionStatus.Text = "Checkpoint · opening Expedition Map"
                            expeditionClick(mapLaunchButton)
                            actionCooldown = os.clock() + 1.0
                        end
                    end
                elseif now >= actionCooldown then
                    expeditionStatus.Text = "Checkpoint · clicking Continue"
                    expeditionClick(snapshot.mainButton)
                    actionCooldown = os.clock() + 0.8
                end
            elseif not state.expeditionStarted then
                stateName = "WAIT CHECKPOINT"
                blocked = true
            end

            state.expeditionBlocked = blocked
            if state.expeditionStarted and not blocked then
                state.expeditionTimeline += delta

                if mode == "auto" and #profile.expedition.steps == 0 then
                    while state.expeditionIndex <= #state.expeditionEvents do
                        local event = state.expeditionEvents[state.expeditionIndex]
                        if (tonumber(event.t) or 0) > state.expeditionTimeline then break end
                        restoreCamera(profile)
                        if event.type == "key" then
                            sendKey(event.key)
                        elseif event.type == "click" then
                            sendClick(event, profile)
                        end
                        state.expeditionIndex += 1
                    end
                end
            end

            if stateName ~= lastState then
                lastState = stateName
                log("[Expedition] State: " .. stateName)
            end
            if not state.expeditionSequenceRunning or blocked then
                expeditionStatus.Text = ("%s · %s · %.2fs"):format(
                    mode == "record" and "RECORD" or "AUTO",
                    stateName, state.expeditionTimeline
                )
            end
            task.wait(0.20)
        end
    end)
    return true
end

local function stopExpedition(message)
    if state.expeditionMode == "record" then saveExpeditionRecording() end
    state.expeditionMode = nil
    state.expeditionToken += 1
    state.expeditionStarted = false
    state.expeditionBlocked = true
    state.expeditionSequenceToken += 1
    state.expeditionSequenceRunning = false
    state.expeditionMapRunning = false
    state.expeditionMapNeeded = false
    state.expeditionEncounterRunning = false
    state.expeditionEncounterCachedPrompt = nil
    state.expeditionEncounterNextScan = 0
    state.expeditionEncounterCooldownUntil = 0
    expeditionRecordButton.Text = "RECORD RUN"
    expeditionAutoButton.Text = "RUN SEQUENCE"
    unlockAutomationCamera()
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    local count = profile and profile.expedition
        and #(profile.expedition.steps or {}) or 0
    expeditionStatus.Text = ("%s · %d saved steps"):format(
        message or "Stopped", count
    )
    log("[Expedition] " .. (message or "Stopped"))
end

expeditionRecordButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        stopExpedition("Recording stopped")
    else
        startExpeditionController("record")
    end
end)

expeditionStopButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        stopExpedition("Stopped by user")
    else
        expeditionStatus.Text = "Expedition is not running"
    end
end)

expeditionAutoButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        stopExpedition("Auto run stopped")
    else
        startExpeditionController("auto")
        if type(sharedEnv.__TowerChallengeFarmStarted) == "function" then
            pcall(sharedEnv.__TowerChallengeFarmStarted, state.selectedExpedition)
        end
    end
end)

expeditionSaveStartButton.MouseButton1Click:Connect(function()
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    if not profile then log("Select an Expedition profile first") return end
    local characterSaved = saveStartState(profile)
    saveConfig()
    expeditionStatus.Text = characterSaved
        and "Expedition camera and character start saved"
        or "Camera saved; character position was unavailable"
end)

expeditionClearButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        expeditionStatus.Text = "Stop Expedition before clearing the timeline"
        return
    end
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    if not profile then log("Select an Expedition profile first") return end
    profile.expedition = profile.expedition or {}
    profile.expedition.events = {}
    saveConfig()
    expeditionStatus.Text = "Expedition timeline cleared"
end)

for slot, button in ipairs(expeditionSlotButtons) do
    button.MouseButton1Click:Connect(function()
        if state.expeditionMode then
            expeditionStatus.Text = "Stop Expedition before editing"
            return
        end
        state.expeditionEditSlot = slot
        refreshExpeditionSequenceVisual(state.selectedExpedition
            and state.expeditionProfiles[state.selectedExpedition])
    end)
end

local function expeditionEditorProfile()
    local name = expeditionNameBox.Text:match("^%s*(.-)%s*$")
    local profile = state.selectedExpedition
        and state.expeditionProfiles[state.selectedExpedition]
    if name ~= "" and (not profile or name ~= state.selectedExpedition) then
        profile = selectExpeditionProfile(name, true)
    end
    if not profile then log("Select or create an Expedition profile first") return nil end
    profile.expedition = type(profile.expedition) == "table"
        and profile.expedition or {events = {}, steps = {}}
    profile.expedition.steps = type(profile.expedition.steps) == "table"
        and profile.expedition.steps or {}
    return profile
end

local function addExpeditionStep(step)
    if state.expeditionMode then
        expeditionStatus.Text = "Stop Expedition before editing"
        return
    end
    local profile = expeditionEditorProfile()
    if not profile then return end
    step.slot = state.expeditionEditSlot
    table.insert(profile.expedition.steps, step)
    saveConfig()
    refreshExpeditionSequenceVisual(profile)
    log(("[Expedition] Added %s for slot %d"):format(step.type, step.slot))
end

expeditionPointButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        expeditionStatus.Text = "Stop Expedition before saving the camera"
        return
    end
    local profile = expeditionEditorProfile()
    if not profile then return end
    saveExpeditionCamera(profile)
    saveConfig()
    expeditionStatus.Text = "Expedition camera saved · character position is not saved"
    log("[Expedition] Camera saved without character position")
end)

expeditionAddPlaceButton.MouseButton1Click:Connect(function()
    if not state.expeditionDraftPoint then
        expeditionStatus.Text = "Save a map point with F7 first"
        return
    end
    local point = {}
    for key, value in pairs(state.expeditionDraftPoint) do point[key] = value end
    addExpeditionStep({type = "PLACE", point = point})
    state.expeditionDraftPoint = nil
end)

expeditionAddUpgradeButton.MouseButton1Click:Connect(function()
    addExpeditionStep({type = "UPGRADE", toMax = false})
end)

expeditionAddMaxButton.MouseButton1Click:Connect(function()
    addExpeditionStep({type = "UPGRADE", toMax = true})
end)

expeditionAddAutoButton.MouseButton1Click:Connect(function()
    addExpeditionStep({type = "AUTO"})
end)

expeditionUndoButton.MouseButton1Click:Connect(function()
    if state.expeditionMode then
        expeditionStatus.Text = "Stop Expedition before editing"
        return
    end
    local profile = expeditionEditorProfile()
    if not profile then return end
    local removed = table.remove(profile.expedition.steps)
    saveConfig()
    refreshExpeditionSequenceVisual(profile)
    log(removed and ("[Expedition] Removed " .. tostring(removed.type))
        or "[Expedition] Sequence is already empty")
end)

local smartSlotCenters = {}
local slotKeyNames = {"One", "Two", "Three", "Four", "Five", "Six"}

local function uiText(object)
    return tostring(object.Text or ""):gsub("<.->", ""):gsub("%s+", " ")
end

local function uiVisible(object)
    local cursor = object
    while cursor and cursor ~= player.PlayerGui do
        if cursor:IsA("LayerCollector") and not cursor.Enabled then return false end
        if cursor:IsA("GuiObject") and not cursor.Visible then return false end
        if cursor:IsA("CanvasGroup") and cursor.GroupTransparency >= 0.98 then
            return false
        end
        cursor = cursor.Parent
    end
    return object.AbsoluteSize.X > 0 and object.AbsoluteSize.Y > 0
end

local function uiNumber(text)
    return tonumber((tostring(text):gsub(",", ""):match("[%d%.]+")))
end

local function readGameUI()
    local result = {prices = {}, limits = {}}
    local priceRows = {}
    local limitRows = {}
    local vp = camera.ViewportSize
    local topHud = player.PlayerGui:FindFirstChild("TopGameHUD")
    local bottomHud = player.PlayerGui:FindFirstChild("BottomHUD")

    if topHud then
        for _, object in ipairs(topHud:GetDescendants()) do
            if (object:IsA("TextLabel") or object:IsA("TextButton"))
                and uiVisible(object) then
                local text = uiText(object)
                local wave, waveMax = text:match("(%d+)%s*/%s*(%d+)")
                if wave and waveMax then
                    result.wave, result.waveMax = tonumber(wave), tonumber(waveMax)
                    break
                end
            end
        end
    end

    if bottomHud then
        for _, object in ipairs(bottomHud:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and uiVisible(object) then
            local text = uiText(object)
            local path = object:GetFullName():lower()
            local center = object.AbsolutePosition + object.AbsoluteSize / 2
            local nx = vp.X > 0 and center.X / vp.X or 0
            local ny = vp.Y > 0 and center.Y / vp.Y or 0

            local plain = text:match("^%s*([%d,]+)%s*$")
            if plain and not path:find("textbutton", 1, true)
                and nx > 0.43 and nx < 0.57 and ny > 0.65 and ny < 0.84 then
                result.money = uiNumber(plain)
            end

            local priceText = text:match("^%s*¥%s*([%d,]+)%s*$")
            if priceText and path:find("textbutton", 1, true) then
                table.insert(priceRows, {
                    nx = nx,
                    price = uiNumber(priceText),
                })
            end

            if object:IsA("TextLabel") and path:find("textbutton", 1, true) then
                local placed, maximum = text:match("^%s*(%d+)%s*/%s*(%d+)%s*$")
                if placed and maximum then
                    table.insert(limitRows, {
                        nx = nx,
                        placed = tonumber(placed),
                        max = tonumber(maximum),
                    })
                end
            end
        end
    end
    end

    table.sort(priceRows, function(a, b) return a.nx < b.nx end)
    if #priceRows >= 6 or #smartSlotCenters == 0 then
        smartSlotCenters = {}
        for slot, row in ipairs(priceRows) do smartSlotCenters[slot] = row.nx end
    end
    for _, row in ipairs(priceRows) do
        local bestSlot, bestDistance
        for slot, centerX in ipairs(smartSlotCenters) do
            local distance = math.abs(centerX - row.nx)
            if not bestDistance or distance < bestDistance then
                bestSlot, bestDistance = slot, distance
            end
        end
        if bestSlot and bestDistance < 0.08 then result.prices[bestSlot] = row.price end
    end

    for _, row in ipairs(limitRows) do
        local bestSlot, bestDistance
        for slot, centerX in ipairs(smartSlotCenters) do
            local distance = math.abs(centerX - row.nx)
            if not bestDistance or distance < bestDistance then
                bestSlot, bestDistance = slot, distance
            end
        end
        if bestSlot and bestDistance < 0.08 then
            result.limits[bestSlot] = {
                placed = row.placed,
                max = row.max,
            }
        end
    end
    return result
end

expeditionManagerOpen = function()
    local manager = player.PlayerGui:FindFirstChild("UnitManager")
    return manager and expeditionFindText(manager, "Close") ~= nil
end

local function expeditionEnsureManagerOpen(sequenceToken)
    if expeditionManagerOpen() then return true end
    sendKey("F")
    local deadline = os.clock() + 3
    repeat
        if state.expeditionSequenceToken ~= sequenceToken then return false end
        task.wait(0.10)
    until expeditionManagerOpen() or os.clock() >= deadline
    return expeditionManagerOpen()
end

local expeditionIgnoredNames = {
    ["auto upgrade"] = true, ["priority"] = true, ["none"] = true,
    ["first"] = true, ["last"] = true, ["strongest"] = true,
    ["weakest"] = true, ["close"] = true, ["sell all"] = true,
}

local function expeditionManagerCards()
    local manager = player.PlayerGui:FindFirstChild("UnitManager")
    local cards = {}
    if not manager or not expeditionManagerOpen() then return cards end
    local names, upgrades, prices, autoButtons = {}, {}, {}, {}

    for _, object in ipairs(manager:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton")) and uiVisible(object) then
            local text = expeditionClean(object.Text)
            local lower = text:lower()
            local path = object:GetFullName():lower()
            local center = object.AbsolutePosition + object.AbsoluteSize / 2
            local nx = center.X / camera.ViewportSize.X
            local ny = center.Y / camera.ViewportSize.Y
            local level, maximum = text:match("[Uu]pgrade%s+(%d+)%s*/%s*(%d+)")

            if level and maximum then
                table.insert(upgrades, {
                    object = object, nx = nx, ny = ny,
                    level = tonumber(level), max = tonumber(maximum),
                })
            elseif lower == "auto upgrade" then
                table.insert(autoButtons, {
                    button = expeditionButtonOf(object), nx = nx, ny = ny,
                })
            elseif path:find("primarybutton", 1, true) and text:match("%d")
                and not text:find("/", 1, true) then
                table.insert(prices, {nx = nx, ny = ny, value = uiNumber(text)})
            elseif path:find("scrollingframe", 1, true)
                and path:find("textbutton", 1, true)
                and text ~= "" and not expeditionIgnoredNames[lower]
                and not lower:find("upgrade", 1, true) then
                table.insert(names, {name = text, nx = nx, ny = ny})
            end
        end
    end

    for _, nameRow in ipairs(names) do
        local card = {name = nameRow.name, nx = nameRow.nx}
        local bestUpgradeDistance
        for _, row in ipairs(upgrades) do
            -- Cards are arranged in multiple rows. X alone would map a lower
            -- card to the button in the same column of the first row.
            local distance = math.abs(row.nx - nameRow.nx) * 3
                + math.abs((row.ny - nameRow.ny) - 0.03)
            if not bestUpgradeDistance or distance < bestUpgradeDistance then
                bestUpgradeDistance = distance
                card.level, card.max = row.level, row.max
                card.upgradeButton = expeditionButtonOf(row.object)
                card.upgradeY = row.ny
            end
        end
        local bestPriceDistance
        for _, row in ipairs(prices) do
            local distance = math.abs(row.nx - nameRow.nx)
                + math.abs(row.ny - (card.upgradeY or row.ny) - 0.025)
            if not bestPriceDistance or distance < bestPriceDistance then
                bestPriceDistance = distance
                card.price = row.value
            end
        end
        local bestAutoDistance
        for _, row in ipairs(autoButtons) do
            local distance = math.abs(row.nx - nameRow.nx) * 3
                + math.abs((row.ny - nameRow.ny) - 0.155)
            if not bestAutoDistance or distance < bestAutoDistance then
                bestAutoDistance = distance
                card.autoButton = row.button
                card.autoNx = row.nx
                card.autoNy = row.ny
            end
        end
        cards[card.name] = card
    end
    return cards
end

local function expeditionButtonVisualSignature(button)
    if not button then return "missing" end
    local parts = {}
    local function capture(object)
        if object:IsA("GuiObject") then
            local color = object.BackgroundColor3
            table.insert(parts, ("B%.3f,%.3f,%.3f:%s"):format(
                color.R, color.G, color.B, tostring(object.Visible)
            ))
        end
        if object:IsA("TextLabel") or object:IsA("TextButton") then
            table.insert(parts, "T:" .. expeditionClean(object.Text):lower())
        end
    end
    capture(button)
    for _, object in ipairs(button:GetDescendants()) do capture(object) end
    return table.concat(parts, "|")
end

local function expeditionMovePointerAway()
    local viewport = camera.ViewportSize
    pcall(function()
        VirtualInputManager:SendMouseMoveEvent(
            math.floor(viewport.X * 0.50), 8, game
        )
    end)
end

local function expeditionSequenceReady(controllerToken, sequenceToken)
    while state.expeditionMode == "auto"
        and state.expeditionToken == controllerToken
        and state.expeditionSequenceToken == sequenceToken do
        if not state.expeditionBlocked then return true end
        task.wait(0.15)
    end
    return false
end

local function expeditionReadBalance()
    local bottom = player.PlayerGui:FindFirstChild("BottomHUD")
    if not bottom then return nil end
    local viewport = camera.ViewportSize
    local bestValue, bestScore
    for _, object in ipairs(bottom:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton")) and uiVisible(object) then
            local text = uiText(object)
            local plain = text:match("^%s*([%d,]+)%s*$")
            local path = object:GetFullName():lower()
            if plain and not path:find("textbutton", 1, true) then
                local center = object.AbsolutePosition + object.AbsoluteSize / 2
                local nx = viewport.X > 0 and center.X / viewport.X or 0
                local ny = viewport.Y > 0 and center.Y / viewport.Y or 0
                if nx > 0.35 and nx < 0.65 and ny > 0.60 and ny < 0.95 then
                    local score = math.abs(nx - 0.50) + math.abs(ny - 0.78) * 0.35
                    if not bestScore or score < bestScore then
                        bestScore = score
                        bestValue = uiNumber(plain)
                    end
                end
            end
        end
    end
    return bestValue
end

local function expeditionWaitMoney(amount, controllerToken, sequenceToken, label)
    local lastReported, lastLogAt, missingSince = nil, 0, nil
    local affordableSince = nil
    while expeditionSequenceReady(controllerToken, sequenceToken) do
        local money = expeditionReadBalance() or readGameUI().money
        expeditionStatus.Text = ("%s · money %s/%s"):format(
            label, tostring(money or "?"), tostring(amount or "?")
        )
        local report = tostring(money) .. "/" .. tostring(amount)
        if lastReported == nil or os.clock() - lastLogAt >= 3 then
            lastReported = report
            lastLogAt = os.clock()
            log(("[Expedition] %s · money %s / price %s"):format(
                label, tostring(money or "NOT FOUND"), tostring(amount or "NOT FOUND")
            ))
        end
        if not money then
            missingSince = missingSince or os.clock()
            if os.clock() - missingSince > 5 then
                expeditionStatus.Text = "Stopped · Expedition balance was not found"
                log("[Expedition] Balance missing for 5s; stopping sequence")
                state.expeditionSequenceRunning = false
                return false
            end
        else
            missingSince = nil
        end
        if money and amount and money >= amount then
            affordableSince = affordableSince or os.clock()
            -- The balance label can stay stale briefly after a placement.
            -- Require affordability to survive several UI samples.
            if os.clock() - affordableSince >= 0.35 then return true end
        else
            affordableSince = nil
        end
        task.wait(0.15)
    end
    return false
end

startExpeditionSequenceWorker = function(profile, controllerToken)
    state.expeditionSequenceToken += 1
    local sequenceToken = state.expeditionSequenceToken
    state.expeditionSequenceRunning = true
    state.expeditionRuntimeSlots = {}

    task.spawn(function()
        if not expeditionEnsureManagerOpen(sequenceToken) then
            expeditionStatus.Text = "Sequence stopped · Unit Manager did not open"
            state.expeditionSequenceRunning = false
            return
        end
        log("[Expedition] Conditional sequence started; Unit Manager stays open")

        for index, step in ipairs(profile.expedition.steps or {}) do
            if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
            local slot = math.clamp(math.floor(tonumber(step.slot) or 1), 1, 6)
            expeditionStatus.Text = ("Step %d/%d · %s slot %d"):format(
                index, #profile.expedition.steps, tostring(step.type), slot
            )

            if step.type == "PLACE" then
                local beforeCards = expeditionManagerCards()
                local gameState = readGameUI()
                local price = gameState.prices[slot]
                if not price then
                    log(("[Expedition] Step %d failed: no price for slot %d"):format(index, slot))
                    state.expeditionSequenceRunning = false
                    return
                end
                if not expeditionWaitMoney(price, controllerToken, sequenceToken,
                    ("PLACE S%d"):format(slot)) then return end

                local newName
                local maxAttempts = 5
                for attempt = 1, maxAttempts do
                    if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                    expeditionStatus.Text = ("PLACE S%d · attempt %d/%d"):format(
                        slot, attempt, maxAttempts
                    )
                    sendKey(slotKeyNames[slot])
                    task.wait(0.20)
                    sendClick(step.point, profile)
                    task.wait(0.50)

                    -- Selecting a bottom unit card closes Unit Manager in Expedition.
                    -- Reopen it once after the placement click before checking cards.
                    if not expeditionManagerOpen() then
                        log(("[Expedition] PLACE S%d · reopening Unit Manager with F"):format(
                            slot
                        ))
                        if not expeditionEnsureManagerOpen(sequenceToken) then
                            log(("[Expedition] PLACE S%d · Unit Manager did not reopen"):format(
                                slot
                            ))
                        end
                    end

                    local attemptDeadline = os.clock() + 0.50
                    repeat
                        if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                        for name in pairs(expeditionManagerCards()) do
                            if not beforeCards[name] then newName = name break end
                        end
                        if newName then break end
                        task.wait(0.10)
                    until os.clock() >= attemptDeadline

                    if newName then break end
                    if attempt < maxAttempts then
                        log(("[Expedition] PLACE S%d attempt %d unconfirmed; retrying"):format(
                            slot, attempt
                        ))
                    end
                end

                if not newName then
                    log(("[Expedition] Step %d PLACE slot %d failed after 5 attempts"):format(
                        index, slot
                    ))
                    state.expeditionSequenceRunning = false
                    expeditionStatus.Text = ("Stopped · PLACE S%d unconfirmed"):format(slot)
                    return
                end
                state.expeditionRuntimeSlots[slot] = newName
                log(("[Expedition] Step %d PLACE S%d -> %s"):format(index, slot, newName))
                expeditionStatus.Text = "Placement confirmed · waiting for balance to settle"
                task.wait(0.65)

            elseif step.type == "UPGRADE" then
                local unitName = state.expeditionRuntimeSlots[slot]
                if not unitName then
                    expeditionStatus.Text = ("Stopped · slot %d has no placed unit"):format(slot)
                    log(("[Expedition] UPGRADE S%d has no runtime card mapping"):format(slot))
                    state.expeditionSequenceRunning = false
                    return
                end

                local completedForStep = 0
                local failedClicks = 0
                while step.toMax or completedForStep < 1 do
                    if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                    if not expeditionManagerOpen() then
                        log(("[Expedition] UPGRADE S%d · reopening Unit Manager with F"):format(
                            slot
                        ))
                        if not expeditionEnsureManagerOpen(sequenceToken) then
                            expeditionStatus.Text = "Stopped · Unit Manager did not open"
                            state.expeditionSequenceRunning = false
                            return
                        end
                        task.wait(0.20)
                    end
                    local card = expeditionManagerCards()[unitName]
                    if not card or card.level == nil or card.max == nil then
                        expeditionStatus.Text = "Stopped · card unavailable: " .. unitName
                        state.expeditionSequenceRunning = false
                        return
                    end
                    if card.level >= card.max then break end
                    if not card.price or not card.upgradeButton then
                        expeditionStatus.Text = "Stopped · upgrade UI unavailable: " .. unitName
                        log(("[Expedition] Card %s incomplete: level=%s/%s price=%s button=%s"):format(
                            unitName, tostring(card.level), tostring(card.max),
                            tostring(card.price), tostring(card.upgradeButton ~= nil)
                        ))
                        state.expeditionSequenceRunning = false
                        return
                    end
                    local oldLevel = card.level
                    log(("[Expedition] UPGRADE card=%s slot=%d level=%d/%d price=%s"):format(
                        unitName, slot, oldLevel, card.max, tostring(card.price)
                    ))
                    if not expeditionWaitMoney(card.price, controllerToken, sequenceToken,
                        ("UPGRADE %s %d/%d"):format(unitName, oldLevel, card.max)) then return end
                    -- A level-up or Stat Anvil prompt may have appeared while money
                    -- was being awaited and closed Unit Manager. Refresh the live button.
                    if not expeditionManagerOpen() then
                        if not expeditionEnsureManagerOpen(sequenceToken) then
                            expeditionStatus.Text = "Stopped · Unit Manager did not reopen"
                            state.expeditionSequenceRunning = false
                            return
                        end
                        task.wait(0.20)
                    end
                    local refreshedCard = expeditionManagerCards()[unitName]
                    if not refreshedCard or not refreshedCard.upgradeButton then
                        expeditionStatus.Text = "Stopped · upgrade button disappeared"
                        state.expeditionSequenceRunning = false
                        return
                    end
                    card = refreshedCard
                    oldLevel = card.level
                    log(("[Expedition] Clicking upgrade for %s at level %d"):format(
                        unitName, oldLevel
                    ))
                    expeditionClick(card.upgradeButton)
                    task.wait(0.25)
                    if not expeditionManagerOpen() then
                        log("[Expedition] Upgrade closed Unit Manager · reopening with F")
                        if not expeditionEnsureManagerOpen(sequenceToken) then
                            expeditionStatus.Text = "Stopped · Unit Manager did not reopen"
                            state.expeditionSequenceRunning = false
                            return
                        end
                    end

                    local upgraded = false
                    local activeWait = 0
                    while activeWait < 4 do
                        if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                        -- Level-up / Anvil prompts close Unit Manager. Their duration
                        -- must not consume the four-second confirmation window.
                        if not expeditionManagerOpen() then
                            log("[Expedition] Upgrade confirmation · reopening Unit Manager")
                            if not expeditionEnsureManagerOpen(sequenceToken) then
                                expeditionStatus.Text = "Stopped · Unit Manager did not reopen"
                                state.expeditionSequenceRunning = false
                                return
                            end
                            task.wait(0.20)
                        end
                        local updated = expeditionManagerCards()[unitName]
                        upgraded = updated and updated.level and updated.level > oldLevel
                        if upgraded then break end
                        task.wait(0.15)
                        activeWait += 0.15
                    end
                    if not upgraded then
                        failedClicks += 1
                        if failedClicks >= 3 then
                            expeditionStatus.Text = "Stopped · upgrade failed after 3 attempts"
                            log(("[Expedition] Upgrade click for %s failed after 3 attempts"):format(
                                unitName
                            ))
                            state.expeditionSequenceRunning = false
                            return
                        end
                        log(("[Expedition] Upgrade click for %s was intercepted · retry %d/3"):format(
                            unitName, failedClicks + 1
                        ))
                        task.wait(0.50)
                    else
                        failedClicks = 0
                        completedForStep += 1
                        log(("[Expedition] %s upgraded %d -> %d"):format(
                            unitName, oldLevel, oldLevel + 1
                        ))
                        task.wait(0.45)
                    end
                end

            elseif step.type == "AUTO" then
                local unitName = state.expeditionRuntimeSlots[slot]
                local autoConfirmed = false
                for attempt = 1, 3 do
                    if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                    if not expeditionManagerOpen() then
                        log(("[Expedition] AUTO S%d · reopening Unit Manager with F"):format(slot))
                        if not expeditionEnsureManagerOpen(sequenceToken) then
                            expeditionStatus.Text = "Stopped · Unit Manager did not open for AUTO"
                            state.expeditionSequenceRunning = false
                            return
                        end
                        task.wait(0.25)
                    end
                    local card = unitName and expeditionManagerCards()[unitName]
                    if not card or not card.autoButton then
                        expeditionStatus.Text = ("Stopped · AUTO card missing for slot %d"):format(slot)
                        state.expeditionSequenceRunning = false
                        return
                    end
                    if card.level and card.max and card.level >= card.max then
                        autoConfirmed = true
                        log(("[Expedition] AUTO S%d %s skipped · already maxed %d/%d"):format(
                            slot, unitName, card.level, card.max
                        ))
                        break
                    end
                    expeditionMovePointerAway()
                    task.wait(0.06)
                    local beforeSignature = expeditionButtonVisualSignature(card.autoButton)
                    log(("[Expedition] AUTO S%d %s · click attempt %d/3 at %.3f,%.3f"):format(
                        slot, unitName, attempt, card.autoNx or -1, card.autoNy or -1
                    ))
                    expeditionClick(card.autoButton)
                    task.wait(0.20)
                    expeditionMovePointerAway()
                    task.wait(0.25)
                    if not expeditionSequenceReady(controllerToken, sequenceToken) then return end
                    if not expeditionManagerOpen() then
                        if not expeditionEnsureManagerOpen(sequenceToken) then return end
                        task.wait(0.20)
                    end
                    local updated = expeditionManagerCards()[unitName]
                    local afterSignature = updated and updated.autoButton
                        and expeditionButtonVisualSignature(updated.autoButton) or "missing"
                    if afterSignature ~= beforeSignature and afterSignature ~= "missing" then
                        autoConfirmed = true
                        break
                    end
                    task.wait(0.30)
                end
                if not autoConfirmed then
                    expeditionStatus.Text = ("Stopped · AUTO S%d was not confirmed"):format(slot)
                    log(("[Expedition] AUTO S%d %s failed after 3 attempts"):format(
                        slot, tostring(unitName)
                    ))
                    state.expeditionSequenceRunning = false
                    return
                end
                log(("[Expedition] AUTO confirmed for S%d %s"):format(slot, unitName))
                task.wait(0.30)
            end
        end

        if state.expeditionSequenceToken == sequenceToken then
            state.expeditionSequenceRunning = false
            expeditionStatus.Text = ("Sequence complete · %d steps · waiting for result"):format(
                #(profile.expedition.steps or {})
            )
            log("[Expedition] Conditional sequence completed")
        end
    end)
end

local function saveSmartFields(profile)
    profile.smart = type(profile.smart) == "table" and profile.smart
        or {}
    profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
    local slot = math.clamp(math.floor(tonumber(smartSlotBox.Text) or 6), 1, 6)
    local slotKey = tostring(slot)
    local job = profile.smart.jobs[slotKey] or {
        wave = 8, reserve = 5000, slot = slot, points = {}
    }
    job.points = type(job.points) == "table" and job.points or {}
    -- Migrate points created by v0.4 into their original slot.
    if type(profile.smart.points) == "table" and #profile.smart.points > 0
        and #job.points == 0 then
        job.points = profile.smart.points
        profile.smart.points = {}
    end
    job.slot = slot
    job.wave = math.max(1, math.floor(tonumber(smartWaveBox.Text) or job.wave or 8))
    job.reserve = math.max(0, math.floor(tonumber(smartReserveBox.Text) or job.reserve or 5000))
    profile.smart.jobs[slotKey] = job
    profile.smart.slot = slot
    smartWaveBox.Text = tostring(job.wave)
    smartReserveBox.Text = tostring(job.reserve)
    smartSlotBox.Text = tostring(slot)
    saveConfig()
    return job, profile.smart
end

smartSlotBox.FocusLost:Connect(function()
    local profile = state.selected and state.profiles[state.selected]
    if not profile then return end
    profile.smart = type(profile.smart) == "table" and profile.smart or {}
    profile.smart.jobs = type(profile.smart.jobs) == "table" and profile.smart.jobs or {}
    local slot = math.clamp(math.floor(tonumber(smartSlotBox.Text) or 6), 1, 6)
    smartSlotBox.Text = tostring(slot)
    local job = profile.smart.jobs[tostring(slot)]
    if job then
        smartWaveBox.Text = tostring(job.wave or 8)
        smartReserveBox.Text = tostring(job.reserve or 5000)
        smartInfo.Text = ("Slot %d points: %d"):format(
            slot, type(job.points) == "table" and #job.points or 0
        )
    else
        smartWaveBox.Text = "8"
        smartReserveBox.Text = "5000"
        smartInfo.Text = ("Slot %d is not configured"):format(slot)
    end
end)

smartEnabledButton.MouseButton1Click:Connect(function()
    local profile = state.selected and state.profiles[state.selected]
    if not profile then log("Select a profile first") return end
    profile.smart = type(profile.smart) == "table" and profile.smart or {}
    profile.smart.enabled = not (profile.smart.enabled == true)
    saveConfig()
    refreshSmartVisual(profile, tonumber(profile.smart.slot) or 6)
    log(profile.smart.enabled and "Smart mode enabled for this profile"
        or "Smart mode disabled for this profile")
end)

smartPointButton.MouseButton1Click:Connect(function()
    log("Move the cursor onto the map and press F7 to save a point")
end)

smartClearButton.MouseButton1Click:Connect(function()
    if state.smartRunning then
        log("Stop Smart mode before clearing points")
        return
    end
    local profile = state.selected and state.profiles[state.selected]
    if not profile then log("Select a profile first") return end
    local job = saveSmartFields(profile)
    job.points = {}
    saveConfig()
    smartInfo.Text = ("Slot %d points: 0"):format(job.slot)
    refreshSmartVisual(profile, job.slot)
    log(("Smart placement points cleared for slot %d"):format(job.slot))
end)

local function toggleSmart(forceRestart)
    if state.expeditionMode then
        log("Stop Expedition before starting Smart mode")
        return
    end
    if state.smartRunning then
        state.smartRunning = false
        state.smartToken += 1
        smartRunButton.Text = "SMART START"
        if not forceRestart then
            log("Smart placement stopped")
            if not state.playing then unlockAutomationCamera() end
            if not state.playing then setRunProfileActive(false) end
            return
        end
    end
    local profile = state.selected and state.profiles[state.selected]
    if not profile then log("Select a profile first") return end
    local _, smartConfig = saveSmartFields(profile)
    local jobs = {}
    for _, job in pairs(smartConfig.jobs or {}) do
        if type(job) == "table" and type(job.points) == "table" and #job.points > 0 then
            job.pointIndex = 1
            job.done = false
            table.insert(jobs, job)
        end
    end
    table.sort(jobs, function(a, b)
        if (a.wave or 1) == (b.wave or 1) then return a.slot < b.slot end
        return (a.wave or 1) < (b.wave or 1)
    end)
    if #jobs == 0 then
        log("Add at least one point with F7")
        setRunProfileActive(false)
        return
    end

    state.smartRunning = true
    state.smartToken += 1
    local token = state.smartToken
    smartRunButton.Text = "SMART STOP"
    task.spawn(function()
        restoreStart(profile)
        lockAutomationCamera(profile)
        local initialState = readGameUI() -- Capture all slot centers before selecting a unit.
        for _, job in ipairs(jobs) do
            job.cachedPrice = initialState.prices[job.slot]
            log(("Smart job: wave %d, slot %d, reserve %d, %d points"):format(
                job.wave, job.slot, job.reserve, #job.points
            ))
        end

        while state.smartRunning and state.smartToken == token do
            local gameState = readGameUI()
            local unfinished = 0
            local acted = false

            for _, job in ipairs(jobs) do
                if not job.done then
                    unfinished += 1
                    local price = gameState.prices[job.slot] or job.cachedPrice
                    if price then job.cachedPrice = price end
                    local limit = gameState.limits[job.slot]

                    if job.pointIndex > #job.points then
                        job.done = true
                    elseif limit and limit.placed >= limit.max then
                        job.done = true
                        log(("Slot %d reached its limit %d/%d"):format(
                            job.slot, limit.placed, limit.max
                        ))
                    elseif not acted
                        and gameState.wave and gameState.wave >= job.wave
                        and gameState.money and price
                        and gameState.money >= price + job.reserve then
                        local index = job.pointIndex
                        smartInfo.Text = ("W:%s money:%s | slot %d point %d/%d"):format(
                            tostring(gameState.wave), tostring(gameState.money),
                            job.slot, index, #job.points
                        )
                        sendKey(slotKeyNames[job.slot])
                        task.wait(0.20)
                        local before = readGameUI().limits[job.slot]
                        if before and before.placed >= before.max then
                            job.done = true
                            log(("Slot %d reached its dynamic limit %d/%d"):format(
                                job.slot, before.placed, before.max
                            ))
                        else
                            sendClick(job.points[index], profile)
                            task.wait(0.20)
                            local afterState = readGameUI()
                            local after = afterState.limits[job.slot]
                            local success = after and before and after.placed > before.placed
                            if not success and afterState.money and gameState.money then
                                success = afterState.money
                                    <= gameState.money - math.floor(price * 0.75)
                            end
                            log(("Slot %d point %d: %s | limit %s -> %s | money %s -> %s"):format(
                                job.slot, index, success and "PLACED" or "UNCONFIRMED",
                                before and before.placed or "?", after and after.placed or "?",
                                gameState.money or "?", afterState.money or "?"
                            ))
                            job.pointIndex += 1
                        end
                        acted = true
                    end
                end
            end

            if unfinished == 0 then break end
            if not acted then
                task.wait(0.40)
            end
        end

        if state.smartToken == token then
            state.smartRunning = false
            smartRunButton.Text = "SMART START"
            smartInfo.Text = ("Finished: %d slot jobs"):format(#jobs)
            log("Smart placement finished")
            if not state.playing then
                unlockAutomationCamera()
                setRunProfileActive(false)
            end
        end
    end)
end

smartRunButton.MouseButton1Click:Connect(function()
    toggleSmart(false)
end)

local function detectAndClickMacroRepeat()
    if state.towerRunning then return false end
    if not state.repeatEnabled or state.macroResultTriggered then return false end
    if type(sharedEnv.__TowerChallengeShouldExit) == "function" then
        local ok, shouldExit = pcall(sharedEnv.__TowerChallengeShouldExit)
        if ok and shouldExit then return false end
    end
    local prompt = player.PlayerGui:FindFirstChild("Prompt")
    local repeatLabel = expeditionFindText(prompt, "Repeat Stage")
    local button = expeditionButtonOf(repeatLabel)
    if button and expeditionVisible(button) then
        state.macroResultTriggered = true
        log("[Macro] Result detected -> clicking Repeat Stage")
        expeditionClick(button)
        return true
    end
    return false
end

local function preciseWaitUntil(targetClock, token)
    while state.playing and state.playToken == token do
        if detectAndClickMacroRepeat() then return false end
        local remaining = targetClock - os.clock()
        if remaining <= 0 then return true end
        if remaining > 0.05 then
            task.wait(math.min(remaining - 0.02, 0.1))
        else
            RunService.Heartbeat:Wait()
        end
    end
    return false
end

local keyAliases = {
    ["0"] = "Zero", ["1"] = "One", ["2"] = "Two", ["3"] = "Three",
    ["4"] = "Four", ["5"] = "Five", ["6"] = "Six", ["7"] = "Seven",
    ["8"] = "Eight", ["9"] = "Nine",
}

local function normalizeKeyName(text)
    local cleaned = tostring(text or ""):match("^%s*(.-)%s*$")
    if keyAliases[cleaned] then return keyAliases[cleaned] end
    if #cleaned == 1 then cleaned = string.upper(cleaned) end
    if Enum.KeyCode[cleaned] then return cleaned end
    local titleCase = cleaned:sub(1, 1):upper() .. cleaned:sub(2):lower()
    if Enum.KeyCode[titleCase] then return titleCase end
    return nil
end

repeatButton.MouseButton1Click:Connect(function()
    state.repeatEnabled = not state.repeatEnabled
    updateRepeatButton()
    log(state.repeatEnabled and "Infinite repeat enabled (0.5s delay)"
        or "Repeat disabled; current run will finish")
end)

state.raidPopupButton.MouseButton1Click:Connect(function()
    local profile = state.selected and state.profiles[state.selected]
    if not profile then
        log("Select a macro profile first")
        return
    end
    profile.raidRewardDismiss = not profile.raidRewardDismiss
    state.raidPopupButton.Text = profile.raidRewardDismiss
        and "RAID REWARD DISMISS: ON" or "RAID REWARD DISMISS: OFF"
    state.raidPopupButton.BackgroundColor3 = profile.raidRewardDismiss
        and Color3.fromRGB(28, 62, 49) or Color3.fromRGB(33, 38, 57)
    saveConfig()
    log(profile.raidRewardDismiss
        and "Raid reward popup dismiss enabled for this profile"
        or "Raid reward popup dismiss disabled for this profile")
end)

addKeyButton.MouseButton1Click:Connect(function()
    if state.recording or state.playing then
        log("Stop recording/playback before editing")
        return
    end
    local profile = selectProfile(trimmedName(), false)
    if not profile then return end
    local normalizedTime = (timeBox.Text or ""):gsub(",", ".")
    local timestamp = tonumber(normalizedTime)
    local keyName = normalizeKeyName(keyBox.Text)
    if not timestamp or timestamp < 0 then
        log("Invalid time; use seconds, for example 2.5")
        return
    end
    if not keyName then
        log("Invalid Roblox KeyCode: " .. tostring(keyBox.Text))
        return
    end
    profile.events = type(profile.events) == "table" and profile.events or {}
    table.insert(profile.events, {type = "key", key = keyName, t = timestamp})
    table.sort(profile.events, function(a, b)
        return (tonumber(a.t) or 0) < (tonumber(b.t) or 0)
    end)
    profile.placeId = profile.placeId or game.PlaceId
    saveConfig()
    log(("Added %s at %.3fs · now %d events"):format(
        keyName, timestamp, #profile.events
    ))
end)

local function startPlayback(withSmart)
    if state.recording or state.playing or state.expeditionMode then
        log("Stop the current operation first")
        return
    end
    local profile = selectProfile(trimmedName(), false)
    if not profile then return end
    if type(profile.events) ~= "table" or #profile.events == 0 then
        log("This profile has no recorded events")
        return
    end
    if profile.placeId and tonumber(profile.placeId) ~= game.PlaceId then
        log(("PlaceId mismatch: macro %s, current %s"):format(
            tostring(profile.placeId), tostring(game.PlaceId)
        ))
        return
    end

    state.playing = true
    if withSmart then setRunProfileActive(true) end
    lockAutomationCamera(profile)
    state.playToken += 1
    local token = state.playToken
    task.spawn(function()
        local pass = 0
        while state.playing and state.playToken == token do
            pass += 1
            state.macroResultTriggered = false
            local _, moved = restoreStart(profile)
            if profile.character and not moved then
                warn("[TowerMacro] Character start position could not be restored")
            end
            task.wait(pass == 1 and 0.35 or 0.5)
            if not state.playing or state.playToken ~= token then return end
            if withSmart and profile.smart and profile.smart.enabled then
                toggleSmart(true)
            end
            local started = os.clock()
            log(("Playback pass %d started: %d events"):format(pass, #profile.events))

            for index, event in ipairs(profile.events) do
                if detectAndClickMacroRepeat() then break end
                if not preciseWaitUntil(started + (tonumber(event.t) or 0), token) then
                    if state.macroResultTriggered then break end
                    return
                end
                restoreCamera(profile)
                local ok, err = pcall(function()
                    if event.type == "key" then
                        local sent, why = sendKey(event.key)
                        if not sent then error(why) end
                    elseif event.type == "click" then
                        sendClick(event, profile)
                    end
                end)
                if not ok then
                    warn(("[TowerMacro] Event #%d failed: %s"):format(index, tostring(err)))
                else
                    print(("[TowerMacro] Played #%d/%d: %s"):format(index, #profile.events, event.type))
                end
            end

            -- Tower owns the result transition and must run each profile once.
            if state.towerRunning then break end
            if not state.repeatEnabled then break end

            if not state.macroResultTriggered then
                log("[Macro] Timeline finished; waiting for Repeat Stage")
                local rewardDismissCount = 0
                local nextRewardDismissAt = os.clock() + 2.5
                while state.playing and state.playToken == token
                    and state.repeatEnabled and not state.macroResultTriggered do
                    detectAndClickMacroRepeat()
                    if profile.raidRewardDismiss and rewardDismissCount < 2
                        and os.clock() >= nextRewardDismissAt
                        and not state.macroResultTriggered then
                        rewardDismissCount += 1
                        local viewport = camera.ViewportSize
                        local x, y = math.floor(viewport.X * 0.88), math.floor(viewport.Y * 0.18)
                        VirtualInputManager:SendMouseMoveEvent(x, y, game)
                        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
                        task.wait(0.04)
                        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
                        nextRewardDismissAt = os.clock() + 1.2
                        log(("[Macro] Raid reward dismiss click %d/2"):format(
                            rewardDismissCount
                        ))
                    end
                    task.wait(0.20)
                end
            end
            if not state.playing or state.playToken ~= token then return end
            if not state.repeatEnabled then break end

            local repeatConfirmed = false
            local retryCount = 0
            while state.playing and state.playToken == token and state.repeatEnabled do
                local prompt = player.PlayerGui:FindFirstChild("Prompt")
                local label = expeditionFindText(prompt, "Repeat Stage")
                if not label then
                    repeatConfirmed = true
                    break
                end
                retryCount += 1
                if retryCount > 1 then
                    local button = expeditionButtonOf(label)
                    log(("[Macro] Repeat still visible; retry click #%d"):format(
                        retryCount - 1
                    ))
                    expeditionClick(button)
                end
                task.wait(0.80)
            end
            if not state.playing or state.playToken ~= token then return end
            if not state.repeatEnabled then break end
            if not repeatConfirmed then return end

            log("[Macro] Repeat window closed; restarting timeline")
            task.wait(1.0)
        end
        if state.playToken == token and state.playing then
            state.playing = false
            log("Playback complete")
            if not state.smartRunning then
                unlockAutomationCamera()
                setRunProfileActive(false)
            end
        end
    end)
end

-- Tower mode ---------------------------------------------------------------
-- Keep the complete controller inside one table. Luau has a 200-local limit
-- per top-level chunk; table methods add no persistent top-level registers.
local Tower = {
    mapIndex = 1,
    maps = {
        {key = "rose kingdom", label = "Rose Kingdom"},
        {key = "school grounds", label = "School Grounds"},
        {key = "flower forest", label = "Flower Forest"},
        {key = "king's tomb", label = "King's Tomb"},
        {key = "fairy king forest", label = "Fairy King Forest"},
        {key = "east town", label = "East Town"},
    },
}

function Tower.refreshMapping()
    local item = Tower.maps[Tower.mapIndex]
    local profile = state.mapProfiles[item.key]
    towerUI.map.Text = "MAP: " .. item.label:upper()
    towerUI.mapping.Text = profile and (item.label .. "  →  " .. profile)
        or (item.label .. "  →  NOT ASSIGNED")
end

towerUI.map.MouseButton1Click:Connect(function()
    Tower.mapIndex = Tower.mapIndex % #Tower.maps + 1
    Tower.refreshMapping()
end)

towerUI.assign.MouseButton1Click:Connect(function()
    local item = Tower.maps[Tower.mapIndex]
    if not state.selected or not state.profiles[state.selected] then
        Tower.status("Select a normal macro on the MACRO tab first")
        return
    end
    state.mapProfiles[item.key] = state.selected
    if item.key == "king's tomb" then state.mapProfiles["kings tomb"] = state.selected end
    saveConfig()
    Tower.refreshMapping()
    Tower.status(("%s assigned to %s for Tower and Challenges"):format(
        state.selected, item.label
    ))
end)

Tower.refreshMapping()

sharedEnv.__TowerMacroResolveMapProfile = function(map)
    return state.mapProfiles[tostring(map or ""):lower()]
end

function Tower.status(text)
    towerUI.status.Text = tostring(text)
    log("[Tower] " .. tostring(text):gsub("\n", " | "))
end

function Tower.parse(text)
    local clean = expeditionClean(text)
    local floor, map = clean:match("[Ff]loor%s*(%d+)%s*[%-%?%?]%s*(.+)$")
    if not floor then return nil end
    map = expeditionClean(map):gsub("%s+[Hh]ard%s*[Mm]ode.*$", "")
    return tonumber(floor), map
end

function Tower.read()
    for _, object in ipairs(player.PlayerGui:GetDescendants()) do
        if (object:IsA("TextLabel") or object:IsA("TextButton"))
            and expeditionVisible(object) then
            local floor, map = Tower.parse(object.Text)
            if floor and map and map ~= "" then return floor, map end
        end
    end
end

function Tower.button(text)
    return expeditionButtonOf(expeditionFindText(player.PlayerGui, text))
end

function Tower.stopPass()
    state.playing = false
    state.playToken += 1
    state.smartRunning = false
    state.smartToken += 1
    state.macroResultTriggered = false
    unlockAutomationCamera()
    setRunProfileActive(false)
end

function Tower.launch(token)
    local deadline = os.clock() + 25
    while state.towerRunning and state.towerToken == token
        and not Tower.button("Start Game") and os.clock() < deadline do
        task.wait(0.45)
    end
    if not state.towerRunning or state.towerToken ~= token then return false end
    if not Tower.button("Start Game") then
        Tower.status("Start Game did not appear; monitoring current floor")
        return true
    end

    task.wait(0.85)
    local floor, map = Tower.read()
    if not map then
        Tower.status("Map name was not found; retrying UI read")
        task.wait(1)
        floor, map = Tower.read()
    end
    local profileName = map and state.mapProfiles[map:lower()] or nil
    if not profileName or not state.profiles[profileName] then
        Tower.status(("Stopped: no profile for %s"):format(map or "unknown map"))
        state.towerRunning = false
        towerUI.toggle.Text = "START TOWER AUTO"
        towerUI.toggle.BackgroundColor3 = Color3.fromRGB(28, 73, 54)
        return false
    end

    state.towerFloor, state.towerMap, state.towerProfile = floor, map, profileName
    selectProfile(profileName, false)
    Tower.status(("Floor %s - %s\nProfile: %s\nStarting..."):format(
        tostring(floor or "?"), map, profileName
    ))
    startPlayback(true)
    return true
end

function Tower.start()
    if state.towerRunning then return end
    if state.recording or state.expeditionMode then
        log("Stop the current operation first")
        return
    end
    if state.playing or state.smartRunning then Tower.stopPass() end
    state.towerRunning = true
    state.towerToken += 1
    local token = state.towerToken
    towerUI.toggle.Text = "STOP TOWER AUTO"
    towerUI.toggle.BackgroundColor3 = Color3.fromRGB(91, 40, 50)
    Tower.status("Tower auto started; checking current floor")

    task.spawn(function()
        if Tower.button("Start Game") then
            if not Tower.launch(token) then return end
        else
            Tower.status("Monitoring the current floor for Victory")
        end

        while state.towerRunning and state.towerToken == token do
            local nextButton = Tower.button("Next Floor")
            if nextButton and expeditionFindText(player.PlayerGui, "Victory") then
                Tower.status("Victory detected; loading next floor")
                task.wait(0.65)
                if not state.towerRunning or state.towerToken ~= token then break end
                Tower.stopPass()
                if expeditionClick(nextButton) then
                    local deadline = os.clock() + 6
                    while state.towerRunning and state.towerToken == token
                        and Tower.button("Next Floor") and os.clock() < deadline do
                        task.wait(0.30)
                    end
                    if not Tower.launch(token) then break end
                else
                    Tower.status("Next Floor click failed; retrying")
                end
            elseif expeditionFindText(player.PlayerGui, "Defeat") then
                Tower.status("Stopped: floor was defeated")
                state.towerRunning = false
                break
            end
            task.wait(0.60)
        end

        if state.towerToken == token then
            state.towerRunning = false
            towerUI.toggle.Text = "START TOWER AUTO"
            towerUI.toggle.BackgroundColor3 = Color3.fromRGB(28, 73, 54)
        end
    end)
end

towerUI.toggle.MouseButton1Click:Connect(function()
    if state.towerRunning then
        state.towerRunning = false
        state.towerToken += 1
        Tower.stopPass()
        towerUI.toggle.Text = "START TOWER AUTO"
        towerUI.toggle.BackgroundColor3 = Color3.fromRGB(28, 73, 54)
        Tower.status("Stopped by user")
    else
        Tower.start()
    end
end)

runProfileButton.MouseButton1Click:Connect(function()
    if state.playing or state.smartRunning then
        stopAll("Profile stopped")
        return
    end
    local profile = state.selected and state.profiles[state.selected]
    if not profile then log("Select a profile first") return end
    local hasMacro = type(profile.events) == "table" and #profile.events > 0
    local smartEnabled = profile.smart and profile.smart.enabled == true
    if not hasMacro and not smartEnabled then
        log("This profile has no macro and Smart mode is disabled")
    elseif hasMacro then
        startPlayback(true)
    elseif smartEnabled then
        setRunProfileActive(true)
        toggleSmart(true)
    end
    if type(sharedEnv.__TowerChallengeFarmStarted) == "function" then
        pcall(sharedEnv.__TowerChallengeFarmStarted, state.selected)
    end
end)

challengeSettingsButton.MouseButton1Click:Connect(function()
    if type(sharedEnv.__TowerChallengeToggleWindow) == "function" then
        pcall(sharedEnv.__TowerChallengeToggleWindow)
    else
        log("Challenge scheduler is still loading")
    end
end)

restoreButton.MouseButton1Click:Connect(function()
    local profile = selectProfile(trimmedName(), false)
    if not profile then return end
    local ok, moved, cameraSet = restoreStart(profile)
    if not ok then
        log("Failed to restore start state")
    elseif moved then
        log("Character and camera restored")
    elseif cameraSet then
        log("Camera restored; no saved character position")
    else
        log("No start state saved")
    end
end)

autoQueueButton.MouseButton1Click:Connect(function()
    if state.autoQueue then
        state.autoQueue = false
        saveConfig()
        updateAutoQueueButton()
        log("Automatic loading disabled")
        return
    end
    if not findQueueFunction() then
        log("This Xeno build does not expose queue_on_teleport")
        return
    end
    state.autoQueue = true
    saveConfig()
    updateAutoQueueButton()
    if not queueForNextTeleport(false) then
        state.autoQueue = false
        saveConfig()
        updateAutoQueueButton()
    end
end)

deleteButton.MouseButton1Click:Connect(function()
    local name = trimmedName()
    if name == "" or not state.profiles[name] then
        log("Profile not found")
        return
    end
    stopAll()
    state.profiles[name] = nil
    if state.selected == name then state.selected = nil end
    nameBox.Text = ""
    saveConfig()
    rebuildDropdown()
    dropdown.Visible = false
    log("Deleted profile: " .. name)
end)

listButton.MouseButton1Click:Connect(function()
    local names = {}
    for name, profile in pairs(state.profiles) do
        table.insert(names, ("%s (%d)"):format(name, #(profile.events or {})))
    end
    table.sort(names)
    log(#names > 0 and table.concat(names, " | ") or "No saved profiles")
end)

testButton.MouseButton1Click:Connect(function()
    task.spawn(function()
        log("Input test in 1 second: key 1")
        task.wait(1)
        local ok, err = pcall(sendKey, "One")
        log(ok and "Input test sent: key 1" or ("Input test failed: " .. tostring(err)))
    end)
end)

updateAutoQueueButton()
updateRepeatButton()
task.defer(function()
    if type(sharedEnv.__TowerChallengeToggleWindow) == "function" then return end
    local ok, source = pcall(readfile, "challenge_handoff_test.lua")
    if not ok or not source then
        warn("[TowerMacro] Challenge scheduler file was not found")
        return
    end
    local chunk, compileError = loadstring(source)
    if chunk then chunk()
    else warn("[TowerMacro] Challenge scheduler compile failed:", compileError) end
end)
if state.autoQueue then
    task.defer(function()
        if not queueForNextTeleport(true) then
            state.autoQueue = false
            saveConfig()
            updateAutoQueueButton()
            log("Automatic loading unavailable in this Xeno build")
        end
    end)
end
if state.selected then
    selectProfile(state.selected, false)
    log(("Auto-selected '%s' for PlaceId %s"):format(state.selected, tostring(game.PlaceId)))
else
    log(("No profile for PlaceId %s; choose or create one"):format(tostring(game.PlaceId)))
end

task.spawn(function()
    while gui and gui.Parent do
        local shouldMonitor = (smartPage.Visible or statusPage.Visible)
            and not state.smartRunning
        if shouldMonitor then
            local ok, gameState = pcall(readGameUI)
            if ok and gameState then
            local profile = state.selected and state.profiles[state.selected]
            local mode = state.expeditionMode
                and ("EXPEDITION " .. string.upper(state.expeditionMode))
                or (state.playing and "MACRO"
                    or (state.smartRunning and "SMART" or "IDLE"))
            statusDetails.Text = (
                "Profile: %s\nMode: %s\nPlaceId: %s\n\n"
                .. "Wave: %s / %s\nBalance: %s\n"
                .. "Repeat: %s\nSmart: %s"
            ):format(
                tostring(state.selected or "none"), mode, tostring(game.PlaceId),
                tostring(gameState.wave or "?"), tostring(gameState.waveMax or "?"),
                tostring(gameState.money or "?"),
                state.repeatEnabled and "ON" or "OFF",
                profile and profile.smart and profile.smart.enabled and "ENABLED" or "DISABLED"
            )
            if profile and profile.smart then
                for slot, button in ipairs(smartSlotButtons) do
                    local job = profile.smart.jobs and profile.smart.jobs[tostring(slot)]
                    local points = job and type(job.points) == "table" and #job.points or 0
                    local price = gameState.prices[slot]
                    button.Text = ("%d\n%s%s"):format(
                        slot,
                        price and ("¥" .. tostring(price)) or "—",
                        points > 0 and (" · " .. points .. "p") or ""
                    )
                end
            end
        end
        end
        task.wait(shouldMonitor and 1.5 or 2.0)
    end
end)

