#!/usr/bin/env python3
"""tools/report.py's own tests: python3 tools/report_test.py"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import report  # noqa: E402

SDK = {"antithesis_sdk": {"language": {"name": "Zig", "version": "0.16.0"}, "sdk_version": "0.0.1", "protocol_version": "1.1.0"}}


def where(line=1):
    return {"class": "root", "function": "f", "file": "tcp.zig", "begin_line": line, "begin_column": 5}


def assertion(message, display, hit, condition, details=None):
    a = {"hit": hit, "must_hit": display in ("Always", "Sometimes", "Reachable"),
         "assert_type": {"Always": "always", "AlwaysOrUnreachable": "always", "Sometimes": "sometimes",
                         "Reachable": "reachability", "Unreachable": "reachability"}[display],
         "display_type": display, "message": message, "condition": condition, "id": message, "location": where()}
    if details is not None:
        a["details"] = details
    return {"antithesis_assert": a}


def guidance(message, maximize, left=None, right=None):
    g = {"location": where(), "guidance_type": "numeric", "message": message, "id": message,
         "maximize": maximize, "hit": left is not None}
    if left is not None:
        g = {"guidance_data": {"left": left, "right": right}, **g}
    return {"antithesis_guidance": g}


def run(seed=None, knobs="none"):
    return {"metal_vmm_run": {"seed": seed, "knobs": knobs}}


def boot(*hits):
    """One boot: its version line, its declarations, then its hits."""
    out = [SDK]
    for m, d in (("syn", "Sometimes"), ("rto capped", "Always"), ("slots", "Always"), ("rare one", "Reachable")):
        out.append(assertion(m, d, False, False))
    out.append(guidance("slots", True))
    return out + list(hits)


class Report(unittest.TestCase):
    def judge(self, *files, floor=None):
        paths = []
        with tempfile.TemporaryDirectory() as d:
            for i, events in enumerate(files):
                p = os.path.join(d, f"run{i}.jsonl")
                with open(p, "w") as f:
                    for e in events:
                        f.write(json.dumps(e) + "\n")
                paths.append(p)
            fl = None
            if floor is not None:
                fp = os.path.join(d, "floor.txt")
                with open(fp, "w") as f:
                    f.write(floor)
                fl = report.read_floor(fp)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = report.main(paths, fl)
            return code, out.getvalue().replace(d + "/", "")

    def line(self, text, prop):
        return next(l for l in text.splitlines() if f" {prop}  (" in l)

    def test_marked_runs_count_once_however_many_boots(self):
        code, text = self.judge(
            [run(7, "WIRE_EAT=3")] + boot(assertion("syn", "Sometimes", True, True))
            + [run(8, "PEER_EAT=2")] + boot(assertion("syn", "Sometimes", True, True))
            + boot(assertion("syn", "Sometimes", True, True), assertion("rare one", "Reachable", True, True)))
        self.assertEqual(code, 0)
        self.assertTrue(text.startswith("2 runs, 4 properties"))
        self.assertIn("reached by 2 of 2 runs, first FAULT_SEED=7; 3 true, 0 false", self.line(text, "syn"))
        self.assertIn("reached by one run only:\n       rare one  (FAULT_SEED=8)", text)

    def test_an_unmarked_file_is_a_run_per_boot(self):
        code, text = self.judge(boot(assertion("syn", "Sometimes", True, False))
                                + boot(assertion("syn", "Sometimes", True, True)))
        self.assertTrue(text.startswith("2 runs,"))
        # Reached is hit, true or false, as metal-vmm's merge counts it.
        self.assertIn("reached by 2 of 2 runs, first run0.jsonl, boot 1; 1 true, 1 false", self.line(text, "syn"))

    def test_many_files_one_table(self):
        code, text = self.judge(boot(assertion("syn", "Sometimes", True, True)),
                                [run(None, "none")] + boot())
        self.assertTrue(text.startswith("2 runs,"))
        self.assertIn("reached by 1 of 2 runs, first run0.jsonl, boot 1", self.line(text, "syn"))

    def test_a_broken_always_fails_and_a_miss_does_not(self):
        code, text = self.judge(boot(assertion("rto capped", "Always", True, False, {"rto": 70})))
        self.assertEqual(code, 1)
        self.assertTrue(self.line(text, "rto capped").startswith("FAIL"))
        self.assertIn('first failure: {"rto": 70}', text)
        self.assertTrue(self.line(text, "syn").startswith("MISS"))
        code, _ = self.judge(boot())
        self.assertEqual(code, 0)

    def test_the_floor_under_and_stale(self):
        code, text = self.judge(boot(), floor="# must\nsyn\nno such property\n")
        self.assertEqual(code, 1)
        self.assertTrue(self.line(text, "syn").startswith("FLOOR"))
        self.assertIn("STALE floor", text)
        self.assertIn("under the floor: 1 never reached, 1 stale", text)

    def test_a_comparisons_edge_and_the_run_that_reached_it(self):
        _, text = self.judge(
            [run(1)] + boot(assertion("slots", "Always", True, True, {"left": 3, "right": 256}),
                            guidance("slots", True, 3, 256), guidance("slots", True, 200, 256))
            + [run(2)] + boot(assertion("slots", "Always", True, True, {"left": 9, "right": 256}),
                              guidance("slots", True, 9, 256), guidance("slots", True, 250, 256))
            + [run(3)] + boot(guidance("slots", True, 100, 256)))
        self.assertIn("its edge: left 250, right 256, in FAULT_SEED=2", self.line(text, "slots"))
        # Minimized: the least left - right wins.
        _, text = self.judge(boot(assertion("slots", "Always", True, True),
                                  guidance("slots", False, 30, 10), guidance("slots", False, 12, 10)))
        self.assertIn("its edge: left 12, right 10", self.line(text, "slots"))

    def test_long_sh_reads_the_same_lines(self):
        # gopher-metal's long.sh keeps only these: the verdict prefixes, the
        # first line, and the floor's summary.
        _, text = self.judge(boot(), floor="syn\n")
        kept = [l for l in text.splitlines() if l.startswith(("FAIL", "FLOOR", "STALE")) or "under the floor" in l
                or l.split(" ")[0].isdigit() and " runs" in l]
        self.assertEqual(kept[0].split(",")[0], "1 runs")
        self.assertTrue(any(l.startswith("FLOOR") for l in kept))


if __name__ == "__main__":
    unittest.main()
