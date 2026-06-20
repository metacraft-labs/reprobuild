# empty_ambiguous

A trace directory with NO backend signal: no canonical `trace.json`, no `rr/`
subdir, no `*.ct` container, no `trace_db_metadata.json`. `detectBackend` must
return an `Err` (the engine re-runs upstream — never guesses a backend).

This README is an unrelated file (not a backend signal), present only so the
directory is tracked by git.
