-- Challenge Handoff Batch Test v0.5
-- Processes all eligible Regular Challenges and persists progress across teleports.

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local sharedEnv = (getgenv and getgenv()) or _G
local stateFile = "ChallengeHandoffTest_" .. player.Name .. ".json"
local macroConfigFile = "TowerMacro_" .. player.Name .. ".json"
local logFile = "AutoChallengeLog_" .. player.Name .. ".txt"
if type(isfolder) == "function" and isfolder(logFile) then
    -- An older build could accidentally create this path as a directory.
    logFile = "AutoChallengeLog_" .. player.Name .. "_current.txt"
end
local mapProfiles = {
    ["rose kingdom"] = "Rose_Kingdom",
    ["school grounds"] = "School Grounds_ch",
    ["flower forest"] = "Flower_forest",
    ["king's tomb"] = "Kings_Tomb",
    ["kings tomb"] = "Kings_Tomb",
    ["fairy king forest"] = "Fairy_King_Forest_ch",
}

local function profileForMap(map)
    if type(sharedEnv.__TowerMacroResolveMapProfile) == "function" then
        local ok, profile = pcall(sharedEnv.__TowerMacroResolveMapProfile, map)
        if ok and type(profile) == "string" and profile ~= "" then return profile end
    end
    return map and mapProfiles[map:lower()] or nil
end
local running = false
local farmMonitorToken = 0

local function logTime()
    local ok, value = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    return ok and value or tostring(os.time())
end

local function challengeLog(kind, message)
    local line = ("[%s] [%s] place=%s job=%s | %s\n"):format(
        logTime(), tostring(kind or "INFO"), tostring(game.PlaceId),
        tostring(game.JobId):sub(1, 12), tostring(message or "")
    )
    pcall(function()
        if isfile(logFile) then
            local old = readfile(logFile)
            if #old > 300000 then
                writefile(logFile, "[log rotated]\n" .. old:sub(-120000))
            end
        end
        if type(appendfile) == "function" then
            appendfile(logFile, line)
        else
            local old = isfile(logFile) and readfile(logFile) or ""
            writefile(logFile, old .. line)
        end
    end)
end

local function currentChallengeCycle()
    -- Ten-second grace prevents opening the list while the server is still
    -- replacing the :00/:30 challenge cards.
    return math.floor((workspace:GetServerTimeNow() - 10) / 1800)
end

local function clean(value)
    return tostring(value or ""):gsub("[\r\n\t]", " "):gsub("%s+", " ")
end

local function visible(object)
    if not object:IsA("GuiObject") or not object.Visible then return false end
    local current = object.Parent
    while current and current ~= playerGui and current ~= CoreGui do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("LayerCollector") and not current.Enabled then return false end
        current = current.Parent
    end
    return object.AbsoluteSize.X > 1 and object.AbsoluteSize.Y > 1
end

local function textOf(object)
    if object:IsA("TextLabel") or object:IsA("TextButton")
        or object:IsA("TextBox") then
        return clean(object.Text)
    end
    return ""
end

local function findText(root, exact, pattern)
    local best
    for _, object in ipairs(root:GetDescendants()) do
        if visible(object) then
            local text = textOf(object)
            if (exact and text == exact) or (pattern and text:match(pattern)) then
                if not best or object.AbsoluteSize.X > best.AbsoluteSize.X then
                    best = object
                end
            end
        end
    end
    return best
end

local function findCompactText(root, exact)
    local best, bestWidth
    for _, object in ipairs(root:GetDescendants()) do
        if visible(object) and textOf(object) == exact then
            local size = object.AbsoluteSize
            -- This is the same rule used by the successful reader test:
            -- the real title is a short, wide label. Tiny duplicate labels can
            -- report a center inside the reward row, especially for slots 2/3.
            if size.Y <= 90 and size.X >= 80
                and (not bestWidth or size.X > bestWidth) then
                best, bestWidth = object, size.X
            end
        end
    end
    return best
end

local function challengeTitleCandidates(slot)
    local exact = "Regular Challenge #" .. tostring(slot)
    local result = {}
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) and textOf(object) == exact then
            local position, size = object.AbsolutePosition, object.AbsoluteSize
            if position.X > 450 and size.Y <= 80 then
                table.insert(result, object)
            end
        end
    end
    table.sort(result, function(a, b)
        if math.abs(a.AbsolutePosition.Y - b.AbsolutePosition.Y) > 2 then
            return a.AbsolutePosition.Y < b.AbsolutePosition.Y
        end
        return a.AbsoluteSize.X > b.AbsoluteSize.X
    end)
    return result
end

local function findChallengeTitle(slot)
    local candidates = challengeTitleCandidates(slot)
    local best
    for _, object in ipairs(candidates) do
        local size = object.AbsoluteSize
        if size.Y >= 12 and size.Y <= 55 and size.X >= 100 then
            if not best or size.X > best.AbsoluteSize.X then best = object end
        end
    end
    return best or candidates[1]
end

local function readChallengeLimit(slot)
    local title = findChallengeTitle(slot)
    if not title then return nil end
    local titleY = title.AbsolutePosition.Y + title.AbsoluteSize.Y / 2
    local captions = {}
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) and textOf(object) == "Daily Limit" then
            table.insert(captions, {
                x = object.AbsolutePosition.X + object.AbsoluteSize.X / 2,
                y = object.AbsolutePosition.Y + object.AbsoluteSize.Y / 2,
            })
        end
    end
    local best, bestBelow
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) then
            local remaining, maximum = textOf(object):match("^(%d+)%s*/%s*(%d+)$")
            if remaining and maximum then
                local x = object.AbsolutePosition.X + object.AbsoluteSize.X / 2
                local y = object.AbsolutePosition.Y + object.AbsoluteSize.Y / 2
                local paired = false
                for _, caption in ipairs(captions) do
                    if math.abs(caption.y - y) <= 12 and math.abs(caption.x - x) <= 180 then
                        paired = true
                        break
                    end
                end
                local below = y - titleY
                if paired and below >= 100 and below <= 260
                    and (not bestBelow or below < bestBelow) then
                    best, bestBelow = tonumber(remaining), below
                end
            end
        end
    end
    return best
end

local function challengeAlreadyCompleted(slot)
    local title = findChallengeTitle(slot)
    if not title then return false end
    local titleY = title.AbsolutePosition.Y + title.AbsoluteSize.Y / 2
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) and (object:IsA("TextLabel") or object:IsA("TextButton")) then
            local raw = tostring(object.Text or "")
            local y = object.AbsolutePosition.Y + object.AbsoluteSize.Y / 2
            if raw:find("<s>", 1, true) and y > titleY and y - titleY < 120 then
                return true
            end
        end
    end
    return false
end

local function buttonOf(object)
    local current = object
    while current and current ~= playerGui and current ~= CoreGui do
        if current:IsA("GuiButton") and visible(current) then return current end
        current = current.Parent
    end
end

local function pointOf(object)
    local center = object.AbsolutePosition + object.AbsoluteSize / 2
    local inset = GuiService:GetGuiInset()
    return math.floor(center.X + 0.5), math.floor(center.Y + inset.Y + 0.5)
end

local function click(object)
    if not object or not visible(object) then return false end
    local x, y = pointOf(object)
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

local function clickOnce(object)
    if not object or not visible(object) then return false end
    local x, y = pointOf(object)
    local ok = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        task.wait(0.10)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.04)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    task.wait(0.15)
    return ok
end

local function clickChallengeTitle(slot)
    local title = findChallengeTitle(slot)
    if not title then return false end

    local position, size = title.AbsolutePosition, title.AbsoluteSize
    local inset = GuiService:GetGuiInset()
    local x = math.floor(position.X + math.min(math.max(size.X * 0.25, 24), 90) + 0.5)
    local y = math.floor(position.Y + math.min(size.Y * 0.5, 22) + inset.Y + 0.5)
    print(("[ChallengeHandoffTest] Clicking challenge #%d title at %d,%d"):format(slot, x, y))

    local nativeOk = pcall(function()
        mousemove(x, y)
        task.wait(0.15)
        mouse1click()
    end)
    local vimOk = pcall(function()
        task.wait(0.05)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
        task.wait(0.03)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
    end)
    task.wait(0.8)
    return nativeOk or vimOk
end

local function waitFor(root, exact, timeout)
    local deadline = os.clock() + timeout
    repeat
        local object = findText(root, exact)
        if object then return object end
        task.wait(0.15)
    until os.clock() >= deadline
end

local function loadState()
    local ok, decoded = pcall(function()
        if not isfile(stateFile) then return nil end
        return HttpService:JSONDecode(readfile(stateFile))
    end)
    return ok and type(decoded) == "table" and decoded or {phase = "idle"}
end

local function saveState(data)
    data.updatedAt = os.time()
    data.jobId = game.JobId
    writefile(stateFile, HttpService:JSONEncode(data))
end

local function selectMacroProfile(name)
    local ok, config = pcall(function()
        if not isfile(macroConfigFile) then return nil end
        return HttpService:JSONDecode(readfile(macroConfigFile))
    end)
    if not ok or type(config) ~= "table" then return false, "macro config missing" end
    if type(config.profiles) ~= "table" or type(config.profiles[name]) ~= "table" then
        return false, "profile '" .. name .. "' not found"
    end
    config.selected = name
    local saved, err = pcall(function()
        writefile(macroConfigFile, HttpService:JSONEncode(config))
    end)
    return saved, err
end

local function queueFunction()
    local env = (getgenv and getgenv()) or _G
    return env.queue_on_teleport or env.queueonteleport
        or (type(env.syn) == "table" and env.syn.queue_on_teleport)
        or (type(env.fluxus) == "table" and env.fluxus.queue_on_teleport)
end

local function queueCombinedLoader(data)
    -- Tower Macro's normal Auto TP loader is sufficient.  Registering a second
    -- callback made Xeno execute the whole script twice after every teleport.
    if sharedEnv.__TowerMacroQueuedJobId == game.JobId then
        challengeLog("QUEUE", "Reusing Tower Macro loader; phase=" .. tostring(data and data.phase))
        return true
    end
    local queue = queueFunction()
    if type(queue) ~= "function" then return false, "queue_on_teleport unavailable" end
    -- Carry the handoff state inside the queued source as well as on disk.
    -- Some executors can teleport before their filesystem view reflects the
    -- final write, which used to make the next server start at phase "idle".
    local encodedState = HttpService:JSONEncode(data or loadState())
    local loader = ([=[
repeat task.wait() until game:IsLoaded()
task.wait(1.2)
pcall(function()
    writefile(%q, %q)
end)
local function runFile(name)
    local ok, source = pcall(readfile, name)
    if not ok or not source then warn("[ChallengeHandoff] Cannot read " .. name) return end
    local compiled, err = loadstring(source)
    if compiled then compiled() else warn("[ChallengeHandoff] Compile failed:", err) end
end
runFile("tower_macro.lua")
]=]):format(stateFile, encodedState)
    local ok, err = pcall(queue, loader)
    if ok then sharedEnv.__TowerMacroQueuedJobId = game.JobId end
    challengeLog(ok and "QUEUE" or "ERROR", ok
        and ("Teleport loader registered; phase=" .. tostring(data and data.phase))
        or ("Teleport loader failed: " .. tostring(err)))
    return ok, err
end

local function hasBlockedModifier()
    -- Asset ids are not unique across the whole game UI.  After UI updates an
    -- unrelated visible image may reuse one of them, so only inspect the
    -- horizontal band that belongs to the challenge's Stage Effects section.
    local effectsLabel = findText(playerGui, "Stage Effects")
    if not effectsLabel then
        challengeLog("MODIFIER", "Stage Effects section was not found; allowing challenge")
        return nil
    end

    local effectsX = effectsLabel.AbsolutePosition.X
    local effectsY = effectsLabel.AbsolutePosition.Y
    local effectsRight = effectsX + math.max(effectsLabel.AbsoluteSize.X, 620)
    local effectsBottom = effectsY + 190

    local rewardsLabel = findText(playerGui, "Rewards")
    if rewardsLabel and rewardsLabel.AbsolutePosition.Y > effectsY then
        effectsBottom = math.min(effectsBottom, rewardsLabel.AbsolutePosition.Y)
    end

    for _, object in ipairs(playerGui:GetDescendants()) do
        if (object:IsA("ImageLabel") or object:IsA("ImageButton")) and visible(object) then
            local centerX = object.AbsolutePosition.X + object.AbsoluteSize.X * 0.5
            local centerY = object.AbsolutePosition.Y + object.AbsoluteSize.Y * 0.5
            if centerX >= effectsX - 35 and centerX <= effectsRight
                and centerY >= effectsY - 8 and centerY < effectsBottom then
                local image = tostring(object.Image)
                local modifier
                if image:find("113341984139405", 1, true) then
                    modifier = "Shielded"
                elseif image:find("129453236360587", 1, true) then
                    modifier = "Boss Waves"
                end
                if modifier then
                    challengeLog("MODIFIER", ("Detected %s in Stage Effects: %s @ %d,%d"):format(
                        modifier, image, math.floor(centerX), math.floor(centerY)))
                    return modifier
                end

            end
        end
    end
    challengeLog("MODIFIER", "No blocked modifier in Stage Effects")
    return nil
end

local function currentMap()
    local fragments = {}
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) then
            local value = textOf(object)
            if value ~= "" then
                table.insert(fragments, {
                    text = value:gsub("<.->", ""),
                    x = object.AbsolutePosition.X,
                    y = object.AbsolutePosition.Y,
                })
            end
        end
    end

    -- Since the update, the title is rendered as separate labels on one row:
    -- "Rose " + "Kingdom " + "- Act " + "3". Reassemble that row by X.
    for _, seed in ipairs(fragments) do
        if seed.text:lower():find("act", 1, true) then
            local row = {}
            for _, fragment in ipairs(fragments) do
                if math.abs(fragment.y - seed.y) <= 3
                    and fragment.x >= seed.x - 650
                    and fragment.x <= seed.x + 650 then
                    table.insert(row, fragment)
                end
            end
            table.sort(row, function(a, b) return a.x < b.x end)
            local pieces = {}
            for _, fragment in ipairs(row) do table.insert(pieces, fragment.text) end
            local combined = clean(table.concat(pieces, ""))
            local map, act = combined:match("^(.-)%s*%-%s*Act%s*(%d+)%s*$")
            if map and clean(map) ~= "" then
                map = clean(map)
                challengeLog("MAP", ("Reconstructed map=%s act=%s from %s"):format(
                    map, tostring(act), combined))
                return map, tonumber(act)
            end
        end
    end

    -- Fallback for the previous UI where the complete title was one label.
    for _, fragment in ipairs(fragments) do
        local map, act = fragment.text:match("^(.-)%s*%-%s*Act%s*(%d+)%s*$")
        if map and clean(map) ~= "" then
            map = clean(map)
            challengeLog("MAP", ("Read legacy map=%s act=%s"):format(map, tostring(act)))
            return map, tonumber(act)
        end
    end

    challengeLog("MAP", "No stage-title row could be reconstructed")
    return nil
end

local function findResultExit()
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("ImageLabel") and visible(object)
            and tostring(object.Image):find("86900269145845", 1, true) then
            return buttonOf(object)
        end
    end
end

for _, name in ipairs({
    "ChallengeHandoffTest_v01", "ChallengeHandoffTest_v02", "ChallengeHandoffTest_v03",
    "ChallengeHandoffTest_v04", "ChallengeHandoffTest_v05",
}) do
    local old = CoreGui:FindFirstChild(name)
    if old then old:Destroy() end
end

local gui = Instance.new("ScreenGui")
gui.Name = "ChallengeHandoffTest_v05"
gui.ResetOnSpawn = false
gui.Parent = CoreGui
local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(350, 302)
frame.Position = UDim2.fromOffset(18, 270)
frame.BackgroundColor3 = Color3.fromRGB(17, 21, 31)
frame.BorderSizePixel = 0
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 9)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(57, 151, 188)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -48, 0, 34)
title.Position = UDim2.fromOffset(12, 3)
title.BackgroundTransparency = 1
title.Text = "CHALLENGE BATCH TEST  ·  v0.5"
title.TextColor3 = Color3.fromRGB(220, 239, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(26, 26)
close.Position = UDim2.new(1, -34, 0, 6)
close.BackgroundColor3 = Color3.fromRGB(67, 34, 43)
close.Text = "X"
close.TextColor3 = Color3.fromRGB(255, 220, 225)
close.Font = Enum.Font.GothamBold
close.TextSize = 12
close.Parent = frame
Instance.new("UICorner", close).CornerRadius = UDim.new(0, 6)

local status = Instance.new("TextLabel")
status.Size = UDim2.fromOffset(326, 66)
status.Position = UDim2.fromOffset(12, 40)
status.BackgroundColor3 = Color3.fromRGB(23, 28, 41)
status.Text = "Open the Regular list. Shielded and Boss Waves will be skipped."
status.TextColor3 = Color3.fromRGB(165, 184, 218)
status.Font = Enum.Font.Gotham
status.TextSize = 10
status.TextWrapped = true
status.Parent = frame
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)

local start = Instance.new("TextButton")
start.Size = UDim2.fromOffset(158, 36)
start.Position = UDim2.fromOffset(12, 158)
start.BackgroundColor3 = Color3.fromRGB(31, 73, 58)
start.Text = "START BATCH TEST"
start.TextColor3 = Color3.fromRGB(232, 251, 242)
start.Font = Enum.Font.GothamBold
start.TextSize = 10
start.Parent = frame
Instance.new("UICorner", start).CornerRadius = UDim.new(0, 6)

local armFarm = Instance.new("TextButton")
armFarm.Size = UDim2.fromOffset(158, 36)
armFarm.Position = UDim2.fromOffset(180, 158)
armFarm.BackgroundColor3 = Color3.fromRGB(62, 48, 78)
armFarm.Text = "ARM FROM FARM"
armFarm.TextColor3 = Color3.fromRGB(241, 232, 255)
armFarm.Font = Enum.Font.GothamBold
armFarm.TextSize = 10
armFarm.Parent = frame
Instance.new("UICorner", armFarm).CornerRadius = UDim.new(0, 6)

local startHub = Instance.new("TextButton")
startHub.Size = UDim2.fromOffset(210, 34)
startHub.Position = UDim2.fromOffset(12, 200)
startHub.BackgroundColor3 = Color3.fromRGB(35, 69, 92)
startHub.Text = "START CHALLENGES FROM HUB"
startHub.TextColor3 = Color3.fromRGB(226, 244, 255)
startHub.Font = Enum.Font.GothamBold
startHub.TextSize = 10
startHub.Parent = frame
Instance.new("UICorner", startHub).CornerRadius = UDim.new(0, 6)

local returnModeButton = Instance.new("TextButton")
returnModeButton.Size = UDim2.fromOffset(108, 34)
returnModeButton.Position = UDim2.fromOffset(230, 200)
returnModeButton.TextColor3 = Color3.fromRGB(230, 240, 255)
returnModeButton.Font = Enum.Font.GothamBold
returnModeButton.TextSize = 9
returnModeButton.Parent = frame
Instance.new("UICorner", returnModeButton).CornerRadius = UDim.new(0, 6)

local schedulerButton = Instance.new("TextButton")
schedulerButton.Size = UDim2.fromOffset(326, 34)
schedulerButton.Position = UDim2.fromOffset(12, 238)
schedulerButton.TextColor3 = Color3.fromRGB(230, 240, 255)
schedulerButton.Font = Enum.Font.GothamBold
schedulerButton.TextSize = 10
schedulerButton.Parent = frame
Instance.new("UICorner", schedulerButton).CornerRadius = UDim.new(0, 6)

local phaseLabel = Instance.new("TextLabel")
phaseLabel.Size = UDim2.fromOffset(326, 18)
phaseLabel.Position = UDim2.fromOffset(12, 278)
phaseLabel.BackgroundTransparency = 1
phaseLabel.TextColor3 = Color3.fromRGB(103, 124, 161)
phaseLabel.Font = Enum.Font.Code
phaseLabel.TextSize = 9
phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
phaseLabel.Parent = frame

local slotsLabel = Instance.new("TextLabel")
slotsLabel.Size = UDim2.fromOffset(82, 30)
slotsLabel.Position = UDim2.fromOffset(12, 116)
slotsLabel.BackgroundTransparency = 1
slotsLabel.Text = "RUN SLOTS:"
slotsLabel.TextColor3 = Color3.fromRGB(145, 163, 196)
slotsLabel.Font = Enum.Font.GothamBold
slotsLabel.TextSize = 9
slotsLabel.TextXAlignment = Enum.TextXAlignment.Left
slotsLabel.Parent = frame

local slotButtons = {}
for slot = 1, 3 do
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(72, 30)
    button.Position = UDim2.fromOffset(98 + (slot - 1) * 80, 116)
    button.TextColor3 = Color3.fromRGB(232, 245, 255)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 9
    button.Parent = frame
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    slotButtons[slot] = button
end

local function setPhase(data, phase, message)
    local previous = data.phase
    data.phase = phase
    if phase == "failed" then
        data.lastError = tostring(message or "Unknown scheduler error")
    elseif phase ~= "failed" then
        data.lastError = nil
    end
    saveState(data)
    phaseLabel.Text = "PHASE: " .. phase
    if message then status.Text = message end
    challengeLog(phase == "failed" and "ERROR" or "PHASE",
        ("%s -> %s | slot=%s map=%s profile=%s | %s"):format(
            tostring(previous), tostring(phase), tostring(data.slot),
            tostring(data.map), tostring(data.profile), tostring(message or "")
        ))
end

local function backToChallengeList()
    local back = buttonOf(findText(playerGui, "Back"))
    if not back then return false end
    click(back)
    task.wait(0.55)
    if not waitFor(playerGui, "Regular Challenge #1", 5) then return false end
    -- The title becomes visible before the scrolling list finishes its layout.
    -- Let all cards settle before reading the next title coordinates.
    task.wait(0.60)
    return true
end

local launchEventFarm
local resumeSelectedFarm

local function leaveChallengeListForHub()
    local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
        or Vector2.new(1920, 1080)
    local closeButton
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("GuiButton") and visible(object) then
            local p, s = object.AbsolutePosition, object.AbsoluteSize
            if p.X > viewport.X * 0.72 and p.Y < viewport.Y * 0.16
                and s.X >= 35 and s.X <= 140 and s.Y >= 35 and s.Y <= 140 then
                if not closeButton or p.X > closeButton.AbsolutePosition.X then
                    closeButton = object
                end
            end
        end
    end
    if not closeButton then return false, "Challenge list close button was not found" end
    click(closeButton)
    local back = waitFor(playerGui, "Back", 8)
    if not back then return false, "Play menu Back button was not found" end
    task.wait(0.6)
    click(buttonOf(back) or back)
    if not waitFor(playerGui, "Events", 10) then
        return false, "Main hub was not reached after closing challenges"
    end
    return true
end

local function processBatch(data)
    data.processed = type(data.processed) == "table" and data.processed or {}
    -- Retry slots that an older title parser incorrectly marked as unknown.
    for key, reason in pairs(data.processed) do
        if reason == "No profile for nil" then data.processed[key] = nil end
    end
    data.enabled = type(data.enabled) == "table" and data.enabled
        or { ["1"] = true, ["2"] = true, ["3"] = true }
    for slot = 1, 3 do
        local key = tostring(slot)
        if data.enabled[key] == false and not data.processed[key] then
            data.processed[key] = "Disabled"
            saveState(data)
        elseif not data.processed[key] then
            challengeLog("SLOT", ("Checking challenge #%d"):format(slot))
            status.Text = ("Checking Regular Challenge #%d..."):format(slot)
            local titleLabel = findChallengeTitle(slot)
            if not titleLabel then return false, "Challenge #" .. slot .. " was not found" end
            local remaining = readChallengeLimit(slot)
            if remaining ~= nil and remaining <= 0 then
                data.processed[key] = "Daily limit exhausted"
                saveState(data)
                status.Text = ("Skipped #%d: daily limit 0/10"):format(slot)
                challengeLog("SKIP", ("#%d daily limit exhausted"):format(slot))
            elseif challengeAlreadyCompleted(slot) then
                data.processed[key] = "Already completed this cycle"
                saveState(data)
                status.Text = ("Skipped #%d: already completed"):format(slot)
                challengeLog("SKIP", ("#%d already completed this cycle"):format(slot))
            else
            status.Text = ("Opening #%d from its header..."):format(slot)
            clickChallengeTitle(slot)
            if not waitFor(playerGui, "Select Stage", 5) then
                return false, "Challenge #" .. slot .. " details did not open"
            end
            task.wait(0.40)
            local map = currentMap()
            local profile = profileForMap(map)
            local blocked = hasBlockedModifier()
            if blocked or not profile then
                data.processed[key] = blocked or ("No profile for " .. tostring(map))
                saveState(data)
                status.Text = ("Skipped #%d: %s"):format(slot, data.processed[key])
                challengeLog("SKIP", ("#%d map=%s reason=%s"):format(
                    slot, tostring(map), tostring(data.processed[key])))
                warn(("[ChallengeHandoffTest] SKIP #%d | map=%s | reason=%s"):format(
                    slot, tostring(map), tostring(data.processed[key])))
                if not backToChallengeList() then
                    return false, "Could not return after skipped challenge #" .. slot
                end
            else
                local selected, selectError = selectMacroProfile(profile)
                if not selected then
                    data.processed[key] = "Profile error: " .. tostring(selectError)
                    saveState(data)
                    if not backToChallengeList() then return false, selectError end
                else
                    data.slot = slot
                    data.map = map
                    data.profile = profile
                    challengeLog("LAUNCH", ("#%d map=%s profile=%s"):format(
                        slot, tostring(map), profile))
                    setPhase(data, "entering_challenge", ("Launching #%d %s -> %s"):format(
                        slot, map, profile
                    ))
                    -- Save once more immediately before registering the queued
                    -- loader so both copies contain the same transition state.
                    saveState(data)
                    local queued, queueError = queueCombinedLoader(data)
                    if not queued then return false, tostring(queueError) end
                    click(buttonOf(findText(playerGui, "Select Stage")))
                    local startLabel = waitFor(playerGui, "Start", 5)
                    if not startLabel then return false, "Start party window did not appear" end
                    task.wait(0.35)
                    click(buttonOf(startLabel))
                    return true
                end
            end
            end
        end
    end
    data.slot = nil
    data.map = nil
    data.profile = nil
    if data.schedulerEnabled then
        data.completedCycle = data.cycle or currentChallengeCycle()
        setPhase(data, "returning_to_farm", "No runnable challenges remain; resuming event1...")
        local left, leaveError = leaveChallengeListForHub()
        if not left then return false, leaveError end
        return resumeSelectedFarm(data)
    end
    setPhase(data, "complete", "BATCH COMPLETE: all three slots processed")
    return true
end

local function hasRemainingChallenges(data)
    local enabled = type(data.enabled) == "table" and data.enabled or {}
    local processed = type(data.processed) == "table" and data.processed or {}
    for slot = 1, 3 do
        local key = tostring(slot)
        if enabled[key] ~= false and processed[key] == nil then return true end
    end
    return false
end

local function runStage(data)
    if not data.profile then
        setPhase(data, "failed", "Handoff profile is missing")
        return
    end
    setPhase(data, "challenge_stage", "Challenge server detected; starting " .. data.profile .. "...")

    -- Do not rely on the config file alone: Tower Macro has already loaded its
    -- own in-memory state by this point and may still have event1 selected.
    local selected = false
    if type(sharedEnv.__TowerMacroSelectProfile) == "function" then
        local ok, result = pcall(sharedEnv.__TowerMacroSelectProfile, data.profile)
        selected = ok and result == true
    else
        selected = selectMacroProfile(data.profile)
    end
    if not selected then
        setPhase(data, "failed", "Could not select challenge profile '" .. tostring(data.profile) .. "'")
        return
    end
    if type(sharedEnv.__TowerMacroSelectedProfile) == "function" then
        local ok, active = pcall(sharedEnv.__TowerMacroSelectedProfile)
        if not ok or active ~= data.profile then
            setPhase(data, "failed", "Tower Macro kept the wrong profile: " .. tostring(active))
            return
        end
    end

    local runProfile
    local deadline = os.clock() + 15
    repeat
        for _, object in ipairs(CoreGui:GetDescendants()) do
            if object:IsA("TextButton") and clean(object.Text) == "RUN PROFILE"
                and object.Visible and object.AbsoluteSize.X > 1 then
                runProfile = object
                break
            end
        end
        if not runProfile then task.wait(0.20) end
    until runProfile or os.clock() >= deadline
    if not runProfile then
        setPhase(data, "failed", "Tower Macro RUN PROFILE was not found")
        return
    end
    task.wait(1.0)
    local started = false
    for attempt = 1, 3 do
        challengeLog("CLICK", ("RUN PROFILE %s attempt %d/3"):format(
            tostring(data.profile), attempt))
        status.Text = ("Starting %s · attempt %d/3..."):format(data.profile, attempt)
        clickOnce(runProfile)
        local confirmDeadline = os.clock() + 2.0
        repeat
            for _, object in ipairs(CoreGui:GetDescendants()) do
                if object:IsA("TextButton") and clean(object.Text) == "STOP PROFILE"
                    and object.Visible and object.AbsoluteSize.X > 1 then
                    started = true
                    break
                end
            end
            if not started then task.wait(0.20) end
        until started or os.clock() >= confirmDeadline
        if started then break end
        task.wait(0.50)
    end
    if not started then
        setPhase(data, "failed", "RUN PROFILE click was not confirmed after 3 attempts")
        return
    end
    challengeLog("CONFIRM", "RUN PROFILE confirmed for " .. tostring(data.profile))
    data.result = nil
    setPhase(data, "challenge_running", data.profile .. " started; waiting for result...")
    task.spawn(function()
        while gui.Parent and data.phase == "challenge_running" do
            local result = findText(playerGui, "Victory") or findText(playerGui, "Defeat")
            if result then
                data.result = textOf(result)
                data.processed = type(data.processed) == "table" and data.processed or {}
                data.processed[tostring(data.slot)] = data.result
                setPhase(data, "leaving_result", data.result .. " detected; returning to lobby...")
                local exitButton = findResultExit()
                if not exitButton then
                    setPhase(data, "failed", "Red result exit button was not found")
                    return
                end
                click(exitButton)
                local returnLabel = waitFor(playerGui, "Return to Lobby", 5)
                if not returnLabel then
                    setPhase(data, "failed", "Return to Lobby confirmation was not found")
                    return
                end
                -- The confirmation text appears before its modal finishes the
                -- opening tween. Wait for the button to reach its final point.
                task.wait(0.65)
                local moreChallenges = hasRemainingChallenges(data)
                local returnPhase = moreChallenges and "returning_to_hub" or "returning_to_farm"
                local returnMessage = moreChallenges
                    and "Return confirmed; opening the next challenge..."
                    or "Last selected challenge finished; resuming event1..."
                setPhase(data, returnPhase, returnMessage)
                local queued, queueError = queueCombinedLoader(data)
                if not queued then
                    setPhase(data, "failed", "Return queue failed: " .. tostring(queueError))
                    return
                end
                task.wait(0.2)
                click(buttonOf(returnLabel))
                return
            end
            -- Result UI does not need frame-tight detection. A slower poll keeps
            -- the large PlayerGui traversal from affecting gameplay FPS.
            task.wait(2.5)
        end
    end)
end

local function monitorFarmResult(data)
    farmMonitorToken += 1
    local monitorToken = farmMonitorToken
    status.Text = "Armed: waiting for the current farm stage result..."
    task.spawn(function()
        while gui.Parent and monitorToken == farmMonitorToken
            and data.phase == "farm_running" do
            local due = data.schedulerEnabled == true
                and currentChallengeCycle() > tonumber(data.completedCycle or -1)
            if not due then
                task.wait(5.0)
                continue
            end
            local result = findText(playerGui, "Victory") or findText(playerGui, "Defeat")
            if result and due then
                data.cycle = currentChallengeCycle()
                data.processed = {}
                data.farmResult = textOf(result)
                status.Text = data.farmResult .. " detected; opening exit confirmation..."
                local exitButton = findResultExit()
                if not exitButton then
                    setPhase(data, "failed", "Farm result exit button was not found")
                    return
                end
                click(exitButton)
                local returnLabel = waitFor(playerGui, "Return to Lobby", 5)
                if not returnLabel then
                    setPhase(data, "failed", "Return to Lobby confirmation was not found")
                    return
                end
                -- Avoid clicking coordinates from the first frames of the
                -- confirmation animation.
                task.wait(0.65)
                setPhase(data, "returning_to_hub", "Farm finished; returning for challenges...")
                local queued, queueError = queueCombinedLoader(data)
                if not queued then
                    setPhase(data, "failed", "Farm return queue failed: " .. tostring(queueError))
                    return
                end
                task.wait(0.25)
                click(buttonOf(returnLabel))
                return
            end
            task.wait(1.0)
        end
    end)
end

local function waitForPattern(pattern, timeout)
    local deadline = os.clock() + timeout
    repeat
        local object = findText(playerGui, nil, pattern)
        if object then return object end
        task.wait(0.25)
    until os.clock() >= deadline
end

local function waitForEventCard(name, timeout)
    local deadline = os.clock() + timeout
    repeat
        local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
            or Vector2.new(1920, 1080)
        local best
        for _, object in ipairs(playerGui:GetDescendants()) do
            if visible(object) and textOf(object) == name then
                local center = object.AbsolutePosition + object.AbsoluteSize / 2
                -- Event cards live in the narrow list on the left. This avoids
                -- the large duplicate title in the selected-event panel.
                if center.X < viewport.X * 0.30 then
                    if not best or object.AbsoluteSize.X > best.AbsoluteSize.X then
                        best = object
                    end
                end
            end
        end
        if best then return best end
        task.wait(0.25)
    until os.clock() >= deadline
end

launchEventFarm = function(data)
    status.Text = "Hub reached; opening Events..."
    local eventsLabel = waitFor(playerGui, "Events", 20)
    if not eventsLabel then return false, "Events button was not found" end
    task.wait(0.75)
    click(eventsLabel)

    local villainCard = waitForEventCard("Villain Invasion", 10)
    if not villainCard then return false, "Villain Invasion event card was not found" end
    status.Text = "Selecting Villain Invasion event..."
    challengeLog("CLICK", "Selecting Villain Invasion card from the Events list")
    task.wait(0.65)
    click(villainCard)
    -- The Event Gamemode button exists for every event, so wait for the
    -- selected panel to finish swapping before pressing it.
    task.wait(1.0)

    local eventMode = waitFor(playerGui, "Event Gamemode", 10)
    if not eventMode then return false, "Event Gamemode button was not found" end
    status.Text = "Opening Event Gamemode..."
    task.wait(0.75)
    click(eventMode)

    local actOne = waitForPattern("^Act 1%s*%-", 10)
    if not actOne then return false, "Event Act 1 card was not found" end
    status.Text = "Selecting Event Act 1..."
    task.wait(0.75)
    click(actOne)
    local selectStage = waitFor(playerGui, "Select Stage", 8)
    if not selectStage then return false, "Event Select Stage did not appear" end

    local selected, selectError = selectMacroProfile(data.resumeProfile or "event1")
    if not selected then return false, tostring(selectError) end
    data.profile = nil
    setPhase(data, "entering_farm", "Launching Event Act 1; waiting for teleport...")
    local queued, queueError = queueCombinedLoader(data)
    if not queued then return false, tostring(queueError) end

    task.wait(0.55)
    click(buttonOf(selectStage) or selectStage)
    local startLabel = waitFor(playerGui, "Start", 8)
    if not startLabel then return false, "Event party Start did not appear" end
    task.wait(0.55)
    click(buttonOf(startLabel) or startLabel)
    return true
end

local function expeditionSelection()
    local ok, config = pcall(function()
        if not isfile(macroConfigFile) then return nil end
        return HttpService:JSONDecode(readfile(macroConfigFile))
    end)
    if not ok or type(config) ~= "table" then return nil, nil end
    local profile = config.selectedExpedition
    local normalized = tostring(profile or ""):lower():gsub("_", " ")
    local map = normalized:find("flower", 1, true) and "Flower Forest"
        or (normalized:find("rose", 1, true) and "Rose Kingdom" or "School Grounds")
    return profile, map
end

local function expeditionDifficultyPlus(difficulty)
    local center = difficulty.AbsolutePosition + difficulty.AbsoluteSize / 2
    local best, bestDistance
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("TextButton") and visible(object) and textOf(object) == "" then
            local objectCenter = object.AbsolutePosition + object.AbsoluteSize / 2
            local dx, dy = objectCenter.X - center.X, math.abs(objectCenter.Y - center.Y)
            local size = object.AbsoluteSize
            if dx > 100 and dx < 420 and dy < 110
                and size.X >= 55 and size.X <= 160 and size.Y >= 55 and size.Y <= 160 then
                local distance = dx + dy * 3
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = object, distance
                end
            end
        end
    end
    return best
end

local function launchExpeditionFarm(data)
    local profile, mapName = expeditionSelection()
    if not profile then return false, "No selected Expedition profile" end
    data.resumeProfile = profile

    local play = waitFor(playerGui, "Play", 20)
    if not play then return false, "Play button was not found for Expedition" end
    task.wait(0.65)
    click(play)
    local expedition = waitFor(playerGui, "Expedition", 8)
    if not expedition then return false, "Expedition card was not found" end
    task.wait(0.85)
    click(expedition)

    local map = waitFor(playerGui, mapName, 10)
    if not map then return false, mapName .. " Expedition map was not found" end
    task.wait(0.60)
    click(map)
    local difficulty = waitForPattern("^Difficulty %d+$", 8)
    if not difficulty then return false, "Expedition difficulty was not found" end
    for _ = 1, 3 do
        local level = tonumber(textOf(difficulty):match("(%d+)$"))
        if level and level >= 3 then break end
        local plus = expeditionDifficultyPlus(difficulty)
        if not plus then return false, "Expedition difficulty + was not found" end
        click(plus)
        task.wait(0.45)
        difficulty = waitForPattern("^Difficulty %d+$", 3) or difficulty
    end
    if textOf(difficulty) ~= "Difficulty 3" then
        return false, "Could not confirm Expedition Difficulty 3"
    end

    local selectStage = waitFor(playerGui, "Select Stage", 8)
    if not selectStage then return false, "Expedition Select Stage was not found" end
    setPhase(data, "entering_farm", "Launching Expedition " .. mapName .. " D3...")
    local queued, queueError = queueCombinedLoader(data)
    if not queued then return false, tostring(queueError) end
    task.wait(0.55)
    click(buttonOf(selectStage) or selectStage)
    local startLabel = waitFor(playerGui, "Start", 8)
    if not startLabel then return false, "Expedition party Start did not appear" end
    task.wait(0.55)
    click(buttonOf(startLabel) or startLabel)
    return true
end

resumeSelectedFarm = function(data)
    local mode = data.returnMode or data.resumeMode or "event"
    if mode == "hub" then
        data.completedCycle = data.cycle or currentChallengeCycle()
        setPhase(data, "idle", "Challenge batch complete; stopped in hub")
        return true
    elseif mode == "expedition" then
        return launchExpeditionFarm(data)
    end
    return launchEventFarm(data)
end

local function runResumedFarm(data)
    local expeditionMode = (data.returnMode or data.resumeMode) == "expedition"
    status.Text = expeditionMode and "Expedition server detected; starting sequence..."
        or ("Event server detected; starting " .. (data.resumeProfile or "event1") .. "...")

    if not expeditionMode then
        local wanted = data.resumeProfile or "event1"
        local selected = false
        if type(sharedEnv.__TowerMacroSelectProfile) == "function" then
            local ok, result = pcall(sharedEnv.__TowerMacroSelectProfile, wanted)
            selected = ok and result == true
        else
            selected = selectMacroProfile(wanted)
        end
        if not selected then
            setPhase(data, "failed", "Could not select resumed Event profile '" .. wanted .. "'")
            return
        end
        if type(sharedEnv.__TowerMacroSelectedProfile) == "function" then
            local ok, active = pcall(sharedEnv.__TowerMacroSelectedProfile)
            if not ok or active ~= wanted then
                setPhase(data, "failed", "Event return kept the wrong profile: " .. tostring(active))
                return
            end
        end
    end

    local runProfile
    local deadline = os.clock() + 15
    repeat
        for _, object in ipairs(CoreGui:GetDescendants()) do
            local expected = expeditionMode and "RUN SEQUENCE" or "RUN PROFILE"
            if object:IsA("TextButton") and clean(object.Text) == expected
                and object.Visible and object.AbsoluteSize.X > 1 then
                runProfile = object
                break
            end
        end
        if not runProfile then task.wait(0.25) end
    until runProfile or os.clock() >= deadline
    if not runProfile then
        setPhase(data, "failed", expeditionMode
            and "RUN SEQUENCE was not found after resuming Expedition"
            or "RUN PROFILE was not found after resuming Event")
        return
    end
    if not expeditionMode then
        local startGate = waitFor(playerGui, "Start Game", 12)
            or findText(playerGui, "Start Game?")
        if startGate then
            challengeLog("WAIT", "Event Start Game UI detected; waiting 1.2s for its tween")
            task.wait(1.2)
        else
            challengeLog("WAIT", "Event Start Game UI was not detected before profile start")
            task.wait(0.8)
        end
    else
        task.wait(0.8)
    end
    challengeLog("CLICK", expeditionMode and "RUN SEQUENCE after farm return"
        or "RUN PROFILE event1 after farm return")
    clickOnce(runProfile)

    if not expeditionMode then
        task.spawn(function()
            task.wait(2.0)
            local startGate = findText(playerGui, "Start Game")
            if startGate then
                challengeLog("RECOVERY", "Start Game still visible; sending one fallback click")
                task.wait(0.35)
                click(buttonOf(startGate) or startGate)
            else
                challengeLog("CONFIRM", "Event Start Game window closed normally")
            end
        end)
    end
    data.completedCycle = data.cycle
    if data.schedulerEnabled then
        setPhase(data, "farm_running", expeditionMode
            and "FULL CYCLE COMPLETE: Expedition resumed; scheduler armed"
            or "FULL CYCLE COMPLETE: event1 resumed; scheduler armed")
        monitorFarmResult(data)
    else
        setPhase(data, "farm_resumed", expeditionMode
            and "FULL CYCLE COMPLETE: Expedition resumed"
            or "FULL CYCLE COMPLETE: event1 resumed")
    end
end

local function openChallengeBatchFromHub(data, message)
    status.Text = message or "Opening challenges from hub..."
    local playLabel = waitFor(playerGui, "Play", 20)
    if not playLabel then return false, "Play button was not found in hub" end
    task.wait(0.65)
    click(playLabel)

    local challengeLabel = waitFor(playerGui, "Challenge", 7)
    if not challengeLabel then
        task.wait(0.75)
        click(playLabel)
        challengeLabel = waitFor(playerGui, "Challenge", 7)
    end
    if not challengeLabel then return false, "Challenge card was not found" end
    task.wait(0.90)
    click(challengeLabel)

    if not waitFor(playerGui, "Regular Challenge #1", 8) then
        task.wait(0.90)
        challengeLabel = findText(playerGui, "Challenge")
        if challengeLabel then click(challengeLabel) end
    end
    if not waitFor(playerGui, "Regular Challenge #1", 8) then
        return false, "Regular Challenge list did not open"
    end

    -- Roblox exposes the labels slightly earlier than their cards reach the
    -- final screen positions. Clicking during that layout transition can land
    -- on a reward icon below the title.
    task.wait(0.60)

    setPhase(data, "batch_hub", "Regular list reached; continuing batch...")
    return processBatch(data)
end

local data = loadState()
challengeLog("START", ("Controller loaded | phase=%s scheduler=%s return=%s slot=%s profile=%s"):format(
    tostring(data.phase), tostring(data.schedulerEnabled == true),
    tostring(data.returnMode), tostring(data.slot), tostring(data.profile)
))
data.enabled = type(data.enabled) == "table" and data.enabled
    or { ["1"] = true, ["2"] = true, ["3"] = true }
data.schedulerEnabled = data.schedulerEnabled == true
if data.returnMode ~= "event" and data.returnMode ~= "expedition"
    and data.returnMode ~= "hub" then
    data.returnMode = "event"
end
phaseLabel.Text = "PHASE: " .. tostring(data.phase)

local function refreshReturnModeButton()
    local labels = {event = "RETURN: EVENT", expedition = "RETURN: EXPED.", hub = "RETURN: HUB"}
    returnModeButton.Text = labels[data.returnMode] or labels.event
    returnModeButton.BackgroundColor3 = data.returnMode == "event"
        and Color3.fromRGB(66, 48, 82)
        or (data.returnMode == "expedition" and Color3.fromRGB(31, 73, 70)
            or Color3.fromRGB(53, 55, 68))
end
refreshReturnModeButton()

local function refreshSchedulerButton()
    schedulerButton.Text = data.schedulerEnabled
        and "AUTO CHALLENGE: ON" or "AUTO CHALLENGE: OFF"
    schedulerButton.BackgroundColor3 = data.schedulerEnabled
        and Color3.fromRGB(31, 78, 59) or Color3.fromRGB(48, 43, 61)
end
refreshSchedulerButton()

sharedEnv.__TowerChallengeToggleWindow = function()
    gui.Enabled = not gui.Enabled
end
sharedEnv.__TowerChallengeShouldExit = function()
    if data.schedulerEnabled ~= true
        or currentChallengeCycle() <= tonumber(data.completedCycle or -1) then
        return false
    end
    local busyPhases = {
        opening_challenges = true,
        batch_hub = true,
        entering_challenge = true,
        challenge_stage = true,
        challenge_running = true,
        leaving_result = true,
        returning_to_hub = true,
        returning_to_farm = true,
        entering_farm = true,
    }
    -- Once a result transition has begun, ordinary macro/Expedition Repeat
    -- must remain blocked until the new server is reached.
    if busyPhases[data.phase] then return true end
    if data.phase ~= "farm_running" then
        setPhase(data, "farm_running", "Pending cycle recovered; Repeat blocked")
        monitorFarmResult(data)
    end
    return true
end
sharedEnv.__TowerChallengeFarmStarted = function(profileName)
    if not data.schedulerEnabled then return end
    data.resumeMode = data.returnMode
    data.resumeProfile = data.returnMode == "event" and "event1" or profileName
    data.farmProfile = profileName
    if data.completedCycle == nil then
        data.completedCycle = currentChallengeCycle() - 1
    end
    setPhase(data, "farm_running", "Scheduler armed; waiting for farm result...")
    monitorFarmResult(data)
end
sharedEnv.__TowerChallengeDisable = function()
    data.schedulerEnabled = false
    farmMonitorToken += 1
    setPhase(data, "idle", "Auto Challenge disabled with Tower Macro")
    refreshSchedulerButton()
end

local function refreshSlotButton(slot)
    local enabled = data.enabled[tostring(slot)] ~= false
    local button = slotButtons[slot]
    button.Text = ("#%d: %s"):format(slot, enabled and "ON" or "OFF")
    button.BackgroundColor3 = enabled and Color3.fromRGB(38, 76, 66)
        or Color3.fromRGB(55, 43, 51)
end

for slot = 1, 3 do
    refreshSlotButton(slot)
    slotButtons[slot].MouseButton1Click:Connect(function()
        if running then return end
        local key = tostring(slot)
        data.enabled[key] = not (data.enabled[key] ~= false)
        saveState(data)
        refreshSlotButton(slot)
    end)
end

if data.phase == "farm_running" then
    monitorFarmResult(data)
end

local function stageIdentityVisible()
    if findText(playerGui, "Start Game?") or findText(playerGui, "Start Game") then
        return true
    end
    if currentMap() then return true end
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) then
            local text = textOf(object):lower()
            if text:find("regular challenge #", 1, true) then
                return true
            end
        end
    end
    return false
end

local function recoverChallengeStage()
    local challengeSlot
    for _, object in ipairs(playerGui:GetDescendants()) do
        if visible(object) then
            local text = textOf(object):lower()
            local slot = text:match("regular challenge%s*#(%d)")
            if slot then
                challengeSlot = tonumber(slot)
                break
            end
        end
    end
    if not challengeSlot then return false end

    local map = currentMap()
    local profile = profileForMap(map)
    if not profile then
        setPhase(data, "failed", "Challenge recovery could not map stage '" .. tostring(map) .. "'")
        return true
    end
    data.slot = challengeSlot
    data.map = map
    data.profile = profile
    setPhase(data, "challenge_stage", ("Recovered challenge #%d %s -> %s"):format(
        challengeSlot, tostring(map), profile
    ))
    task.defer(function() runStage(data) end)
    return true
end

if recoverChallengeStage() then
    -- Recovery is intentionally checked before the persisted phase.  A Roblox
    -- or executor crash can leave disk at batch_hub while the rejoined client
    -- is already inside a Regular Challenge server.
elseif data.phase == "entering_challenge" or data.phase == "challenge_stage" then
    task.defer(function()
        local deadline = os.clock() + 60
        repeat
            if stageIdentityVisible() then
                runStage(data)
                return
            end
            task.wait(0.25)
        until os.clock() >= deadline
        if data.phase == "entering_challenge" then
            status.Text = "Still waiting: challenge stage identity was not found."
        end
    end)
elseif data.phase == "leaving_result" or data.phase == "returning_to_hub"
    or data.phase == "challenge_running" then
    -- The queued script can start before the destination UI exists.  Recover
    -- from the screen that actually appears instead of trusting a phase that
    -- may have been saved a fraction of a second before teleportation.
    task.defer(function()
        local deadline = os.clock() + 35
        repeat
            if recoverChallengeStage() then return end
            local play = findText(playerGui, "Play")
            if play then
                setPhase(data, "returning_to_hub", "Hub detected; continuing remaining challenges...")
                local ok, err = openChallengeBatchFromHub(data,
                    "Hub recovered; opening the next selected challenge...")
                if not ok then setPhase(data, "failed", tostring(err)) end
                return
            end
            task.wait(0.75)
        until os.clock() >= deadline
        setPhase(data, "failed", "Neither challenge stage nor hub UI appeared after teleport")
    end)
elseif data.phase == "entering_farm" then
    task.defer(function() runResumedFarm(data) end)
elseif data.phase == "returning_to_hub" then
    task.defer(function()
        local ok, err = openChallengeBatchFromHub(data, "Hub return detected; opening next challenge...")
        if not ok then setPhase(data, "failed", tostring(err)) end
    end)
elseif data.phase == "returning_to_farm" then
    task.defer(function()
        local deadline = os.clock() + 35
        repeat
            -- We may already be in the destination Event/Expedition server;
            -- in that case there is no hub Play button to find.
            if recoverChallengeStage() then return end
            if stageIdentityVisible() then
                runResumedFarm(data)
                return
            end
            if findText(playerGui, "Play") then
                local ok, err = resumeSelectedFarm(data)
                if not ok then setPhase(data, "failed", tostring(err)) end
                return
            end
            task.wait(0.75)
        until os.clock() >= deadline
        setPhase(data, "failed", "Neither resumed farm stage nor hub UI appeared")
    end)
end

start.MouseButton1Click:Connect(function()
    if running then return end
    running = true
    data = {
        phase = "idle",
        processed = {},
        enabled = data.enabled,
        schedulerEnabled = data.schedulerEnabled,
        returnMode = data.returnMode,
    }
    start.Text = "WORKING..."
    task.spawn(function()
        local ok, err = processBatch(data)
        if not ok then
            setPhase(data, "failed", tostring(err))
            start.Text = "START BATCH TEST"
            running = false
        end
    end)
end)

startHub.MouseButton1Click:Connect(function()
    if running then return end
    running = true
    data = {
        phase = "opening_challenges",
        processed = {},
        enabled = data.enabled,
        schedulerEnabled = data.schedulerEnabled,
        returnMode = data.returnMode,
        cycle = math.floor(workspace:GetServerTimeNow() / 1800),
        resumeMode = data.returnMode,
        resumeProfile = data.returnMode == "event" and "event1" or nil,
    }
    saveState(data)
    phaseLabel.Text = "PHASE: opening_challenges"
    startHub.Text = "OPENING CHALLENGES..."
    task.spawn(function()
        local ok, err = openChallengeBatchFromHub(data, "Starting selected challenges from hub...")
        if not ok then
            setPhase(data, "failed", tostring(err))
            startHub.Text = "START CHALLENGES FROM HUB"
            running = false
        end
    end)
end)

returnModeButton.MouseButton1Click:Connect(function()
    if running then return end
    local modes = {event = "expedition", expedition = "hub", hub = "event"}
    data.returnMode = modes[data.returnMode] or "event"
    data.resumeMode = data.returnMode
    saveState(data)
    refreshReturnModeButton()
end)

schedulerButton.MouseButton1Click:Connect(function()
    data.schedulerEnabled = not data.schedulerEnabled
    if data.schedulerEnabled then
        data.completedCycle = currentChallengeCycle() - 1
        data.resumeMode = data.returnMode
        data.resumeProfile = data.returnMode == "event" and "event1" or nil
        data.processed = {}
        setPhase(data, "farm_running", "Auto Challenge enabled; current cycle is pending")
        monitorFarmResult(data)
    else
        farmMonitorToken += 1
        setPhase(data, "idle", "Auto Challenge disabled")
    end
    refreshSchedulerButton()
end)

armFarm.MouseButton1Click:Connect(function()
    if running then return end
    running = true
    data = {
        phase = "farm_running",
        processed = {},
        enabled = data.enabled,
        schedulerEnabled = data.schedulerEnabled,
        returnMode = data.returnMode,
        cycle = math.floor(workspace:GetServerTimeNow() / 1800),
        resumeMode = data.returnMode,
        resumeProfile = data.returnMode == "event" and "event1" or nil,
    }
    saveState(data)
    phaseLabel.Text = "PHASE: farm_running"
    armFarm.Text = "ARMED"
    monitorFarmResult(data)
end)

close.MouseButton1Click:Connect(function()
    if not running then gui.Enabled = false end
end)

for _, object in ipairs(CoreGui:GetChildren()) do
    if object.Name:match("^TowerMacro_v") then
        gui.Enabled = false
        break
    end
end
print("[ChallengeHandoffTest] Phase: " .. tostring(data.phase))
print("[ChallengeHandoffTest] Log: " .. logFile)

task.spawn(function()
    while gui.Parent do
        task.wait(60)
        if not gui.Parent then break end
        local screen = "unknown"
        if findText(playerGui, "Victory") then
            screen = "victory"
        elseif findText(playerGui, "Defeat") then
            screen = "defeat"
        elseif findText(playerGui, nil, "^Regular Challenge #%d") then
            screen = "challenge_menu_or_stage"
        elseif findText(playerGui, "Play") then
            screen = "hub"
        elseif findText(playerGui, "Start Game?") or findText(playerGui, "Start Game") then
            screen = "stage_start"
        end
        challengeLog("HEARTBEAT", ("phase=%s screen=%s slot=%s profile=%s running=%s"):format(
            tostring(data.phase), screen, tostring(data.slot),
            tostring(data.profile), tostring(running)
        ))
    end
end)
