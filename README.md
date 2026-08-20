# AnimeExpedition

Auto-updating Tower Macro distribution.

## Launch

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/alexgroomov/AnimeExpedition/main/loader.lua?v=" .. os.time()))()
```

The loader downloads and caches `tower_macro.lua` and
`challenge_handoff_test.lua`. User profiles and configuration remain local.
