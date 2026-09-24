# Third-party notices

Branch includes the following third-party code, unchanged except where noted.

| Component | Path | Author | License |
|---|---|---|---|
| ProfileStore | `src/Data/DataService/ProfileStore.luau` | MAD STUDIO (loleris) | Apache License 2.0, <https://github.com/MadStudioRoblox/ProfileStore/blob/main/LICENSE> |
| DataService | `src/Data/DataService/` | leifstout | MIT, <https://github.com/leifstout/dataService> |
| GoodSignal | `src/Data/DataService/Signal/` | stravant (modified by sleitnick) | MIT (notice in the file header) |
| Scythe | `src/Util/Scythe.luau` | checcerr, fridayqx | MPL-2.0 (notice in the file header), <https://mozilla.org/MPL/2.0/> |
| ThreadReaper | `src/Util/ThreadReaper.luau` | divine.no | from Branch 1 (notice in the file header) |

Modifications made by Branch:

- **DataService** (all changes are marked `Branch patch` in the code):
  - the session lock is released when a player leaves mid-load;
  - a leaving player's data is released after every leave handler has run;
  - no updates are sent to players who have left;
  - observers of deeper paths fire when a parent table is replaced.
- **ProfileStore:** unchanged.
