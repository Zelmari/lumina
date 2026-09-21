# Lumina adjustments

Static review of the tree as of 2026-09-21. No code was changed for this note.

Lumina is a guest tiling window manager: spiral splits with permanent axes, emulated workspaces inside one native Mac Space, and a 1px corner stash so it never needs SIP. The pure layout module matches that contract. The agent, which was finished in a hurry, is where windows get lost, hotkeys stay live on the wrong Space, and Accessibility stalls the process.

This was not run on macOS. The findings are from the Swift sources, the spec, and current AeroSpace / SkyLight behavior. AeroSpace still hides by moving a window’s origin to the bottom corner and leaving the size alone. `SLSManagedDisplayGetCurrentSpace` is still the read that works with SIP on.

## What is in good shape

Spiral insert, collapse, `frames()`, spatial focus, launch-tiling z-order, config rejection, and the JSON-lines codec match the spec and have unit tests. Sockets are `0600` with `getpeereid`. The nested agent bundle id, arm64 check, and “sandbox off, no library-validation disable” entitlements match the design. Keyboard chords use virtual key codes, so Option-H stays the H key on non-US layouts.

## Critical: windows and hotkeys do the wrong thing

### 1. SkyLight “who is current” latches onto the wrong Space

`lastSkyLightId` starts nil and is filled on the first space-change with whatever Space is current *then*. The next time the user is on that Space, step 1 of the heuristic says this agent is current.

```1383:1414:Sources/LuminaAgent/AgentRuntime.swift
func recomputeCurrentToken(reason: CurrentReason) {
    // ...
    let cur = skyLight.currentSpaceId(displayUUID: bound.uuid)
    let became = recomputeCurrent(
        reason: reason,
        skyLightCurrent: cur,
        skyLightSelf: lastSkyLightId,
        skyLightOthers: [],
        // ...
    )
    if let cur { lastSkyLightId = lastSkyLightId ?? cur }
```

`skyLightChanged()` then overwrites that same field whenever the id changes, so after one swipe the cached id tracks the live Space and this agent always looks current. `skyLightOthers` is always empty, and the menu extra never tells the loser to unregister. Both agents can own Option-H.

Fix: read SkyLight once at bind into `boundSkyLightId` and never update it. Keep a separate `observedSkyLightId` only for “did a native Space appear?”. When the extra picks a winner, send `mark-current` to that agent and a yield to every other live agent so it sets `isCurrent = false` and unregisters hotkeys. Treat a SkyLight return of `0` as “no id” (null CGS space).

### 2. “Large on-screen window” is any window of a process we have ever touched, not our window

```1386:1390:Sources/LuminaAgent/AgentRuntime.swift
let large = cg.contains { row in
    guard let b = cgWindowRect(row) else { return false }
    return isLargeOnScreen(width: b.w, height: b.h)
        && ownedPid(cgOwnerPID(row))
}
```

After a swipe, Chrome’s window on the other Mac Space is large, and this agent still has Chrome’s AX elements, so it stays current and keeps tiling. The spec test is: one of *this agent’s* managed `CGWindowID`s is at least 8×8 in `optionOnScreenOnly`.

### 3. A new window is dropped whenever that app already has a window on another Lumina space

Stashed windows fail `isTileCandidate` (their frame is a sliver), so they count in `owned` and not in `real`. `real.count <= owned.count` is then true for every create.

```1147:1151:Sources/LuminaAgent/AgentRuntime.swift
let real = adapter.windows(pid: pid).filter(isTileCandidate)
if real.count <= owned.count {
    return elsewhere[0].0
}
```

`onCreate` then restashes that other space and returns without inserting the new window. Delete this count check. Restash only when this AX element or this `CGWindowID` is already in another space.

### 4. AX lookup failure deletes the tile

`applyFrames` treats “no AX element” as a ghost and `removeWindow`s it. Chrome and Electron time out `kAXWindowsAttribute` even with a 0.05s messaging timeout. The window is still on screen; the tree now has a hole.

Fix: prune only when `CGWindowListCopyWindowInfo` no longer contains that id. On a timeout, skip that window this pass and retry once.

### 5. `setFrame` never fails, so the “float after two failures” path is dead

`applyFrame` returns true unless the error is `.apiDisabled` or `.invalidUIElement`. It does not read the frame back. The caller logs `leaving tiled` and keeps a window that ignored the frame.

```186:201:Sources/LuminaAgent/AXAdapter.swift
let s1 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
let pos = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
let s2 = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
// ...
return true
```

Fix: size, then position, then size, then read back. If any edge is off by more than 2pt, retry the sequence once. If it is still wrong, `floatLeaf` and log the bundle id and window id. That is the spec rule, and it is what keeps Electron from sitting on top of the tile forever.

### 6. Every layout pass shoves floaters back, and a drag does not save the new frame

`applyFrames` `setFrame`s every floater to `lastOnscreenFrame`. `handleTitleBarMove` never writes that field. Spec: do not snap floaters. On an untagged move or resize of a floating window, store the AX frame and return. In `applyFrames`, skip a floater whose live frame is already within 2pt of the saved one.

### 7. Hide is undone for every app, tiled or not

`didHideApplicationNotification` calls `unhide(pid:)` with no ownership check. Command-H stops working system-wide while an agent is running, including for apps Lumina does not manage.

Fix: unhide only when `ownedWindows(pid:)` is non-empty. Leave other apps hidden.

### 8. Native fullscreen never comes back

`detachNativeFS` stores a bookmark, and `reinsertNativeFS` exists, but nothing in the agent calls it. `bootLayout` also clears `nativeFSWindows`. Coming out of Control-Command-F leaves the window off the tree. The bookmark is also the wrong shape: `remove` promotes the sibling and deletes the parent, so `parentId` is already gone, and every branch of `reinsertNativeFS` calls `insertSpiral`.

Fix: bookmark the sibling node id, index, axis, and ratio. When the window is back on this display, fullscreen is false, and the sibling still exists, wrap that sibling and the returning window in a new container with the saved axis and ratio. If the sibling is gone, `insertSpiral` at focus. Call that from the “window is on screen again” path, not only from tests.

Also tighten `isNativeFullscreen`: require the window to be missing from this display’s on-screen list. `AXFullScreen == true` by itself currently counts as both “left the display” and “a new Space appeared”, so an in-place zoom detaches the tile. The spec says not to take this path when you are unsure a new Mac Space appeared.

### 9. Closing the lumina-fullscreen window uses the focused id, not the destroyed id

`handleDestroy` detects the fullscreen window, then `closeFocused` removes `focusedWindow`. If a dialog on top is focused, the dialog is removed from the tree and the fullscreen window is left until a later prune. Pass the destroyed `CGWindowID` into the close path.

### 10. Off-screen rescue pulls other displays’ windows onto this one

`rescueOffscreenWindows` and `onCreate`’s `shouldPullOnScreen` move any layer-0 window whose center is not on a connected display. That is the spec’s “never `setFrame` a window onto the bound display” rule, and it fires on quit, boot, and unplug. Only restore ids listed in a session stash, or rects that match our own sliver.

### 11. Fresh start deletes session files without restoring them

`unstashAllSessions` reads the stash and throws it away (`_ = file.stash`), then deletes the files, then spawns a new agent whose new UUID has no session file. Sliver geometry can still be found; the saved frames cannot. If spawn fails, the frames are already gone.

The extra cannot call AX. Move those files aside and pass the directory to the agent. `unstashLeftovers` should restore every file there, then delete them.

## Spec behavior that is implemented, but wrong

### Stash is a 1×8 rect at the top of the display

`stashFrame` uses `axFrame.minY` (menu-bar edge in AX’s top-left, Y-down space) and forces the size to 1×8. Apps that refuse that size get a second “hang above the menu bar” attempt. AeroSpace’s current `hideInCorner` does not resize. It sets the origin to the bottom corner of the visible rect, size unchanged, so only about one pixel stays on screen:

- bottom-right: `visibleRect.bottomRightCorner - (1, 1)`, except Zoom, which jumps away if you use that 1px offset (AeroSpace issue 527; use a zero offset for `us.zoom.xos`)
- bottom-left: same idea, origin at `bottomLeft - (width, 0)` plus the same Zoom exception

Park on the bottom corner of `axVisibleFrame`, Dock-on-the-right choosing the left corner, as the spec says. Keep `lastOnscreenFrame` before the move. Do not shrink.

### Dialogs are detected on `AXRole`, and AppKit puts them on `AXSubrole`

A normal dialog is `AXWindow` / `AXDialog` or `AXSystemDialog`. A sheet is often `AXWindow` / `AXSheet`. `isHardFloat` checks the sheet role, and the dialog check reads `input.role` only. Those windows fall through to “has a zoom button and is at least 400×300”, so they tile. The unit test passes `role: AXDialog`, which is why this stayed green.

Treat subrole `AXDialog`, `AXSystemDialog`, and `AXSheet` as hard-float, same as utility/panel. A `tile` rule still must not override sheet, utility, panel, popover, or tooltip.

### Hidden tabs look on-screen because another window of the same app has a similar frame

`classifyInput` sets `isOnScreen` from `idOnScreen || axFrameLooksOnScreen`. AeroSpace discussion 2160 is the right check: `kCGWindowIsOnscreen` / `optionOnScreenOnly` for that `CGWindowID`. A background Terminal/Finder/Ghostty tab has a live AX window and a real id, and it is absent from the on-screen list. A 1px stash sliver stays on screen, so it will not be mistaken for a hidden tab.

When the private id call works, do not also accept a frame match. On focus or title change for that pid, adopt ids that just became on-screen and drop ids that just left. Give the new tab the old leaf’s parent, index, and ratio (AeroSpace `inheritedBinding` in the Ghostty/Fork tab fix) so the tile does not jump.

### Command-Tab picks an arbitrary window

`switchToWindowOf` walks `session.spaces` in dictionary order and switches if any window of that pid is on another space, even when the app already has a window here. Use the AX focused window of that pid. If that id is on the current space, stay. Otherwise switch to the space that contains it. Remember the last focused id per pid as the fallback.

### Focus-follows-mouse never starts, and does not stop

`startOrStopFFM` runs only from `reloadConfig`. A config that already says `focus-follows-mouse = true` does nothing until the file is saved again. `ffmTick` passes `generationInFlight: false` and does not look at pause, display-gone, or `isCurrent`. Call it at the end of `bootLayout`, cancel it from pause and from “not current”, and skip the tick while `adapter.generationInFlight` is set or the mouse button is down. Read `NSEvent.mouseLocation` on the main thread and pass the point in; Apple does not document that property as safe off the main thread.

### Socket commands ignore pause and “not current”

Hotkeys go through `handleBound`, which returns immediately. `handleAgent`’s `workspace` calls `switchSpace` directly, and `stash` does not check `isCurrent`. A background agent still moves windows. Guard every mutating command the same way, and keep `status`, `mark-current`, and `quit` available.

### New tiled window during lumina fullscreen becomes the focused window, then gets slivered

`insertSpiral` sets `focusedWindow` to the new leaf. Keys then go to a 1px window. Keep focus on the fullscreen leaf. Floating and ignored windows stay visible and unstashed, which the create path already does.

### Option-Space on the fullscreen window clears the flag and leaves siblings stashed

`remove` clears `luminaFullscreen` and does not `markUnstashed`. Call `exitLuminaFS` before `floatLeaf` when the focused leaf is the fullscreen node.

### Keyboard focus does not raise

`setFocused` sets `AXFocused` only. Also perform `AXRaise` for Option-H/J/K/L and for Command-Tab. Leave focus-follows-mouse as focus without raise.

### Title-regex float rules miss when the title arrives late

`onTitleChanged` only toggles a window that is already floating. A nil title skips the rule, the window is tiled, and the later title does not float it. On title change, run `classify` again. If the result is now `floating` and the window is a tiled leaf that was adopted with a nil title, `floatLeaf` it.

### `lumina debug` sends an unknown command

`CLIArgs` turns `debug` into `cmd: "debug"`. The agent replies `unknown cmd`. The design flag is `LUMINA_DEBUG=1` for that process. Make `lumina debug` print that and exit 0, or accept a `debug` IPC that sets the agent’s `debugEnabled` flag.

### `lumina workspace 0` is not space 10

The keybind string is `workspace 10`, so Option-0 works. The CLI passes the integer 0, and `SpaceId` rejects it. Map `0` to `10` in `CLIArgs` before it hits the socket.

### Startup with a broken toml does not surface an error

`loadOrDefault` silently substitutes the bundled file. `configError` is set only on a later reload. If the first parse fails, keep the default and set `configError` so the menu extra shows it immediately.

### Login Items approval is swallowed

`LoginService.toggle()` ignores `SMAppService` errors. `.requiresApproval` should set the extra tooltip to the System Settings → Login Items prompt. The checkmark should stay off unless `status == .enabled`.

### First-run sheet does not wait for Accessibility

It marks `first-run-done` as soon as the alert closes, including on Later. The spec says keep the sheet up until the agent’s `status.axTrusted` is true, polling about twice a second, and bring it back if the grant is removed. The agent prompting itself with `AXTrustedCheckOptionPrompt` is the right process; the extra should only open the Settings URL and poll.

### Menu-bar digits are not buttons

`clicked` is empty once an agent is current, and assigning `item.menu` makes the left click open the menu. Spec: click a digit to switch. Leave the menu for the right click (or a chevron). On left click, map the click x through the title’s character widths to a space index and send `workspace`.

### Status polling blocks the main thread and rebuilds the menu every 0.8s

`Client.request` is a synchronous `read` on the caller. `pollStatus` runs from a main-thread `Timer`, and `rebuildMenu` replaces `NSMenu` even when nothing changed, which dismisses the menu under the cursor. Poll on the menu socket queue, hop the result to main, and skip `rebuildMenu` when the title, tooltip, and pause bit are unchanged. `lumina start` on that same socket queue calls `NSScreen` and `NSWorkspace` off the main thread. Hop `handleExtra` to main before it touches AppKit.

### CLI ignores the socket path in `instances.json` and does not check the pid

It recomputes a path from its own `TMPDIR`. A shell with a different `TMPDIR` than the Finder-launched extra will not connect. Dial `agents[].socket` for a row whose pid is alive (`kill(pid, 0) == 0`). When the extra is down, still prefer that row over “first agent in the file”.

## Performance

### Boot and every destroy walk Accessibility for every running app, on the main thread

`collectManagedWindows` and `recoverManagedWindows` call `AXUIElementCreateApplication` + `kAXWindowsAttribute` per pid, with a 0.05s timeout each. That is the AeroSpace #131 stall: one hung Chrome/Electron holds the process, and the menu extra’s status call blocks behind it. `MutationQueue.scheduleLayoutPass` exists and is never called, so each `kAXWindowCreated` also runs a full `applyFrames` immediately, then again 80ms later.

Fix, in this order:

1. One `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` per pass. AX only those owner pids. Skip `com.zelmari.lumina` and `com.zelmari.lumina.agent` (AX into yourself on the main thread can deadlock).
2. Run that pass on `MutationQueue`, not inside `start()` before `NSApp.run()`.
3. Coalesce creates onto `scheduleLayoutPass` (one pending closure). Keep the 40ms debounce, and do not also `applyFrames` inside every `onCreate`.
4. If a pass has been inside AX for more than 200ms, stop and finish on the next pass. The helper is there; `applyFrames` only checks it between windows, after a single call may already have blocked.
5. Cache `AXMinSize`. `minSizes()` hits every element on every Option-minus.
6. Skip `setFrame` when the live AX frame is already within 1pt of the target.
7. Stop logging window titles at info. `collectManagedWindows` and `onCreate` interpolate `input.title`. The spec forbids that. Log bundle id and `CGWindowID` only. `LuminaLog` also never calls `os.Logger` (`subsystem: com.zelmari.lumina`). Add that, and open the log file with `O_APPEND` once instead of open/seek/close per line.

### Nested min-size clamp ignores grandchildren

For a non-leaf child, `clampSibling` uses a 1pt floor. With three windows, the inner split can be 1pt wide while the outer container still “fits”. Recurse: a container’s minimum on an axis is the sum of its children’s minimums plus `gaps.inner` between them. If both direct children still cannot fit, float the newly inserted leaf, then the focused one.

### Frames are fractional

`frames()` emits raw `Double`s. Round each span to the nearest point and give the remainder to the last sibling so the children still sum to the usable rect. That removes the blurry 0.5pt gaps on non-Retina and the seams on Retina.

### Observers are installed for every pid, from the mutation queue, and never removed from the run loop

`AXObserver` callbacks and `CFRunLoopAddSource(..., CFRunLoopGetMain())` need to happen on the main thread. `unwatch` drops the dictionary entry and leaves the run-loop source. On app quit, remove the notifications and the source, then release the observer. Only watch pids that own a window.

### Hotkeys are registered off the main thread

Carbon’s event manager is main-thread only. `reloadConfig` and `recomputeCurrentToken` call `Hotkeys.register` on `MutationQueue`. Hop register/unregister to main. The command handler can stay on the mutation queue.

### Own-move suppression ignores every geometry event for 200ms, not just our generation

`shouldIgnoreAXGeometry` is true whenever `inFlight[id] != nil`. A user resize that lands in that window is eaten, so snap-back never sees it. Compare generations, which the pure helper already does, and clear the tag when the matching `AXMoved`/`AXResized` arrives instead of on a fixed timer.

### Minimize is undone on the main thread, twice, without checking

The retry should hop back to `MutationQueue`, call `deminiaturize` only if `kAXMinimizedAttribute` is still true, and do that once.

## More edge cases

| Case | What happens | Change |
|---|---|---|
| App quits while a window is stashed on another Lumina space | `dropPid` only removes the focused space | Remove that pid from every space, then `applyFrames` |
| Swiped away, a new app launches | `appLaunched` calls `adoptWindows` with no `isCurrent` check | Return immediately unless current |
| Wake with two instances | `didWake` restashes even when not current, so the background agent slivers the visible space | Restash only the current agent |
| Tiled window dragged and not swapped | `AXMoved` does not restore the tile; it sits displaced until some later layout | On mouse-up, if `shouldTitleBarSwap` is false, `setFrame` the computed tile |
| Title-bar swap | The first `AXMoved` only stores `moveStart` and returns, and that point is already the moved origin | Store the origin when the move starts; evaluate swap once, when `pressedMouseButtons` goes to 0 and displacement is ≥ 20pt and the pasteboard `changeCount` is unchanged |
| Electron mints a new `CGWindowID` | `staleOwnedWindow` requires `CFEqual` on the old AX element, which is already dead | If a pid has exactly one stale id and exactly one new unmatched window, `rebindWindowId` into the old leaf |
| `insertSpiral` cannot find a leaf | It sets `space.nodes = [:]` and the previous tree is gone | Leave the tree and append the new window as root only when `root == nil` |
| Invalid config at boot | Bundled default replaces it with no menu error | Set `configError` on the first failed parse |
| `layer > 0` | Any non-normal window level hard-floats, including a main window an app has raised | Treat known HUD subroles and the hard bundle-id list as the float signal; keep `layer > 0` only for layers at or above floating-panel level, and record misses in `docs/compat.md` |
| Visual Intelligence / Siri HUD | `classifyInput` passes `isVisualIntelligenceOrSiriHUD: false` always | The pure check never runs. Set the flag from bundle id once one is confirmed, and record it in `docs/compat.md` |
| Menu socket `bind` | The return value is discarded, unlike the agent socket | Fail `start()` if `bind` is not 0 |
| `lumina … version` | `argv.contains("version")` exits 0 before parsing, so `lumina focus version` prints the version | Only treat `version`, `-h`, and `--help` as the first argument |
| Signal handler | `signal(SIGTERM)` calls `DispatchQueue.main.async`, which is not async-signal-safe | `DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)` and then `stop()` + terminate |
| Private symbols | `_AXUIElementGetWindow` and `responsibility_spawnattrs_setdisclaim` are `@_silgen_name` hard references. A missing symbol aborts at load. The design says dlsym and fail soft | `dlsym` both. Missing window-id function → frame matcher. Missing disclaim → still spawn, and log that AX identity may follow the extra |
| Developer ID docs | `docs/install.md` signs `Contents/Helpers/lumina-agent.app`. `bundle.sh` builds `Lumina Agent.app` | Point the documented `codesign` at `Lumina Agent.app`, and include the same designated requirement the script pins. After the outer sign, check `codesign -d -r-` on the helper: `--force` on the outer bundle can replace the helper’s requirement and bring back the “new binary every rebuild” Accessibility prompt |

## What to change first

1. Stop deleting tiles on AX failure, and stop adopting every pid. That is the stall and the disappearing windows.
2. Fix current-Space detection (bind-time SkyLight id, match our window ids, yield the other agent) and the `otherSpace` count check. That is hotkeys on the wrong Space and new windows vanishing.
3. Read back `setFrame`, stop snapping floaters, and only unhide apps we manage.
4. Hide like AeroSpace (move origin to the bottom corner, do not resize), and wire native-fullscreen reinsert.
5. Coalesce layout, move Carbon and AppKit back to the main thread, and make the status item poll off main.

The layout tests do not cover the agent bugs. A `MacApp`-style seam (protocol with a fake AX client) around `onCreate`, `applyFrames`, `recomputeCurrentToken`, and `otherSpace` would have caught items 2–7 without a live Accessibility suite.
