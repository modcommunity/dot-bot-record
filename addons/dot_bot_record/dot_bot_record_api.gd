extends RefCounted

## dot-bot-record's API level. The rule for bumping it is on [DotAddonApi].

# 1: the recorder, moved out of dot-bot (its API level 5) with every class name unchanged.
#    DotBotDemoSchema, DotBotDemoEpisode, DotBotDemoRecorder, DotBotDemoConfig (bind_cvars),
#    DotBotDemoStore (from_config), DotBotDemoStoreMemory, DotBotDemoStoreJson, DotBotDemoStoreSql.
const LEVEL := 1
const OLDEST := 1
