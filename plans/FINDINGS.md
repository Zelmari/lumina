# Lumina — Findings

Static audit of the whole repository, 2026-10-04. Five independent passes
read every file under `Sources/`, `Tests/`, `scripts/`, `docs/`, `.github/`,
and `plans/`; the highest-impact findings were then re-read directly by a
second pass.

Confidence tags:

- **[verified]** — re-read directly during the audit.
- **[reported]** — located by cross-file review, not re-read line by line.

Severity: **High** = broken shipped behavior or unrecoverable state.
**Medium** = wrong behavior, races, or misleading guarantees.
**Low** = latent, dead, or hygiene.

## Context

Lumina is a macOS guest tiling WM with four parts: a menu-bar supervisor
(`LuminaExtra`), a nested Accessibility agent (`lumina-agent`), a socket CLI
(`lumina`), and two shared libraries (`LuminaLayout`, `LuminaIPC`). One agent
owns one display; the extra spawns/reattaches agents and talks JSON-lines over
UNIX sockets. Quitting restores managed windows to their pre-tiling frames.
155 tests cover the two pure libraries only; the macOS-only targets are not
compiled by CI.

## Fix first

| # | Issue | Location | Severity |
|---|---|---|---|
| 1 | Fresh-install crash: `Bundle.module` traps because the assembled `.app` never receives `Lumina_Lumina.bundle` | `Sources/Lumina/ExtraApp.swift:88`, `Package.swift:49`, `scripts/bundle.sh:41` | High |
| 2 | SIGPIPE is not ignored in the extra/CLI; one write to a closed socket kills the supervisor | `Sources/Lumina/ExtraApp.swift:10-28`, `Sources/Lumina/MenuSocket.swift:82`, `Sources/LuminaCLI/LuminaCLI.swift:160` | High |
| 3 | `stop()` is not serialized; `.quit` (mutation queue) and the extra's SIGTERM fallback (main thread) can restore windows concurrently | `Sources/LuminaAgent/AgentRuntime.swift:153-163`, `AgentApp.swift:45-52`, `Sources/Lumina/ExtraApp.swift:345-356` | High |
| 4 | Blocking, timeout-free IPC on the extra's main thread can beachball the menu bar | `Sources/Lumina/MenuSocket.swift:89-116`, `ExtraApp.swift:192,267-275,337-374` | High |
| 5 | No macOS CI and no `LuminaAgentTests`; ~3,000 lines of shipped state machine are never compiled or tested | `Package.swift:28-55`, `.github/workflows/test.yml` | High |
| 6 | `JSONValue.int` traps (`Int(1e30)`) on malformed IPC, crashing the agent | `Sources/LuminaIPC/Protocol.swift:141-147`, `Codec.swift:86` | Medium |

---

## 1. Build, packaging, CI

### 1.1 Fresh install crashes before writing config — High **[verified]**

`ExtraController.start()` first calls `writeDefaultConfigIfNeeded()`
(`Sources/Lumina/ExtraApp.swift:57`). That function evaluates `Bundle.module`
(`:88`) before the fallback at `:92-94`. `bundle.sh` copies
`Sources/Lumina/Resources/lumina.toml` into `Contents/Resources` but never
copies the SwiftPM-generated `Lumina_Lumina.bundle`
(`scripts/bundle.sh:41`). SwiftPM's resource accessor `fatalError`s when the
bundle is missing, so a shipped app with no
`~/.config/lumina/lumina.toml` dies on first launch and the
`Config.bundledDefaultTOML` fallback is unreachable. Fix: copy the resource
bundle in `bundle.sh`, or delete the resource and use the embedded string.

### 1.2 CI never compiles the shipped product — High **[verified for gating, reported for CI]**

All app targets are behind `#if os(macOS)` (`Package.swift:28-55`) and the
only workflow runs `ubuntu-24.04` with `--filter LuminaLayoutTests` /
`LuminaIPCTests` (`.github/workflows/test.yml`). A compile error in
`AgentRuntime`, `ExtraApp`, `StatusItemController`, or the CLI passes CI.
There is no macOS build job and `bundle.sh` is never exercised.

### 1.3 No agent tests — High **[reported]**

`Package.swift` declares only the two library test targets (`:18-25`).
`plans/Advancement.md:153-159` (BP-A1) promised a macOS-only
`LuminaAgentTests` target; it does not exist.

### 1.4 Docs reference a DMG nothing creates — Low **[verified]**

`docs/install.md:50-51` runs `notarytool submit dist/Lumina.dmg` and
`stapler staple dist/Lumina.dmg`; `bundle.sh` only produces `dist/Lumina.app`
(no `hdiutil` step anywhere).

### 1.5 Minor CI/script waste — Low **[reported]**

`bundle.sh` runs `swift build` four times (`:15-19`); CI adds the same bin
path to `GITHUB_PATH` twice, has no toolchain cache and no `concurrency`
group; `actions/checkout@v4` is tag-pinned.

---

## 2. Menu extra and IPC robustness

### 2.1 SIGPIPE can kill the menu extra — High **[verified]**

`ExtraApp.main` installs no `signal(SIGPIPE, SIG_IGN)` (`:10-28`); the agent
does (`AgentApp.swift:12`). `MenuSocketServer.serve` writes the response
with a raw `write(2)` (`MenuSocket.swift:82`) after the client may have gone
away (the CLI has no timeout, so Ctrl-C is common). Default SIGPIPE
disposition terminates `LuminaExtra`, taking down supervision of every agent.
`Client.request` (`:110`) has the same exposure in the other direction.

### 2.2 One stalled client wedges all IPC — Medium **[verified]**

Both servers accept/serve on a single serial queue and block in `read()`
with no timeout (`MenuSocket.swift:60-86`, `AgentSocketServer` in
`Sources/LuminaAgent/SocketServer.swift:63-80`). A same-user client that
connects and sends nothing (or no newline) blocks every later connection;
`listen(8)` backlog does not help because `acceptOne` is queued behind the
stuck `serve`.

### 2.3 Command execution can block forever — Medium **[reported]**

`SocketServer.swift:100-107` waits on a semaphore for the mutation queue
with no timeout, so a long `runRefresh`/`collectManagedWindows` blocks the
CLI/menu request indefinitely. Combined with 2.4 (extra's main thread), this
is user-visible.

### 2.4 Large responses are truncated; partial writes ignored — Medium **[reported]**

The CLI does one `read` of 64 KiB (`LuminaCLI.swift:159-164`), and the menu
client one `read` (`MenuSocket.swift:110-113`); `write` return values are
ignored on both servers (`MenuSocket.swift:82`,
`SocketServer.swift:114-118`). `debug-windows`/`list-windows` grow with the
window count; a truncated line fails decode and the CLI prints the
misleading "agent not running on this Space".

### 2.5 Registry has cross-queue races and non-atomic saves — Medium **[reported]**

`RegistryStore.save` (`Sources/Lumina/InstanceRegistry.swift:18-27`) has no
lock, writes the shared `instances.json.tmp` with non-atomic `Data.write`,
and ignores the `rename` result. Writers run on the main queue, the status
queue, and a global queue (`ExtraApp.swift:105-108,289-329,364-373`).
Concurrent saves can interleave; a stale snapshot can resurrect a dead row.
`load` silently falls back to an empty registry on decode failure, which
looks like "no agents" and can orphan live ones.

### 2.6 Crash restart is an unbounded loop — Medium **[reported]**

`pidDeathAction` returns `restartCrashRecover` for every non-quit exit
(`Sources/LuminaLayout/Registry.swift:71-73`) and `agentDied` respawns
immediately (`ExtraApp.swift:219-238`). A deterministic crash becomes an
unbounded spawn/log loop with no backoff or attempt limit (and see 2.7).

### 2.7 Child agents are never reaped — Medium **[reported]**

Nothing calls `waitpid` (`AgentSpawner.swift:117` is the only spawn site),
and liveness is `kill(pid, 0) == 0` (`ExtraApp.swift:101,120,280,291,366-368`),
which is true for zombies. Each crash leaves a zombie considered alive.

### 2.8 Malformed IPC can trap the agent — Medium **[verified]**

`JSONValue.int` does `Int(d)` for any integral double
(`Sources/LuminaIPC/Protocol.swift:141-147`); `1e30` (or infinity) traps.
Any same-user client can crash the agent with
`{"v":1,"id":"1","cmd":"workspace","args":{"id":1e30}}`; the extra then
restarts it (2.6), so it can be spammed.

### 2.9 First-run alert nags forever and blocks main — Medium **[reported]**

`FirstRunController` re-presents the modal every 0.5 s while the flag is
absent and AX is untrusted (`FirstRun.swift:17-23,55-75`); "Later" does not
stop it. Each tick also performs blocking agent IPC on the main run loop
(see 2.4).

### 2.10 Lower-severity extra issues — Low **[reported]**

- Menu socket bind failure is swallowed (`ExtraApp.swift:70`); every CLI
  command then reports "menu extra not running".
- `/tmp` fallback socket paths are pre-creatable by other users
  (`Paths.swift:23-27,53-60`); `unlink`/bind failures are swallowed.
- `quitPids` is never pruned (`AgentSpawner.swift:12`), so a recycled pid can
  be misread as a user quit.
- `currentDisplayUUID()` force-unwraps `CGDisplayCreateUUIDFromDisplayID`
  (`ExtraApp.swift:187`).
- Socket paths are silently truncated at 103 bytes without validation
  (`MenuSocket.swift:28-33,96-101`, `LuminaCLI.swift:147-152`).
- Exit watcher is installed after spawn (`AgentSpawner.swift:64-71`), so an
  immediate crash can be missed.
- `unstashAllSessions` clears `pendingUnstash` before spawn and deletes
  `instances.json` even when nothing moved (`ExtraApp.swift:411-432`).
- `LoginService` cannot turn off a `.requiresApproval` item
  (`LoginService.swift:7-22`).
- `openConfig` blocks main with `waitUntilExit()` (`ExtraApp.swift:376-390`).

---

## 3. Agent runtime

### 3.1 `stop()` is not serialized and pending work outlives it — High **[verified for stop, reported for race]**

`.quit` runs `stop()` on the mutation queue (`AgentRuntime.swift:1234-1237`),
while the extra SIGTERMs a still-alive process 0.5 s later
(`ExtraApp.swift:348-350`); the SIGTERM handler on the main thread calls
`stop()` again (`AgentApp.swift:45-52`). `stop()` does many synchronous AX
round-trips (`recenterAllWindows`, `:154`, `:1661-1669`), so overlapping
executions are realistic: concurrent reads/writes of `session`, `elements`,
`bound`, overlapping restores, and racing `tmp`+`rename` in `writeSession`.
`stop()` also never cancels queued mutation work (refresh, resize debounce,
continuation pass), so a pending `applyFrames`/stash can run after the quit
restore.

### 3.2 Lumina-fullscreen window is written twice per layout pass — Medium **[verified]**

In `applyFrames`, the loop only skips nodes when `fs != nodeId`
(`AgentRuntime.swift:1279`), so the FS leaf is first written to its *tile*
rect and then to the usable rect by the dedicated block (`:1325-1334`).
Every pass snaps it to the tile and back. The FS block also uses a local
`var window` and never writes the incremented `generation` back to `session`,
so the self-write-echo suppression for that window depends on the earlier
loop write.

### 3.3 Title-change float toggle can hit the wrong window — Medium **[reported]**

`onTitleChanged` handles a floater that now classifies as tiled with
`session.floatToggle(space: session.focusedSpace, ...)`
(`AgentRuntime.swift:1121-1123`); `floatToggle` acts on
`space.focusedWindow`, not the id that changed
(`Sources/LuminaLayout/SpaceSwitch.swift:54-72`). The focused tiled window
gets floated instead. The reverse branch correctly uses `leaf.id`.

### 3.4 Main-thread-only AppKit APIs called from the mutation queue — Medium **[reported]**

`NSPasteboard.general.changeCount`, `NSEvent.mouseLocation`, and
`NSEvent.pressedMouseButtons` are read in title-bar move handling
(`AgentRuntime.swift:1056-1057,1084,1087`), which runs on
`MutationQueue`. The FFM code deliberately hops to main for the same APIs
(`:2253-2257`), so this is an inconsistency; behavior ranges from stale reads
to Main Thread Checker hits.

### 3.5 `focusDir` does not activate the app — Medium **[reported]**

`AgentRuntime.swift:1911-1920` sets AX focus/raise but never calls
`NSRunningApplication.activate()` (unlike `nativeFocus`, `:1463-1475`), and
looks up `elements` directly instead of `resolvedElement(for:)`. Focusing a
background app's window with Option-h/j/k/l may not move keyboard focus and
silently drops on a stale cache entry.

### 3.6 Native-fullscreen entries leak — Medium **[reported]**

`removeDestroyedWindow` never touches `session.nativeFSWindows`
(`AgentRuntime.swift:965-980`), `dropPid` removes them only per-window
(`:2071`), and reconcile runs only over `session.allWindowIds`, which
excludes them (`SpaceSwitch.swift:89-91`). A user-closed native-FS window
stays in the model forever and can be reinserted into the tree if its
recycled CGWindowID reappears.

### 3.7 Cross-thread reads of `@unchecked Sendable` state — Medium **[reported]**

The class is `@unchecked Sendable`; several fields are written on one thread
and read on another without synchronization: pause flags read on main
(`:119-122`) but written on the mutation queue (`:31`), `lastSpaceChange`
written on main (`:447`), `secureInput` written on main (`:2275`) and read on
the queue (`:2350`), `hotkeys.hotkeyError` (`:2360`), and
`AXObserverHub.onNotification` written on the queue (`AgentRuntime.swift:368`)
but read from the AX callback on main (`AXObserverHub.swift:10,19-27`).

### 3.8 Config watcher misses in-place saves — Medium **[reported]**

`watchConfig` watches the directory with `O_EVTONLY`
(`AgentRuntime.swift:2218-2233`). Atomic replace fires `.rename`, but an
in-place write (`echo > lumina.toml`, some editors) changes no directory
entry and never reloads. If the config directory does not exist, `open`
fails and the watcher is silently absent.

### 3.9 `dropPid` leaves FS siblings marked `.stashed` while visible — Medium **[verified]**

`dropPid` calls `session.removeWindow` for every space
(`AgentRuntime.swift:2065-2078`). `Tree.remove` clears `luminaFullscreen`
without calling `markUnstashed` (`Tree.swift:102-104`), unlike the focused
space path. Remaining siblings render on screen (`applyFrames` ignores role)
but `nativeFocus` refuses `.stashed` windows (`AgentRuntime.swift:1465`)
until the user switches away and back.

### 3.10 Lower-severity agent issues — Low **[reported]**

- AX observers are installed before `onNotification` is assigned, and
  `AXObserverCreate`/`AddNotification` errors are ignored
  (`AgentRuntime.swift:304,320` vs `:368`; `AXObserverHub.swift:19-27,36,63`).
- `Hotkeys.hotkeyError` is never cleared after a successful reload
  (`Hotkeys.swift:10,14-57`), so one transient failure warns forever.
- `isOurStashSliver` compares against the display frame while parking uses
  the visible frame (`AgentRuntime.swift:1767-1772` vs `Stash.swift:18-31`),
  so parked windows are missed with a side Dock.
- Stale `moveStart` state can fabricate a swap after an interrupted drag
  (`AgentRuntime.swift:1055-1103`).
- `launchPollsRemaining` is decremented by every refresh, not just launch
  polls (`:704-707`), shortening post-launch discovery on busy event streams.
- `AXApplicationHidden` is registered (`AXObserverHub.swift:32`) but
  unhandled (`AgentRuntime.swift:466-512`).
- `screenLockedOrAsleep` checks only the main display (`:712-715`).
- `takeFlag` with a trailing flag (no value) can pass the flag itself as the
  socket path (`AgentApp.swift:15-22`).
- SIGINT is unhandled, so Ctrl-C on a manually launched agent skips restore
  (`AgentApp.swift:12,45`).
- `session.paused` is written but never read; `installWorkspaceObservers()` is
  empty; `forceRegisterPlaceholder` is never true; several stash helpers are
  unused (`AgentRuntime.swift:182-183,192,2281,736-746`; `MutationQueue.scheduleLayoutPass`;
  `AXAdapter.clearInFlight`; `SkyLightClient.available`).

---

## 4. Layout engine

### 4.1 `markUnstashed` breaks the FS-sibling invariant and causes flicker — Medium **[verified]**

`markUnstashed` promotes every stashed leaf that is not the FS leaf to
`.tiled` even when `space.luminaFullscreen != nil` (`Stash.swift:215-230`).
`switchSpace` calls `unstashSpace` on return (`AgentRuntime.swift:1416`),
which restores *every* tiled leaf regardless of role (`:1541-1548`) before
`restashOffspace` re-parks them (`:1419`). Returning to a fullscreen space
therefore briefly shows hidden siblings and issues extra AX writes.

### 4.2 `floatLeaf` drops model focus — Medium **[reported]**

`Balance.swift:184-198` removes the leaf (which reassigns `focusedWindow`),
appends the window to `floating`, and never sets focus back. No caller
re-asserts it (`SpaceSwitch.swift:54-72`, `AgentRuntime.swift:957-959,1117-1120,1940-1953`).
The next focus/resize/close command can target the wrong window until an
activation sync corrects it.

### 4.3 FS teardown paths never unstash siblings — Medium **[verified]**

`Tree.remove` clears `luminaFullscreen` without `markUnstashed`
(`Tree.swift:102-104`), and `dropPid`/`removeWindow` do not compensate
(`AgentRuntime.swift:2065-2078`). Windows stay `.stashed` while visible;
`nativeFocus` refuses them and `shouldCaptureOnscreenFrame` stops recording
their frames (`Stash.swift:82-86`).

### 4.4 Reconcile's miss cap does not cover hidden-space floaters — Medium **[reported]**

The bounded-miss grace only applies to `role == .floating`
(`Reconcile.swift:136-146`), but `markStashed` rewrites floaters on inactive
spaces to `.stashed` (`Stash.swift:208-210`), and `floatingIds` is built only
from `.floating` (`AgentRuntime.swift:575-578`). Hidden-workspace floaters —
where retention windows actually live — fall into the uncapped "defer while
CG lists it" branch.

### 4.5 One-out/one-in rebind assumes replacement — Medium (documented) **[reported]**

`Reconcile.swift:54-56,79-83` treats a single removed + single added id in
the same pid as a rebind, so a close followed by an unrelated open inherits
the old slot, ratio, role, and native-FS bookmark. Documented in
`plans/NOTES.md:47-53`, but the identity assumption is real and consequential.

### 4.6 Config parsing sharp edges — Medium **[reported]**

- `parseChord` silently drops unsupported modifiers: `alt-cmd-h` parses as
  `alt-h` (`Config.swift:171-179`) instead of erroring.
- `parseConfig(text:defaults:)` only uses `defaults` when the text is blank
  (`:229-233`); every key (`space-count`, gaps, FFM, launch-tiling) is
  mandatory (`:253-267`), so a partial config is rejected despite the API's
  merge promise.
- The duplicate-key workaround only recognizes the exact `[bindings]` header
  (`:431`); `[bindings] # comment` or `[ bindings ]` bypasses it and
  TOMLDecoder rejects the whole file.
- `applySpaceCount` pours windows with `insertSpiral`, overwriting space 1's
  recorded focus (`:377-397`); the destination's fullscreen state is ignored.

### 4.7 Launch tiling alias branch is dead and divergent — Medium **[reported]**

`bootLayout` passes `windows: []` for `float-existing`/`new-only` and appends
floaters itself (`AgentRuntime.swift:200-219`), so the branch at
`LaunchTiling.swift:33-44` never runs in production; the two paths differ on
whether `focusedWindow` gets set. The enum name also overpromises: new
windows are tiled regardless of policy.

### 4.8 `toggleLuminaFS` silently no-ops when a floater is focused — Medium **[reported]**

Exit requires `space.focusedWindow` to be the FS leaf
(`Fullscreen.swift:74-86`). Floaters can own focus, so after opening a dialog
Option-F appears dead.

### 4.9 Lower-severity layout issues — Low **[reported]**

- `removeWindow`'s focus fallback uses the impossible sentinel
  `NodeId(raw: 0)` (`Tree.swift:175-177`), so it is always nil; removal then
  falls back to leftmost, not the MRU semantics the plan wants
  (`Tree.swift:153-154` vs `plans/Advancement.md:246`).
- `Frames.swift:5-6` claims stashed windows are excluded; they are not
  (`Stash.markStashed` only changes `role`).
- `wholePointSpans` can emit a negative final span for n-ary nodes with tiny
  available space (`Frames.swift:69-81`); binary trees are safe.
- `tileFloater`/`floatToggle`/`reinsertNativeFS` remove before an
  `insertSpiral` that can no-op on a corrupt tree — silent window loss
  (`Tree.swift:223-232`, `SpaceSwitch.swift:63-69`, `NativeFS.swift:65-67`).
- Dead model state: `Space.lastDisplayFrame` (which backs a documented
  display-change clamp path that is never called), `Session.nativeSpaceToken`,
  `Bookmark.parentId`/`wasFloating` (`Model.swift:193,232,88`,
  `Balance.swift:123`).
- `SpaceId`'s 1…10 invariant is bypassed by synthesized `Codable`
  (`Model.swift:19,25-28`).
- `Registry.decode` has no legacy tolerance unlike `SessionFile`
  (`Registry.swift:40-42`); `preferredAgentSocket` can pick another display's
  agent (`:84-90`).
- `collectOriginals` omits `nativeFSWindows` (`Stash.swift:233-248`);
  `cascadeRestoreRect` can go negative for negative indices (`:191`).
- `NativeFS` bookmark assumes a binary split (`NativeFS.swift:32-45`).
- Tile/tile `swap` leaves `lastTiledLeaf` stale (`Spatial.swift:80-88`);
  line `:120` is a no-op assignment.
- `Rect.inset` clamps size but not origin (`Rect.swift:52-54`).
- `InputPolicy.shouldIgnoreAXGeometry` has a single-slot in-flight generation
  that `AXAdapter.setFrame` can overwrite (`InputPolicy.swift:50-53`,
  `AXAdapter.swift:221-236`).
- `CurrentSpace.recomputeCurrent`'s `skyLightOthers`/`otherClaims`
  arbitration is dead in production (caller hardcodes `[]`/`false`,
  `AgentRuntime.swift:2120,2123`) while tests exercise it.

---

## 5. Docs, tests, and repo hygiene

### 5.1 README quit claim contradicts the code — Medium **[verified]**

`README.md:5` says quitting "leaves apps open and frames where they are".
`stop()` calls `recenterAllWindows()` (`AgentRuntime.swift:153-155`), which
restores every managed window to its pre-tiling frame or a cascade
(`:1585-1601,1661-1669`). `plans/NOTES.md:119-120` describes the real
behavior.

### 5.2 `docs/compat.md` references a Cursor rule that does not exist — Medium **[verified]**

`docs/compat.md:15` says the config "keeps the `ignore` rule commented out"
and tells the user to "restore" it. The default config has no Cursor rule at
all (`Sources/Lumina/Resources/lumina.toml:50-61`).

### 5.3 Advancement plan diverges from the tree — Medium **[reported]**

`plans/Advancement.md` is marked "proposal" with no per-BP status, and parts
of its delete-list remain:

- BP-A3 says drop the global 50 ms AX timeout (`:220-221`); it is still set
  (`AgentRuntime.swift:108`, `AXAdapter.swift:70-73`).
- BP-A2 says delete the launch poll ladder (`:186-187`); it remains
  (`AgentRuntime.swift:54-57,394,425,704-707`).
- `knownOriginals`/`originalFrame`, ghost pruning, and resolvedElement
  probing are still present despite the "goes" list (`:111-125`).
- A7's `WorldSnapshot` and A1's `AXWindowSource` do not exist; A8's decision
  gate is still open (`:333,150-152,353-378`).

### 5.4 Smaller doc gaps — Low **[reported]**

- `docs/compat.md:9` says Visual Intelligence capture is hard-floated; the
  production bundle-id set is empty (`Classify.swift:132-134`).
- `README.md:39` lists only `Tests/LuminaLayoutTests/`; `Tests/LuminaIPCTests/`
  exists.
- The macOS requirement that `swift test` needs the Xcode toolchain
  (`DEVELOPER_DIR`) lives only in `plans/NOTES.md:106-108`, not install docs.
- Source comments still cite a design/SPEC document that is gitignored and
  gone (`Config.swift:139`, `Spatial.swift:31`, `CurrentSpace.swift:11`,
  `AgentSpawner.swift:103`; `.gitignore:5-8`).
- `.gitignore:194-196` ignores `AGENTS.md` and `CLAUDE.md`, so the repo's own
  agent rules are absent from a fresh clone unless force-added.

### 5.5 Coverage gaps — Low **[reported]**

- No tests for `floatToggle`, `toggleLuminaFS`, `closeWindow`,
  `workspacePrev/Next`, `applySpaceCount` growth, `usableRect`/`usableIsWide`,
  or any socket server/client path.
- `StatusStripView` click routing is untested (BP-A6 asked for a click
  matrix).
- Several test-only helpers pin behavior production never invokes
  (`wrapWorkspace`, `menuBarHangFrame`, `LayoutCoalesce`, `shouldAttach`,
  `axFrameLooksOnScreen`), which creates false confidence.
- `Tests/LuminaLayoutTests/LuminaLayoutTests.swift` is an empty placeholder.
- `ConfigTests.bundledDefaultMatchesResourceFile` couples a Swift string to a
  relative file path and silently breaks if packaging moves.

---

## 6. Intentional hacks worth knowing about

These are load-bearing and not bugs by themselves, but they constrain future
changes: private `_AXUIElementGetWindow` with frame-matching fallback
(`AXAdapter.swift:38-51`), private SkyLight framework (`SkyLight.swift`),
`AXEnhancedUserInterface` used both to wake Chromium and to suppress write
animation (`AXAdapter.swift:134-159,298-313`), the 1 px corner park
(`Stash.swift:13-31`), the 200 ms layout budget with continuation
(`MutationQueue.swift`, `AgentRuntime.swift:1273-1365`), and
`responsibility_spawnattrs_setdisclaim` so Accessibility attaches to the
agent rather than the extra (`AgentSpawner.swift:8-18,107-112`).
