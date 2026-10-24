#!/usr/bin/env python3
"""Turns the raw files from scripts/perf.sh into summary.json and a short table, and checks budgets."""
import json
import re
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

out = Path(sys.argv[1])
arch = sys.argv[2]
budget_overlay, budget_preview, budget_idle_cpu = float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
budget_leaks, budget_hang, check = int(sys.argv[6]), float(sys.argv[7]), sys.argv[8] == "1"
seconds = float(sys.argv[9])  # length of the idle sample


def stats(values):
    if not values:
        return None
    values = sorted(values)
    return {"n": len(values), "median": round(statistics.median(values), 1),
            "p90": round(values[min(len(values) - 1, int(len(values) * 0.9))], 1),
            "min": round(values[0], 1), "max": round(values[-1], 1)}


# Marks are timed from the trigger before them; spans are timed on their own.
marks, spans = defaultdict(list), defaultdict(list)
first = {}
for line in (out / "perf.ndjson").read_text().splitlines():
    try:
        message = json.loads(line).get("eventMessage", "")
    except json.JSONDecodeError:
        continue
    parts = message.split()
    if len(parts) == 3 and parts[0] in ("mark", "span"):
        value = float(parts[2])
        (marks if parts[0] == "mark" else spans)[parts[1]].append(value)
        first.setdefault(parts[0] + " " + parts[1], value)


def hyperfine_ms(name):
    path = out / name
    if not path.exists():
        return None
    result = json.loads(path.read_text())["results"][0]
    times = result.get("times")  # hyperfine 1.x
    if times is None:  # hyperfine 2.x
        times = [m["time_wall_clock"]["value"] for m in result.get("measurements", [])]
    return stats([t * 1000 for t in times])


def footprint_mb(name):
    text = (out / name).read_text() if (out / name).exists() else ""
    match = re.search(r"phys_footprint:\s+([\d.]+)\s*(KB|MB|GB)", text)
    if not match:
        return None
    return round(float(match.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[match.group(2)], 1)


leaks_text = (out / "leaks.txt").read_text() if (out / "leaks.txt").exists() else ""
leak_match = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", leaks_text)
leaks_total = int(leak_match.group(1)) if leak_match else None
# macOS's own XPC connections (e.g. com.apple.linkd for Shortcuts) show up as leaked cycles in every
# app; count only the rest against the budget. Root lines look like "   96 (4.69K) ROOT CYCLE: <...>".
roots = re.findall(r"^( *)(\d+) \([^)]*\) (?:\S+ --> )?ROOT (?:CYCLE|LEAK): (.*)$", leaks_text, re.M)
top = min((len(indent) for indent, _, _ in roots), default=0)  # nested roots are counted by their parent
system_leaks = sum(int(count) for indent, count, rest in roots
                   if len(indent) == top and re.search(r'"com\.apple\.[^"]*"', rest))
leaks = None if leaks_total is None else leaks_total - system_leaks

idle_cpu = idle_wakeups = None
idle_lines = [l.split() for l in (out / "idle.txt").read_text().splitlines() if re.match(r"^\s*\d+\s", l)]
if idle_lines:
    # top prints one line per sample; the first covers no time. IDLEW is a running total, so the
    # wake-ups are the last total minus the first ("+" marks a total too wide for the column).
    samples = idle_lines[1:] or idle_lines
    idle_cpu = round(sum(float(l[1]) for l in samples) / len(samples), 2)
    idle_wakeups = round((int(idle_lines[-1][2].rstrip("+")) - int(idle_lines[0][2].rstrip("+"))) / seconds, 2)


def time_profile():
    """Heaviest functions on the main thread, by samples (inclusive and self)."""
    path = out / "time-profile.xml"
    if not path.exists() or path.stat().st_size == 0:
        return None
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return None
    by_id = {el.get("id"): el for el in root.iter() if el.get("id")}

    def resolve(el):
        return by_id.get(el.get("ref"), el) if el is not None and el.get("ref") else el

    samples = []  # (thread id, [frame names, leaf first])
    for row in root.iter("row"):
        thread = resolve(row.find("thread"))
        tid = resolve(thread.find("tid")) if thread is not None else None
        tagged = resolve(row.find("tagged-backtrace"))
        backtrace = resolve(tagged.find("backtrace") if tagged is not None else row.find("backtrace"))
        if tid is None or backtrace is None:
            continue
        names = [resolve(f).get("name") or "?" for f in backtrace.findall("frame")]
        if names:
            samples.append((tid.text, names))
    # The main thread is the one running the app's run loop.
    main = Counter(t for t, names in samples if "NSApplicationMain" in names or "-[NSApplication run]" in names)
    if not main:
        return {"main_thread_samples": 0, "top_inclusive": [], "top_self": []}
    main_tid = main.most_common(1)[0][0]
    inclusive, leaf, total = Counter(), Counter(), 0
    for tid, names in samples:
        if tid != main_tid:
            continue
        total += 1
        leaf[names[0]] += 1
        for name in set(names):
            inclusive[name] += 1
    return {"main_thread_samples": total,
            "top_inclusive": inclusive.most_common(40), "top_self": leaf.most_common(15)}


def hangs():
    path = out / "hangs.xml"
    if not path.exists() or path.stat().st_size == 0:
        return []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        return []
    by_id = {el.get("id"): el for el in root.iter() if el.get("id")}
    result = []
    for row in root.iter("row"):
        duration = row.find("duration")
        if duration is not None and duration.get("ref"):
            duration = by_id.get(duration.get("ref"))
        if duration is not None and duration.text:
            result.append(round(int(duration.text) / 1e6, 1))  # nanoseconds → ms
    return result


hang_list = hangs()
summary = {
    "arch": arch,
    "launch_to_ready_ms": int((out / "launch_ms.txt").read_text()) if (out / "launch_ms.txt").exists() else None,
    "preview_card_ms": stats(marks["preview.shown"]),
    "overlay_drawn_ms": stats(marks["overlay.drawn"]),
    "first_preview_card_ms": first.get("mark preview.shown"),
    "first_overlay_ms": first.get("mark overlay.drawn"),
    "spans_ms": {name: stats(values) for name, values in sorted(spans.items())},
    "cli_screenshot_cold_ms": hyperfine_ms("cli_cold.json"),
    "cli_screenshot_warm_ms": hyperfine_ms("cli_warm.json"),
    "footprint_mb_before": footprint_mb("footprint_before.txt"),
    "footprint_mb_after": footprint_mb("footprint_after.txt"),
    "leaks": leaks,
    "leaks_total_including_macos": leaks_total,
    "idle_cpu_percent": idle_cpu,
    "idle_wakeups_per_second": idle_wakeups,
    "hangs_ms": hang_list,
    "time_profile": time_profile(),
}
(out / "summary.json").write_text(json.dumps(summary, indent=2))

checks = [
    ("Shortcut → overlay drawn (median ms)", (summary["overlay_drawn_ms"] or {}).get("median"), budget_overlay),
    ("Capture → preview card (median ms)", (summary["preview_card_ms"] or {}).get("median"), budget_preview),
    ("Idle CPU (%)", idle_cpu, budget_idle_cpu),
    ("Leaks", leaks, budget_leaks),
    ("Longest hang (ms)", max(hang_list) if hang_list else 0, budget_hang),
]
print(f"\nResults ({arch}) in {out}")
failed = False
for name, value, budget in checks:
    ok = value is not None and value <= budget
    failed |= not ok
    print(f"  {'PASS' if ok else 'OVER' if value is not None else 'N/A '}  {name}: {value}  (budget {budget})")
print(f"  info  Idle wake-ups/s: {idle_wakeups}   Memory: {summary['footprint_mb_before']} → "
      f"{summary['footprint_mb_after']} MB   Launch: {summary['launch_to_ready_ms']} ms")
for name, s in summary["spans_ms"].items():
    if s:
        print(f"  span  {name}: median {s['median']} ms, p90 {s['p90']} ms (n={s['n']})")
if check and failed:
    sys.exit(1)
