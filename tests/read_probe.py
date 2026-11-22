"""Summarizes NyteFramesProbeDB from the game's SavedVariables file.

    python tests/read_probe.py                 # finds the file under _forever_\\WTF
    python tests/read_probe.py path\\to\\NyteFrames.lua
    python tests/read_probe.py --out docs\\probe-raw.md

Prints, per context (ooc/combat/encounter @ instance type), which fields are
readable (ok), secret, nil or erroring for each unit token, plus fights,
inspects, display tests, events and errors.
"""
import glob
import os
import sys

from lupa.lua51 import LuaRuntime

WOW = r"C:\Program Files (x86)\World of Warcraft\_forever_\WTF\Account"


def find_sv():
    hits = glob.glob(os.path.join(WOW, "*", "SavedVariables", "NyteFrames.lua"))
    if not hits:
        sys.exit("NyteFrames.lua not found under " + WOW + " (did you /reload after playing?)")
    return max(hits, key=os.path.getmtime)


def py(v):
    if hasattr(v, "items"):
        d = {k: py(x) for k, x in v.items()}
        if d and sorted(d) == list(range(1, len(d) + 1)):
            return [d[k] for k in sorted(d)]
        return d
    return v


def short(counts):
    if not isinstance(counts, dict):
        return str(counts)
    total = sum(counts.values())
    parts = sorted(counts.items(), key=lambda kv: -kv[1])
    if len(parts) == 1:
        return parts[0][0]
    return " ".join(f"{k}:{round(100 * n / total)}%" for k, n in parts)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_path = None
    if "--out" in sys.argv:
        out_path = sys.argv[sys.argv.index("--out") + 1]
        args = [a for a in args if a != out_path]
    path = args[0] if args else find_sv()
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(path, encoding="utf-8", errors="replace") as f:
        lua.execute(f.read())
    db = py(lua.eval("NyteFramesProbeDB"))
    if not db:
        sys.exit("NyteFramesProbeDB is empty in " + path)
    lines = [f"# Nyte Frames probe ({path})", ""]
    s = db.get("static", {})
    lines += [f"- build {s.get('build')}, interface {s.get('interface')}, project {s.get('projectId')}, "
              f"class {s.get('playerClass')}",
              f"- samples {db.get('samples')}, fights {len(db.get('fights', []))}, "
              f"inspects {len(db.get('inspects', []))}, sessions {len(db.get('sessions', []))}", ""]
    for key in ("apis", "globals", "templates", "frameMethods", "blizzard", "events"):
        lines.append(f"## {key}")
        val = s.get(key, {})
        if isinstance(val, dict):
            missing = sorted(k for k, v in val.items() if v is False or v == "missing")
            present = sorted(k for k, v in val.items() if not (v is False or v == "missing"))
            if key in ("apis", "events"):
                lines.append("missing: " + (", ".join(missing) or "none"))
            else:
                for k in sorted(val):
                    lines.append(f"- {k}: {val[k]}")
        lines.append("")
    lines.append("## ownTalents")
    lines.append(str(s.get("ownTalents")))
    for name in ("displayPlayer",):
        lines += ["", f"## display tests: {name} (out of combat)"]
        for k, v in sorted((s.get(name) or {}).items()):
            lines.append(f"- {k}: {v}")
    for name in ("displayCombat", "displayCombatParty"):
        lines += ["", f"## display tests: {name}"]
        for k, v in sorted((db.get(name) or {}).items()):
            lines.append(f"- {k}: {v}")
    lines.append("")
    for ctx, units in sorted(db.get("agg", {}).items()):
        lines.append(f"## {ctx}")
        for unit, fields in sorted(units.items()):
            row = [f"{f}={short(c)}" for f, c in sorted(fields.items())]
            lines.append(f"- **{unit}**: " + ", ".join(row))
        lines.append("")
    lines.append("## first error per field")
    for k, v in sorted(db.get("errs", {}).items()):
        lines.append(f"- {k}: {v}")
    lines += ["", "## plain values seen"]
    for k, v in sorted(db.get("examples", {}).items()):
        lines.append(f"- {k}: {v}")
    lines += ["", "## fights"]
    for f in db.get("fights", []):
        lines.append(f"- {f.get('zone')} [{f.get('inst')}/{f.get('group')} {f.get('size')}] "
                     f"{f.get('dur')}s, {f.get('samples')} samples, boss tokens {f.get('boss') or '-'}, "
                     f"boss targets {f.get('bossTargets') or '-'}")
    lines += ["", "## inspects"]
    for i in db.get("inspects", []):
        lines.append(f"- {i}")
    lines += ["", "## event counts"]
    for ctx, evs in sorted(db.get("eventCounts", {}).items()):
        lines.append(f"- {ctx}: " + "; ".join(f"{e} {c}" for e, c in sorted(evs.items())))
    lines += ["", "## events (last 150)"]
    lines += [f"- {e}" for e in db.get("events", [])[-150:]]
    lines += ["", "## aura payload (UNIT_AURA updateInfo; debuff highlight part A)"]
    for ctx, units in sorted(db.get("agg", {}).items()):
        for unit, fields in sorted(units.items()):
            row = [f"{f}={short(c)}" for f, c in sorted(fields.items()) if f.startswith("payload")]
            if row:
                lines.append(f"- {ctx} **{unit}**: " + ", ".join(row))
    lines += ["", "## mana tick intervals (seconds: count; 2.0 = classic ticks)"]
    mt = db.get("manaTicks") or {}
    iv = mt.get("intervals") or {}
    if isinstance(iv, list):
        iv = {i + 1: v for i, v in enumerate(iv)}
    lines.append("- " + (", ".join(f"{int(k) / 10:.1f}s: {v}" for k, v in sorted(iv.items(), key=lambda kv: int(kv[0])))
                          or "none recorded") + f" (phase locked: {mt.get('locked')})")
    lines += ["", "## perf (/nf perf, newest first)"]
    for r in db.get("perf", []) or []:
        lines.append(f"- {r.get('at')} v{r.get('version')} {r.get('context')}: {r.get('seconds', 0):.0f}s, "
                     f"{r.get('calls')} runs, {r.get('msPerSec', 0):.2f} ms/s, peak {r.get('peakMs', 0):.2f} ms, "
                     f"mem {r.get('memKB') or 0:.0f} KB")
        for x in (r.get("rows") or [])[:12]:
            n = x.get("n") or 1
            lines.append(f"  - {x.get('name')}: {x.get('n')} runs, {x.get('ms', 0):.2f} ms, "
                         f"avg {x.get('ms', 0) / n:.3f}, max {x.get('max', 0):.2f}")
    lines += ["", "## errors"]
    lines += [f"- {e}" for e in db.get("errors", [])] or ["- none"]
    text = "\n".join(lines)
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote " + out_path)
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(text)


if __name__ == "__main__":
    main()
