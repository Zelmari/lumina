#!/usr/bin/env bash
# End-to-end smoke harness for Lumina on macOS.
#
# Drives the real CLI against the running agent using scriptable TextEdit
# windows, and checks `lumina verify` after every step. An agent can run this
# during development instead of clicking around by hand:
#
#   scripts/harness.sh
#
# Requirements: Lumina is running on this Space, the process running the
# harness has Accessibility and Automation permission (System Settings →
# Privacy & Security), and TextEdit is available. The script opens and
# closes TextEdit documents and opens/kills a test Ghostty instance for the
# native-tabs and new-window sections; do not run it while you are editing a document.
#
# Env:
#   LUMINA       path to the CLI (default: bundled app, PATH, then .build/debug)
#   WINDOW_COUNT how many test windows to open (default 3)
#   KEEP_WINDOWS set to 1 to leave the documents open for inspection
#   QUIT_TEST    set to 1 to finish by quitting Lumina and checking that every
#                managed window was restored to a usable size (Lumina stays
#                quit afterwards; relaunch it yourself)
#   LUMINA_LOG   agent log path (default ~/Library/Logs/Lumina.log)
#   RECORD       set to 1 to write per-step geometry artifacts under
#                artifacts/harness-<timestamp>/ (windows, workspaces, verify,
#                debug-windows dumps, and geometry.txt)
#   VERBOSE      set to 1 to print the per-window geometry table every step
#   TABS_TEST    set to 0 to skip the native-tabs (Ghostty) section
#   NEW_WINDOW_TEST set to 0 to skip the Ghostty Cmd-N new-window section
#   GHOSTTY_SPACES_TEST set to 0 to skip the multi-workspace Ghostty section
#                (one window on workspaces 2-4, an empty 5, five on 2 with
#                focus and swap, nine on 3, a tenth that overlaps, and
#                lumina close)
#   BENCH        set to 0 to skip the latency section (default 1)
#   BENCH_COUNT  pings for `lumina bench` (default 50)
#   BENCH_WARMUP warmup pings (default 5)
#   BENCH_MAX_P95_MS  fail when IPC round-trip p95 exceeds this (default 25)
#   BENCH_STRICT set to 1 to fail when a launch takes longer than
#                BENCH_LAUNCH_MAX_MS (default 500) or the menu push takes
#                longer than BENCH_MENU_MAX_MS (default 250)
#   LAUNCH_TEST  set to 0 to skip the cold-launch CG measurement (default 1)
#   FEATURE_TEST set to 0 to skip the config checks (gaps, a float window
#                rule, an ignore rule, a rejected config file,
#                focus-follows-mouse, launch-tiling, speculative-tile,
#                and hide-until-tiled). They edit the config and restore it
#                (default 1)
#   SHIELD_BOOT_TEST set to 1 to also restart Lumina to check that an app
#                left hidden by a previous agent is revealed at boot
#                (default 0; it quits and restarts the agent)
#   BENCH_COLD_MAX_MS  strict gate for the CG-measured cold launch
#                (default 3000; it includes the app's own launch time)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WINDOW_COUNT="${WINDOW_COUNT:-3}"
KEEP_WINDOWS="${KEEP_WINDOWS:-0}"
LUMINA_LOG="${LUMINA_LOG:-$HOME/Library/Logs/Lumina.log}"
CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/lumina/lumina.toml}"
FAILURES=0
STEP=0

ARTIFACTS=""
if [[ "${RECORD:-0}" == "1" ]]; then
  ARTIFACTS="$ROOT/artifacts/harness-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ARTIFACTS"
fi
TMP_BEFORE="$(mktemp -t lumina-harness-before)"
TMP_AFTER="$(mktemp -t lumina-harness-after)"
# Independent OS-truth window dumper, compiled once.
CGWINDOWS_BIN=""
if [[ -f "$ROOT/scripts/cgwindows.swift" ]] && command -v swiftc >/dev/null 2>&1; then
  CGWINDOWS_BIN="$(mktemp -t lumina-cgwindows)"
  if ! swiftc -O -o "$CGWINDOWS_BIN" "$ROOT/scripts/cgwindows.swift" >/dev/null 2>&1; then
    CGWINDOWS_BIN=""
  fi
fi
# The feature sections temporarily add top-level config keys; the original
# file is restored on every exit path, including Ctrl-C.
CONFIG_BACKUP=""
cleanup_tmp() {
  rm -f "$TMP_BEFORE" "$TMP_AFTER"
  [[ -n "$CGWINDOWS_BIN" ]] && rm -f "$CGWINDOWS_BIN"
}
cleanup_all() {
  cleanup_tmp
  if declare -F restore_config >/dev/null 2>&1; then restore_config; fi
}
trap cleanup_all EXIT INT TERM

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "harness.sh only runs on macOS." >&2
  exit 2
fi

pick_lumina() {
  if [[ -n "${LUMINA:-}" ]]; then echo "$LUMINA"; return; fi
  local bundled="$ROOT/dist/Lumina.app/Contents/MacOS/lumina"
  if [[ -x "$bundled" ]]; then echo "$bundled"; return; fi
  if command -v lumina >/dev/null 2>&1; then command -v lumina; return; fi
  echo "$ROOT/.build/debug/lumina"
}

LUMINA="$(pick_lumina)"
if [[ ! -x "$LUMINA" ]]; then
  echo "cannot find the lumina CLI; set LUMINA=/path/to/lumina" >&2
  exit 2
fi

say()  { printf '\n== %s\n' "$*"; }
pass() { printf '   ok: %s\n' "$*"; }
fail() { printf '   FAIL: %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# Run a CLI command and print its output. Expected to succeed.
run() {
  local out
  out="$("$LUMINA" "$@" 2>&1)"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "lumina $* exited $rc: $out"
  fi
  printf '%s\n' "$out"
}

# --- Feature-test config surgery -------------------------------------------

backup_config() {
  [[ -n "$CONFIG_BACKUP" ]] && return 0
  [[ -f "$CONFIG_PATH" ]] || return 0
  CONFIG_BACKUP="$(mktemp -t lumina-config-backup)"
  cp "$CONFIG_PATH" "$CONFIG_BACKUP" 2>/dev/null || true
}

# Deleting a key from the file does not reset it on reload: a missing key
# falls back to the value in the running config. So restoring means putting
# the user's file back, explicitly resetting the test keys to their
# defaults, reloading, and reading the user's file again.
restore_config() {
  [[ -n "$CONFIG_BACKUP" ]] || return 0
  cp "$CONFIG_BACKUP" "$CONFIG_PATH" 2>/dev/null || true
  write_config_top_level speculative-tile false
  write_config_top_level hide-until-tiled-apps "[]"
  "$LUMINA" reload >/dev/null 2>&1 || true
  cp "$CONFIG_BACKUP" "$CONFIG_PATH" 2>/dev/null || true
  "$LUMINA" reload >/dev/null 2>&1 || true
  rm -f "$CONFIG_BACKUP"
  CONFIG_BACKUP=""
}

# Force the running agent's test keys back to defaults while preserving the
# file; used at startup in case an interrupted earlier run left them active.
reset_feature_config_in_memory() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  local tmp
  tmp="$(mktemp -t lumina-config-reset)"
  cp "$CONFIG_PATH" "$tmp" 2>/dev/null || true
  write_config_top_level speculative-tile false
  write_config_top_level hide-until-tiled-apps "[]"
  "$LUMINA" reload >/dev/null 2>&1 || true
  cp "$tmp" "$CONFIG_PATH" 2>/dev/null || true
  rm -f "$tmp"
  "$LUMINA" reload >/dev/null 2>&1 || true
}

# Add or replace a top-level key without touching the backup. TOML tables
# own every key after their header, so an appended key would land inside the
# last table; insert before the first table header instead.
write_config_top_level() {
  local key="$1" value="$2"
  python3 - "$CONFIG_PATH" "$key" "$value" <<'PY'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
stripped = [l.strip() for l in lines]
lines = [l for l, s in zip(lines, stripped) if not s.startswith(key + " ")]
idx = next((i for i, s in enumerate(stripped) if s.startswith("[")), len(lines))
lines.insert(idx, "%s = %s" % (key, value))
open(path, "w").write("\n".join(lines) + "\n")
PY
}

set_config_top_level() {
  backup_config
  write_config_top_level "$1" "$2"
}

# --- Cold-launch CG measurement --------------------------------------------

# Open a fresh instance of `app`, then sample the independent CG oracle until
# the new window matches its model tile. Prints one JSON object with the
# first frame the window ever had, when it first appeared, when it reached
# the tile, and whether the very first frame already was the tile.
measure_launch() {
  local app="$1" timeout="${2:-5}"
  [[ -n "$CGWINDOWS_BIN" ]] || return 1
  local before_pids pid deadline t0 out
  before_pids="$(pgrep -x "$app" 2>/dev/null | tr '\n' ' ' || true)"
  t0="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  open -n -a "$app" >/dev/null 2>&1 || return 1
  pid=""
  deadline=$((SECONDS + 4))
  while ((SECONDS < deadline)); do
    for p in $(pgrep -x "$app" 2>/dev/null || true); do
      case " $before_pids " in *" $p "*) continue ;; esac
      pid="$p"
      break
    done
    [[ -n "$pid" ]] && break
    sleep 0.01
  done
  [[ -z "$pid" ]] && return 1
  out=$(python3 - "$CGWINDOWS_BIN" "$LUMINA" "$pid" "$t0" "$timeout" <<'PY' 2>/dev/null || true
import json, subprocess, sys, time

cg_bin, lumina, pid, t0, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
pid_str = str(pid)
deadline = time.time() * 1000 + timeout * 1000
first = None
tiled_at = None
model = None
models = []
i = 0

def close(a, b):
    # CG border bounds include the shadow; the model geometry checks use
    # 12pt.
    return (abs(a["x"] - b["x"]) <= 12 and abs(a["y"] - b["y"]) <= 12
            and abs(a["w"] - b["w"]) <= 12 and abs(a["h"] - b["h"]) <= 12)

while time.time() * 1000 < deadline:
    now = time.time() * 1000
    try:
        rows = json.loads(subprocess.run([cg_bin, pid_str], capture_output=True, timeout=1).stdout)
    except Exception:
        rows = []
    if i % 4 == 0:
        try:
            raw = subprocess.run([lumina, "list-windows"], capture_output=True, timeout=2).stdout
            models = [w for w in json.loads(raw).get("windows", []) if int(w.get("pid", -1)) == pid]
        except Exception:
            models = []
    model_ids = {int(w["cgWindowId"]) for w in models}
    # Prefer a window the model actually tracks: a restored document can sit
    # next to the new one and outsize it.
    tracked = [r for r in rows if int(r["cgWindowId"]) in model_ids] if model_ids else rows
    live = max(tracked or rows, key=lambda r: float(r["w"]) * float(r["h"])) if (tracked or rows) else None
    if live is not None and first is None:
        first = dict(live)
        first["at"] = now
    model = None
    if live is not None:
        model = next((w for w in models if int(w["cgWindowId"]) == int(live["cgWindowId"])), None)
    if live is not None and model is not None and close(live, model):
        tiled_at = now
        break
    i += 1
    time.sleep(0.008)

def rect(r):
    return None if r is None else {"x": r["x"], "y": r["y"], "w": r["w"], "h": r["h"], "onscreen": r.get("onscreen")}

result = {
    "pid": pid,
    "firstMs": None if first is None else round(first["at"] - t0),
    "tiledMs": None if tiled_at is None else round(tiled_at - t0),
    "first": rect(first),
    "model": rect(model),
    "firstIsTile": None if first is None or model is None else close(first, model),
}
print(json.dumps(result))
PY
)
  printf '%s\n' "$out"
}

# Kill a test instance and wait for it to exit. SIGKILL on purpose: SIGTERM
# opens TextEdit's save-confirmation dialog for the untitled test document.
kill_test_instance() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -9 "$pid" >/dev/null 2>&1 || true
  local deadline=$((SECONDS + 5))
  while ((SECONDS < deadline)); do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  return 1
}

# One line per managed window: id, bundle, space, role, size, position.
geometry_table() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
for w in json.load(sys.stdin).get("windows", []):
    print("id=%-7s %-28s space=%-2d %-7s %4dx%-4d @%d,%d" % (
        w["cgWindowId"], (w.get("bundleId") or "?")[:28], w["space"], w["role"],
        w["w"], w["h"], w["x"], w["y"]))
' 2>/dev/null || true
}

# Per-step artifacts: the geometry a human/agent needs to see a sizing bug
# after the fact. Off unless RECORD=1.
record_step() {
  local label="$1"
  [[ -n "$ARTIFACTS" ]] || return 0
  local n slug
  n="$(printf '%02d' "$STEP")"
  slug="$(printf '%s' "$label" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//;s/-$//')"
  "$LUMINA" list-windows > "$ARTIFACTS/step-$n-$slug.windows.json" 2>/dev/null
  "$LUMINA" list-workspaces > "$ARTIFACTS/step-$n-$slug.workspaces.json" 2>/dev/null
  "$LUMINA" verify > "$ARTIFACTS/step-$n-$slug.verify.json" 2>/dev/null
  local dump
  dump="$("$LUMINA" debug-windows 2>/dev/null)"
  if [[ -n "$dump" && -f "$dump" ]]; then
    cp "$dump" "$ARTIFACTS/step-$n-$slug.debug.json"
  fi
  {
    echo "== step $STEP: $label"
    geometry_table
  } >> "$ARTIFACTS/geometry.txt"
}

# Canonical per-window geometry, sorted, for convergence polling.
geometry_signature() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
rows = []
for w in json.load(sys.stdin).get("windows", []):
    rows.append("%s:%s:%d:%d:%d:%d" % (
        w["cgWindowId"], w["space"], w["x"], w["y"], w["w"], w["h"]))
print("|".join(sorted(rows)))
' 2>/dev/null || true
}

# The layout may need a pass or two to settle after a change (observed
# minimum sizes re-balance a split). Wait until it stops changing.
wait_for_stable_geometry() {
  local deadline=$((SECONDS + 8)) prev="" cur
  while ((SECONDS < deadline)); do
    cur="$(geometry_signature)"
    if [[ -n "$cur" && "$cur" == "$prev" ]]; then return 0; fi
    prev="$cur"
    sleep 0.4
  done
  return 1
}

# Ids whose geometry changed between two list-windows snapshots while staying
# on the same workspace.
geometry_moves() {
  python3 - "$1" "$2" <<'PY'
import json, sys
before = {w["cgWindowId"]: w for w in json.load(open(sys.argv[1]))["windows"]}
after = {w["cgWindowId"]: w for w in json.load(open(sys.argv[2]))["windows"]}
moved = []
for i, w in before.items():
    n = after.get(i)
    if not n or w["space"] != n["space"]:
        continue
    if any(abs(w[k] - n[k]) > 2 for k in ("x", "y", "w", "h")):
        moved.append(i)
print(" ".join(str(i) for i in sorted(moved)))
PY
}

live_windows() {
  [[ -n "$CGWINDOWS_BIN" ]] || return 1
  local pids
  pids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", [])))
' 2>/dev/null)"
  if [[ -z "$pids" ]]; then
    echo "[]"
    return 0
  fi
  "$CGWINDOWS_BIN" $pids
}

# Independent live-geometry check against real CG border coordinates, not the
# model: tile/tile overlap, a focused-space tile with no live window (closed
# but still in the model), a real frame far from its model frame, and a tiled
# area that no longer spans the model's tiles. Floater-over-tile is noted but
# allowed by design.
assert_live_geometry() {
  local label="$1"
  [[ -n "$CGWINDOWS_BIN" ]] || return 0
  # A window that refuses its tile floats after the 1.5s refusal hold; give
  # the layout that convergence window before failing.
  local attempt out
  for attempt in 1 2 3; do
    local model live focused
    model="$("$LUMINA" list-windows 2>/dev/null)"
    focused="$("$LUMINA" list-workspaces 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["focused"])' 2>/dev/null)"
    live="$(live_windows 2>/dev/null)" || return 0
    [[ -z "$model" || -z "$focused" || -z "$live" ]] && return 0
    out="$(MODEL="$model" LIVE="$live" FOCUSED="$focused" python3 - <<'PY'
import json, os
model = json.loads(os.environ["MODEL"])
live = json.loads(os.environ["LIVE"])
focused = int(os.environ["FOCUSED"])
live_by_id = {w["cgWindowId"]: w for w in live}
windows = model.get("windows", [])
tiles = [w for w in windows if w.get("role") == "tiled" and w.get("space") == focused]
floats = [w for w in windows if w.get("role") == "floating" and w.get("space") == focused]
problems = []
notes = []

def rect(w):
    return (w["x"], w["y"], w["x"] + w["w"], w["y"] + w["h"])

def overlap(a, b, slop=4):
    ax, ay, ax2, ay2 = rect(a)
    bx, by, bx2, by2 = rect(b)
    iw = min(ax2, bx2) - max(ax, bx)
    ih = min(ay2, by2) - max(ay, by)
    return iw > slop and ih > slop

for w in tiles:
    lw = live_by_id.get(w["cgWindowId"])
    if lw is None:
        problems.append("live-missing-window id=%s %s model=%.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w.get("bundleId", "?"), w["w"], w["h"], w["x"], w["y"]))
        continue
    if (abs(lw["x"] - w["x"]) > 12 or abs(lw["y"] - w["y"]) > 12
            or abs(lw["w"] - w["w"]) > 12 or abs(lw["h"] - w["h"]) > 12):
        problems.append("live-frame-mismatch id=%s %s live=%.0fx%.0f@%.0f,%.0f model=%.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w.get("bundleId", "?"),
            lw["w"], lw["h"], lw["x"], lw["y"], w["w"], w["h"], w["x"], w["y"]))

for i in range(len(tiles)):
    for j in range(i + 1, len(tiles)):
        a, b = tiles[i], tiles[j]
        la, lb = live_by_id.get(a["cgWindowId"]), live_by_id.get(b["cgWindowId"])
        if la is None or lb is None:
            continue
        if overlap(la, lb):
            problems.append("live-overlap id=%s %s %.0fx%.0f@%.0f,%.0f vs id=%s %s %.0fx%.0f@%.0f,%.0f" % (
                a["cgWindowId"], a.get("bundleId", "?"), la["w"], la["h"], la["x"], la["y"],
                b["cgWindowId"], b.get("bundleId", "?"), lb["w"], lb["h"], lb["x"], lb["y"]))

for f in floats:
    lf = live_by_id.get(f["cgWindowId"])
    if lf is None:
        continue
    for t in tiles:
        lt = live_by_id.get(t["cgWindowId"])
        if lt is not None and overlap(lf, lt):
            notes.append("floater-over-tile id=%s %s over id=%s %s" % (
                f["cgWindowId"], f.get("bundleId", "?"), t["cgWindowId"], t.get("bundleId", "?")))

def bbox(entries):
    if not entries:
        return None
    xs = [e[0] for e in entries]
    ys = [e[1] for e in entries]
    x2 = [e[2] for e in entries]
    y2 = [e[3] for e in entries]
    return (min(xs), min(ys), max(x2), max(y2))

model_bbox = bbox([rect(w) for w in tiles])
live_bbox = bbox([rect(live_by_id[w["cgWindowId"]]) for w in tiles if w["cgWindowId"] in live_by_id])
if model_bbox and live_bbox and any(abs(a - b) > 6 for a, b in zip(model_bbox, live_bbox)):
    problems.append("live-coverage-hole model=%s live=%s" % (
        ",".join("%.0f" % v for v in model_bbox),
        ",".join("%.0f" % v for v in live_bbox)))

for n in notes:
    print("NOTE " + n)
for p in problems:
    print("PROBLEM " + p)
PY
)"
    if [[ -z "$out" ]]; then
      return 0
    fi
    if printf '%s\n' "$out" | grep -q '^PROBLEM' && [[ "$attempt" -lt 3 ]]; then
      if [[ "$attempt" -eq 1 ]]; then sleep 0.8; else sleep 1.5; fi
      continue
    fi
    printf '%s\n' "$out" | grep '^NOTE' | sed 's/^NOTE/   note:/' || true
    if printf '%s\n' "$out" | grep -q '^PROBLEM'; then
      fail "$label: live geometry issues:"
      printf '%s\n' "$out" | grep '^PROBLEM' | sed 's/^PROBLEM/      /'
      geometry_table | sed 's/^/      /'
    fi
    return 0
  done
}

# Check invariants and that no tracked window silently left the model.
verify() {
  local label="${1:-verify}"
  STEP=$((STEP + 1))
  local out rc
  if ! "$LUMINA" list-windows >/dev/null 2>&1; then
    fail "$label: lumina list-windows failed (agent down?)"
    return
  fi
  out="$("$LUMINA" verify 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "$label: verify found issues ($out)"
    geometry_table | sed 's/^/      /'
  else
    pass "$label: verify clean"
  fi
  if [[ -n "${TRACKED_IDS:-}" ]]; then
    local missing
    missing="$(missing_ids "$TRACKED_IDS")"
    if [[ -n "$missing" ]]; then
      fail "$label: windows left the model: $missing"
      geometry_table | sed 's/^/      /'
    fi
  fi
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    geometry_table | sed 's/^/      /'
  fi
  assert_live_geometry "$label"
  record_step "$label"
}

managed_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("windows", [])))' 2>/dev/null || echo 0
}

status_visible_count() {
  "$LUMINA" status 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("visibleSpaceCount", 0))' 2>/dev/null || echo 0
}

status_space_count() {
  "$LUMINA" status 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("spaceCount", 10))' 2>/dev/null || echo 10
}

# Tab apps are excluded: their backing window id legitimately changes on a
# tab switch (the tab section asserts their tile count separately).
window_ids() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
skip = {"com.apple.Terminal", "com.mitchellh.ghostty"}
d = json.load(sys.stdin)
print(" ".join(str(w["cgWindowId"]) for w in d.get("windows", []) if w.get("bundleId") not in skip))
' 2>/dev/null || true
}

count_on_space() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=int(sys.argv[1]); print(sum(1 for w in d.get("windows", []) if w.get("space") == s))' "$1" 2>/dev/null || echo 0
}

# Ids that were in the model before but are gone now. Catches the reported
# "opening on a new workspace empties the others" bug directly.
missing_ids() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
current = {w["cgWindowId"] for w in json.load(sys.stdin).get("windows", [])}
expected = {int(x) for x in sys.argv[1].split()}
print(" ".join(str(i) for i in sorted(expected - current)))
' "$1" 2>/dev/null || true
}

new_textedit_id() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
before = {int(x) for x in sys.argv[1].split()}
for w in json.load(sys.stdin).get("windows", []):
    if w["cgWindowId"] not in before and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
        break
' "$1" 2>/dev/null || true
}

# `open -n` activates TextEdit, so the new window is visible and adopted
# deterministically. `make new document` launches the app hidden, which
# delays adoption until an activation event. Wait for each window: rapid
# document churn makes TextEdit's AX tree flaky.
open_windows() {
  local n="$1"
  for ((i = 0; i < n; i++)); do
    local before id deadline
    before="$(window_ids)"
    open -n -a TextEdit >/dev/null 2>&1 ||
      { fail "could not launch TextEdit window $((i + 1))"; return 1; }
    deadline=$((SECONDS + 8))
    id=""
    while ((SECONDS < deadline)); do
      id="$(new_textedit_id "$before")"
      [[ -n "$id" ]] && break
      sleep 0.3
    done
    if [[ -z "$id" ]]; then
      fail "TextEdit window $((i + 1)) was not adopted"
    fi
  done
}

# Close documents before quitting: killing TextEdit makes macOS restore the
# open documents on the next launch, so repeated runs accumulate windows.
close_windows() {
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
  osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
  sleep 0.8
  pkill -x TextEdit >/dev/null 2>&1 || true
}

# Start from zero test windows even if a previous run was interrupted.
reset_test_app() {
  close_windows
}

wait_for_count() {
  local want="$1" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(managed_count)" -ge "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

wait_for_space_count() {
  local space="$1" want="$2" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(count_on_space "$space")" -ge "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

wait_for_count_at_most() {
  local want="$1" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(managed_count)" -le "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

# The native-tabs section uses a dedicated Ghostty instance: each tab is a
# separate NSWindow, so every Cmd-T activates a new backing window.
ghostty_pids() {
  ps -axo pid,comm | grep 'Ghostty.app/Contents/MacOS/ghostty' | grep -v grep | awk '{print $1}'
}

# A restored session is a real second OS window. Counting that as a tile the
# test created makes "Cmd-T stays one tile" and "Cmd-N adds one" unmeasurable.
# The flag overrides the user's Ghostty config for this process only.
open_test_ghostty() {
  local before p deadline
  before="$(ghostty_pids)"
  open -n -a Ghostty --args --window-save-state=never >/dev/null 2>&1 || true
  deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    for p in $(ghostty_pids); do
      if ! printf '%s\n' "$before" | grep -qx "$p"; then
        echo "$p"
        return 0
      fi
    done
    sleep 0.4
  done
  return 1
}

pid_count() {
  "$LUMINA" list-windows 2>/dev/null |
    python3 -c '
import json, sys
pid = int(sys.argv[1])
print(sum(1 for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid))
' "$1" 2>/dev/null || echo 0
}

wait_for_pid_count() {
  local pid="$1" want="$2" deadline=$((SECONDS + 10))
  while ((SECONDS < deadline)); do
    if [[ "$(pid_count "$pid")" -eq "$want" ]]; then return 0; fi
    sleep 0.4
  done
  return 1
}

wait_for_pid_tiled() {
  local pid="$1" space="$2" deadline=$((SECONDS + 8))
  while ((SECONDS < deadline)); do
    if "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
space = int(sys.argv[2])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("pid") == pid and w.get("space") == space and w.get("role") == "tiled":
        sys.exit(0)
sys.exit(1)
' "$pid" "$space" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

ghostty_new_tab() {
  osascript -e 'tell application "System Events" to keystroke "t" using command down' >/dev/null 2>&1 || true
}

ghostty_next_tab() {
  osascript -e 'tell application "System Events" to keystroke "]" using {command down, shift down}' >/dev/null 2>&1 || true
}

# Cmd-N is a new OS window. Cmd-T (ghostty_new_tab) is a tab in the current one.
ghostty_new_window() {
  osascript -e 'tell application "System Events" to keystroke "n" using command down' >/dev/null 2>&1 || true
}

# Keystrokes go to whichever app is frontmost. Pin that to the test pid and
# return the unix id that actually ended up frontmost.
focus_pid() {
  local pid="$1"
  osascript -e "tell application \"System Events\" to set frontmost of first process whose unix id is $pid to true" >/dev/null 2>&1 || true
  osascript -e 'tell application "System Events" to unix id of first process whose frontmost is true' 2>/dev/null || true
}

# Point the agent at a TextEdit tile on the workspace that is already
# focused. Activating TextEdit follows whichever document macOS considers
# frontmost, including a sole window on another workspace, and every later
# check then runs against that one-window space.
focus_textedit() {
  local space deadline id bundle win_space
  space="$(focused_workspace)"
  deadline=$((SECONDS + 4))
  while ((SECONDS < deadline)); do
    id="$(focused_window_id)"
    bundle="$(window_field "$id" bundleId)"
    win_space="$(window_field "$id" space)"
    if [[ "$bundle" == "com.apple.TextEdit" && "$win_space" == "$space" && "$(window_field "$id" role)" == "tiled" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
    run focus right >/dev/null
    sleep 0.15
  done
  return 1
}

focused_window_id() {
  "$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    value = json.load(sys.stdin).get("focusedWindow")
except Exception:
    value = None
print("" if value is None else value)
' 2>/dev/null || true
}

window_field() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
want = int(sys.argv[1])
field = sys.argv[2]
for w in json.load(sys.stdin).get("windows", []):
    if int(w.get("cgWindowId") or 0) == want:
        value = w.get(field)
        print("" if value is None else value)
        break
' "$1" "$2" 2>/dev/null || true
}

window_frame() {
  local x y w h
  x="$(window_field "$1" x)"
  y="$(window_field "$1" y)"
  w="$(window_field "$1" w)"
  h="$(window_field "$1" h)"
  [[ -n "$x" ]] || return 0
  python3 -c 'import sys; print("%d,%d,%d,%d" % tuple(round(float(v)) for v in sys.argv[1:]))' "$x" "$y" "$w" "$h" 2>/dev/null || true
}

focused_workspace() {
  "$LUMINA" list-workspaces 2>/dev/null | python3 -c '
import json, sys
try: print(int(json.load(sys.stdin).get("focused") or 0))
except Exception: print(0)
' 2>/dev/null || echo 0
}

count_role_on_space() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
space = int(sys.argv[1])
role = sys.argv[2]
print(sum(1 for w in json.load(sys.stdin).get("windows", []) if w.get("space") == space and w.get("role") == role))
' "$1" "$2" 2>/dev/null || echo 0
}

status_flag() {
  "$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try: print(json.load(sys.stdin).get(sys.argv[1]))
except Exception: print("")
' "$1" 2>/dev/null || true
}

# Live on-screen overlap among the given pids. Empty output is clean.
# Stashed windows are off the display and are not counted.
live_overlap_pids() {
  [[ -n "$CGWINDOWS_BIN" ]] || return 0
  [[ -n "${1// }" ]] || return 0
  # shellcheck disable=SC2086
  "$CGWINDOWS_BIN" $1 2>/dev/null | python3 -c '
import json, sys
rows = [w for w in json.load(sys.stdin) if w.get("onscreen") and w["w"] >= 20 and w["h"] >= 20 and w["x"] < 1600 and w["y"] < 980]
def overlap(a, b, slop=8):
    ax, ay, ax2, ay2 = a["x"], a["y"], a["x"] + a["w"], a["y"] + a["h"]
    bx, by, bx2, by2 = b["x"], b["y"], b["x"] + b["w"], b["y"] + b["h"]
    return min(ax2, bx2) - max(ax, bx) > slop and min(ay2, by2) - max(ay, by) > slop
lines = []
for i in range(len(rows)):
    for j in range(i + 1, len(rows)):
        if overlap(rows[i], rows[j]):
            lines.append("overlap pid=%s pid=%s" % (rows[i]["pid"], rows[j]["pid"]))
print("\n".join(lines))
' 2>/dev/null || true
}

pid_ids() {
  "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
ids = [str(w["cgWindowId"]) for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid]
print(" ".join(ids))
' "$1" 2>/dev/null || true
}

# On-screen windows of one pid that are missing from the model, overlap
# each other, or cover another tiled window. A floating window sitting on
# a tile is allowed, same as assert_live_geometry. Empty output is clean.
# No output when the CG oracle is unavailable, so a machine without swiftc
# still has the model checks.
pid_onscreen_problems() {
  local pid="$1"
  [[ -n "$CGWINDOWS_BIN" ]] || return 0
  local model pids live
  model="$("$LUMINA" list-windows 2>/dev/null)" || return 0
  [[ -n "$model" ]] || return 0
  pids="$(printf '%s' "$model" | python3 -c '
import json, sys
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", [])))
' 2>/dev/null)"
  live="$("$CGWINDOWS_BIN" "$pid" $pids 2>/dev/null)" || return 0
  [[ -n "$live" ]] || return 0
  MODEL="$model" LIVE="$live" PID="$pid" python3 - <<'PY'
import json, os
model = json.loads(os.environ["MODEL"])
live = json.loads(os.environ["LIVE"])
pid = int(os.environ["PID"])
roles = {w["cgWindowId"]: w.get("role") for w in model.get("windows", [])}
managed = set(roles)

def big(w):
    return w.get("onscreen") and w.get("w", 0) >= 80 and w.get("h", 0) >= 80

def overlap(a, b, slop=4):
    iw = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
    ih = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
    return iw > slop and ih > slop

ours = [w for w in live if w.get("pid") == pid and big(w)]
others = [w for w in live if w.get("pid") != pid and big(w) and roles.get(w["cgWindowId"]) == "tiled"]
problems = []
for w in ours:
    if w["cgWindowId"] not in managed:
        problems.append("unmanaged-onscreen id=%s %.0fx%.0f@%.0f,%.0f" % (
            w["cgWindowId"], w["w"], w["h"], w["x"], w["y"]))
for i in range(len(ours)):
    for j in range(i + 1, len(ours)):
        a, b = ours[i], ours[j]
        if overlap(a, b):
            problems.append("overlap id=%s %.0fx%.0f@%.0f,%.0f vs id=%s %.0fx%.0f@%.0f,%.0f" % (
                a["cgWindowId"], a["w"], a["h"], a["x"], a["y"],
                b["cgWindowId"], b["w"], b["h"], b["x"], b["y"]))
for w in ours:
    for other in others:
        if overlap(w, other):
            problems.append("covers id=%s pid=%s vs id=%s pid=%s" % (
                w["cgWindowId"], w.get("pid"), other["cgWindowId"], other.get("pid")))
print("\n".join(problems))
PY
}

say "Lumina at $LUMINA"
if ! "$LUMINA" status >/dev/null 2>&1; then
  echo "agent is not answering; start Lumina on this Space first." >&2
  exit 2
fi
# The agent reads the config at start and on reload. Reset the feature-test
# keys in memory and re-read the file so an interrupted earlier run cannot
# leave shield/speculative behavior active for this run.
reset_feature_config_in_memory

reset_test_app
sleep 0.5
baseline="$(managed_count)"
say "baseline: $baseline managed windows"
verify "baseline"

say "opening $WINDOW_COUNT TextEdit windows"
open_windows "$WINDOW_COUNT" || exit 2
if wait_for_count $((baseline + WINDOW_COUNT)); then
  pass "all $WINDOW_COUNT windows adopted"
else
  fail "windows were not adopted: still $(managed_count) managed (wanted $((baseline + WINDOW_COUNT)))"
fi
verify "after open"
TRACKED_IDS="$(window_ids)"

# Regression for "swapped to a new workspace and opened something, all the
# other workspaces got emptied". Opening on a fresh workspace must not remove
# a single tracked window from any other workspace.
say "open on a fresh workspace keeps the other workspaces intact"
space1_before="$(count_on_space 1)"
run workspace 2 >/dev/null
verify "on empty workspace 2"
open_windows 1
if wait_for_space_count 2 1; then
  pass "the new window landed on workspace 2"
else
  fail "the new window did not land on workspace 2 (found on another workspace)"
fi
TRACKED_IDS="$TRACKED_IDS $(window_ids)"
if [[ "$(count_on_space 1)" -ge "$space1_before" ]]; then
  pass "workspace 1 kept its $space1_before windows"
else
  fail "workspace 1 lost windows: had $space1_before, now $(count_on_space 1)"
fi
verify "after opening on workspace 2"
run workspace 1 >/dev/null
verify "back on workspace 1"

say "focus movement"
focus_before="$(focused_window_id)"
run focus right >/dev/null
verify "after focus right"
focus_after="$(focused_window_id)"
if [[ -n "$focus_before" && "$focus_after" != "$focus_before" ]]; then
  pass "focus right moved to window $focus_after"
else
  run focus left >/dev/null
  focus_after="$(focused_window_id)"
  if [[ -n "$focus_before" && "$focus_after" != "$focus_before" ]]; then
    pass "focus left moved to window $focus_after"
  else
    fail "focus did not leave window ${focus_before:-none}"
  fi
fi
run focus up >/dev/null
verify "after focus up"
run focus down >/dev/null
verify "after focus down"

say "swap"
swap_id="$(focused_window_id)"
swap_before="$(window_frame "$swap_id")"
run swap right >/dev/null
verify "after swap right"
swap_after="$(window_frame "$swap_id")"
if [[ -n "$swap_before" && "$swap_after" != "$swap_before" ]]; then
  pass "swap right moved window $swap_id"
else
  run swap left >/dev/null
  swap_after="$(window_frame "$swap_id")"
  if [[ -n "$swap_before" && "$swap_after" != "$swap_before" ]]; then
    pass "swap left moved window $swap_id"
  else
    fail "swap did not move window ${swap_id:-none}"
  fi
fi
run swap up >/dev/null
verify "after swap up"
run swap down >/dev/null
verify "after swap down"

say "resize and balance"
focus_textedit >/dev/null || fail "could not focus a tiled TextEdit for resize"
resize_space="$(focused_workspace)"
resize_tiled="$(count_role_on_space "$resize_space" tiled)"
if [[ "${resize_tiled:-0}" -lt 2 ]]; then
  fail "resize needs at least two tiled windows on workspace $resize_space (have ${resize_tiled:-0})"
elif ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
  fail "geometry snapshot before resize failed"
else
  run resize grow >/dev/null
  if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
    grown="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
    if [[ -n "$grown" ]]; then
      pass "resize grow moved:$grown"
    else
      fail "resize grow did not move a window"
    fi
    if "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null && [[ -s "$TMP_BEFORE" ]]; then
      run resize shrink >/dev/null
      if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
        shrunk="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
        if [[ -n "$shrunk" ]]; then
          pass "resize shrink moved:$shrunk"
        else
          fail "resize shrink did not move a window"
        fi
      else
        fail "geometry snapshot after resize shrink failed"
      fi
    else
      fail "geometry snapshot before resize shrink failed"
    fi
    run resize grow >/dev/null
    if "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null && [[ -s "$TMP_BEFORE" ]]; then
      run balance >/dev/null
      if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
        balanced="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
        if [[ -n "$balanced" ]]; then
          pass "balance moved:$balanced"
        else
          fail "balance did not move a window"
        fi
      else
        fail "geometry snapshot after balance failed"
      fi
    else
      fail "geometry snapshot before balance failed"
    fi
  else
    fail "geometry snapshot after resize grow failed"
  fi
fi
verify "after resize/balance"

say "native fullscreen"
nf_id="$(focus_textedit || true)"
if [[ -z "$nf_id" ]]; then
  fail "could not focus a tiled TextEdit for native fullscreen"
else
  nf_pid="$(window_field "$nf_id" pid)"
  run fullscreen native >/dev/null
  nf_gone=0
  nf_deadline=$((SECONDS + 6))
  while ((SECONDS < nf_deadline)); do
    if [[ -z "$(window_field "$nf_id" role)" ]]; then
      nf_gone=1
      break
    fi
    sleep 0.3
  done
  if (( nf_gone == 1 )); then
    pass "native fullscreen detached TextEdit $nf_id"
    run fullscreen native >/dev/null
    nf_back=0
    nf_deadline=$((SECONDS + 6))
    while ((SECONDS < nf_deadline)); do
      if [[ -n "$nf_pid" ]] && "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("pid") == pid and w.get("role") == "tiled":
        sys.exit(0)
sys.exit(1)
' "$nf_pid" 2>/dev/null; then
        nf_back=1
        break
      fi
      sleep 0.3
    done
    if (( nf_back == 1 )); then
      pass "native fullscreen exit tiled TextEdit pid $nf_pid again"
    else
      fail "native fullscreen exit did not retile TextEdit pid ${nf_pid:-none}"
      run fullscreen native >/dev/null || true
    fi
  else
    fail "native fullscreen left TextEdit $nf_id in the model (role $(window_field "$nf_id" role))"
    run fullscreen native >/dev/null || true
  fi
  # TextEdit replaces the window and comes back zoomed to the screen.
  # setFrame does not stick, and the id is then dropped from the model.
  # This process is only the fullscreen probe. Close it before geometry
  # checks so the zoomed frame is not scored against the other tiles.
  if [[ -n "$nf_pid" ]]; then
    kill -9 "$nf_pid" >/dev/null 2>&1 || true
    nf_deadline=$((SECONDS + 4))
    while ((SECONDS < nf_deadline)); do
      if ! kill -0 "$nf_pid" 2>/dev/null && [[ -z "$(window_field "$nf_id" role)" ]]; then
        break
      fi
      sleep 0.2
    done
  fi
  if [[ -n "$nf_id" ]]; then
    TRACKED_IDS="$(printf '%s' "$TRACKED_IDS" | tr ' ' '\n' | grep -v "^${nf_id}$" | tr '\n' ' ')"
  fi
  verify "after native fullscreen"
fi

say "float toggle"
float_id="$(focus_textedit || true)"
if [[ -z "$float_id" ]]; then
  fail "could not focus a tiled TextEdit for float-toggle"
else
  run float-toggle >/dev/null
  verify "after float on"
  float_role="$(window_field "$float_id" role)"
  if [[ "$float_role" == "floating" ]]; then
    pass "window $float_id is floating"
  else
    fail "float-toggle left window $float_id as ${float_role:-missing}"
  fi
  run float-toggle >/dev/null
  verify "after float off"
  float_role="$(window_field "$float_id" role)"
  if [[ "$float_role" == "tiled" ]]; then
    pass "window $float_id is tiled again"
  else
    fail "float-toggle did not retile window $float_id (role ${float_role:-missing})"
  fi
fi

say "lumina fullscreen"
fs_id="$(focus_textedit || true)"
fs_space="$(focused_workspace)"
fs_before="$(count_role_on_space "$fs_space" tiled)"
if [[ -z "$fs_id" ]]; then
  fail "could not focus a tiled TextEdit for fullscreen"
else
  run fullscreen lumina >/dev/null
  verify "in fullscreen"
  fs_role="$(window_field "$fs_id" role)"
  fs_during="$(count_role_on_space "$fs_space" tiled)"
  if [[ "$fs_role" == "luminaFS" && "$fs_during" == "0" ]]; then
    pass "lumina fullscreen parked the other tiles"
  else
    fail "lumina fullscreen role=${fs_role:-missing} tiled=$fs_during (was $fs_before)"
  fi
  run fullscreen lumina >/dev/null
  verify "after fullscreen exit"
  fs_role="$(window_field "$fs_id" role)"
  fs_after="$(count_role_on_space "$fs_space" tiled)"
  if [[ "$fs_role" == "tiled" && "$fs_after" == "$fs_before" ]]; then
    pass "fullscreen exit restored $fs_after tiled windows"
  else
    fail "fullscreen exit role=${fs_role:-missing} tiled=$fs_after (was $fs_before)"
  fi
fi

# Closing one window (app stays running) must reflow the remaining tiles.
# The live-geometry oracle inside verify catches a stale tile/coverage hole.
say "closing one window reflows the rest"
before_ids="$(window_ids)"
open_windows 1
closed_id="$(new_textedit_id "$before_ids")"
close_count="$(managed_count)"
osascript -e 'tell application "TextEdit" to close front window saving no' >/dev/null 2>&1
if wait_for_count_at_most "$((close_count - 1))"; then
  pass "closed window left the model"
else
  fail "closed window still managed: $(managed_count) (was $close_count)"
fi
if [[ -n "$closed_id" ]]; then
  TRACKED_IDS="$(printf '%s' "$TRACKED_IDS" | tr ' ' '\n' | grep -v "^${closed_id}$" | tr '\n' ' ')"
fi
verify "after closing one window"

say "workspace switch with hidden windows"
# The first round trip may converge once (observed minimum sizes can
# re-balance a split); the layout must be identical on the next one.
if ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
  fail "geometry snapshot before the workspace switch failed"
else
  run workspace 2 >/dev/null
  verify "on workspace 2"
  run workspace 1 >/dev/null
  verify "back on workspace 1"
  if ! wait_for_stable_geometry; then
    fail "geometry did not converge after a workspace round trip"
  elif ! "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || [[ ! -s "$TMP_AFTER" ]]; then
    fail "geometry snapshot after the first workspace switch failed"
  else
    run workspace 2 >/dev/null
    verify "second trip on workspace 2"
    run workspace 1 >/dev/null
    verify "second trip back on workspace 1"
  fi
  if ! wait_for_stable_geometry; then
    fail "geometry did not converge after the second workspace round trip"
  elif ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
    fail "geometry snapshot after the workspace switch failed"
  elif ! moved="$(geometry_moves "$TMP_AFTER" "$TMP_BEFORE")"; then
    fail "geometry comparison failed (malformed snapshot)"
  elif [[ -n "$moved" ]]; then
    fail "geometry changed across a second workspace round trip: $moved"
    geometry_table | sed 's/^/      /'
  else
    pass "geometry stable across a second workspace round trip"
  fi
fi

say "workspace next and prev"
space_before="$(focused_workspace)"
run workspace next >/dev/null
space_next="$(focused_workspace)"
if [[ "$space_next" != "$space_before" && "$space_next" != "0" ]]; then
  pass "workspace next left $space_before for $space_next"
else
  fail "workspace next stayed on ${space_next:-none}"
fi
verify "after workspace next"
run workspace prev >/dev/null
space_back="$(focused_workspace)"
if [[ "$space_back" == "$space_before" ]]; then
  pass "workspace prev returned to $space_back"
else
  fail "workspace prev landed on $space_back (wanted $space_before)"
fi
verify "after workspace prev"

say "move window to workspace 2 and back"
move_id="$(focused_window_id)"
run move-node-to-workspace 2 >/dev/null
verify "after move to 2"
move_space="$(window_field "$move_id" space)"
if [[ "$move_space" == "2" ]]; then
  pass "window $move_id is on workspace 2"
else
  fail "window $move_id is on workspace ${move_space:-none} after the move"
fi
run workspace 2 >/dev/null
verify "on workspace 2 after move"
run move-node-to-workspace 1 >/dev/null
move_space="$(window_field "$move_id" space)"
if [[ "$move_space" == "1" ]]; then
  pass "window $move_id is back on workspace 1"
else
  fail "window $move_id is on workspace ${move_space:-none} after moving back"
fi
run workspace 1 >/dev/null
verify "back on workspace 1"

# The menu extra strip shows at least five workspaces and grows only when a
# higher one is used.
say "menu extra workspace count grows with use"
visible_before="$(status_visible_count)"
configured="$(status_space_count)"
if [[ "$visible_before" -ge 5 ]]; then
  pass "strip shows at least 5 workspaces ($visible_before)"
else
  fail "strip shows only $visible_before workspaces (want at least 5)"
fi
target="$configured"
[[ "$target" -gt 7 ]] && target=7
if [[ "$target" -gt 5 ]]; then
  run move-node-to-workspace "$target" >/dev/null
  sleep 1
  visible_used="$(status_visible_count)"
  if [[ "$visible_used" -ge "$target" ]]; then
    pass "strip grew to $visible_used after using workspace $target"
  else
    fail "strip did not grow after using workspace $target: $visible_used"
  fi
  run move-node-to-workspace 1 >/dev/null
  run workspace 1 >/dev/null
  sleep 1
  visible_after="$(status_visible_count)"
  if [[ "$visible_after" -ge 5 && "$visible_after" -le "$visible_used" ]]; then
    pass "strip settled at $visible_after after the window left"
  else
    fail "strip did not settle: $visible_after (was $visible_used)"
  fi
  verify "after workspace count check"
else
  pass "configured space count is $configured; the 5-workspace minimum covers it"
fi

say "workspace 0 is workspace 10"
if [[ "$(status_space_count)" -ge 10 ]]; then
  run workspace 0 >/dev/null
  if [[ "$(focused_workspace)" == "10" ]]; then
    pass "workspace 0 focused workspace 10"
  else
    fail "workspace 0 focused workspace $(focused_workspace)"
  fi
  verify "on workspace 10"
  run workspace 1 >/dev/null
  verify "back from workspace 10"
else
  pass "space count is $(status_space_count); workspace 0 is workspace 10 only when that space exists"
fi

say "reload config"
run reload >/dev/null
verify "after reload"

say "pause freezes layout commands"
if ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null; then
  fail "geometry snapshot before pause failed"
else
  run pause >/dev/null
  if [[ "$(status_flag paused)" == "True" ]]; then
    pass "agent is paused"
  else
    fail "pause left paused=$(status_flag paused)"
  fi
  run resize grow >/dev/null
  if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null; then
    paused_moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
    if [[ -z "$paused_moved" ]]; then
      pass "resize while paused did not move a window"
    else
      fail "resize while paused moved:$paused_moved"
    fi
  else
    fail "geometry snapshot during pause failed"
  fi
  run resume >/dev/null
  if [[ "$(status_flag paused)" == "False" ]]; then
    pass "agent resumed"
  else
    fail "resume left paused=$(status_flag paused)"
  fi
  verify "after resume"
fi

say "version, ping, and debug dump"
ver="$("$LUMINA" version 2>&1)" || fail "version command failed"
if [[ -n "$ver" ]]; then
  pass "version: $ver"
else
  fail "version printed nothing"
fi
ping_out="$("$LUMINA" ping 2>&1)" || fail "ping failed: $ping_out"
if printf '%s' "$ping_out" | grep -q 'pong'; then
  pass "ping answered"
else
  fail "ping did not answer pong: $ping_out"
fi
dump="$("$LUMINA" debug-windows 2>&1)" || fail "debug-windows failed: $dump"
if [[ -f "$dump" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dump" >/dev/null 2>&1; then
  pass "debug-windows wrote JSON"
else
  fail "debug-windows did not write JSON (${dump:-no path})"
fi
help_out="$("$LUMINA" --help 2>&1)" || fail "help failed: $help_out"
if printf '%s' "$help_out" | grep -q 'workspace'; then
  pass "help lists the commands"
else
  fail "help did not list commands: $help_out"
fi
debug_out="$("$LUMINA" debug 2>&1)" || fail "debug failed: $debug_out"
if printf '%s' "$debug_out" | grep -q 'LUMINA_DEBUG='; then
  pass "debug reports the env flag"
else
  fail "debug did not report LUMINA_DEBUG: $debug_out"
fi
token_out="$("$LUMINA" current-token 2>&1)" || fail "current-token failed: $token_out"
token_id="$(printf '%s' "$token_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("instanceId") or "")
except Exception: print("")' 2>/dev/null)"
status_id="$(status_flag instanceId)"
if [[ -n "$token_id" && "$token_id" == "$status_id" ]]; then
  pass "current-token matches status"
else
  fail "current-token ${token_id:-none} does not match status ${status_id:-none}"
fi

# Latency: pure IPC round trips (no Accessibility needed) and the agent's
# recorded event-to-frame time. The IPC gate is always on; the frame gate is
# opt-in because it is machine- and app-dependent.
if [[ "${BENCH:-1}" != "0" ]]; then
  say "latency: IPC round trips"
  bench_out="$("$LUMINA" bench --count "${BENCH_COUNT:-50}" --warmup "${BENCH_WARMUP:-5}" --max-p95-ms "${BENCH_MAX_P95_MS:-25}" 2>&1)"
  bench_rc=$?
  printf '%s\n' "$bench_out"
  if [[ $bench_rc -eq 0 ]]; then
    pass "bench p95 within ${BENCH_MAX_P95_MS:-25}ms"
  else
    fail "bench exited $bench_rc"
  fi
  if [[ -n "$ARTIFACTS" ]]; then
    printf '%s\n' "$bench_out" > "$ARTIFACTS/bench.json"
  fi

  say "latency: agent refresh-to-frame"
  # Generate fresh samples with a workspace round trip, then read the p95 the
  # agent recorded for real discovery events.
  "$LUMINA" workspace 2 >/dev/null 2>&1
  "$LUMINA" workspace 1 >/dev/null 2>&1
  sleep 0.5
  frame_out="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
last = s.get("refreshLatencyMs")
p95 = s.get("refreshLatencyP95Ms")
if last is None:
    print("no refresh latency samples yet")
else:
    print("refreshLatency last=%.1fms p95=%.1fms" % (last, p95 if p95 is not None else last))
' 2>/dev/null || true)"
  if [[ -n "$frame_out" ]]; then
    printf '   %s\n' "$frame_out"
  fi
  if [[ -n "$ARTIFACTS" ]]; then
    "$LUMINA" status > "$ARTIFACTS/bench-status.json" 2>/dev/null
  fi

  say "latency: launch adoption"
  # A fresh document in the already-running TextEdit exercises the created
  # path end to end; status carries the agent's event-to-frame time for it.
  launch_before="$(managed_count)"
  if osascript -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1; then
    deadline=$((SECONDS + 5))
    while ((SECONDS < deadline)) && [[ "$(managed_count)" -le "$launch_before" ]]; do sleep 0.1; done
    sleep 0.3
    launch_ms="$("$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
try:
    s = json.load(sys.stdin)
except Exception:
    sys.exit(0)
v = s.get("refreshLatencyMs")
if v is not None:
    print("%.1f" % v)
' 2>/dev/null || true)"
    if [[ -n "$launch_ms" ]]; then
      printf '   refreshLatency last=%sms (created path)\n' "$launch_ms"
      if [[ -n "$ARTIFACTS" ]]; then
        printf '%s\n' "$launch_ms" > "$ARTIFACTS/bench-launch-ms.txt"
      fi
      if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
        launch_max="${BENCH_LAUNCH_MAX_MS:-500}"
        if python3 -c "import sys; sys.exit(0 if float('${launch_ms}') <= float('${launch_max}') else 1)"; then
          pass "launch-to-frame ${launch_ms}ms within ${launch_max}ms"
        else
          fail "launch-to-frame ${launch_ms}ms exceeds ${launch_max}ms"
        fi
      fi
    else
      printf '   no launch latency sample\n'
    fi
    osascript -e 'tell application "TextEdit" to close front document saving no' >/dev/null 2>&1
  else
    printf '   TextEdit unavailable; launch latency skipped\n'
  fi

  say "latency: menu push"
  # The extra logs a timestamped line for every pushed snapshot; compare it
  # with the moment the switch command was issued.
  "$LUMINA" workspace 2 >/dev/null 2>&1
  push_before="$(python3 -c 'import time; print(int(time.time() * 1000))')"
  "$LUMINA" workspace 1 >/dev/null 2>&1
  sleep 0.3
  push_line="$(grep 'push space=1 at=' "$LUMINA_LOG" 2>/dev/null | tail -1 || true)"
  push_at="${push_line##*at=}"
  if [[ -n "$push_at" && "$push_at" =~ ^[0-9]+$ ]]; then
    push_delta=$((push_at - push_before))
    if ((push_delta >= 0 && push_delta < 5000)); then
      printf '   menu push=%dms\n' "$push_delta"
      if [[ -n "$ARTIFACTS" ]]; then
        printf '%s\n' "$push_delta" > "$ARTIFACTS/bench-menu-push-ms.txt"
      fi
      if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
        menu_max="${BENCH_MENU_MAX_MS:-250}"
        if ((push_delta <= menu_max)); then
          pass "menu push ${push_delta}ms within ${menu_max}ms"
        else
          fail "menu push ${push_delta}ms exceeds ${menu_max}ms"
        fi
      fi
    else
      printf '   no fresh menu push observed\n'
    fi
  else
    printf '   no menu push line in the agent log\n'
  fi

  if [[ "${LAUNCH_TEST:-1}" != "0" ]]; then
    say "latency: cold-launch CG measurement"
    if [[ -n "$CGWINDOWS_BIN" ]]; then
      cold_json="$(measure_launch TextEdit 8)"
      cold_pid="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
      cold_tiled="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try:
    v = json.load(sys.stdin).get("tiledMs")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
      cold_first_tile="$(printf '%s' "$cold_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstIsTile"))
except Exception: print("")' 2>/dev/null)"
      if [[ -n "$cold_tiled" ]]; then
        printf '   cold launch pid=%s first=%sms tiled=%sms firstIsTile=%s\n' \
          "$cold_pid" \
          "$(printf '%s' "$cold_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("firstMs"))' 2>/dev/null)" \
          "$cold_tiled" "$cold_first_tile"
        if [[ -n "$ARTIFACTS" ]]; then
          printf '%s\n' "$cold_json" > "$ARTIFACTS/cold-launch.json"
        fi
        if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
          cold_max="${BENCH_COLD_MAX_MS:-3000}"
          if ((cold_tiled <= cold_max)); then
            pass "cold launch tiled in ${cold_tiled}ms within ${cold_max}ms"
          else
            fail "cold launch took ${cold_tiled}ms (limit ${cold_max}ms)"
          fi
        fi
      else
        fail "cold launch never produced a tiled window ($cold_json)"
      fi
      if [[ -n "$cold_pid" ]]; then
        repark_count="$(grep -c "pre-park re-park .* pid=$cold_pid " "$LUMINA_LOG" 2>/dev/null || true)"
        printf '   re-park lines for pid %s: %s (bounded at 3)\n' "$cold_pid" "${repark_count:-0}"
        if (( ${repark_count:-0} > 3 )); then
          fail "re-park looped for pid $cold_pid (${repark_count} attempts)"
        fi
      fi
      kill_test_instance "$cold_pid" >/dev/null 2>&1 || fail "could not stop the cold-launch test instance"
      sleep 0.6
    else
      printf '   cgwindows unavailable; cold-launch CG measurement skipped\n'
    fi
  fi

  if [[ "${FEATURE_TEST:-1}" != "0" && -n "$CGWINDOWS_BIN" && -f "$CONFIG_PATH" ]]; then
    say "config: gaps, focus-follows-mouse, launch-tiling, float rule"
    backup_config
    if [[ -z "$CONFIG_BACKUP" ]]; then
      fail "could not back up $CONFIG_PATH"
    else
      python3 - "$CONFIG_PATH" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
def num(key, default):
    m = re.search(r'(?m)^%s\s*=\s*(\d+)' % key, text)
    return int(m.group(1)) if m else default
inner, outer = num("inner", 8), num("outer", 8)
new_inner, new_outer = inner + 16, outer + 24
def widen(body):
    body = re.sub(r'(?m)^inner\s*=\s*\d+', 'inner = %d' % new_inner, body, count=1)
    body = re.sub(r'(?m)^outer\s*=\s*\d+', 'outer = %d' % new_outer, body, count=1)
    if not re.search(r'(?m)^inner\s*=', body):
        body = body.rstrip() + '\ninner = %d\n' % new_inner
    if not re.search(r'(?m)^outer\s*=', body):
        body = body.rstrip() + '\nouter = %d\n' % new_outer
    return body
if re.search(r'(?m)^\[gaps\]', text):
    gap = re.search(r'(?ms)^\[gaps\][^\[]*', text)
    if gap:
        text = text[:gap.start()] + widen(gap.group(0)) + text[gap.end():]
else:
    text += '\n[gaps]\ninner = %d\nouter = %d\n' % (new_inner, new_outer)
lines = text.splitlines()
def drop(key, rows):
    return [row for row in rows if not row.strip().startswith(key + " ") and not row.strip().startswith(key + "=")]
lines = drop("focus-follows-mouse", lines)
lines = drop("launch-tiling", lines)
stripped = [row.strip() for row in lines]
idx = next((i for i, s in enumerate(stripped) if s.startswith("[")), len(lines))
lines.insert(idx, 'launch-tiling = "new-only"')
lines.insert(idx, "focus-follows-mouse = true")
text = "\n".join(lines) + "\n"
text += '\n[[window-rule]]\napp-id = "com.apple.TextEdit"\naction = "float"\n'
open(path, "w").write(text)
PY
      if ! "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || [[ ! -s "$TMP_BEFORE" ]]; then
        fail "geometry snapshot before the gap change failed"
      else
        run reload >/dev/null
        sleep 0.6
        if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
          gap_moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
          if [[ -n "$gap_moved" ]]; then
            pass "larger gaps reflowed tiles:$gap_moved"
          else
            fail "larger gaps did not move a tile"
          fi
        else
          fail "geometry snapshot after the gap change failed"
        fi
      fi
      rule_before="$(window_ids)"
      rule_pids_before="$(pgrep -x TextEdit 2>/dev/null | tr '\n' ' ' || true)"
      open_windows 1
      rule_id="$(new_textedit_id "$rule_before")"
      rule_role="$(window_field "$rule_id" role)"
      if [[ "$rule_role" == "floating" ]]; then
        pass "window rule floated the new TextEdit ($rule_id)"
      else
        fail "window rule left the new TextEdit ${rule_role:-unmanaged} (id ${rule_id:-none})"
      fi
      rule_pid="$(window_field "$rule_id" pid)"
      case " $rule_pids_before " in
        *" $rule_pid "*)
          osascript -e 'tell application "TextEdit" to close front window saving no' >/dev/null 2>&1 || true
          ;;
        *)
          kill_test_instance "$rule_pid" >/dev/null 2>&1 || true
          ;;
      esac
      restore_config
      sleep 0.6
      verify "after config restore"
    fi

    say "launch concealment: speculative tile"
    set_config_top_level speculative-tile true
    "$LUMINA" reload >/dev/null 2>&1
    sleep 0.3
    spec_json="$(measure_launch TextEdit 8)"
    spec_pid="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
    spec_first_tile="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstIsTile"))
except Exception: print("")' 2>/dev/null)"
    if [[ -n "$ARTIFACTS" ]]; then printf '%s\n' "$spec_json" > "$ARTIFACTS/speculative-tile.json"; fi
    spec_first_ms="$(printf '%s' "$spec_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("firstMs"))
except Exception: print("")' 2>/dev/null)"
    printf '   speculative tile pid=%s first=%sms firstIsTile=%s\n' "$spec_pid" "$spec_first_ms" "$spec_first_tile"
    # The app can paint before the watch detects it, and a fast adoption can
    # tile before any pre-park runs, so the first observed frame is not a
    # sound assertion on its own. Pass when the window was written straight
    # to a predicted tile, or when its first observed frame already was the
    # tile; fail if a corner park was used.
    if [[ -n "$spec_pid" ]] \
      && grep -q "pre-park tile .* pid=$spec_pid " "$LUMINA_LOG" 2>/dev/null; then
      if grep -q "pre-park window .* pid=$spec_pid " "$LUMINA_LOG" 2>/dev/null; then
        fail "speculative tile: a corner park was also used for pid $spec_pid"
      else
        pass "speculative tile: window was written straight to a predicted tile"
      fi
    elif [[ "$spec_first_tile" == "True" ]]; then
      pass "speculative tile: first observed frame already was the tile (adopted before any park)"
    elif [[ -n "$spec_pid" ]]; then
      fail "speculative tile: no 'pre-park tile' line and first frame was not the tile ($spec_json)"
    else
      fail "speculative tile: no measurement ($spec_json)"
    fi
    kill_test_instance "$spec_pid" >/dev/null 2>&1 || true
    restore_config
    sleep 0.6

    say "launch concealment: hide until tiled"
    set_config_top_level hide-until-tiled-apps '["com.apple.TextEdit"]'
    "$LUMINA" reload >/dev/null 2>&1
    sleep 0.3
    shield_json="$(measure_launch TextEdit 8)"
    shield_pid="$(printf '%s' "$shield_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
    shield_tiled="$(printf '%s' "$shield_json" | python3 -c 'import json,sys
try:
    v = json.load(sys.stdin).get("tiledMs")
    print("" if v is None else v)
except Exception: print("")' 2>/dev/null)"
    if [[ -n "$ARTIFACTS" ]]; then printf '%s\n' "$shield_json" > "$ARTIFACTS/hide-until-tiled.json"; fi
    if [[ -z "$shield_tiled" ]]; then
      fail "hide-until-tiled: window never reached its tile ($shield_json)"
    else
      pass "hide-until-tiled: window tiled in ${shield_tiled}ms"
    fi
    if [[ -n "$shield_pid" ]]; then
      if grep -q "launch shield hide pid=$shield_pid " "$LUMINA_LOG" 2>/dev/null \
        && grep -q "launch shield reveal pid=$shield_pid reason=tiled" "$LUMINA_LOG" 2>/dev/null; then
        pass "shield hid the app then revealed it after tiling"
      else
        fail "shield log missing hide/reveal(tiled) for pid $shield_pid"
      fi
      sleep 0.4
      shield_visible="$(osascript -e "tell application \"System Events\" to get visible of first process whose unix id is $shield_pid" 2>/dev/null || true)"
      if [[ "$shield_visible" == "true" ]]; then
        pass "shielded app visible after reveal"
      else
        fail "shielded app still not visible (visible=$shield_visible)"
      fi
      kill_test_instance "$shield_pid" >/dev/null 2>&1 || true
    fi
    restore_config
    sleep 0.6

    say "config: ignore rule and a rejected file"
    backup_config
    if [[ -z "$CONFIG_BACKUP" ]]; then
      fail "could not back up $CONFIG_PATH for the ignore rule"
    else
      printf '\n[[window-rule]]\napp-id = "com.apple.TextEdit"\naction = "ignore"\n' >> "$CONFIG_PATH"
      run reload >/dev/null
      sleep 0.4
      ignore_before="$(window_ids)"
      ignore_pids="$(pgrep -x TextEdit 2>/dev/null | tr '\n' ' ' || true)"
      open -n -a TextEdit >/dev/null 2>&1 || fail "could not launch TextEdit for the ignore rule"
      ignore_deadline=$((SECONDS + 4))
      ignore_id=""
      while ((SECONDS < ignore_deadline)); do
        ignore_id="$(new_textedit_id "$ignore_before")"
        [[ -n "$ignore_id" ]] && break
        sleep 0.3
      done
      if [[ -z "$ignore_id" ]]; then
        pass "ignore rule left the new TextEdit unmanaged"
      else
        fail "ignore rule adopted TextEdit $ignore_id as $(window_field "$ignore_id" role)"
      fi
      for ignore_pid in $(pgrep -x TextEdit 2>/dev/null || true); do
        case " $ignore_pids " in
          *" $ignore_pid "*) ;;
          *) kill -9 "$ignore_pid" >/dev/null 2>&1 || true ;;
        esac
      done
      restore_config
      sleep 0.4
      backup_config
      if [[ -z "$CONFIG_BACKUP" ]]; then
        fail "could not back up $CONFIG_PATH before the broken config"
      else
        printf 'this is not toml [\n' > "$CONFIG_PATH"
        bad_reload=0
        "$LUMINA" reload >/dev/null 2>&1 || bad_reload=1
        if [[ "$bad_reload" == "1" ]]; then
          pass "reload rejected a broken config"
        else
          fail "reload accepted a broken config"
        fi
        bad_error="$(status_flag configError)"
        if [[ -n "$bad_error" && "$bad_error" != "None" && "$bad_error" != "null" ]]; then
          pass "status reports the config error"
        else
          fail "status configError is empty after a broken config"
        fi
        restore_config
        sleep 0.4
        restored_error="$(status_flag configError)"
        if [[ -z "$restored_error" || "$restored_error" == "None" || "$restored_error" == "null" ]]; then
          pass "config error cleared after restore"
        else
          fail "config error still set after restore ($restored_error)"
        fi
        verify "after rejected config"
      fi
    fi
  fi

  if [[ "${BENCH_STRICT:-0}" == "1" ]]; then
    "$LUMINA" status 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin)
created = s.get("createdLatencyP95Ms")
launched = s.get("launchedLatencyP95Ms")
print("created p95=%s launched p95=%s (report only)" % (created, launched))
' 2>/dev/null || true
  fi
fi

# Native tabs: each tab is a separate NSWindow, so every Cmd-T makes a new
# backing window active. Lumina must keep exactly one tile per app window.
# A dedicated Ghostty instance is opened and killed, so the user's session
# and any Terminal windows are untouched, and the pid count is exact.
if [[ "${TABS_TEST:-1}" != "0" ]]; then
  say "native tabs: one Ghostty tile across tab creation and switches"
  saved_tracked="${TRACKED_IDS:-}"
  TRACKED_IDS=""
  ghost_pid="$(open_test_ghostty || true)"
  if [[ -z "$ghost_pid" ]]; then
    fail "could not start a test Ghostty instance"
  else
    if wait_for_pid_count "$ghost_pid" 1; then
      pass "Ghostty window adopted"
    else
      fail "Ghostty window was not adopted"
    fi
    # The cold launch should have been caught by the willLaunch watch (or, if
    # app-driven, the created note). Either is fine; report which.
    if grep -Eq "launch watch (start pid=$ghost_pid reason=willLaunch|sighting pid=$ghost_pid)" "$LUMINA_LOG" 2>/dev/null; then
      pass "cold launch watched from willLaunch"
    else
      printf '   note: no launch-watch line for pid %s (created note handled it)\n' "$ghost_pid"
    fi
    for tab in 1 2 3; do
      front="$(focus_pid "$ghost_pid")"
      if [[ "$front" != "$ghost_pid" ]]; then
        fail "Cmd-T $tab not sent: frontmost pid is ${front:-none}, test pid is $ghost_pid"
        break
      fi
      ghostty_new_tab
      sleep 1.2
      managed="$(pid_count "$ghost_pid")"
      if [[ "$managed" -eq 1 ]]; then
        pass "after Cmd-T $tab: Ghostty still has 1 tile"
      else
        fail "after Cmd-T $tab: Ghostty has $managed managed windows (want 1)"
        geometry_table | sed 's/^/      /'
      fi
      verify "after Ghostty tab $tab"
    done
    # Tab switching is best effort: the key binding is user-configurable.
    for i in 1 2 3; do
      front="$(focus_pid "$ghost_pid")"
      if [[ "$front" != "$ghost_pid" ]]; then
        fail "tab switch $i not sent: frontmost pid is ${front:-none}, test pid is $ghost_pid"
        break
      fi
      ghostty_next_tab
      sleep 0.8
      managed="$(pid_count "$ghost_pid")"
      if [[ "$managed" -eq 1 ]]; then
        pass "after tab switch $i: Ghostty still has 1 tile"
      else
        fail "after tab switch $i: Ghostty has $managed managed windows (want 1)"
      fi
    done
    verify "after Ghostty tabs"
    kill "$ghost_pid" >/dev/null 2>&1 || true
    if wait_for_pid_count "$ghost_pid" 0; then
      pass "test Ghostty instance removed"
    else
      fail "test Ghostty instance still managed"
    fi
  fi
  TRACKED_IDS="$saved_tracked"
  verify "after native tabs"
fi

# Cmd-N is a new window, not a tab. Each one joins the tile tree beside the
# windows already on the workspace. Collapsing it into the existing Ghostty
# tile leaves the old window on screen and stacks later windows on top of
# every other app. A dedicated instance is opened and killed, same as tabs.
if [[ "${NEW_WINDOW_TEST:-1}" != "0" ]]; then
  say "Ghostty Cmd-N opens a new tiled window"
  focused="$("$LUMINA" list-workspaces 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["focused"])' 2>/dev/null || true)"
  te_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
focused = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("space") == focused and w.get("role") == "tiled" and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
' "$focused" 2>/dev/null || true)"
  if [[ -z "$te_ids" ]]; then
    open_windows 1 || true
    te_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
focused = int(sys.argv[1])
for w in json.load(sys.stdin).get("windows", []):
    if w.get("space") == focused and w.get("role") == "tiled" and w.get("bundleId") == "com.apple.TextEdit":
        print(w["cgWindowId"])
' "$focused" 2>/dev/null || true)"
  fi
  if [[ -z "$te_ids" ]]; then
    fail "no tiled TextEdit on the focused workspace to tile beside"
  else
    # insertSpiral splits the model's focused tiled window. Walk focus onto
    # a TextEdit so the reflow check has that window as its target.
    te_flat="$(printf '%s' "$te_ids" | tr '\n' ' ')"
    focused_te=""
    now_focus=""
    aim_deadline=$((SECONDS + 8))
    while ((SECONDS < aim_deadline)); do
      now_focus="$(focused_window_id)"
      case " $te_flat " in
        *" $now_focus "*) focused_te="$now_focus"; break ;;
      esac
      run focus right >/dev/null || true
      sleep 0.2
    done
    if [[ -z "$focused_te" ]]; then
      fail "could not focus a tiled TextEdit before opening Ghostty (focused ${now_focus:-none})"
    fi
    if ! wait_for_stable_geometry; then
      fail "geometry did not settle before the Ghostty new-window test"
    fi
    "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null || fail "pre-Ghostty snapshot failed"
    ghost_pid="$(open_test_ghostty || true)"
    if [[ -z "$ghost_pid" ]]; then
      fail "could not start a test Ghostty instance for Cmd-N"
    else
      if wait_for_pid_count "$ghost_pid" 1; then
        pass "first Ghostty window adopted"
      else
        fail "first Ghostty window was not adopted (managed $(pid_count "$ghost_pid"))"
      fi
      if ! wait_for_stable_geometry; then
        fail "geometry did not settle after the first Ghostty window"
      fi
      verify "after first Ghostty window for Cmd-N"
      "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || true
      moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
      if [[ -n "$moved" ]]; then
        pass "existing tiles reflowed when Ghostty joined"
      else
        fail "no existing tile moved when the first Ghostty window was adopted"
        geometry_table | sed 's/^/      /'
      fi
      kept_ids="$(pid_ids "$ghost_pid")"
      for n in 1 2; do
        front="$(focus_pid "$ghost_pid")"
        if [[ "$front" != "$ghost_pid" ]]; then
          fail "Cmd-N $n not sent: frontmost pid is ${front:-none}, test pid is $ghost_pid"
          break
        fi
        ghostty_new_window
        want=$((n + 1))
        sleep 0.6
        if wait_for_pid_count "$ghost_pid" "$want"; then
          if ! wait_for_stable_geometry; then
            fail "geometry did not settle after Cmd-N $n"
          fi
          managed="$(pid_count "$ghost_pid")"
          if [[ "$managed" -eq "$want" ]]; then
            pass "after Cmd-N $n: Ghostty has $want managed windows"
          else
            fail "after Cmd-N $n: Ghostty settled at $managed managed windows (want $want)"
            geometry_table | sed 's/^/      /'
          fi
        else
          fail "after Cmd-N $n: Ghostty has $(pid_count "$ghost_pid") managed windows (want $want)"
          geometry_table | sed 's/^/      /'
        fi
        missing=""
        now_ids="$(pid_ids "$ghost_pid")"
        for id in $kept_ids; do
          case " $now_ids " in
            *" $id "*) ;;
            *) missing="$missing $id" ;;
          esac
        done
        if [[ -z "$missing" ]]; then
          pass "after Cmd-N $n: earlier Ghostty windows stayed in the model"
        else
          fail "after Cmd-N $n: Ghostty windows left the model:$missing"
        fi
        problems="$(pid_onscreen_problems "$ghost_pid")"
        if [[ -n "$problems" ]]; then
          fail "after Cmd-N $n: Ghostty windows overlap or sit outside the model"
          printf '%s\n' "$problems" | sed 's/^/      /'
        else
          pass "after Cmd-N $n: on-screen Ghostty windows match their tiles"
        fi
        verify "after Ghostty Cmd-N $n"
        kept_ids="$now_ids"
      done
      "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null || true
      moved="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
      te_moved=""
      for id in $te_ids; do
        case " $moved " in
          *" $id "*) te_moved="$te_moved $id" ;;
        esac
      done
      if [[ -n "$te_moved" ]]; then
        pass "TextEdit still reflowed after Cmd-N:$te_moved"
      else
        # The focused TextEdit is the split target. Later Cmd-N presses
        # split the Ghostty side, so that TextEdit stays off its original
        # frame. Matching the snapshot means the new windows never joined.
        fail "TextEdit frames match the pre-Ghostty snapshot after Cmd-N (ids: $te_ids)"
        geometry_table | sed 's/^/      /'
      fi
      kill "$ghost_pid" >/dev/null 2>&1 || true
      if wait_for_pid_count "$ghost_pid" 0; then
        pass "Cmd-N test Ghostty instance removed"
      else
        fail "Cmd-N test Ghostty instance still managed"
      fi
      verify "after Ghostty new-window cleanup"
    fi
  fi
fi

# The showcase opens Ghostty across workspaces 2-5 and fills workspace 3 to
# the largest set that still tiles. This section checks that sequence with
# assertions and then puts the windows away. It does not quit Lumina.
# Nine is the measured maximum on a 1454x907 tile area (8pt gaps): the
# tenth window's live frame overlaps a neighbour.
if [[ "${GHOSTTY_SPACES_TEST:-1}" != "0" ]]; then
  say "ghostty across workspaces"
  GHOSTTY_CROWD=9
  space1_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
print(" ".join(str(w["cgWindowId"]) for w in json.load(sys.stdin).get("windows", []) if w.get("space") == 1))
' 2>/dev/null || true)"
  spawned=""
  LAST_OPENED_PID=""
  open_ghostty_on() {
    local space="$1" pid=""
    LAST_OPENED_PID=""
    run workspace "$space" >/dev/null
    pid="$(open_test_ghostty || true)"
    if [[ -z "$pid" ]]; then
      fail "could not open a Ghostty on workspace $space"
      return 1
    fi
    spawned="$spawned $pid"
    if wait_for_pid_tiled "$pid" "$space"; then
      LAST_OPENED_PID="$pid"
      return 0
    fi
    fail "Ghostty $pid did not tile on workspace $space"
    return 1
  }
  spawned_on() {
    "$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
space = int(sys.argv[1])
pids = set(int(x) for x in sys.argv[2].split())
print(sum(1 for w in json.load(sys.stdin).get("windows", []) if w.get("space") == space and w.get("pid") in pids and w.get("role") == "tiled"))
' "$1" "$spawned" 2>/dev/null || echo 0
  }

  run workspace 1 >/dev/null
  open_ghostty_on 1 || true
  if [[ "$(spawned_on 1)" -ge 1 ]]; then
    pass "a new Ghostty tiled beside the windows already on workspace 1"
  else
    fail "no new Ghostty tiled on workspace 1"
  fi

  open_ghostty_on 2 || true
  open_ghostty_on 3 || true
  open_ghostty_on 4 || true
  ws4_pid="$LAST_OPENED_PID"

  run workspace 5 >/dev/null
  verify "on empty workspace 5"
  if [[ "$(spawned_on 5)" == "0" ]]; then
    pass "workspace 5 has no demo Ghostty"
  else
    fail "workspace 5 has $(spawned_on 5) demo Ghosttys"
  fi

  run workspace 2 >/dev/null
  for _ in 1 2 3 4; do
    open_ghostty_on 2 || true
  done
  if [[ "$(spawned_on 2)" == "5" ]]; then
    pass "workspace 2 has 5 tiled Ghosttys"
  else
    fail "workspace 2 has $(spawned_on 2) tiled Ghosttys (want 5)"
  fi
  focus_before="$(focused_window_id)"
  run focus right >/dev/null
  focus_after="$(focused_window_id)"
  if [[ -n "$focus_before" && "$focus_after" != "$focus_before" ]]; then
    pass "focus right moved among the five Ghosttys"
  else
    run focus down >/dev/null
    focus_after="$(focused_window_id)"
    if [[ -n "$focus_before" && "$focus_after" != "$focus_before" ]]; then
      pass "focus down moved among the five Ghosttys"
    else
      fail "focus did not move on the five-Ghostty workspace"
    fi
  fi
  swap_id="$(focused_window_id)"
  swap_before="$(window_frame "$swap_id")"
  run swap right >/dev/null
  swap_after="$(window_frame "$swap_id")"
  if [[ -n "$swap_before" && "$swap_after" != "$swap_before" ]]; then
    pass "swap right moved a Ghostty tile"
  else
    run swap down >/dev/null
    swap_after="$(window_frame "$swap_id")"
    if [[ -n "$swap_before" && "$swap_after" != "$swap_before" ]]; then
      pass "swap down moved a Ghostty tile"
    else
      fail "swap did not move a Ghostty tile on workspace 2"
    fi
  fi
  verify "after ghostty focus and swap"

  if "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null && [[ -s "$TMP_BEFORE" ]]; then
    run resize grow >/dev/null
    if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
      grown="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
      if [[ -n "$grown" ]]; then
        pass "ghostty resize grow moved:$grown"
      else
        fail "ghostty resize grow did not move a window"
      fi
    else
      fail "geometry snapshot after ghostty resize grow failed"
    fi
    if "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null && [[ -s "$TMP_BEFORE" ]]; then
      run resize shrink >/dev/null
      if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
        shrunk="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
        if [[ -n "$shrunk" ]]; then
          pass "ghostty resize shrink moved:$shrunk"
        else
          fail "ghostty resize shrink did not move a window"
        fi
      else
        fail "geometry snapshot after ghostty resize shrink failed"
      fi
    fi
    run resize grow >/dev/null
    if "$LUMINA" list-windows > "$TMP_BEFORE" 2>/dev/null && [[ -s "$TMP_BEFORE" ]]; then
      run balance >/dev/null
      if "$LUMINA" list-windows > "$TMP_AFTER" 2>/dev/null && [[ -s "$TMP_AFTER" ]]; then
        balanced="$(geometry_moves "$TMP_BEFORE" "$TMP_AFTER")"
        if [[ -n "$balanced" ]]; then
          pass "ghostty balance moved:$balanced"
        else
          fail "ghostty balance did not move a window"
        fi
      else
        fail "geometry snapshot after ghostty balance failed"
      fi
    fi
  else
    fail "geometry snapshot before ghostty resize failed"
  fi

  float_id="$(focused_window_id)"
  run float-toggle >/dev/null
  if [[ "$(window_field "$float_id" role)" == "floating" ]]; then
    pass "ghostty $float_id floated"
  else
    fail "ghostty $float_id did not float (role $(window_field "$float_id" role))"
  fi
  run float-toggle >/dev/null
  if [[ "$(window_field "$float_id" role)" == "tiled" ]]; then
    pass "ghostty $float_id tiled again"
  else
    fail "ghostty $float_id did not retile (role $(window_field "$float_id" role))"
  fi

  fs_id="$(focused_window_id)"
  run fullscreen lumina >/dev/null
  sleep 0.5
  if [[ "$(window_field "$fs_id" role)" == "luminaFS" ]]; then
    pass "ghostty $fs_id is lumina fullscreen"
  else
    fail "ghostty $fs_id did not enter lumina fullscreen (role $(window_field "$fs_id" role))"
  fi
  if [[ "$(count_role_on_space 2 stashed)" -ge 1 ]]; then
    pass "fullscreen parked the other windows"
  else
    fail "fullscreen left no stashed window on workspace 2"
  fi
  run fullscreen lumina >/dev/null
  sleep 0.6
  if [[ "$(window_field "$fs_id" role)" == "tiled" && "$(spawned_on 2)" == "5" ]]; then
    pass "fullscreen exit restored the five Ghosttys"
  else
    fail "fullscreen exit left ghostty $fs_id role $(window_field "$fs_id" role), workspace 2 has $(spawned_on 2)"
  fi
  verify "after ghostty resize float and fullscreen"

  move_id="$(focused_window_id)"
  run move-node-to-workspace 5 >/dev/null
  sleep 0.5
  if [[ "$(window_field "$move_id" space)" == "5" ]]; then
    pass "moved Ghostty $move_id onto the empty workspace"
  else
    fail "Ghostty $move_id did not land on workspace 5 (space $(window_field "$move_id" space))"
  fi
  run move-node-to-workspace 2 >/dev/null
  sleep 0.5
  if [[ "$(window_field "$move_id" space)" == "2" && "$(spawned_on 2)" == "5" && "$(spawned_on 5)" == "0" ]]; then
    pass "moved Ghostty $move_id back, workspace 5 empty again"
  else
    fail "move back failed: space $(window_field "$move_id" space), workspace 2 has $(spawned_on 2), workspace 5 has $(spawned_on 5)"
  fi

  # A tab is another window inside the same tile. Cmd-N is a new tile.
  # Ghostty's native fullscreen replaces the window, so this stays on the
  # ordinary tiled window and never sends keys to any other process.
  if [[ -n "$ws4_pid" ]]; then
    run workspace 4 >/dev/null
    front="$(focus_pid "$ws4_pid")"
    if [[ "$front" == "$ws4_pid" ]]; then
      "$LUMINA" debug-ax "$ws4_pid" >/dev/null 2>&1 && pass "debug-ax answered for Ghostty $ws4_pid" || fail "debug-ax failed for Ghostty $ws4_pid"
      tabs_before="$(pid_count "$ws4_pid")"
      ghostty_new_tab
      sleep 1.1
      if [[ "$(pid_count "$ws4_pid")" == "$tabs_before" ]]; then
        pass "Cmd-T kept Ghostty $ws4_pid at $tabs_before tile"
      else
        fail "Cmd-T changed Ghostty $ws4_pid from $tabs_before windows to $(pid_count "$ws4_pid")"
      fi
      ghostty_new_window
      if wait_for_pid_count "$ws4_pid" "$((tabs_before + 1))"; then
        pass "Cmd-N opened another tiled window of Ghostty $ws4_pid"
      else
        fail "Cmd-N left Ghostty $ws4_pid at $(pid_count "$ws4_pid") windows"
      fi
    else
      fail "could not focus Ghostty $ws4_pid for tabs (frontmost ${front:-none})"
    fi
    # Native fullscreen replaces the Ghostty window. Exit has to bring a
    # normal tile back; a screen-sized leftover is closed so it cannot
    # overlap the rest of the tour.
    run workspace 4 >/dev/null
    run fullscreen native >/dev/null
    sleep 1.4
    run fullscreen native >/dev/null
    if wait_for_pid_tiled "$ws4_pid" 4; then
      native_w="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pid = int(sys.argv[1])
widths = [w.get("w") or 0 for w in json.load(sys.stdin).get("windows", []) if w.get("pid") == pid]
print(int(max(widths) if widths else 0))
' "$ws4_pid" 2>/dev/null || echo 0)"
      if [[ "${native_w:-0}" -lt 1200 ]]; then
        pass "native fullscreen returned Ghostty $ws4_pid to a tile"
      else
        fail "native fullscreen left Ghostty $ws4_pid screen-sized (${native_w}pt wide)"
        kill -9 "$ws4_pid" >/dev/null 2>&1 || true
        spawned="${spawned// $ws4_pid/}"
      fi
    else
      fail "native fullscreen did not retile Ghostty $ws4_pid"
      kill -9 "$ws4_pid" >/dev/null 2>&1 || true
      spawned="${spawned// $ws4_pid/}"
    fi
  fi

  run workspace 3 >/dev/null
  while [[ "$(spawned_on 3)" -lt "$GHOSTTY_CROWD" ]]; do
    open_ghostty_on 3 || break
  done
  crowd_now="$(spawned_on 3)"
  if [[ "$crowd_now" == "$GHOSTTY_CROWD" ]]; then
    pass "workspace 3 has $GHOSTTY_CROWD tiled Ghosttys"
  else
    fail "workspace 3 has $crowd_now tiled Ghosttys (want $GHOSTTY_CROWD)"
  fi
  if ! wait_for_stable_geometry; then
    fail "geometry did not settle at $GHOSTTY_CROWD Ghosttys"
  fi
  crowd_pids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pids = set(int(x) for x in sys.argv[1].split())
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", []) if w.get("space") == 3 and w.get("pid") in pids))
' "$spawned" 2>/dev/null || true)"
  overlap="$(live_overlap_pids "$crowd_pids")"
  if [[ -z "$overlap" ]]; then
    pass "nine Ghosttys do not overlap"
  else
    fail "nine Ghosttys overlap"
    printf '%s\n' "$overlap" | sed 's/^/      /'
  fi
  verify "after nine ghosttys"

  extra="$(open_test_ghostty || true)"
  if [[ -n "$extra" ]]; then
    spawned="$spawned $extra"
    for _ in 1 2 3 4 5 6 7 8; do
      [[ "$(pid_count "$extra")" == "1" ]] && break
      sleep 0.25
    done
    sleep 2.2
    extra_role="$(window_field "$(pid_ids "$extra" | awk '{print $1}')" role)"
    extra_overlap="$(live_overlap_pids "$crowd_pids $extra")"
    if [[ "$extra_role" == "floating" || -n "$extra_overlap" ]]; then
      pass "a tenth Ghostty is past the no-overlap maximum"
    else
      fail "a tenth Ghostty still tiles without overlapping (role ${extra_role:-missing})"
    fi
    run close >/dev/null
    if wait_for_pid_count "$extra" 0; then
      pass "lumina close removed the tenth Ghostty"
      spawned="${spawned// $extra/}"
    else
      fail "lumina close left the tenth Ghostty $extra managed"
    fi
    if ! wait_for_stable_geometry; then
      fail "geometry did not settle after closing the tenth Ghostty"
    fi
    rest_pids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
pids = set(int(x) for x in sys.argv[1].split())
print(" ".join(str(w["pid"]) for w in json.load(sys.stdin).get("windows", []) if w.get("space") == 3 and w.get("pid") in pids and w.get("role") == "tiled"))
' "$spawned" 2>/dev/null || true)"
    rest_overlap="$(live_overlap_pids "$rest_pids")"
    if [[ "$(spawned_on 3)" == "$GHOSTTY_CROWD" && -z "$rest_overlap" ]]; then
      pass "closing the extra reflowed the nine Ghosttys"
    else
      fail "after closing the extra, workspace 3 has $(spawned_on 3) tiled Ghosttys"
      [[ -n "$rest_overlap" ]] && printf '%s\n' "$rest_overlap" | sed 's/^/      /'
    fi
    reflow_before="$(spawned_on 3)"
    run close >/dev/null
    sleep 0.6
    reflow_after="$(spawned_on 3)"
    if [[ "$reflow_after" -lt "$reflow_before" ]]; then
      pass "closing one Ghostty reflowed the rest ($reflow_before -> $reflow_after)"
    else
      fail "close did not remove a tiled Ghostty on workspace 3 (still $reflow_after)"
    fi
    verify "after ghostty reflow"
  else
    fail "could not open the tenth Ghostty"
  fi

  for p in $spawned; do
    kill "$p" >/dev/null 2>&1 || true
  done
  sleep 0.8
  for p in $spawned; do
    kill -9 "$p" >/dev/null 2>&1 || true
  done
  gone=1
  for p in $spawned; do
    if ! wait_for_pid_count "$p" 0; then
      gone=0
      fail "Ghostty $p is still managed after cleanup"
    fi
  done
  if (( gone == 1 )); then
    pass "demo Ghosttys left the model"
  fi
  run workspace 1 >/dev/null
  missing=""
  now_ids="$("$LUMINA" list-windows 2>/dev/null | python3 -c '
import json, sys
print(" ".join(str(w["cgWindowId"]) for w in json.load(sys.stdin).get("windows", [])))
' 2>/dev/null || true)"
  for id in $space1_ids; do
    case " $now_ids " in
      *" $id "*) ;;
      *) missing="$missing $id" ;;
    esac
  done
  if [[ -z "$missing" ]]; then
    pass "workspace 1 kept its windows through the Ghostty tour"
  else
    fail "workspace 1 lost windows:$missing"
  fi
  verify "after ghostty workspace cleanup"
fi

# Shield recovery: a crash or force-quit can leave a hide-until-tiled app
# hidden with no in-memory state to reveal it. Boot must unhide it. Off by
# default because it quits and restarts the agent (which recenters windows).
if [[ "${SHIELD_BOOT_TEST:-0}" == "1" && -f "$CONFIG_PATH" ]]; then
  say "launch concealment: hidden app revealed after agent restart"
  set_config_top_level hide-until-tiled-apps '["com.apple.TextEdit"]'
  "$LUMINA" reload >/dev/null 2>&1
  sleep 0.3
  boot_json="$(measure_launch TextEdit 8)"
  boot_pid="$(printf '%s' "$boot_json" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("pid") or "")
except Exception: print("")' 2>/dev/null)"
  if [[ -z "$boot_pid" ]]; then
    fail "shield boot test: no test instance was launched"
  else
    # Simulate a stranded app: hide it by hand, then restart the agent.
    osascript -e "tell application \"System Events\" to set visible of first process whose unix id is $boot_pid to false" >/dev/null 2>&1 || true
    sleep 0.5
    "$LUMINA" quit >/dev/null 2>&1 || true
    sleep 2.5
    "$LUMINA" start >/dev/null 2>&1 || true
    sleep 6
    boot_visible="$(osascript -e "tell application \"System Events\" to get visible of first process whose unix id is $boot_pid" 2>/dev/null || true)"
    if [[ "$boot_visible" == "true" ]]; then
      pass "boot revealed an app left hidden by the previous agent"
    else
      fail "app still hidden after agent restart (visible=$boot_visible)"
    fi
    kill_test_instance "$boot_pid" >/dev/null 2>&1 || true
  fi
  restore_config
  verify "after shield boot recovery"
fi

if [[ "${QUIT_TEST:-0}" == "1" ]]; then
  # Quit restore is the other reported failure: windows left parked
  # off-screen or at sliver sizes. The agent logs one restore per managed
  # window; check every target is a usable size, then confirm it exited.
  say "quit restore leaves windows usable (QUIT_TEST=1)"
  log_file="${LUMINA_LOG:-$HOME/Library/Logs/Lumina.log}"
  managed_before="$(managed_count)"
  marker="$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')"
  if [[ -z "$marker" ]]; then
    fail "cannot read agent log at $log_file"
    marker=0
  fi
  "$LUMINA" quit >/dev/null 2>&1 || true
  exited=1
  for _ in $(seq 1 30); do
    if ! pgrep -f lumina-agent >/dev/null 2>&1; then
      exited=0
      break
    fi
    sleep 0.5
  done
  if [[ $exited -ne 0 ]]; then
    fail "lumina-agent did not exit after quit"
  fi
  sleep 1
  new_lines="$(tail -n "+$((marker + 1))" "$log_file" 2>/dev/null || true)"
  restored="$(printf '%s\n' "$new_lines" | grep -c 'quit restore' || true)"
  if [[ "$restored" -ge "$managed_before" ]]; then
    pass "logged $restored restores for $managed_before managed windows"
  else
    fail "only $restored restore logs for $managed_before managed windows"
  fi
  slivers="$(printf '%s\n' "$new_lines" | grep 'quit restore' | grep -Ev 'target=[0-9]{3,}x[0-9]{3,}' | wc -l | tr -d ' ')"
  if [[ "$slivers" == "0" ]]; then
    pass "every restore target is a usable size"
  else
    fail "$slivers restore targets are slivers or tiny"
  fi
  TRACKED_IDS=""
  pkill -x TextEdit >/dev/null 2>&1 || true
else
  if [[ "$KEEP_WINDOWS" != "1" ]]; then
    say "closing test windows"
    TRACKED_IDS=""
    close_windows
    if wait_for_count "$baseline"; then
      pass "baseline restored"
    else
      fail "windows did not close: $(managed_count) managed (baseline $baseline)"
    fi
    verify "after close"
  else
    say "KEEP_WINDOWS=1: leaving documents open"
  fi
fi

if [[ -n "$ARTIFACTS" ]]; then
  printf '\nartifacts: %s\n' "$ARTIFACTS"
fi
if [[ $FAILURES -eq 0 ]]; then
  printf '\nharness: PASS (%d verify steps)\n' "$STEP"
  exit 0
fi
printf '\nharness: FAIL (%d failures)\n' "$FAILURES"
exit 1
