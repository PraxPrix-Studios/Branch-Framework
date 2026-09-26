<p align="center">
  <img src="assets/Logo.png" alt="Branch" width="320">
</p>

# Branch

A Roblox game framework that stays out of your way. The full documentation, with guides and the API reference, is at **[praxprix-studios.github.io/Branch-Framework](https://praxprix-studios.github.io/Branch-Framework/website/)**.

- **Segments.** A loader with a strict lifecycle (`Init` in dependency order, then `Start`), player and frame hooks, and typed lookups.
- **Branch.Data.** Player data on DataService + ProfileStore: typed paths, template checks, migrations, leaderstats, and safe saves.
- **Branch.Network.** Compiled buffer networking. You declare events on your services and get generated serialisation code that is faster and smaller on the wire than Blink and NetRay in our benchmarks ([report](https://praxprix-studios.github.io/Branch-Framework/website/benchmarks.html), [full text](/docs/markdowns/benchmarks.md)). The compiler ships in the free **Branch Studio** plugin.

The runtime in this repository is free and open source (MIT). Branch Studio, the Studio plugin, is free to use but not open source.

---

## Install

**pesde**

```sh
pesde add realllityyy/branch
```

**Rojo / manual:** build `src/` as a model (`rojo build -o Branch.rbxm`), or copy `src/` into `ReplicatedStorage.Packages.Branch`.

**Branch Studio:** the plugin installs and updates the runtime for you (Overview > Install). It also compiles types and networking as you type.

Start Branch once on each side:

```lua
-- ServerScriptService/Main (Script)
local Branch = require(game.ReplicatedStorage.Packages.Branch)
Branch:Start(script.Parent.Services)

-- StarterPlayerScripts/Main (LocalScript)
local Branch = require(game.ReplicatedStorage.Packages.Branch)
Branch:Start(script.Parent:WaitForChild("Controllers"))
```

---

## Segments

A segment is a ModuleScript that returns a table.

**Which modules are segments** (the segment rule):

| Rule | Segments | Everything else |
|---|---|---|
| `"Suffix"` (default) | Every module under the roots whose name ends with **Service** (server) or **Controller** (client), at any depth and in any casing: `ShopService`, `shopService`, `shop_service`, `SHOP_SERVICE`. Services can nest inside services. | Helpers, never loaded on their own. |
| `"Folders"` | Modules directly under a root or under Folders inside it. | A module parented to another module is its private helper. |

```lua
Branch:Start(script.Parent.Services)                               -- rule from Branch Studio, else "Suffix"
Branch:Start(script.Parent.Services, { SegmentRule = "Folders" })  -- explicit
```

```lua
local ShopService = { Dependencies = { "PlayerService" } } -- Init runs after PlayerService:Init

function ShopService:Init() end                 -- sequential, dependency-ordered, may yield
function ShopService:Start() end                -- each in its own thread, after every Init
function ShopService:PlayerAdded(player) end    -- players already in game + every future join
function ShopService:PlayerRemoving(player) end -- can still read/write the player's data
function ShopService:Heartbeat(dt) end          -- also PreSimulation, PreRender (client)

return ShopService
```

- Frame hooks share one engine connection per hook type. A hook that errors is reported (at most once every 5 s) and does not stop the others.
- If a segment's `Init` fails, it is marked `Failed` and not started. Segments that depend on it get a warning.
- A `require` or `Init` that is still running after 5 s gets a warning, since everything after it is waiting.
- `Branch:GetSegment(name)` (typed per segment with Branch Studio), `Branch:AwaitStart()`, `Branch:GetReport()`.
- Two segments with the same name are an error. So is a typo such as `Branch.Netwrok`.

---

## Branch.Data

```lua
-- server
local Data = Branch.Data.Server
Data.Start({
	Template = require(script.DataTemplate),
	Store = "Default",                                  -- ProfileStore name
	Mock = game:GetService("RunService"):IsStudio(),
	Leaderstats = { coins = "Coins" },                  -- mirrored live
	Migrations = { function(data) data.gold = data.coins end },
})

Data.Get(player, "stats.kills")          -- nil until loaded, never errors
Data.Set(player, "coins", 5)             -- checked against the template
Data.Increment(player, "coins")          -- returns the new value
Data.Update(player, "stats.best", function(old) return math.max(old, 10) end)
Data.Insert(player, "items", { id = 1 }) ; Data.Remove(player, "items", 1)
Data.Observe(player, "coins", function(new, old) end)
Data.Await(player) ; Data.OnLoaded(function(player, data) end)
Data.Peek(userId)                        -- offline read
Data.Send(userId, "Gift", payload) ; Data.OnMessage("Gift", handler)

-- client (syncs as soon as it is required)
local Data = Branch.Data.Client
Data.Observe("coins", function(value) label.Text = value end)
```

Guarantees:

- **Template checks.** Writes are checked against the template all the way down. A missing field or a wrong type is refused. If an array in the template holds an element, `Insert` checks new elements against it (that element is also part of every new player's starting data, so keep arrays empty unless it is a real starting item).
- **No NaN or infinity.** They are refused on every write: DataStores cannot store them, and one would stop the profile from saving.
- **Observers see table swaps.** `Observe` also fires when a parent table is replaced.
- **String keys that look like numbers.** `"friends.12345"` reaches the string key `"12345"` in a UserId-keyed dictionary; arrays still index by number.
- **Safe migrations.** They run on a copy. If one fails, the saved data is left untouched and the player is asked to rejoin.
- **Leave-time writes are saved.** `PlayerRemoving` hooks can still write the leaving player's data, and those writes are saved with the session.

---

## Branch.Network

Declare events on a server segment; Branch Studio compiles every declaration into `Branch.Network`.

```lua
local CombatService = {}

CombatService.Network = {
	Hit    = { From = "Client", Type = "Unreliable", Data = { Target = "Instance(Model)", Power = "f32(0..1, 0.01)" } },
	Damage = { From = "Server", Data = { "u16", "boolean" } },   -- tuple: two arguments
	Move   = { From = "Server", Unpack = true, Data = { pos = "vector", yaw = "f32" } },
	Buy    = { Data = "string(..32)", Return = "boolean" },      -- request / response
}

return CombatService
```

```lua
-- server
local Net = Branch.Network.Server.CombatService
Net.Damage.Fire(player, 25, true)       -- also FireAll / FireList / FireExcept / FireNear(position, radius, ...)
Net.Mob.FireFrom(position, mob)         -- events with Lod: each player at the rate of their distance
Net.Buy.On(function(player, item) return true end)

-- client
local Net = Branch.Network.Client.CombatService
Net.Hit.Fire({ Target = model, Power = 0.8 })
local ok = Net.Buy.Invoke("sword")
```

**Types:**

- **Numbers:** `u8 u16 u32 i8 i16 i32 f16 f32 f64 number`, with ranges (`u8(0..100)`) and steps (`f32(0..1, 0.01)` sends 1 byte instead of 4).
- **Other values:** `boolean`, `string(..32)`, `buffer`, `vector`, `CFrame`, `Color3`, `Instance(Model)`, `Enum(KeyCode)`, `enum(A, B)`, `unknown`.
- **Containers:** arrays `T[]`, maps `{ [K]: V }`, structs, optionals `T?`.

**How it stays fast and safe:**

- **Batching.** Events are batched per player per frame, and FireAll ships once with `FireAllClients`.
- **Compact encoding.** Repeated events are sent as runs, booleans are bit-packed, and lengths are varints.
- **Validation.** The server checks everything a client sends before any listener sees it. Malformed packets are reported through `Branch.Network.OnReject`.
- **Order.** Order is exact for every recipient.
- **Errors stay contained.** A listener that errors is reported like any script error; the rest of the packet still arrives.

**Send less, and limit what clients send** (options on any event):

| Option | What it does |
|---|---|
| `Latest = true` | Several sends to the same recipient in one frame send only the newest (per `Key`, with `Delta`). Latest values go out at the end of the frame. Not for functions. |
| `Hz = 20` | The newest value goes out at most this many times a second (up to 60); the last one is never lost. Includes `Latest`. |
| `Lod = { { 50, 30 }, { 200, 5 } }` | Distance rings, near to far: `FireFrom(position, ...)` sends each player at the rate of the ring their character is in, and nothing beyond the last ring. Server to client only. |
| `Delta = true` | A struct travels in full once, then only the fields that changed since the last send to that recipient; a changed boolean costs no bytes. Reliable events only. Listeners always get the full struct. |
| `Key = "id"` | With `Delta`: the field that tells objects apart, so one event carries many objects, each with its own state. `Event.Forget(key)` drops a key's state on both sides. An Instance key works with StreamingEnabled: a client that does not have the Instance yet keeps the object's state, and hears about it once the Instance has streamed in. |
| `Threshold = { pos = 0.05 }` | With `Delta`: a number or vector that moved less than this counts as unchanged. One number applies to every number and vector field. Small moves add up, so the receiver is never further off than the threshold. |
| `Predict = { pos = 0.25 }` | With `Delta`, server to client: a number or vector travels with its speed, the client keeps guessing between updates (`Event.At(key)` on the client), and an update goes out only when the guess is off by more than this. A straight walk costs one update; if you stop firing an object to a player, its guess stops where it was fired last. `Event.Exact(key, true)` on the server turns the guessing off for one object (a fight), `Exact(key, false)` turns it back on. |
| `Pack = true` | Booleans, enums, stepped numbers, whole numbers with a range and bounded lengths are written as bits instead of whole bytes (a `u8(0..100)` is 7 bits). Not with `Delta`, not on functions. |
| `Rate = "10/s"` | On `From = "Client"` events and functions: sends over the limit are dropped (functions answer "failed"), and `OnReject` hears about it with a reason starting `rate limit:`. |

```lua
Mob    = { From = "Server", Delta = true, Key = "id", Predict = { pos = 0.25 }, Lod = { { 50, 30 }, { 200, 5 } }, Data = { id = "u16", pos = "vector", hp = "u8" } },
Bag    = { From = "Server", Pack = true, Data = "{ id: u16(0..1000), count: u8(0..99) }[]" },
Attack = { From = "Client", Rate = "10/s", Data = { dir = "vector" } },
```

**Where the code lives.** `Branch.Network` in ReplicatedStorage holds the entry module, the client half and the remotes; the server half is generated into `ServerScriptService.BranchNetworkServer`, so players never download it (or read the server's checks).

**See the traffic.** While you Play in Studio, Branch Studio opens a live network profiler: sends and bytes per second for every event, its share of the traffic, and hints for numbers that could use a smaller type. The counters only run in Studio.

**Apply the hints in one click.** Press **Profile** on Branch Studio's Network page, play, then press **Finish** in the profiler window. The hints appear under Problems on the Overview page; clicking one changes that type in your declaration (one undo step). Profile is needed because Play runs in a copy of the place, and only a session started this way can hand data back to the place you edit.

---

## Moving from Branch 1

| Branch 1 | Branch 2 |
|---|---|
| `Branch:StartSegments(f)` / `StartSegmentsDeep(f)` | `Branch:Start(f, ...)` |
| every nested ModuleScript was a segment | modules named `…Service` / `…Controller` are segments (or, with `"Folders"`, only modules reached through Folders) |
| `Packages.Branch.Scythe` / `ThreadReaper` / `Timer` | `Packages.Branch.Util.*` |
| a separate `Packages.DataService` | `Packages.Branch.Data` (`Branch.Data.Server` / `.Client`) |
| `-- BRANCH_EXPORTS` block | `-- BRANCH_GENERATED` block (managed by Branch Studio) |

Branch Studio does not touch a Branch 1 runtime until you press **Update**. Existing ProfileStore saves load unchanged as long as `Data.Start` uses the same `Store` name. Branch 1's DataService used `"Public"` unless you passed another `profileStoreIndex`, and `Branch.Data` defaults to `"PlayerData"`, so pass `Store = "Public"` (or your old name). The key prefix, `"PLAYER_"`, is the same.

---

## Developing

```sh
rokit install                          # lune, pesde, rojo
lune run tests/runtime.test.luau       # runtime tests
rojo build -o Branch.rbxm              # model of src/
pesde publish                          # maintainers
```

## Credits

- [ProfileStore](https://github.com/MadStudioRoblox/ProfileStore) (loleris, Apache-2.0)
- [DataService](https://github.com/leifstout/dataService) (leifstout, MIT)
- GoodSignal (stravant, MIT)

See [ThirdPartyDocs.md](/docs/markdowns/ThirdPartyDocs.md).
