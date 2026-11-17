# Built-in predicate fixtures (GM5)

Shared cases for the built-in predicate grammar — the grammar of a data
file's `when` field and of every guard in a `repro home export` document
(reprobuild-pm `spec/Gradual-Nix-To-Reprobuild-Migration.md` §Declarative
data files read at plan time, §Platform-neutral intent). Two implementations
of that grammar exist, and these cases are what hold them together:

- `repro_home_intent/predicate.nim` (`validateBuiltinPredicate`,
  `predicateHolds`) with the target table `ProfileTargetPlatforms`
  (`repro_profile_compile/platforms.nim`), tested by
  `libs/repro_profile_compile/tests/t_builtin_predicate_fixtures.nim`;
- the Nix helper library's evaluator (`nix/lib/predicate.nix`), the second
  implementation forced by the Nix boundary, tested by the flake check
  `lib-tests` (`nix/tests/lib.nix`).

Both read `cases.json` unchanged. A change to the grammar changes this file,
and both sides must follow.

`cases.json`:

```json
{
  "systems": ["x86_64-linux", ...],
  "evaluations": [
    { "predicate": "macos and arm64", "host": "m1", "holdsOn": ["aarch64-darwin"] }
  ],
  "rejections": [
    { "predicate": "headless", "error": "unknown-identifier", "identifier": "headless" },
    { "predicate": "host", "error": "invalid" }
  ]
}
```

- `systems` lists every target system (the `ProfileTargetPlatforms` names).
  Each evaluation is evaluated for EVERY one of them, with the evaluation's
  `host`; the predicate must hold exactly on the systems in `holdsOn` and on
  no other. `macos` / `linux` / `windows` / `bsd` and `x86_64` / `arm64` /
  `arm32` come from the system; `wsl` is false for every target; `nixos` is the stated fact (below).
- `nixos` is a fact about the host, not about the system name, so an
  evaluation states it: `"nixos": true` or `false`. An evaluation that leaves
  it out has the fact unstated, and must be `"refused": true` when its
  predicate names `nixos` anywhere (instead of `holdsOn`): every implementation
  refuses it on every system, and none reads it as false. Naming it is enough:
  the refusal does not depend on what the operands before it evaluate to, or
  on the order operands are written or canonicalized in (a data file's `when`
  is canonicalized by the planner and read as written by Nix).
- A rejection must be refused by the validator. `unknown-identifier`: the
  predicate names an identifier that is not built in (Nim:
  `EUnknownPredicate` naming `identifier`). `invalid`: malformed or mistyped
  (Nim: `EUnstructured`).
