# Contributing

Lumina is a macOS tiling window manager. Layout and the IPC protocol are pure Swift. The menu extra, agent, and CLI need macOS.

## Build

```sh
swift test --filter LuminaLayoutTests
swift test --filter LuminaIPCTests
```

Linux CI runs those tests with Swift 6.3.3. The package tools version is 6.3, so a Mac with Xcode’s Swift 6.3 or newer is enough. On a Mac, `swift test` needs the Xcode toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Command Line Tools do not ship the `Testing` module.

An ad-hoc-signed app, Apple silicon only:

```sh
./scripts/bundle.sh
```

That writes `dist/Lumina.app`. Grant Accessibility to **Lumina Agent** (`com.zelmari.lumina.agent`), then launch that build with `open dist/Lumina.app`. `open -a Lumina` may start a different registered copy. See [docs/install.md](docs/install.md).

## What to run

| Change | Check |
|---|---|
| `Sources/LuminaLayout`, `Sources/LuminaIPC` | `swift test --filter LuminaLayoutTests` and `LuminaIPCTests` |
| Agent, menu extra, CLI, accessibility | `scripts/harness.sh` on a Mac with Lumina running |
| A user-visible demo change | `demo/showcase.sh` from inside Ghostty |

The harness opens TextEdit and a test Ghostty, drives `lumina`, and checks `verify` plus real window frames after every step. It edits `~/.config/lumina/lumina.toml` during the config section and restores the file. Do not run it while you are editing a document. `RECORD=1` keeps the geometry under `artifacts/` (gitignored). Flags are listed in the script header and in the README.

`demo/showcase.sh` quits Lumina when it finishes. The harness does not. The showcase is a recording, not a test. Run it from inside Ghostty. It keeps that window. The crowd of nine (`CROWD=9`) was measured on 2026-10-06 for a 1454×907 tile area with 8 pt gaps; a tenth window no longer fits. That number is specific to that display.

## Changes

- Work on a branch named `<type>/<short-kebab-description>`. `type` is one of `feat`, `fix`, `docs`, `test`, `chore`, `refactor`, `ci`, `perf`.
- Commit subjects use [Conventional Commits](https://www.conventionalcommits.org/): `fix: tile a new ghostty window`. Imperative, lowercase after the type, no trailing period.
- One logical change per commit. The body should say why.
- Do not commit secrets, signing identities, `.env`, `dist/`, `artifacts/`, or `plans/`.
- Layout behavior belongs in `LuminaLayout` with a unit test. Do not reach for AppKit there. That target is what Linux CI compiles.
- Contributions are licensed under the MIT license in `LICENSE`.

## Reporting

Use the bug and feature templates. Accessibility traces and window dumps can contain window titles. Trim those before posting.

Security issues: see [SECURITY.md](SECURITY.md).
