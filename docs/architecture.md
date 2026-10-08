# Architecture

Lumina is one Swift package with five targets. Layout and IPC have no AppKit, so Linux CI can compile and test them. The other three targets exist only on macOS (`#if os(macOS)` in `Package.swift`).

```
TOMLDecoder
    ↑
LuminaLayout          LuminaIPC
    ↑  ↑                ↑  ↑
    │  └──── LuminaCLI ─┘  │
    │                      │
    └── LuminaAgent ───────┘
    ↑
    └── Lumina   (product LuminaExtra; does not link LuminaAgent)
```

An arrow points at the library a target links. `LuminaLayout` and `LuminaIPC` do not depend on each other. The menu extra does not link the agent target. It launches `lumina-agent` as a nested helper and talks to it over a Unix socket.

## LuminaLayout

Pure tiling model: spiral tree, workspaces, gaps, window rules, focus and swap, fullscreen, stash, verify. No processes, no windows, no sockets. New layout behavior lands here with a test in `Tests/LuminaLayoutTests`.

## LuminaIPC

JSON-lines request and response types, the CLI argument parser, socket paths, and the log. `Tests/LuminaIPCTests` covers parsing and the path-length fallback. Socket paths must fit `sun_path`; a too-long macOS temp directory falls back to a shorter name. Tests use stand-in paths, not a developer's home directory.

## LuminaCLI

The `lumina` executable. It parses argv, talks to the menu extra or the agent, and prints JSON. Exit `0` is success, `1` is a command or verify failure, `2` means no agent is running on this Space. `help`, `--help`, and `-h` print usage and do not contact the agent.

## LuminaAgent

One agent per display. It owns accessibility observers, hotkeys, the layout session, and the command socket. `AgentRuntime` is the session loop: adopt windows, apply frames, handle commands, publish status. Launch watching, command dispatch, and the JSON queries are extensions in the same module (`AgentRuntime+Launch.swift`, `AgentRuntime+Commands.swift`, `AgentRuntime+Queries.swift`). `AXAdapter` is the accessibility boundary. Display geometry and the CoreGraphics window list live beside it in `BoundDisplay.swift` and `CGWindows.swift`. `MutationQueue` serializes mutations onto one queue.

The product name is `lumina-agent`. `scripts/bundle.sh` nests it at `Contents/Helpers/Lumina Agent.app` with bundle id `com.zelmari.lumina.agent`. Accessibility must be granted to that bundle id.

## Lumina (menu extra)

SwiftPM target `Lumina`, product `LuminaExtra`. The product cannot be named `Lumina`: on a case-insensitive disk it would collide with the `lumina` CLI. The menu extra draws the workspace strip, starts and stops the agent, and serves the few commands that are not layout commands (`start`, `quit`, `open-config`, `grant-accessibility`, `current-token`, `strip-buttons`).

## What CI does not run

Linux CI runs the layout and IPC tests. A macOS job compiles `lumina`, `lumina-agent`, and `LuminaExtra` and runs the same tests. Neither job runs `scripts/harness.sh`. The harness needs a logged-in session, Accessibility, and Automation permission.
