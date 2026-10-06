#!/usr/bin/env python3
"""**AN SDK.JSONL, JUDGED** the way Antithesis's triage report would: one
verdict per property (src/coverage.zig), over every run the files hold. A
property is its `id`; its sites are declared (`hit: false`) by each run, and
a run reports the first pass and the first failure of each.

    tools/report.py <a.jsonl> [b.jsonl ...] [--floor <file>] [--edges <file>]

FAIL is a property the runs broke: an Always or AlwaysOrUnreachable seen
false, an Unreachable reached. MISS is one they never got to: a Sometimes
never true, a Reachable or an Always never reached. Antithesis fails both;
this exits 1 on a FAIL only, because a MISS is a gap in the runs, not a bug
(README.md, "Where this differs from Antithesis").

**A FLOOR** is the list of properties a run is expected to reach: one message
per line, `#` for comments. With one, a MISS of a property on it fails too,
and so does a line naming no property any run declared, which is a floor
gone stale.

**MANY RUNS.** A run is a `metal_vmm_run` line and what follows it, however
many times its guest boots (metal-vmm's `COVERAGE_OUT`, which names it by
its seed or its knobs); a file with no such line is a run per boot (each
`antithesis_sdk` line). For each property: how many runs reached it and
which first, and at the end the ones only one run ever reached, the rare
ones an explorer steers toward.

**THE NUMERIC COMPARISONS** (`alwaysGreaterThan` and the rest) also write
`antithesis_guidance` lines at each new edge; for each, the report gives the
nearest any run came (the most or the least `left - right`, as the line's
`maximize` says) and which run it was, and its **reach**: the furthest
`left` went the way the comparison steers (the most `left` of one that
maximizes, the least of one that minimizes). The reach is what tells a full
table of 256 from a full table of 2, which are the same edge.

**AN EDGE FLOOR** (`--edges <file>`) is how far each comparison must reach:
one line each, the message, then `>=` or `<=` and a number, `#` for comments:

    tcp: slots in use stay within the table  >= 64

`>=` judges a comparison that maximizes by its most `left`, `<=` one that
minimizes by its least. A comparison that never reached the number fails
(EDGE), and so does a line naming no comparison any run declared, or one
whose sign is not the way that comparison steers (STALE).
"""
import re
import json
import sys

# The kinds a false condition breaks (Unreachable records its hit as false).
MUST_HOLD = {"Always", "AlwaysOrUnreachable", "Unreachable"}
RUN_KEY = "metal_vmm_run"


EDGE_LINE = re.compile(r"^(.*\S)\s+(>=|<=)\s+(-?[0-9]+(?:\.[0-9]+)?)$")


def read_edges(path):
    """[(message, sign, number)] from an edge floor; exits on a bad line."""
    out = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = EDGE_LINE.match(line)
            if m is None:
                sys.exit(f"{path}:{n}: not '<message>  >= <number>' or '<= <number>': {line!r}")
            number = float(m.group(3)) if "." in m.group(3) else int(m.group(3))
            out.append((m.group(1), m.group(2), number))
    return out


def read_floor(path):
    with open(path) as f:
        return [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]


def run_name(run, path, index):
    if isinstance(run, dict):
        if isinstance(run.get("seed"), int):
            return f"FAULT_SEED={run['seed']}"
        knobs = run.get("knobs")
        if isinstance(knobs, str):
            return "a run with no faults" if knobs == "none" else knobs
    return f"{path}, run {index}"


class Runs:
    """Every property over every run read so far."""

    def __init__(self):
        self.names = []
        self.props = {}
        self.edges = {}
        self.reaches = {}
        # Every numeric comparison declared, and whether it maximizes.
        self.declared_guidance = {}

    def read(self, path):
        events = []
        with open(path) as f:
            for n, line in enumerate(f, 1):
                if not line.strip():
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError as e:
                    sys.exit(f"{path}:{n}: not JSON ({e}): {line[:120]!r}")
        marked = any(RUN_KEY in e for e in events)
        boots = 0
        in_run = False
        for event in events:
            if RUN_KEY in event:
                self.names.append(run_name(event[RUN_KEY], path, len(self.names) + 1))
                in_run = True
                continue
            if "antithesis_sdk" in event:
                boots += 1
                if not marked:
                    self.names.append(f"{path}, boot {boots}")
                    in_run = True
                continue
            if not in_run:
                self.names.append(path)
                in_run = True
            run = len(self.names) - 1
            if "antithesis_guidance" in event:
                g = event["antithesis_guidance"]
                if g.get("guidance_type") == "numeric":
                    self.declared_guidance[g["id"]] = bool(g.get("maximize"))
                self.guidance(g, run)
                continue
            a = event.get("antithesis_assert")
            if a is None:
                continue
            p = self.props.setdefault(a["id"], {
                "display": a["display_type"], "where": a["location"],
                "true": 0, "false": 0, "first_false": None,
                "runs": 0, "first_run": None, "last_run": None,
            })
            if not a["hit"]:
                continue
            if a["condition"]:
                p["true"] += 1
            else:
                p["false"] += 1
                if p["first_false"] is None:
                    p["first_false"] = a.get("details")
            if p["last_run"] != run:
                if p["first_run"] is None:
                    p["first_run"] = run
                p["runs"] += 1
                p["last_run"] = run

    def guidance(self, g, run):
        if g.get("guidance_type") != "numeric" or not g.get("hit"):
            return
        data = g.get("guidance_data") or {}
        left, right = data.get("left"), data.get("right")
        if not isinstance(left, (int, float)) or not isinstance(right, (int, float)):
            return
        gap = left - right
        best = self.edges.get(g["id"])
        maximize = bool(g.get("maximize"))
        if best is None or (gap > best["gap"] if maximize else gap < best["gap"]):
            self.edges[g["id"]] = {"gap": gap, "left": left, "right": right, "run": run}
        far = self.reaches.get(g["id"])
        if far is None or (left > far["left"] if maximize else left < far["left"]):
            self.reaches[g["id"]] = {"left": left, "right": right, "run": run, "maximize": maximize}


def main(paths, floor=None, edges=None):
    runs = Runs()
    for path in paths:
        runs.read(path)
    props, names = runs.props, runs.names

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

    print(f"{len(names)} runs, {len(props)} properties" + (f", {len(floor)} on the floor" if floor else ""))
    for ok, missed, id_, p in rows:
        where = p["where"]
        verdict = "ok  " if ok else ("FLOOR" if id_ in on_floor else "MISS") if missed else "FAIL"
        reached = f"reached by {p['runs']} of {len(names)} runs"
        if p["first_run"] is not None:
            reached += f", first {names[p['first_run']]}"
        edge = runs.edges.get(id_)
        at_edge = f"; its edge: left {edge['left']}, right {edge['right']}, in {names[edge['run']]}" if edge else ""
        far = runs.reaches.get(id_)
        if far and edge and far["left"] != edge["left"]:
            at_edge += f"; its reach: left {far['left']}, right {far['right']}, in {names[far['run']]}"
        print(f"{verdict:<5} {p['display']:<19} {id_}  ({where['file']}:{where['begin_line']}; "
              f"{reached}; {p['true']} true, {p['false']} false{at_edge})")
        if p["first_false"] is not None and not ok:
            print(f"       first failure: {json.dumps(p['first_false'])}")
    rare = [(id_, p) for id_, p in props.items() if p["runs"] == 1]
    if rare and len(names) > 1:
        print("reached by one run only:")
        for id_, p in sorted(rare):
            print(f"       {id_}  ({names[p['first_run']]})")
    for m in stale:
        print(f"STALE {'floor':<19} {m}  (on the floor, but no run declared it)")
    if under or stale:
        print(f"under the floor: {len(under)} never reached, {len(stale)} stale")
    short = 0
    for message, sign, number in edges or []:
        if message not in runs.declared_guidance:
            print(f"STALE {'edge':<19} {message}  (on the edge floor, but no run declared such a comparison)")
            short += 1
            continue
        steers = runs.declared_guidance[message]
        far = runs.reaches.get(message)
        if (sign == ">=") != steers:
            way = "maximizes" if steers else "minimizes"
            print(f"STALE {'edge':<19} {message}  ({sign} {number}, but it {way}: its reach is its "
                  f"{'most' if steers else 'least'} left)")
            short += 1
            continue
        reached = far["left"] if far else None
        if reached is None or (reached < number if sign == ">=" else reached > number):
            print(f"EDGE  {'short':<19} {message}  (wanted left {sign} {number}; "
                  f"{'never reached' if reached is None else f'its reach: left {reached}'})")
            short += 1
    if short:
        print(f"short of the edge floor: {short}")
    return 1 if broken or under or stale or short else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    floor = None
    edges = None
    for flag in ("--floor", "--edges"):
        if flag in args:
            at = args.index(flag)
            if at + 1 >= len(args):
                sys.exit(__doc__)
            if flag == "--floor":
                floor = read_floor(args[at + 1])
            else:
                edges = read_edges(args[at + 1])
            args = args[:at] + args[at + 2:]
    if not args:
        sys.exit(__doc__)
    sys.exit(main(args, floor, edges))
