# Changelog

## 2.0.0

A rewrite of Branch 1.

**Loader**

- `Branch:Start(roots..., options?)` replaces `StartSegments` / `StartSegmentsDeep`.
- Segment rule: `"Suffix"` (default: modules named `...Service` / `...Controller` at any depth) or `"Folders"`.
- Other loader changes:
  - `Dependencies` order `Init`;
  - frame hooks share one connection per hook type;
  - typed `GetSegment`, `GetReport`, `AwaitStart`;
  - duplicate names are errors;
  - warnings for dependencies that failed and for a `require` or `Init` that hangs.
- Utilities moved to `Branch.Util`: Scythe, ThreadReaper, Timer.

**Branch.Data** (on DataService + ProfileStore)

- Typed paths and template checks all the way down.
- NaN and infinity are refused; string keys that look like numbers (UserIds) work.
- Migrations run on a copy; leaderstats are bound to data paths.
- `Observe` fires when a parent table is replaced.
- Leave-time writes are saved.
- `Peek`, `Send`, `OnMessage`.

**Branch.Network**

- Compiled by Branch Studio from `Service.Network` declarations.
- Batching per player per frame, and one `FireAllClients` for FireAll.
- Run packing, bit-packed booleans, varint lengths, stepped numbers.
- Server validation; `OnReject`.
- Errors in listeners stay contained.

**Timer** (from Branch 1): fixed

- pause/resume;
- `IncrementTime` ordering;
- `Stop` with waiting threads;
- repeated callbacks;
- errors in callbacks.
