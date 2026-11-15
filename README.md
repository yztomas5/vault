# Vault

Data package for Roblox games: session locked player profiles with replication to the client, private
fields, migrations and Studio safety, plus global data (shared documents, counters, leaderboards, `docs/GLOBAL.md`). Next to it, Market sells products,
passes and subscriptions and handles gifts on top of Vault (`docs/MARKET.md`). Games receive a copy of `src/Vault`.

Vault saves with its own engine (`src/Vault/Engine`): ProfileStore's algorithm, saved format and MessagingService
topic rebuilt as small modules, so servers on ProfileStore and servers on Vault can share live profiles during a
rollout. It is proven on simulated servers and has not run on real Roblox servers yet. Design, status and what
changed for games: `docs/PLAN.md`.

## Highlights

- **Its own save engine.** Session locking, autosave, cross server messages and shutdown handling, rebuilt as
  small modules that keep ProfileStore's saved format, so a game can move over one server at a time.
- **Tested against a simulated Roblox.** A fake DataStoreService and MessagingService with fault injection, simulated
  servers that crash and shut down, and randomized soak runs with players hopping between servers.
- **Tests that prove themselves.** Deliberate bugs (`tools/lune/Breaks.luau`) must make the scenarios fail; every
  committed write is checked against invariants (`tools/lune/Watch.luau`).
- **Purchases that never charge twice.** Market keeps a receipt ledger in the profile and confirms the save before
  telling Roblox a purchase was granted.

## Setup

1. Install [Rokit](https://github.com/rojo-rbx/rokit), then run `rokit install` in this folder.
2. Download `ProfileStore.luau` from [its official repository](https://github.com/MadStudioRoblox/ProfileStore) into
   `reference/`. It is not included here because it is not my code; the specs use it as the behaviour the engine is
   compared against.
3. `lune run tools/check`.

## Commands

| Command | What it does |
|---|---|
| `lune run tools/check` | BOM, `rojo build`, real Luau syntax (luau-lsp on an accent-free copy) and every spec |
| `lune run tools/test [filter]` | builds `test.project.json` and runs `tools/specs/*.spec.luau` |
| `rojo build realtest/realtest.project.json -o build/VaultRealTest.rbxl` | builds the real server test place |

## Layout

| Path | What is in it |
|---|---|
| `src/Vault` | the package, exactly what games copy into `ReplicatedStorage/Packages/Vault` |
| `src/Vault/Engine` | the save engine: session locking, saving, messages, mock store, health, request budget |
| `src/Vault/Global` | shared documents, counters and leaderboards on top of the engine |
| `src/Market` | Robux purchases: products, passes, subscriptions and gifts, using Vault |
| `reference/ProfileStore.luau` | not included (see Setup): the original ProfileStore, only for the specs, the behaviour the engine is compared against |
| `realtest` | the real server test place, see `docs/REALTEST.md` |
| `tools/lune/Scheduler.luau` | virtual clock and task library shared by every simulated server |
| `tools/lune/Cloud.luau` | simulated DataStoreService and MessagingService with fault injection |
| `tools/lune/Cluster.luau` | simulated servers: own module cache, JobId, shutdown and crash |
| `tools/lune/Drivers.luau` | one adapter per engine so the same scenarios run against each |
| `tools/lune/Watch.luau` | invariants checked on every committed write |
| `tools/lune/Marketplace.luau` | simulated MarketplaceService: passes, subscriptions, price levels, prompts |
| `tools/lune/Breaks.luau` | deliberate bugs used to prove the scenarios catch them |
| `tools/lune/Soak.luau` | one randomized run: players, server hops, crashes, outages and messages |
| `tools/lune/Replay.luau` | rebuilds a recorded write with `Engine/Record` and `Engine/Lock` |
| `tools/specs` | scenarios on both engines (`sessions`), random runs (`soak`), mixed fleets (`fleet`), `replay`, the whole server (`vault`), engine only behaviour (`engine`), table specs (`record`, `lock`, `storable`, `wheel`, `queue`), calibration and harness self tests |

## License

Copyright (c) yztomas5. All rights reserved. This code is published only so it can be read. No permission is
granted to use, copy, modify or distribute it, in whole or in part.
