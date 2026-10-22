This is the **bot-record** asset for TMC's **Dot** collection. It records what players do, as episodes against a schema the game declares, for bots to learn from.

All `dot-*` assets are open source under the MIT license; see [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap) to clone and link them. Treat this as partially tested.

## What it does
A game registers a `DotBotDemoSchema` per kind of episode, then calls `begin`, `sample` and `end` on a `DotBotDemoRecorder`. The recorder samples at a rate that is high while a key has few recordings and falls to a base rate once it has enough, queues finished episodes, and writes them in time-budgeted batches to a store: JSON files (default), SQL through dot-sql (by duck typing), or memory. Nothing identifying is kept. It is on by default (`bot_record 0` switches it off).

## Getting started
Copy `addons/dot_bot_record/` and [dot-core](https://github.com/modcommunity/dot-core)'s `addons/dot_core/` into your project and enable the plugin. dot-core is the only dependency. See [docs/demonstration-recorder.md](docs/demonstration-recorder.md).
