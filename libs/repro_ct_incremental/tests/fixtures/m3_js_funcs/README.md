# M3 fixture: `m3_js_funcs`

A tiny JavaScript program (`src/three_funcs.js`) plus a CodeTracer JSON trace
(`trace/`) used by the M3 multi-language tests of the
Trace-Based-Incremental-Testing prototype. It proves the engine is
language-agnostic: the SAME `decide()`/`record()` engine drives JavaScript via
the `.js` brace-matching extractor, with no per-language branching outside the
extractor.

## The program

`main` calls `used_a` and `used_b`. `unused_c` is defined but never called. So
the executed-function set is exactly `{main, used_a, used_b}` and `unused_c`
must be absent. Definition lines (1-based) are pinned in the source comment and
in the trace's `Function` records: `used_a`=21, `used_b`=26, `unused_c`=30,
`main`=34. `used_a` deliberately contains a NESTED object brace and braces
inside a string and a `//` comment, to exercise the brace matcher's string/
comment handling.

## Extraction strategy (JavaScript) + documented limitation

JavaScript is brace-delimited — a genuinely different strategy from the
indentation-based Ruby/Python extractors. The `.js` extractor
(`src/repro_ct_incremental/extractors.nim`) scans from the function's opening
`{` to its matching `}`, counting block/object nesting depth and lexing past
braces inside single/double-quoted strings, template literals (backtick,
including nested `${ … }` interpolation), regex literals (`/…/flags`), and `//`
/ `/* */` comments.

The classic JS `/` ambiguity (regex literal vs division operator) is NOT
resolved precisely — that is impossible without a full grammar and was the
source of earlier under-capture bugs. The brace lexer is instead SAFE BY
CONSTRUCTION: the `/` decision is **biased to regex**. A `/` is read as division
ONLY when the previous significant token is *provably* a value that cannot
precede a regex: a numeric/string/template/completed-regex literal, a non-keyword
identifier, a `]`, or a **value-`)`**. After any expression-introducing keyword
(`return`, `void`, `typeof`, …), after `}`, after a **control-head-`)`**, or in
any case of doubt, it is read as a regex.

Not every `)` is a value. A `)` closing a CALL or a GROUPING (`f(x)`, `(a + b)`)
ends a value, so a following `/` is division — `(a + b) / c` stays precise. But
a `)` closing the HEAD of a control-flow statement (`if (c)`, `while (c)`,
`for (;;)`, `switch (x)`, `with (o)`, `catch (e)`) is a STATEMENT boundary, where
`/` legally begins a regex (`if (c) /}/.test(s)`). The pre-fix lexer treated
EVERY `)` as a value, so it mis-lexed `/}/` after a control-head `)` as division,
counted the in-regex `}` as the function close, and dropped the tail — a
false-skip (the third rejection). The two cases are now told apart by an
**open-bracket stack**: each open `(` records whether the token immediately
before it was a control-flow keyword; the matching `)` pops that flag — a
control-head `)` becomes regex-expecting (safe over-capture if it is actually a
value), a call/grouping `)` becomes a value (precise division). `]` stays a value
(so `arr[i] / 2` is division); the only construct that could abuse that — a regex
whose `}` follows a `]` "division" — is not valid JS either way, so it cannot
cause a false skip. Any residual ambiguity, and ANY token kind not on the
provable-value list, defaults to regex-expecting (bias to safety).

Guarantee — the brace lexer never under-captures (no false-skip), proved rather
than merely intended. The only way to count an in-regex `}` as a block-close is
to mistake a real regex `/` for division, which the regex bias makes impossible
(division is chosen only after a provable value that cannot precede a regex —
including the value-`)` vs control-head-`)` distinction above); the reverse error
(a real division read as a regex) only ever scans forward to the next `/`, which
can over-capture or run to EOF, never reduce the brace count. So the extractor
either captures the exact body, OVER-captures (still safe — any edit changes the
hash ⇒ re-run), or FAILS SAFE with an `Err` (unbalanced braces, or an
unterminated string / template literal / regex literal / block comment at end of
input), which the engine maps to the reserved `"missing"` shallow hash so the
test RE-RUNS. It never returns a body whose tail it might have dropped — so
editing a statement after a tricky construct (e.g. a regex literal containing
`}`, or a regex after a control-head `)`) can never collapse to a byte-identical
captured body and a silent skip. A tree-sitter-based extractor remains the
production path (a later milestone).

## Trace schema (same real schema as M0)

`trace.json` + `trace_paths.json` + `trace_metadata.json`, identical to the M0
`m0_three_funcs` fixture — see that fixture's README for the full confirmation
of the real CodeTracer JSON schema. Executed functions = the `Function` records
referenced by `Call` records; this trace's call stream references `function_id`
0/1/2 (`main`/`used_a`/`used_b`) and never 3 (`unused_c`).

## Live-recording validation (deferred)

This trace was hand-crafted in the real CodeTracer JSON schema, exactly as the
M0 fixture was. The real JavaScript recorder (`codetracer-js-recorder`) is not
prebuilt in this dev environment; live-recording validation with the real
recorder is deferred. The property the M3 tests exercise — the executed-function
SET and per-function source extraction — is fully determined by the schema
fields above, which match the M0-confirmed real schema. To re-record with the
real recorder once available:

```
# inside codetracer-js-recorder's dev shell, once the recorder is built
codetracer-js-recorder --trace-out <dir> src/three_funcs.js
# (then point the trace fixture at <dir>'s trace.json/trace_paths.json/…)
```
