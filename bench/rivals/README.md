# Round 2: BlinkBlox, QuickNet, Warp

This round runs inside BlinkBlox's own benchmark, the one BlinkBlox publishes its numbers with. We added Branch, QuickNet and Warp to it and left the rest alone.

## Run it

From the repository root, with Lune 0.10:

```sh
lune run bench/rivals/run
```

That runs BlinkBlox's three Lune benchmarks one after another and prints a table per case. It takes a few minutes. To run one of them by hand:

```sh
cd bench/rivals/blinkblox/benchmark
lune run Runtime -- --tools blink,branch,quicknet,upstream,warp
lune run Rivals -- --tools blink,branch,quicknet,upstream,warp
lune run Ours
```

`--frames 50` makes a run shorter. In the tables `blink` is BlinkBlox and `upstream` is Blink (those are BlinkBlox's own names for them).

## What the three are

- `Runtime`: BlinkBlox's main benchmark. 1000 events a frame of booleans, entities and one-byte events.
- `Rivals`: BlinkBlox's game scenarios: a broadcast to 50 players, unreliable input, events with an Instance, world state and per-player state.
- `Ours`: Branch's seven workloads from round 1 (`bench/core.luau`), run in BlinkBlox's harness.

Each one counts what arrives every frame (`Runtime` also compares the first value), so a tool that drops events fails instead of looking fast.

## What is in here

- `blinkblox/` is BlinkBlox at commit `7b0201c` (MIT, see `blinkblox/LICENSE`), trimmed to what the Lune benchmarks need. Its compiler in `blinkblox/src` builds BlinkBlox's side when the benchmark starts.
- `blinkblox/benchmark/packages/branch` is Branch's code for the same events, made by Branch Studio (`Definition`, `Scenarios`, `Ours`).
- `blinkblox/benchmark/packages/quicknet` is QuickNet 0.3.5 and `packages/warp` is Warp 1.1.0-pre7, each with its license. Warp's `const` lines are written as `local` so it loads on Lune 0.10 (Luau 0.709). That changes nothing about its speed.
- Blink's code is the one BlinkBlox ships for this benchmark (`src/shared/upstream`).
- zap, ByteNet and Packet are left out. BlinkBlox downloads them with `lune run build --download` in its own repository.

## Notes

- BlinkBlox measures on LuneBlox, a Lune build with Roblox's Luau version, and prints a warning when it runs on plain Lune. The numbers move a little between the two; the order does not.
- For steady numbers close other programs. On CPUs with performance and efficiency cores, pin the run to one performance core (on Windows: `start /affinity 4 /wait /b lune run ...`).
- The results we got are on the [benchmarks page](https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html#rivals).
