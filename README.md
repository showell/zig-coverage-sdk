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

The message names the property and must be comptime. `details` is anything
`std.json` can write, or `null`.

At the end of a run, `report(writer)` gives every property a verdict, and
`failing()` counts the ones that don't hold. If a `sink` is set, each event
also goes out as a JSONL line, to whatever the program chooses: a file, or a
serial port on a machine with no OS.

    zig build test      # the SDK's own tests, Debug and ReleaseSafe
    tools/report.py sdk.jsonl

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
  64 bytes, aligned and tagged, and the walk takes only tagged ones.
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
- **Tiered gating follows from that.** The intended use is that a FAIL
  fails every tier of testing, from a quick pre-commit run to a long hunt,
  while a MISS fails only a long run, and only for properties on a list
  that run is expected to reach. A quick gate can't promise to reach rare
  cases, and shouldn't be failed for not reaching them.
- **The verdict can be read in-process.** `report` and `failing()` need no
  external platform: a test or simulator judges its own run.

## What is missing, compared with their SDKs

- randomness (`get_random`, `random_choice`) and lifecycle (`setup_complete`,
  `send_event`);
- the guidance assertions (`always_greater_than`, `sometimes_all`, ...);
- their native output path (`libvoidstar.so`, loaded when present); only
  the JSONL is written, through `sink`;
- thread safety: one thread is assumed.

## Open

- Whether Antithesis would want a Zig SDK at all. If they do, this repo is
  meant to grow into one.

No license yet.
