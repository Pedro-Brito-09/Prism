# Testing and checks

## Tests

Part of the suite needs no Roblox at all:

```bash
scripts/test-pure.sh
```

`tests/Pure.luau` covers Varint, Handles, IdPool, the codecs, Try, CustomEnum,
permission resolution and property layout: everything that needs no DataModel.
Much of it is the floor the format stands on: every id, length and count in a
pack is a varint, every saved object is addressed by a persistent id, every
registry id comes out of a pool. It checks every byte length boundary this file
claims for varints, that `PersistentId` really is `Scene * 2^32 + Local` across
the 48 bits it uses, that every codec that does not need a Roblox type round
trips at its boundaries, that a blacklist beats a whitelist, and that a
non-recycling pool never hands out a released id twice. It fetches a Luau CLI
into `.tooling/`; CI runs it on every push.

The rest needs a DataModel, players and replication, so Studio is the only place
it runs.

The tests run the unit suite on the server and the replication, permissions,
optimistic-edit, transaction and lifecycle suite on one client. Insert
`PrismTests.rbxmx` — from a release, or from `dist/` after
`node scripts/build.js` — into ReplicatedStorage in an empty place. It brings
its own copy of Prism:

```text
ReplicatedStorage
└── PrismTests
    ├── Prism                      <- src/
    ├── Harness                    <- tests/Harness.luau
    ├── Server                     <- tests/Server.server.luau (RunContext Server)
    └── Client                     <- tests/Client.client.luau (RunContext Client)
```

Both suites are Scripts with RunContext set, so they run from where they are,
and every require is relative to the model.

Then use **Test > Play** with one player. The server creates a set of
integration fixtures and intentionally keeps them alive so the client can
validate both live delivery and late-join replay. A failed test prints its group
and assertion, then fails the corresponding script.

> **Warning: the database tests write to real data stores.** They use the
> DataStore and MemoryStore keys `PrismSelfTest` and `PrismSelfTestBurst`, need
> Studio API access enabled, and are **on by default**: `RUN_DATABASE` near the
> top of `tests/Server.server.luau` switches them. They **wipe both keys** before
> they start and after they finish, so never point them at a key that holds
> anything you want. Set `RUN_DATABASE = false` in any place whose data stores
> you care about.

## Type checking

Every file is `--!strict`, and `scripts/analyze.sh` is what actually holds them
to it:

```bash
scripts/analyze.sh
```

It fetches a pinned `luau-lsp` and the Roblox API definitions into `.tooling/`
and runs the analyser over `src/` and `tests/`. Nothing has to be installed
first, and nothing is left behind that `.gitignore` does not already cover. CI
runs this script, `check-channels.js` and `test-pure.sh`, so a push is checked
exactly the way a local run is.

The tests are only lightly checked. The analyser reads files, not the model, so
it cannot resolve the suites' `require("./Prism")`, and everything the suites get from Prism
reads as `any`, and a mistake in how a test calls Prism shows up when the test
runs rather than here. [`ROADMAP.md`](https://github.com/Pedro-Brito-09/Prism/blob/main/ROADMAP.md) has the reasoning for leaving it that way.

It fails when a file grows a diagnostic it did not have before, rather than
when any diagnostic exists at all. `.analyze-baseline.txt` records the count
per file, and `scripts/analyze.sh --update-baseline` rewrites it.

It runs the new type solver (`LuauSolverV2`), the one the code is written for:
`type function` and `read` fields are new-solver features, and the default
solver reports them as errors that are not. Under it `src/` is clean. What the
baseline still holds is the three unresolved `require`s in the suites described
above, so the ratchet is what lets the check pass without pretending those
away.

`scripts/analyze.sh --raw` prints everything, baseline or not.

`node scripts/check-channels.js` is the other half, and it checks what the
analyser structurally cannot. `Fire`, `FireAll` and `Invoke` all take `...:
any`, so sending a channel the wrong number of arguments type checks cleanly
and then errors at runtime. The script finds every caller across all three
call forms, the `Audience.Fire` paths included, and checks each against the
count the channel declares.

This is the check the Studio pass cannot do cheaply. A wrong argument count on a
channel, a function that returns one value where two are read, a field that
moved — the analyser finds all of those across 20,000 lines in seconds, where
playing the game finds them one at a time, each costing a rebuild and a replay.
Run it before taking a build into Studio, not after.
