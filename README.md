# AnimeExpedition

Auto-updating Tower Macro distribution.

## Launch

```lua
local source = assert(game:HttpGet("https://raw.githubusercontent.com/alexgroomov/AnimeExpedition/main/loader.lua?v=latest"))
local start, compileError = loadstring(source:gsub("^\239\187\191", ""))
assert(start, compileError)()
```

The loader downloads and caches `tower_macro.lua` and
`challenge_handoff_test.lua`. User profiles and configuration remain local.
