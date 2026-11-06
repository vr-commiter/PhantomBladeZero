# TrueGearSDK shared Lua module

Use from any UE4SS Lua mod:

```lua
local truegear = require("TrueGearSDK")
truegear.init("APP_ID", "API_KEY")
truegear.play_effect_by_uuid("EffectUuid")
```

See the project-level `TrueGearLuaSDK/README.md` for the complete API.
