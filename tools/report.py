#!/usr/bin/env python3
"""**AN SDK.JSONL, JUDGED** the way Antithesis's triage report would: one
verdict per property (src/coverage.zig), over every run whose lines the
file holds. A property is its `id`; its sites are declared (`hit: false`) by
each run, and a run reports the first pass and the first failure of each.

    tools/report.py <sdk.jsonl> [--floor <file>]

FAIL is a property the runs broke: an Always or AlwaysOrUnreachable seen
false, an Unreachable reached. MISS is one they never got to: a Sometimes
never true, a Reachable or an Always never reached. Antithesis fails both;
this exits 1 on a FAIL only, because a MISS is a gap in the runs, not a bug
(README.md, "Where this differs from Antithesis").

**A FLOOR** is the list of properties a run is expected to reach: one message
per line, `#` for comments. With one, a MISS of a property on it fails too,
and so does a line naming no property this run declared, which is a floor
gone stale.
"""
import json
import sys

# The kinds a false condition breaks (Unreachable records its hit as false).
MUST_HOLD = {"Always", "AlwaysOrUnreachable", "Unreachable"}


def read_floor(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]


def main(path, floor=None):
    props = {}
    runs = 0
    with open(path) as f:
        for n, line in enumerate(f, 1):
            try:
                event = json.loads(line)
            except json.JSONDecodeError as e:
                sys.exit(f"{path}:{n}: not JSON ({e}): {line[:120]!r}")
            if "antithesis_sdk" in event:
                runs += 1
                continue
            a = event.get("antithesis_assert")
            if a is None:
                continue
            p = props.setdefault(a["id"], {
                "display": a["display_type"], "where": a["location"],
                "true": 0, "false": 0, "first_false": None,
            })
            if not a["hit"]:
                continue
            if a["condition"]:
                p["true"] += 1
            else:
                p["false"] += 1
                if p["first_false"] is None:
                    p["first_false"] = a.get("details")

    broken = 0
    rows = []
    for id_, p in props.items():
        d, t, f = p["display"], p["true"], p["false"]
        ok = {
            "Always": t + f > 0 and f == 0,
            "AlwaysOrUnreachable": f == 0,
            "Unreachable": f == 0,
            "Sometimes": t > 0,
            "Reachable": t > 0,
        }[d]
        missed = not ok and not (d in MUST_HOLD and f > 0)
        if not ok and not missed:
            broken += 1
        rows.append((ok, missed, id_, p))
    rows.sort(key=lambda r: (r[0], r[1], r[2]))

    floor = floor or []
    on_floor = set(floor)
    stale = [m for m in floor if m not in props]
    under = [id_ for ok, missed, id_, _ in rows if missed and id_ in on_floor]

    print(f"{runs} runs, {len(props)} properties" + (f", {len(floor)} on the floor" if floor else ""))
    for ok, missed, id_, p in rows:
        where = p["where"]
        verdict = "ok  " if ok else ("FLOOR" if id_ in on_floor else "MISS") if missed else "FAIL"
        print(f"{verdict:<5} {p['display']:<19} {id_}  ({where['file']}:{where['begin_line']}; "
              f"{p['true']} runs true, {p['false']} false)")
        if p["first_false"] is not None and not ok:
            print(f"       first failure: {json.dumps(p['first_false'])}")
    for m in stale:
        print(f"STALE {'floor':<19} {m}  (on the floor, but no run declared it)")
    if under or stale:
        print(f"under the floor: {len(under)} never reached, {len(stale)} stale")
    return 1 if broken or under or stale else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    floor = None
    if len(args) == 3 and args[1] == "--floor":
        floor = read_floor(args[2])
        args = args[:1]
    if len(args) != 1:
        sys.exit(__doc__)
    sys.exit(main(args[0], floor))
