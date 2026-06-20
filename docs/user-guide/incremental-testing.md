# Trace-Based Incremental Testing

> **Status: experimental prototype.** This feature is available behind the
> `--ct-incremental` flag on `repro watch`. It is validated end-to-end for
> interpreted-language tests (Ruby, Python, JavaScript/TypeScript) and for
> Nim source tests; the native / MCR path (compiled C/C++/Rust, and Nim via
> the multi-core recorder) builds and records but is not yet wired end-to-end
> — see [Language support](#language-support) below.

When you watch a test with `repro watch`, reprobuild normally re-runs the
watched test on every rebuild cycle. **Trace-based incremental testing** makes
that smarter: it skips re-running a test when none of the functions that test
actually executed have changed.

The idea (from CodeTracer's recorded traces) is simple:

1. The first time a test runs, reprobuild records a trace of it and remembers
   **which functions it executed** and a hash of each of those functions.
2. On the next rebuild, reprobuild looks at what you changed. If your edit only
   touched functions the test never ran — or code elsewhere in the project —
   the test's result cannot have changed, so reprobuild **skips it**.
3. If you changed a function the test *did* execute, reprobuild **re-runs** the
   test and records a fresh trace.

This turns "edit → rebuild → wait for every watched test" into "edit → rebuild
→ only the tests your change can actually affect re-run."

## Enabling it

```bash
repro watch <target> --ct-incremental
```

Two flags control the mode:

| Flag | Meaning |
|------|---------|
| `--ct-incremental` | Enable trace-based incremental skipping for the watched test edge. |
| `--ct-incremental-trace-dir=PATH` | Where the test's trace is produced. Defaults to `.repro/ct-incremental/trace` under the project root. |

With `--ct-incremental` **absent**, `repro watch` behaves exactly as before —
the incremental path is opt-in and never changes the default behaviour.

## What you see

On each rebuild cycle, the watched test edge reports one of:

- **`skipped (unchanged: <test>)`** — none of the functions the test executed
  changed; the test was not re-run, and watching resumed immediately.
- a normal **re-run** — a function the test executed changed (or this is the
  first/baseline cycle), so the test ran and its fresh trace was recorded.

These decisions are also emitted as structured `ct-incremental` watch events
(`skip` / `rerun` / `record-error`), so they can be consumed by tooling.

## How the decision is made

For each watched test, reprobuild reads the recorded trace, derives the set of
**executed functions**, and computes a per-function hash. A test is skipped only
when *every* executed function hashes identically to the recorded baseline.

The per-function hash adapts to the language so the comparison is precise:

- **Interpreted languages (Ruby, Python, JS/TS):** a hash of the function's
  **source text**, read from the modern CTFS (`.ct`) trace the recorder
  produces.
- **Nim:** when the test is built with the unit-testing library that reports
  compile-time **`symBodyHash`** values, those deep hashes are used (they
  capture semantic changes through macros and inlined dependencies); otherwise
  the source-text shallow hash is used as a fallback.
- **Native (compiled C/C++/Rust):** a hash of the function's **compiled
  instruction bytes**, so a change that alters codegen is caught even when the
  source line is untouched.

The decision is conservative by design: any ambiguity (a function that cannot
be read, a relocation-sensitive native function, a missing baseline) results in
a **re-run**, never a false skip. Skipping is only ever chosen when reprobuild
can prove the executed functions are unchanged.

## Language support

| Language | Status |
|----------|--------|
| Ruby, Python, JavaScript/TypeScript | ✅ Validated live, end-to-end (record → decide → skip/re-run). |
| Nim (source) | ✅ Source-text shallow hash; deep `symBodyHash` when the test library reports it. |
| Native — C/C++/Rust, Nim via MCR | 🚧 The recorder builds and records, but consuming its trace in the engine is in progress; needs a Linux MCR host to validate. |

## Caveats (prototype)

- The trace directory is currently a fixed location the test writes its trace
  into (`--ct-incremental-trace-dir`); a future version will manage trace
  capture automatically per test.
- Incremental skipping is applied to the watched test edge; broader test-graph
  integration is planned.

## See also

- The engine library and its developer documentation:
  [`libs/repro_ct_incremental/README.md`](../../libs/repro_ct_incremental/README.md).
- Design and milestones:
  [`docs/Trace-Based-Incremental-Testing.milestones.org`](../Trace-Based-Incremental-Testing.milestones.org).
- The underlying technique is specified in CodeTracer's
  `Nim-Parallel-Test-Framework` spec (§16.7, runtime-dependency test selection).
