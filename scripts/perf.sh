#!/bin/bash
# Measures how fast Clarishot captures, what it costs while idle, its memory and leaks, and saves
# the raw numbers and an Instruments trace under build/perf/<label>/.
#
#   ./scripts/perf.sh [label]          e.g. ./scripts/perf.sh baseline
#   RUNS=30 APP=build/Clarishot.app ./scripts/perf.sh
#   ./scripts/perf.sh --check [label]  also fail if a result is over budget (used by release.sh)
#
# It runs a copy of the built app with its own empty home folder (CFFIXED_USER_HOME), so your
# settings, history and Desktop are not touched. Your own Clarishot is quit for the test and
# reopened afterwards. The screen flashes while it runs (about 6 minutes). The copy
# is re-signed so `leaks` may read it. Needs Screen Recording allowed for Clarishot, and runs
# from a normal Terminal (not a sandbox), because it launches apps and reads the system log.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
if [ "${1:-}" = "--check" ]; then CHECK=1; shift; fi
LABEL=${1:-$(date +%Y%m%d-%H%M%S)}
RUNS=${RUNS:-30}
CAPTURES=${CAPTURES:-100}
IDLE_SECONDS=${IDLE_SECONDS:-60}
SRC_APP=${APP:-build/Clarishot.app}
ARCH=${ARCH:-$(uname -m)}   # ARCH=x86_64 runs the Intel half under Rosetta

# Budgets (milliseconds, %, count). release.sh fails when one is exceeded.
BUDGET_OVERLAY_MS=${BUDGET_OVERLAY_MS:-50}
BUDGET_PREVIEW_MS=${BUDGET_PREVIEW_MS:-150}
BUDGET_IDLE_CPU=${BUDGET_IDLE_CPU:-0.1}
# One 32-byte "leak" is always reported: a Swift weak-reference side table, which `leaks` can't
# see is in use (Swift stores its pointer encoded). It doesn't grow; anything more is a real leak.
BUDGET_LEAKS=${BUDGET_LEAKS:-1}
BUDGET_HANG_MS=${BUDGET_HANG_MS:-250}

OUT="$PWD/build/perf/$LABEL"
rm -rf "$OUT" && mkdir -p "$OUT"
[ -d "$SRC_APP" ] || { echo "error: $SRC_APP not found; run ./scripts/build-app.sh first" >&2; exit 1; }

# A debuggable copy: same identity plus get-task-allow for leaks. It always lives at the same path,
# so macOS asks to allow screen recording for it only once.
APP="$PWD/build/perf/Clarishot.app"
rm -rf "$APP" && ditto "$SRC_APP" "$APP"
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[ -n "$IDENTITY" ] || IDENTITY=-
cp Resources/Clarishot.entitlements "$OUT/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$OUT/entitlements.plist" >/dev/null
codesign --force --sign "$IDENTITY" --entitlements "$OUT/entitlements.plist" "$APP" 2>/dev/null
CLI="$APP/Contents/Helpers/clarishot"

# Short path: the app's socket lives under it, and Unix socket paths are limited to 104 bytes.
HOME_DIR=$(mktemp -d /tmp/clarishot-perf.XXXXXX)
export CFFIXED_USER_HOME="$HOME_DIR"   # the CLI finds the copy's socket here too

# Only one Clarishot at a time: quit yours for the test (same shortcuts), and reopen it afterwards.
REOPEN=""
for running in $(pgrep -x Clarishot || true); do
    REOPEN=$(ps -o comm= -p "$running" | sed 's#/Contents/MacOS/Clarishot$##')
done
if [ -n "$REOPEN" ]; then
    echo "Quitting your Clarishot for the test; it reopens when the test ends."
    osascript -e 'quit app id "com.scottmackey.clarishot"' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -x Clarishot >/dev/null || break; sleep 0.1; done
fi

LOG_PID=""
cleanup() {
    [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null || true
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
    rm -rf "$HOME_DIR"
    # Without the test home, or your Clarishot would start with empty settings.
    if [ -n "$REOPEN" ]; then sleep 1; env -u CFFIXED_USER_HOME open -g "$REOPEN" || true; fi
}
trap cleanup EXIT

/usr/bin/log stream --level debug --style ndjson \
    --predicate 'subsystem == "com.scottmackey.clarishot" AND category == "perf"' > "$OUT/perf.ndjson" 2>/dev/null &
LOG_PID=$!
sleep 1

launch_start=$(python3 -c 'import time; print(time.time())')
open -n -g --arch "$ARCH" --env CFFIXED_USER_HOME="$HOME_DIR" "$APP" --args \
    -allowAgentAccess '<true/>' -allowURLScheme '<true/>' -setupGuideDone '<true/>' \
    -playSounds '<false/>' -previewAutoClose 1 -showMenuBarIcon '<false/>' --perf-cancel-overlay
echo "If macOS asks to allow Clarishot to record the screen, click Allow (waiting up to 2 minutes)…"
for _ in $(seq 1 1200); do
    "$CLI" status 2>/dev/null | grep -q '"screenRecordingAllowed" : true' && break
    sleep 0.1
done
"$CLI" status > "$OUT/status.json" || { echo "error: the app didn't answer; is Screen Recording allowed?" >&2; exit 1; }
python3 -c "import time; print(round((time.time() - $launch_start) * 1000))" > "$OUT/launch_ms.txt"
PID=$(pgrep -f "$APP/Contents/MacOS/Clarishot" | head -1)
grep -q '"screenRecordingAllowed" : true' "$OUT/status.json" || { echo "error: Screen Recording isn't allowed" >&2; exit 1; }

count() { grep -c "\"mark $1 " "$OUT/perf.ndjson" 2>/dev/null || true; }
# Fires a clarishot:// action at the copy and waits for its mark (or 5 s).
fire() {
    local action=$1 mark=$2 before
    before=$(count "$mark")
    open -g -a "$APP" "clarishot://$action"
    for _ in $(seq 1 100); do [ "$(count "$mark")" -gt "$before" ] && break; sleep 0.05; done
}

echo "Measuring capture → preview card ($RUNS runs)…"
for _ in $(seq 1 "$RUNS"); do fire capture-fullscreen preview.shown; sleep 0.6; done
echo "Measuring shortcut → area overlay ($RUNS runs)…"
for _ in $(seq 1 "$RUNS"); do fire capture-area overlay.drawn; sleep 0.4; done

echo "Measuring the command-line screenshot…"
hyperfine -N --warmup 0 --runs 1 --export-json "$OUT/cli_cold.json" "$CLI screenshot" >/dev/null 2>&1 || true
hyperfine -N --warmup 2 --runs "$RUNS" --export-json "$OUT/cli_warm.json" "$CLI screenshot" >/dev/null 2>&1 || true

echo "Recording an Instruments trace (Time Profiler + Hangs) of 10 captures…"
xcrun xctrace record --template 'Time Profiler' --instrument Hangs --attach "$PID" --time-limit 20s \
    --output "$OUT/captures.trace" >/dev/null 2>&1 &
TRACE_PID=$!
sleep 4
for _ in $(seq 1 5); do fire capture-fullscreen preview.shown; sleep 0.8; fire capture-area overlay.drawn; sleep 0.8; done
wait "$TRACE_PID" || true

echo "Memory before and after $CAPTURES captures…"
sleep 3
footprint -p "$PID" > "$OUT/footprint_before.txt" 2>&1 || true
for _ in $(seq 1 "$CAPTURES"); do fire capture-fullscreen preview.shown; sleep 0.3; done
sleep 4
footprint -p "$PID" > "$OUT/footprint_after.txt" 2>&1 || true
leaks "$PID" > "$OUT/leaks.txt" 2>&1 || true

echo "Idle cost over $IDLE_SECONDS s…"
top -l $((IDLE_SECONDS / 5 + 1)) -s 5 -pid "$PID" -stats pid,cpu,idlew,power > "$OUT/idle.txt" 2>&1

kill "$PID" 2>/dev/null || true; PID=""
sleep 1; kill "$LOG_PID" 2>/dev/null || true; LOG_PID=""
xcrun xctrace export --input "$OUT/captures.trace" --xpath '/trace-toc/run/data/table[@schema="time-profile"]' \
    > "$OUT/time-profile.xml" 2>/dev/null || true
xcrun xctrace export --input "$OUT/captures.trace" --xpath '/trace-toc/run/data/table[@schema="potential-hangs"]' \
    > "$OUT/hangs.xml" 2>/dev/null || true

python3 scripts/perf_report.py "$OUT" "$ARCH" "$BUDGET_OVERLAY_MS" "$BUDGET_PREVIEW_MS" "$BUDGET_IDLE_CPU" \
    "$BUDGET_LEAKS" "$BUDGET_HANG_MS" "$CHECK" "$IDLE_SECONDS"
