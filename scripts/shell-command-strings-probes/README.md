# shell-command-strings probes — what the gate does and does not catch

Every exemption in `scripts/shell_command_strings.py` is a licence to ignore a
real defect, so each one is probed adversarially rather than trusted. This
directory is that probe set, made runnable:

    bash scripts/check_shell_command_strings.sh --self-test

Each `*.nim.probe` file is a **complete, genuine** instance of the family the
gate exists to stop — a shell operator inside a command string reaching an exec
API that runs no shell on Windows — or a **genuine non-instance** that must not
be reported. The filename prefix states the expected verdict, and the self-test
asserts it in **both** directions:

| prefix    | meaning                                                              |
| --------- | -------------------------------------------------------------------- |
| `caught_` | a real defect the scanner MUST report                                 |
| `missed_` | a real defect the scanner does NOT report — a documented blind spot   |
| `exempt_` | NOT a defect; the scanner must stay silent (the exemptions, probed)   |

`missed_` is pinned rather than merely written down. A future change that
closes one of those blind spots fails this test, which is the signal to
reclassify the probe as `caught_` and delete the row from the blind-spot table
below. A change that re-opens a closed one fails it too. Neither can happen
quietly.

The extension is `.nim.probe`, not `.nim`, so nothing in the tree compiles,
imports, or scans these by accident; the self-test copies each into a scratch
directory under a `.nim` name and points the scanner at that.

## Blind spots that remain open

These are the shapes the gate still does not reach. They are limitations of a
lexical scanner, not exemptions — nothing here is a licence being granted, so
the honest floor is to name them.

| probe                                     | why it is missed                                                                                                  |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `missed_05_two_level_binding`             | one level of local `let`/`var`/`const` binding is resolved; a chain two deep is not                               |
| `missed_06_operator_split_literals`       | operators are matched per-literal, so a MULTI-character operator torn in half (`"&" & "&"`) carries none in either |
| `missed_07_poeval_via_named_options`      | the `startProcess` arm requires `poEvalCommand` to appear literally in the call's argument text                     |
| `missed_09_command_from_another_module`   | the command is assembled by a helper in another module; only a bare identifier bound IN THIS FILE is resolved      |
| `missed_13_const_term_in_concatenation`   | a same-file `const` is resolved only when it IS the command expression, not when it is a TERM in the concatenation |

A reviewer must still READ a call site rather than trust that the scanner read
it. The gate is a floor.

Two rows of the original nine-row table did not survive contact with a probe,
and the probes here are the corrected shapes:

- "the operator arriving through a module-level `const`" is **not** missed
  when the `const` IS the command expression — `resolve_binding` finds a
  same-file `const` perfectly well there. Two genuine ceilings remain: the
  CROSS-MODULE case (`missed_09`), and the same-file `const` used as a TERM in
  the concatenation rather than as the whole expression (`missed_13`, found by
  probing this very correction).
- splitting a *single-character* operator into its own literal does not defeat
  the scanner either: the operator patterns allow a literal to end right after
  the token, so a lone `">"` or `"|"` still matches. Only a multi-character
  operator torn in half does, which is what `missed_06` now is.

## Blind spots that were closed (W14)

Four of the original nine were **exemptions waving real defects through**,
which is a different and worse thing than not reaching far enough, plus one
plain bug. All five are now `caught_`:

- `caught_01_case_arm_flavour_enum` — the `of` arm exemption keyed on the ARM
  NAME and never on the case SUBJECT, so any arm whose identifier merely
  contained `posix`/`linux`/… was waved through on every platform.
- `caught_02_case_arm_string_literal` — same cause, reached through a string
  arm naming a Linux artefact.
- `caught_03_when_linux_or_windows` — the `when` test matched a PREFIX and
  never inspected the rest of the condition, so a disjunction that INCLUDES
  Windows read as POSIX-only.
- `caught_04_sh_c_operator_outside_body` — the `sh -c` exemption looked only at
  the FIRST literal, so an operator in a LATER bare argv element was covered by
  a proof that only applies inside the `-c` body.
- `caught_08_stale_when_runtime_else` — the "last `when` seen at this indent"
  map was never cleared and only `when`/`elif` ever wrote to it, so an ordinary
  runtime `if`/`else` inherited an unrelated earlier `when defined(windows)`
  and its `else:` became a "POSIX arm". This one needed no adversarial intent
  at all.
