# Benchmarks

Everything needed to check our numbers yourself. You don't need Branch Studio for this: Branch's compiled code is already in `generated/`, the same code the plugin puts in a game.

Results: [benchmarks page](https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html).

## Round 1: NetRay and Blink

From the repository root, with [Lune](https://github.com/lune-org/lune) 0.10 (`rokit install` sets it up):

```sh
lune run bench/bench.luau                # all 7 cases: 300 frames, best of 5
lune run bench/bench.luau Cars 300 5     # only cases with "Cars" in the name
```

For each case it prints every library, then how much faster or slower Branch is. "X% faster" means the other library needs X% more time for the same work. Every listener counts what arrives, and a library that loses events fails its row.

In Roblox Studio: open `BranchBenchmark.rbxl` and press Play (not Run). Six cases, about a minute, results in the Output. `lune run bench/engine/build.luau` rebuilds the place from these files.

## Round 2: BlinkBlox, QuickNet and Warp

```sh
lune run bench/rivals/run
```

This one runs inside BlinkBlox's own benchmark. See [rivals/README.md](rivals/README.md).

## Files

| Path | What it is |
|---|---|
| `core.luau`, `bench.luau` | Round 1 in Lune: mocked players and remotes, the workloads, the timing |
| `Bench.network.luau` | Branch's declaration of the round 1 events |
| `Definition.blink`, `netray/*.idl` | The same events for Blink and NetRay |
| `generated/` | Each library's code, made by its own tool from those files (`branch-unpack` is Branch with `Unpack = true` on the struct events) |
| `engine/`, `BranchBenchmark.rbxl` | The Studio version of round 1 |
| `rivals/` | Round 2 |

## Fairness

- Same schema, same data and the same mocked wire for every library (Lune), or the same place (Studio).
- In the Studio place all three modules get the same counters: remote calls, bytes, flush time.
- Branch runs as in a live game: its Studio-only profiler and argument checks are off.
- Branch validates what the server receives and its times include that. NetRay doesn't validate by default, so round 1 also runs NetRay with `Validate=Full`.
- Generated code is used as each tool wrote it.
