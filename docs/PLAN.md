# Vault's own save engine

Vault no longer depends on ProfileStore. The engine is ProfileStore's algorithm rebuilt as small modules inside
`src/Vault/Engine`, proven by simulated servers. It has not run on real Roblox servers yet (phase 5).

## Design decisions

1. **Full compatibility with ProfileStore.** Same key content (`Data`, `MetaData`, `GlobalUpdates`, `UserIds`,
   `RobloxMetaData`) and same MessagingService topic (`PS_<session id>` with `LoadCount` and `EndSession`). During a
   game update old servers run ProfileStore and new servers run the engine against the same profiles, so they must
   speak the same protocol. `tools/specs/fleet.spec.luau` runs both side by side.
2. **Pure decisions, effects at the edge.** Who gets the lock is a function with no yields: stored record, this
   server and the time go in; the new record and a verdict come out. The `UpdateAsync` transform only calls it.
3. **One engine per server, built from a platform table.** `Engine.shared()` builds it from the live Roblox
   services; every clock, data store and messaging call goes through `Platform`, so several servers run in one test.

## Modules (`src/Vault/Engine`)

| Module | Role |
|---|---|
| `init` | facade: open a store, start a session, view a key, send a message, remove a key, health signals |
| `Settings` | every time and limit in one place |
| `Platform` | the live Roblox services behind one table |
| `Record` | the saved format: classify what a key holds, messages, copy, reconcile |
| `Lock` | lock decisions, pure |
| `Storable` | says whether a value can be kept by a data store, pure |
| `Budget` | keeps low priority requests out of the budget player saves need |
| `Plain`, `Ordered` | one read or write of a plain key or an OrderedDataStore, for global data |
| `Signal`, `Queue` | listeners; one call at a time per key |
| `Memory` | in memory data store: the mock store and Studio without API access |
| `Backend` | one write or read of a key: queue, live or memory, error report; Studio access probe |
| `Throttle` | holds requests after a throttling error; jitter for retries |
| `Health` | error counts, critical state, size meter, signals for telemetry |
| `Wheel` | auto save turns |
| `Inbox` | messages: append, deliver, mark processed |
| `Saver` | save one session; the last save retries until it lands |
| `Session` | the start loop: conflict, release request, steal, cancel, reload on the same server |
| `Offline` | view and remove a key without a session |
| `Shutdown` | run the shutdown tasks, release everything and wait for the saves |

Global data (shared documents, counters, leaderboards) lives in `src/Vault/Global` on top of the engine; see
`docs/GLOBAL.md`.

Not ported: version queries, forced steal by the caller, `SetConstant`, view mode writes.

## Phases

1. **Simulated world, scenarios green against the original ProfileStore.** Done.
2. **`Record` and `Lock`.** Done. `tools/specs/replay.spec.luau` feeds every write the original ProfileStore made in
   the random runs through them and requires the same result.
3. **The rest of the engine.** Done. Every scenario, the random runs and the calibration pass for the `Engine`
   driver, and mixed fleets pass with ProfileStore servers on the same keys.
4. **Vault on the engine.** Done. `Store.luau` opens the engine, `Server.luau` uses its sessions, and
   `tools/specs/vault.spec.luau` runs the whole server on simulated servers. ProfileStore stays only in `reference/`.
5. **Real servers in a test place.** Prepared, not run: `realtest/` builds a place that runs a suite against the
   real data store and a hop test across four live servers. Steps in `docs/REALTEST.md`; it needs the owner to
   publish the place and join it. First consumer: a game without live saves. Games with live saves come last, and
   only after this phase.
6. **Beyond ProfileStore.** Done, see below.

Out of scope until a game needs it: cross player transactions, splitting data over several keys, MemoryStore locks.

## What the engine does differently from ProfileStore

- A cancelled load whose answer got lost releases the lock it may have taken (one write that clears the lock only
  if it carries this session id). ProfileStore leaves it for the next server to steal after about 45 s.
- A save on a key that was removed under its session ends the session. ProfileStore retries it forever and blocks
  the shutdown.
- A server listens for release requests from its first second. ProfileStore ignores them for 6 s of clock time.
- The release listener uses the session id that is really stored, also when a newer load in the same server took
  over an older one.
- `session.saveNow()` waits for the write and answers `Saved`, `Lost` or `Failed`.
- Every save measures the encoded data and warns at 50, 75 and 90 % of the 4,194,304 key limit (`onSize`).
- After a throttling error every request of the server waits (5 s, 15 s for experience wide limits, with jitter),
  except while shutting down. Retries carry jitter.
- Errors and warnings are prefixed `[Vault]`.

## What changed for games

Vault's API is the same, plus:

- `Vault.server.saveNow(player)` returns `"Saved"`, `"Lost"` or `"Failed"` after the write finished.
- `Vault.server.size(player)` returns the encoded bytes of the last save.
- `set`, `insert` and `update` refuse a value a data store cannot keep (function, thread, Instance or other
  userdata, a table that contains itself, text that is not UTF-8, keys that are not text or numbers). In Studio it
  raises; live it warns and returns false. Shapes that save but may come back different (mixed keys, lists with gaps,
  non finite numbers) only warn in Studio.
- `update` returns nil when its write was refused.
- `wipe` returns false when the data store refused the removal (it used to answer true).

## What running the original taught us

Behaviour of ProfileStore the engine has to copy or change on purpose:

- A server ignores release requests during its first 6 seconds of `os.clock`.
- When a release request never arrives the new server takes the profile after about 45 s. What the old server had
  not saved is lost, and its later saves are refused. By design, keep.
- If a load is cancelled (player left, server closing) after its request reached the data store but the answer got
  lost, the lock stays behind with nobody holding it. The next server waits the steal delay.
- A save on a key that was removed while its session was open errors inside the transform; a last save retries it
  every 20 s forever and the server cannot finish its shutdown in time (checked in the simulation).
- When two servers ask for the same held profile, the first one gives up as soon as it sees the second request.

## What the simulation covers and what it does not

Covered: session hand off, steal after a silent server, dead server limit, data store outages while loading and
while saving, lost responses, repeated transforms, shutdown, cancelled loads, messages, corrupted keys, and random
runs mixing all of them with server hops.

Invariants: only the lock holder changes `Data`; a counter that only grows never goes back; an acknowledged save is
never lost; messages sent equal messages applied plus messages pending on every write; after a run every key can be
opened by a new server within 90 s. Engines without the `ghostLocks` trait must also leave no lock behind when a
server closes cleanly.

The replay proves `Record` and `Lock` produce what ProfileStore wrote for some intent. It cannot catch a rule that
takes the lock in more cases than ProfileStore does; the table specs and the session scenarios cover that side.

The specs are calibrated by mutation: one rule of the engine is changed at a time and the suite has to fail.
Of 60 changes tried, 56 were caught; the other 4 change nothing a caller can observe.

The throttling names and the key limit come from the Roblox docs page "Data stores: error codes and limits" as read
on 2026-11-13. The page does not show the exact text a pcall returns, so `Throttle` matches on substrings. Which
value shapes a real data store refuses is not verified against Roblox either; `Storable` only refuses the ones
that cannot be encoded at all.

Not covered: the real DataStore and MessagingService (limits, throttling, real latency), which is what phase 5 is for.
`os.clock` in the simulation starts at 600 s because ProfileStore ignores release requests during a server's first
6 seconds of clock time.
