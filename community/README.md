# Branch community data

`community.json` is read by the Branch Studio plugin (Community page, roles, profiles).
Owners edit it from the plugin's Admin panel (one commit per change); editing it here works too.

- `roles`: Roblox UserId → `"tester"` or `"vip"`. Owners are built into the plugin.
- `profiles`: Roblox UserId → `theme` (a `BT1-…` theme code), `background` (`rbxassetid://…`, roles only), `games` (`universe` and `place` ids).

No free text: names come from Roblox when shown.
