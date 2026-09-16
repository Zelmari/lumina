# Memory

Setbacks noticed while implementing v1 on a Linux cloud agent. Keep this short so the next session does not repeat them.

## Toolchain

- Swiftly’s `init --skip-install` plus `install` can still exit 1 on GitHub-hosted Ubuntu because of a post-install `apt-get install libcurl4-openssl-dev` hint. Install the toolchain deps first, pass `--post-install-file`, and run that script with sudo.
- `Lumina` / `LuminaAgent` / `LuminaCLI` are `#if os(macOS)` targets. Do not expect `swift build --target LuminaAgent` to work on Linux.

## Swift 6

- `stderr` / `stdout` FILE* are not concurrency-safe. Use `FileHandle.standardError` / `standardOutput` for CLI and log errors.
- `#expect(c.drain())` cannot call a `mutating` method; drain into a `let` first.
- `swap(&a, &b)` inside `Session.swap` resolves to the instance method. Use `Swift.swap`.

## TOML

- TOML tables reject duplicate keys (`alt-h` twice is ill-formed). Duplicate-chord last-wins is implemented by collapsing the `[bindings]` section before decode, then logging.

## Spatial focus

- Nearest center-to-center would pick a nearer floater over a tiled-in-strip window. Spec/tests require tiled-in-strip to outrank floaters. Score only within that class.

## Module split

- `kern.bootsessionuuid` lives in `LuminaIPC` (`kernBootUUID()`) so extra and agent share it. Do not define it only in the agent target.
- `visibleIds(on:)` must be `public` — the agent is a different module.
- Do not add a sixth SwiftPM target. Logging, paths, and IPC stay in `LuminaIPC`.

## Git

- `plans/` is not fully gitignored (only `plans/PROMPTS.md`). Product drafts that must stay local are the SPEC/DESIGN copies listed in `.gitignore` at repo root; `Dogfood.md` / `Memory.md` are agent notes and are committed.
- User asked to work on `main` and push. Conventional Commits still apply.
