# Export fixtures for the Nix helper library (GM5)

Each case is a profile (`<case>/profile/`) and what Reprobuild says about it:

- `export.json` — `repro home export --host m1` of the profile: the snapshot a
  Nix consumer commits and reads with `reprobuild.lib.readIntent { snapshot =
  …; }`.
- `evaluations.json` — for every host in `hosts` below and every target
  system, what `repro home export --host <host> --target <system>` reports:
  `{ "<host>": { "<system>": <evaluation> | { "refused": true } } }`. This is
  Reprobuild's own evaluation (`evaluateHomeExport`), the answer the Nix
  evaluator (`nix/lib/intent.nix`) must reproduce from `export.json` alone.

Hosts evaluated: `m1`, `home-pc`, `server` (declared, declared, undeclared).

Who reads them:

- the flake check `lib-tests` (`nix/tests/lib.nix`): the Nix evaluation of
  `export.json` equals `evaluations.json` for every host and system, and a
  refusal is a refusal — on every system the flake supports, evaluation only;
- the flake check `lib-intent-ifd`: `readIntent` in IFD mode (the packaged
  `repro` in the build sandbox) produces a document whose evaluation equals the
  snapshot's;
- the flake check `lib-home-manager`: the Home Manager module over
  `neutral/export.json`;
- `tests/e2e/m83/t_e2e_nix_reads_intent_like_export.nim`, which re-exports
  every case with `build/bin/repro`, fails when `export.json` is stale
  (`repro home export --check`) or `evaluations.json` differs from a fresh
  `--target` run, and rewrites both with `REPRO_UPDATE_INTENT_FIXTURES=1`.

Cases:

- `neutral` — runtime predicates only (activity guards, host guards, guarded
  resources and config, a data file with package and resource rows): every
  platform `same`.
- `compile-time` — a `when defined(macosx)` in `resources:`: exported on
  Linux, the darwin targets are `differs` and must be refused; the Linux and
  Windows targets are evaluated.

The snapshots are produced on x86_64-linux. `export.json`'s `provenance`
records the producing `repro`; `--check` never compares provenance, so a
`repro` upgrade does not make them stale, only a change in what they say.
