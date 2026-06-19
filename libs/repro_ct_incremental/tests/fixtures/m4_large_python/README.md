# M4 fixture: `m4_large_python`

A larger Python program (`src/library.py`, 18 functions) plus three hand-built
CodeTracer JSON traces — one per test — used by the M4 tests of the
Trace-Based-Incremental-Testing prototype campaign. It scales the M0/M1 setup
to many functions, a call graph several levels deep, and **multiple tests** with
deliberately overlapping and disjoint executed-function sets, so selective
re-run and cache pruning can be demonstrated.

The trace schema is identical to the M0 fixture (`../m0_three_funcs/README.md`
documents how it was confirmed against `codetracer_trace_writer`'s
`TraceEventsFileFormat::Json`): each trace dir holds `trace.json`,
`trace_paths.json`, `trace_metadata.json`. The reader's executed set = the
`Function` records referenced by `Call` records.

## The program

`src/library.py` defines 18 single-statement functions. Source uses the Python
(`.py`) indentation extractor — no JavaScript here, kept deliberately simple.

Call graph (`->` = "calls"), with levels counted from the test entry point:

```
test_a -> run_a (L1) -> mid_a (L2) -> leaf_shared (L3)
                                    -> leaf_a_only (L3)
                                    -> helper_one  (L3) -> leaf_deep (L4)

test_b -> run_b (L1) -> mid_b (L2) -> leaf_shared (L3)
                                    -> leaf_b_only (L3)
                                    -> helper_two  (L3)

test_c -> run_c (L1) -> mid_c (L2) -> compute     (L3) -> validate  (L4)
                                                       -> transform (L4)
                                    -> helper_three(L3)
```

`dead_code` and `unused_helper` are defined but executed by no test.

## Per-test executed-function sets

Each test's `trace_<x>/trace.json` Call stream records EXACTLY the functions
that test executed. Runtime dependencies are transitive *by construction*: a
callee that actually ran (e.g. `leaf_deep`, reached at depth 4 through
`run_a -> mid_a -> helper_one -> leaf_deep`) appears directly in the caller
test's executed set, so no static call-graph analysis is needed.

| function       | def line | test_a | test_b | test_c |
|----------------|---------:|:------:|:------:|:------:|
| run_a          | 121      |   x    |        |        |
| run_b          | 125      |        |   x    |        |
| run_c          | 129      |        |        |   x    |
| mid_a          | 109      |   x    |        |        |
| mid_b          | 113      |        |   x    |        |
| mid_c          | 117      |        |        |   x    |
| leaf_shared    | 69       |   x    |   x    |        |
| leaf_a_only    | 73       |   x    |        |        |
| leaf_b_only    | 77       |        |   x    |        |
| leaf_deep      | 81       |   x    |        |        |
| helper_one     | 85       |   x    |        |        |
| helper_two     | 89       |        |   x    |        |
| helper_three   | 93       |        |        |   x    |
| compute        | 97       |        |        |   x    |
| validate       | 101      |        |        |   x    |
| transform      | 105      |        |        |   x    |
| dead_code      | 133      |        |        |        |
| unused_helper  | 137      |        |        |        |

Properties the M4 tests rely on:

- **`leaf_shared`** is executed by **test_a AND test_b**, not test_c — a leaf
  shared by exactly two tests. Editing it re-runs A and B, skips C.
- **`leaf_a_only`** is executed by **only test_a** — a disjoint function.
  Editing it re-runs A, skips B and C.
- **`leaf_deep`** is executed by **test_a** through a depth-4 transitive chain
  (`run_a -> mid_a -> helper_one -> leaf_deep`); it IS in test_a's trace set,
  so editing it re-runs test_a (transitive-callee-change verification).
- **`dead_code` / `unused_helper`** are executed by no test — editing them
  re-runs nothing.

Definition lines (1-based) are pinned both in the source's header comment and
in the `line` fields of the trace `Function` records; the two MUST stay in
sync. The M4 tests further assert this independently by reading each trace and
checking the executed-set names.
