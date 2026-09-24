<p align="center">
  <img src="assets/Logo.png" alt="Branch" width="320">
</p>

<p align="center">
  <a href="https://praxprix-studios.github.io/Branch-Framework/website/getting-started.html"><img src="https://img.shields.io/badge/Documentation-7A5AF0?style=for-the-badge" alt="Documentation"></a>
  <a href="https://praxprix-studios.github.io/Branch-Framework/website/api/branch.html"><img src="https://img.shields.io/badge/API_reference-3B8FD9?style=for-the-badge" alt="API reference"></a>
  <a href="https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html"><img src="https://img.shields.io/badge/Benchmarks-17B8D6?style=for-the-badge" alt="Benchmarks"></a>
</p>


# Branch
## What is Branch?
it's a silly game framework to give you fame in the big Roblox.

For real though: Branch splits your game into **services** and **controllers** with a strict start order, keeps **player data** safe on ProfileStore, and ships **compiled networking** that beats Blink and NetRay in our benchmarks.

**Everything is on the site: [praxprix-studios.github.io/Branch-Framework](https://praxprix-studios.github.io/Branch-Framework/website/)**

| | |
|---|---|
| [Getting started](https://praxprix-studios.github.io/Branch-Framework/website/getting-started.html) | Install Branch and write your first service and controller. |
| [Guides](https://praxprix-studios.github.io/Branch-Framework/website/guide/segments.html) | Segments, player data, networking, the Branch Studio plugin, moving from Branch 1. |
| [API reference](https://praxprix-studios.github.io/Branch-Framework/website/api/branch.html) | Every function with its signature: `Branch`, `Branch.Data`, `Branch.Network`, the network types and the utilities. |
| [Benchmarks](https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html) | Branch vs NetRay and Blink, measured in Lune and in the real engine. |

## Install

- **Branch Studio** (easiest): the free plugin installs and updates the runtime for you (Overview → Install).
- **pesde:** `pesde add realllityyy/branch`
- **Rojo:** build `src/` (`rojo build -o Branch.rbxm`) into `ReplicatedStorage.Packages`.

```lua
-- ServerScriptService/Main
local Branch = require(game.ReplicatedStorage.Packages.Branch)
Branch:Start(script.Parent.Services)

-- StarterPlayerScripts/Main
local Branch = require(game.ReplicatedStorage.Packages.Branch)
Branch:Start(script.Parent:WaitForChild("Controllers"))
```

## Branch benchmarks
Branch vs NetRay and Blink, measured in Lune and in the real engine (Roblox Studio).

[![Look it here](https://img.shields.io/badge/Look_it_here-%E2%86%92-7A5AF0?style=for-the-badge)](https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html)

<sub>Text version: [benchmarks.md](/docs/markdowns/benchmarks.md)</sub>

## Should we use branch?
upto u vro. it has its own network compiler now (faster than Blink and NetRay, see the benchmarks),
and it's at its best in studio with the Branch Studio plugin.

---

## Support Branch

Branch is free and MIT. If it saved you time and you want to say thanks, you can send some Robux to the people who make it:

| | |
|---|---|
| **Kuyu** | [Profile](https://www.roblox.com/users/2325544836/profile) · [Support with Robux](https://www.roblox.com/game-pass/PASS_ID_KUYU) |
| **realllityyy** | [Profile](https://www.roblox.com/users/4235992680/profile) · [Buy Roblox Plus TR](https://www.roblox.com/plus-referral?v=v2&code=e509ca08-c6e0-4e87-b497-dfea61e0ac0a) |