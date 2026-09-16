# Dogfood

Things this environment could not prove, and the macOS-only matrix a human still has to walk. Unit tests cover layout, classify, config, IPC, stash math, current-space policy, luminaFS session transforms, and native-FS predicates. There is no live Accessibility suite in v1.

## Could not run here

This agent ran on Linux x86_64. It could not:

- Compile or launch `Lumina.app` / `lumina-agent` (AppKit, AX, Carbon).
- Run `scripts/bundle.sh` (requires `uname -m == arm64` plus `codesign`).
- Register Option hotkeys, talk to WindowServer, or grant TCC Accessibility.
- Verify SkyLight `dlopen` / `dlsym` on a real Mac.
- `posix_spawn` the nested helper or confirm `responsibility_spawnattrs_setdisclaim`.
- Exercise `SMAppService.mainApp` login items.
- Confirm `NSStatusItem` shows one extra only.

If any of those fail on a Mac, treat it as a product bug, not a “Linux skip.”

## Manual matrix (Apple silicon only: 15.2, 26 Tahoe, 27 Golden Gate)

Do not include Intel.

- Terminal tabs: only the visible tab tiles.
- Safari tabs, Chrome tabs: same heuristic; record misses in `docs/compat.md`.
- Finder copy dialog floats.
- System Settings floats with the default config (no user rule file required).
- Ghostty, iTerm: terminals with no zoom button still tile.
- Native fullscreen Space (Safari ⌃⌘F / green button that creates a Mac Space): remaining tiles reflow; bookmark is RAM-only.
- In-place green fill → luminaFS; Option-F toggles; sibling becomes a corner sliver; toggle restores.
- In-place half/quarter (Sequoia/Tahoe/Golden Gate Window Manager) → snap back to the computed tile; do not enter luminaFS.
- New window during luminaFS: dialog/sheet on top; tiled window slivered in-tree.
- ⌘M / yellow button: unminimize immediately, no hole.
- ⌘H: unhide immediately, no hole.
- Sleep/wake: one layout pass; off-space slivers re-stashed if WindowServer moved them.
- Lid close/open (same display UUID): auto-resume.
- Different display appears while the bound UUID is gone: stay paused; do not steal the layout.
- Screen lock: agent may die; extra restarts with unstash + launch-tiling (token kept this boot).
- Secure Input: extra tooltip “hotkeys blocked: Secure Input”; agent stays up.
- Two native Spaces, Start on each: `⌥ 2` on A does not move B’s windows; only the current extra digits drive the current agent; no dual `⌥H`.
- Reboot: one fresh agent + `launch-apps` if configured; no restored tree.
- Stage Manager on: must not crash (layout may fight).
- Apple Option-drag tiling on: fights Option modifier; document, do not write the setting.
- Siri.app tiles as a normal window.
- Visual Intelligence overlay floats; ⌘⇧Space / ⌘⇧6 not stolen.
- Swipe away from an empty Lumina space drops hotkeys.
- Swipe-back onto empty space without SkyLight: extra shows Start; attach if any sliver of that agent is on-screen.
- First-run sheet lists the three Desktop & Dock tiling toggles verbatim; Accessibility pane opens; extra does **not** prompt AX as itself.
- `scripts/bundle.sh` produces a runnable `Lumina.app`; Accessibility list shows **Lumina Agent**; `Contents/MacOS/lumina version` works; `file` is arm64.
- Two Terminal windows tile 50/50 with outer/inner gaps 8; close one → the other fills usable.
- `⌥ L` focuses spatially among two tiled windows.
- `⌥ 2` / `⌥ ⇧ 2` / `⌥ [` / `⌥ ]` wrap and move-and-follow.
- Killing the agent pid with extra alive respawns the same instanceId with crash-recover.

## CLI / socket (once a Mac agent is up)

```sh
lumina list-workspaces
lumina focus left
lumina workspace 3
```

No agent: stderr `agent not running on this Space`, exit 2.
