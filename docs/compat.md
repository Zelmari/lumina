# Compatibility

Known misses, fights, and workarounds. Heuristics will be wrong for some apps; if an app fights the model, float or ignore it.

| App | Bundle id | Issue | Workaround |
|---|---|---|---|
| Siri.app (Dock) | `com.apple.siri` | Normal window; tiles unless it looks like a dialog. Not the Siri HUD. | none (intended) |

System UI (Spotlight, Notification Center, Control Center, permission sheets, loginwindow, PiP / HUDs, Visual Intelligence capture, Siri HUD) is hard-floated in code, not via `[[window-rule]]`. A window layer floats only at or above floating-panel level (layer >= 3). Visual Intelligence overlay bundle ids are recorded here as discovered (none confirmed in this tree yet).

## Apps that need rules

| App | Bundle id | Symptom | Rule |
|---|---|---|---|
| Cursor (Computer Use UI) | `com.todesktop.230313mzl4w4u92` | Computer Use window churn fights the tile tree. The shipped config has no Cursor rule, so its windows tile by default. | Add `[[window-rule]]` with `app-id = "com.todesktop.230313mzl4w4u92"` and `action = "ignore"` while Computer Use drives the app; use `action = "float"` if only the agent panel misbehaves. |
| Zoom | `us.zoom.xos` | Jumps away from the standard 1 px corner park, so a hidden window can come back on screen. | none: the agent parks Zoom with a 0 inset (`stashFrame(inset: 0)`). Add `action = "float"` if meeting windows land on the wrong Space. |
| Electron/Chromium splash-window apps (Discord, Slack, VS Code) | varies | The splash window and the real window have different `CGWindowID`s, so one refresh pass sees one id replace another. | none in most cases: a one-in/one-out pass rebinds the ids for that pid. Add `action = "float"` for an app whose splash never settles into a tile. |

Native tab groups: only the on-screen tab is a tile. Hidden tab windows are ignored until they become visible. That public heuristic will be wrong for some apps — record them here.
