# Compatibility

Known misses, fights, and workarounds. Heuristics will be wrong for some apps; if an app fights the model, float or ignore it.

| App | Bundle id | Issue | Workaround |
|---|---|---|---|
| Siri.app (Dock) | `com.apple.siri` | Normal window; tiles unless it looks like a dialog. Not the Siri HUD. | none (intended) |

System UI (Spotlight, Notification Center, Control Center, permission sheets, loginwindow, PiP / HUDs, Visual Intelligence capture, Siri HUD) is hard-floated in code, not via `[[window-rule]]`. Visual Intelligence overlay bundle ids are recorded here as discovered (none confirmed in this tree yet).

Native tab groups: only the on-screen tab is a tile. Hidden tab windows are ignored until they become visible. That public heuristic will be wrong for some apps — record them here.
