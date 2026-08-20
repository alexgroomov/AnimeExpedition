local BASE = "https://raw.githubusercontent.com/alexgroomov/AnimeExpedition/main/"

local function fetch(name)
    local ok, body = pcall(function()
        return game:HttpGet(BASE .. name .. "?v=" .. tostring(os.time()))
    end)
    if ok and type(body) == "string" and #body > 100 then
        body = body:gsub("^\239\187\191", "")
        pcall(writefile, name, body)
        return body
    end
    if isfile and isfile(name) then
        warn("[AnimeExpedition] Update unavailable; using cached " .. name)
        return readfile(name)
    end
    error("[AnimeExpedition] Cannot download " .. name .. ": " .. tostring(body))
end

-- Download shared data and the companion before Tower Macro starts.
fetch("EquipmentDatabase_v3_84515722934860.json")
fetch("challenge_handoff_test.lua")
local source = fetch("tower_macro.lua")
local chunk, compileError = loadstring(source)
if not chunk then
    error("[AnimeExpedition] Compile failed: " .. tostring(compileError))
end
return chunk()

