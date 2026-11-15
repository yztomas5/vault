# Real server test

Phase 5 of `docs/PLAN.md`: run Vault against the real DataStoreService and MessagingService, and across real
servers. The test lives in `realtest/` and builds into one place file. It only writes to data stores whose name starts
with `VaultRealTest`, under keys it creates and removes, so it never touches a game's saves.

## Build

```
rojo build realtest/realtest.project.json -o build/VaultRealTest.rbxl
```

## Step 1: the suite, in Studio

1. Open `build/VaultRealTest.rbxl` in Studio.
2. Publish it as a new private place (File > Publish to Roblox As).
3. Game Settings > Security > turn on Enable Studio Access to API Services.
4. Press Play. The screen fills with the report; the same lines go to the Output window with the prefix
   `[VaultRealTest]`.

It takes about three minutes and ends with `SUITE RESULT: N passed, M failed`.

What it runs, each against the real data store:

| Section | What it proves |
|---|---|
| save, lock and release | the saved format, the lock, user ids on the key, the size meter |
| hand off between two servers | a second server gets the session within seconds through MessagingService |
| take over from a dead server | the steal delay when a server never answers |
| dead server limit | a lock that went silent is taken at once |
| messages | delivery to an offline profile and to an open session |
| view and remove | reading without the lock, removing a key |
| reload in the same server | a quick leave and join keeps the newest data |
| ProfileStore and Vault on the same profile | the original ProfileStore and Vault hand a live profile to each other |
| global data across two servers | shared updates from two servers at once, sums, a cap of five against eight claims, a leaderboard |
| the whole Vault server | join, set, save, leave and join again through `Vault.new()` |
| what the real data store does with odd values | information only: which shapes Roblox refuses, and how the others come back |

The two "servers" of each section are two engines inside the same Roblox server, each with its own server id, so
they only meet through the real data store and the real messaging service. A dead server is an engine that stops
doing anything. Their timings are shortened (steal after 6 s, dead after 20 s) so the suite stays short; the section
with ProfileStore uses the real timings.

## Step 2: the hop test, on live servers

1. Join the published place from the Roblox app (not from Studio).
2. Wait. The first server runs the suite again on live servers, then the hop test starts by itself.
3. You are teleported through four servers: public, reserved, public, reserved. Do not leave.
4. The last server shows `HOP TEST PASSED` or `HOP TEST FAILED`, with one line per server and its load time.

Each server loads your test data through Vault, checks it is what the previous server left, adds one and moves you
on. On the first and third hop the server lets you go WITHOUT releasing your data, the way a game that lost track
of a player would: the next server has to ask for it through MessagingService, and the emptied server has to save it
at shutdown.

## Reading the result

- A `FAIL` line names the check and, in brackets, the measured value.
- Timing checks can fail when Roblox throttles the server: the suite makes about a hundred requests in a few
  minutes. Run it again before reading a timing failure as a bug.
- The `info` lines of the last section are the answer to an open question in `docs/PLAN.md`: which value shapes a
  real data store refuses. `Engine/Storable.luau` should be aligned with them.

## What this test cannot show

A server that really crashes, real throttling under load, and outages. Those stay covered only by the simulation.
