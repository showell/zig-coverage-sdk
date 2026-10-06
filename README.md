# zig-coverage-sdk

Assertions for Zig that are **properties of a whole run**, not checks that
stop it. Includes a `sometimes` that fails when the case you meant to
exercise never happened.

**Inspired by [Antithesis](https://antithesis.com/docs/properties_assertions/)'s
SDK, and cribbed from their Go and Rust ones. Not endorsed by Antithesis, and
not yet compatible with their toolchain:** it writes the JSONL their docs
describe, but it has never run under their platform, and it lacks most of
their API (below).

```zig
const coverage = @import("coverage");

coverage.always(@src(), rto <= max_rto, "a backed-off RTO stays under the cap", .{ .rto = rto });
coverage.sometimes(@src(), dupacks == 3, "three duplicate ACKs resend at once", null);
coverage.reachable(@src(), "a silent peer is given up on", .{ .conn = i });
```

| call | holds when |
|---|---|
| `always(@src(), cond, msg, details)` | reached, and true every time |
| `alwaysOrUnreachable(...)` | true every time it is reached, if ever |
| `sometimes(@src(), cond, msg, details)` | true at least once |
| `reachable(@src(), msg, details)` | reached at least once |
| `@"unreachable"(@src(), msg, details)` | never reached |

**The numeric comparisons**, after Antithesis's `AlwaysGreaterThan` and the
rest, in Zig's case: `alwaysGreaterThan`, `alwaysGreaterThanOrEqualTo`,
`alwaysLessThan`, `alwaysLessThanOrEqualTo`, and the same four as
`sometimes...`. Each is an `always` or a `sometimes` of `left` against
`right`, judged as that kind, with `left` and `right` in its details, and it
remembers its **edge**: the call nearest to breaking an always, or to making
a sometimes hold (the most or the least `left - right`, which way the Go SDK
steers each one).

```zig
coverage.alwaysLessThanOrEqualTo(@src(), in_use, slots.len, "slots in use stay within the table", null);
```

Operands are integers of up to 64 bits or floats, as the Go SDK's are. The
report gives each comparison's edge:
`ok   Always  slots in use ...  (tcp.zig:310; 812 true, 0 false; its edge: left 255, right 256)`.

The message names the property and must be comptime. `details` is anything
`std.json` can write, or `null`.

At the end of a run, `report(writer)` gives every property a verdict, and
`failing()` counts the ones that don't hold. If a `sink` is set, each event
also goes out as a JSONL line, to whatever the program chooses: a file, or a
serial port on a machine with no OS. Set `sink` before `declare()` or the
first assertion: `declare()` (called by the first event, or at startup by a
harness) writes the version line and every site's declaration once a run, and
marks the run declared even with no `sink`, so a `sink` set later never gets
them.

    zig build test      # the SDK's own tests, Debug and ReleaseSafe
    python3 tools/report_test.py
    tools/report.py sdk.jsonl [more.jsonl ...] [--floor floor.txt]

## Who uses it, and what a change here breaks

[gopher-metal](https://github.com/showell/gopher-metal) depends on this repo
**by path, with no version pin** (below), so every push to `main` changes its
build at once. Every change here is a change to gopher-metal's build; say in
the commit what it would see. The flow: gopher-metal's simulators
(`zig build properties`) and its `-Dcoverage` kernels (on COM1) emit the
JSONL; [metal-vmm](https://github.com/showell/metal-vmm) collects a run's
lines into `COVERAGE_OUT`; gopher-metal's `long.sh` judges them with
`tools/report.py --floor` against `coverage/floor-sim.txt` and
`coverage/floor-metal.txt`.

## Using it

It's a Zig package (Zig 0.16): the module `coverage`, plus the scanner
described under "The catalog". Its first user,
[gopher-metal](https://github.com/showell/gopher-metal), declares it as a
path dependency on a sibling checkout:

```zig
// build.zig.zon
.dependencies = .{ .zig_coverage_sdk = .{ .path = "../zig-coverage-sdk" } },

// build.zig
const sdk = b.dependency("zig_coverage_sdk", .{});
const coverage = sdk.module("coverage");
const catalog = @import("zig_coverage_sdk").addCatalog(b, sdk.artifact("coverage-scan"),
    coverage, b.path("src"), &.{"tcp.zig"});
// then import both, as "coverage" and "coverage_catalog", into every module
// that compiles a scanned file
```

Each scanned file says this once, at container level:

```zig
comptime {
    coverage.catalogFile(@import("coverage_catalog"), here());
}
fn here() std.builtin.SourceLocation {
    return @src();
}
```

## The catalog

A `sometimes` that never ran has to be reported, so every assertion must be
known before any of them runs. As in Antithesis's Rust SDK, each call site is
a static in a linker section, `zig_coverage_catalog`, and the linker's
`__start_`/`__stop_` symbols bound it. Five traps, each found by a failing
test and each commented where it's handled:

- **Zig's own linker (Debug) leaves gaps between statics.** Each entry is
  128 bytes, aligned and tagged, and the walk takes only tagged ones.
- **ReleaseSafe dropped sites inside branches it proved dead**, which are
  the sites most worth reporting. Each site is exported under a unique
  hidden name, which keeps it.
- **Generic code was one site per instantiation**, because `@src().fn_name`
  names the instantiation, and two instantiations' exported names collided,
  which was a compile error. The suffix is cut, and the site is keyed by
  value, so they share one.
- **With no site in live code, the section was dropped** by the linker's
  garbage collection, which doesn't count `__start_`/`__stop_` as uses, and
  an optimized build failed to link. An untagged anchor keeps it.
- **A site exists only if its function is compiled**, and Zig compiles only
  what is referenced. Referencing declarations reaches plain functions, but
  not generic ones or ones taking `anytype`, whose bodies can't be analyzed
  without arguments. So, as Antithesis's Go SDK does with its instrumentor,
  **a build step reads the source**: `tools/scan.zig` parses the files
  you name with `std.zig.Ast`, and writes a module that registers each
  assertion it finds, at comptime, as the very `Site` the real call would
  name. `test/` holds the proof: plain, method, `anytype`, generic, nested
  and private functions nothing calls, all cataloged once. Two limits:
  - it matches by name, so another API called `sometimes(@src(), ...)` would
    be cataloged too;
  - a scanned file's assertions in code never compiled for this target,
    such as one behind a `builtin.os` branch, are permanent MISSes.

A freestanding program's link script must keep the section:
`zig_coverage_catalog : { KEEP(*(zig_coverage_catalog)) }`.

## Where this differs from Antithesis

These are deliberate choices, not oversights.

- **FAIL and MISS are different verdicts.** Antithesis fails a `sometimes`
  that was never true exactly as it fails a broken `always`. Here, a
  contradicted property is a **FAIL**: an `always` seen false, or an
  `unreachable` reached. A property the run never got to is a **MISS**: a
  `sometimes` never true, or a `reachable` or `always` never reached. A FAIL
  says the code is wrong; a MISS says the run was short of the case. Both
  appear in the report, and the program decides which ones gate.
- **Tiered gating follows from that.** A FAIL should fail every tier, from
  a quick pre-commit run to a long hunt; a MISS should fail only a long run,
  and only for properties on its floor (below). A quick gate can't promise
  to reach rare cases.
- **The verdict can be read in-process.** `report` and `failing()` need no
  external platform: a test or simulator judges its own run. Both count
  every property that does not hold, MISSes included, so a quick gate that
  fails only on FAILs walks `catalog()` and checks each site's `broken()`.
  `tools/report.py` exits 1 on a FAIL only, unless given a floor.

## The floor

A floor file lists the properties a run must reach: one message per line,
blank lines and lines starting with `#` ignored. In-process,
`checkFloor(floor_text, writer)` returns how many fall under it, printing
`FLOOR  never reached: <message>` for a MISS on it and
`STALE  on the floor, but no such property: <message>` for a line naming no
site in this program. It ignores FAILs, which are `report`'s. Out of process,
`tools/report.py --floor floor.txt` reads the same file and also exits 1 on a
floor MISS or a stale line.

## The numeric comparisons, on the wire

Each writes its assertion line as the Go SDK does: `display_type` and
`assert_type` are the plain kind's (`Always`, `Sometimes`), and `left` and
`right` are added to the details beside the caller's own fields (a caller's
details that are not an object go under `details`). Beside it, an
`antithesis_guidance` line in the Go SDK's `guidanceInfo` order:
`{"guidance_data":{"left":..,"right":..},"location":{..},"guidance_type":"numeric","message":..,"id":..,"maximize":..,"hit":..}`,
declared once a run with `hit: false` and no data, as every site is.

**When a guidance line goes out is this SDK's rule**: the first call, and
every call nearer the edge, or further in its reach (below), than any before
it in this run. The Go SDK keeps
the same extreme per assertion; whether it emits on the same rule is
unchecked.

**Edge and reach.** The edge is the call nearest the limit (`left -
right`), so a full table of 256 is the same edge as a full table of 2. So a
comparison also keeps its **reach**, the furthest `left` went the way it
steers, and a guidance line goes out at each new reach as well as each new
edge; every line is the call's own operands. `report()` and `report.py`
print both, and `report.py --edges <file>` is a floor for reaches: a line
`tcp: slots in use stay within the table  >= 64` fails the runs if that
comparison's reach never got there (EDGE), and a line naming no comparison,
or with the sign against the way it steers, is STALE.

`tools/report.py` reads many runs at once. A run is a line metal-vmm writes
before its guest's output, such as
`{"metal_vmm_run":{"seed":4711,"knobs":"WIRE_EAT=3"}}`, and what follows it;
a file without such lines is a run per boot. It says, for each
property, how many runs reached it and which first, for each comparison the
nearest any run came to its edge and which run, and the properties only one
run ever reached. `python3 tools/report_test.py` is its own test.

## What is missing, compared with their SDKs

- randomness (`get_random`, `random_choice`) and lifecycle (`setup_complete`,
  `send_event`);
- the boolean guidance assertions (`AlwaysSome`, `SometimesAll`) and raw
  guidance (`NumericGuidanceRaw`, `BooleanGuidanceRaw`);
- their native output path (`libvoidstar.so`, loaded when present); only
  the JSONL is written, through `sink`;
- thread safety: one thread is assumed.

## Open

- Whether Antithesis would want a Zig SDK at all. If they do, this repo is
  meant to grow into one.

No license yet.
