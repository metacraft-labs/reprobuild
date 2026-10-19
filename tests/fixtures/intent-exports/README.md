# Export fixtures for the Nix helper library (GM5)

Each case is a profile (`<case>/profile/`) and what Reprobuild says about it:

- `export.json` — `repro home export --host m1` of the profile: the snapshot a
  Nix consumer commits and reads with `reprobuild.lib.readIntent { snapshot =
  …; }`.
- `evaluations.json` — for every host in `hosts` below and every target
  system, what `repro home export --host <host> --target <system>` reports:
  `{ "<host>": { "<system>": <evaluation> | { "refused": true } |
  { "undeclaredHost": true } } }`. This is
  Reprobuild's own evaluation (`evaluateHomeExport`), the answer the Nix
  evaluator (`nix/lib/intent.nix`) must reproduce from `export.json` alone.

Hosts evaluated: `m1`, `home-pc`, `server` (declared, declared, undeclared).
The undeclared host is refused on every system, by `repro home export` and by
the Nix evaluator alike (`{ "undeclaredHost": true }`): a profile with a
`hosts:` registry declares every host it may be applied to (reprobuild-pm
spec Gradual-Nix-To-Reprobuild-Migration.md, Open question 6).

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
  platform `same`. Since GM9 it also has activity-scoped resources (a
  `resources:` block in `activity cli:` and `activity laptop:`, and a data
  resource row with `activity = "cli"`), so each host's evaluation holds only
  the scoped resources of the activities it selects.
  A `when x86_64():` nested in `default`'s `when linux():` puts
  `gm5-linux-x86-tool` in the x86_64-linux evaluations only: nested guards
  conjoin, in the planner and in `nix/lib/intent.nix` alike (reprobuild-pm
  issue 2026-10-18-home-planner-drops-packages-under-nested-activity-guards).
  Since GM10 `m1`'s entry says `system: managedElsewhere("example-org/infra")`,
  so the export carries `intent.systemManagedElsewhere` and every evaluation
  `system` (`elsewhere` for m1, `here` for home-pc); `lib-tests` also checks
  `reprobuild.lib.hostSystemManagement` against them.
- `compile-time` — a `when defined(macosx)` in `resources:`: exported on
  Linux, the darwin targets are `differs` and must be refused; the Linux and
  Windows targets are evaluated.
- `concerns` (GM7) — `hosts:` entries in block form: `m1` declares
  `applies: [applications, environment]`, `server` declares
  `applies: [packages]`, `home-pc` declares nothing. The export carries
  `intent.hostApplies` and the `concerns` classification, including the
  per-system package classification (`concerns.packages`): `gm7app`, defined
  by the fixture catalog `reprobuild-packages/` beside the profile as a disk
  image, is an application on the darwin targets only. The declaring hosts'
  evaluations carry `applies` and each package's `concern` / `resolved`; the
  Home Manager module's switches default to the complement of the
  declaration and packages are routed by their concern (`lib-home-manager`);
  `lib-intent-ifd` exports the profile in the build sandbox with the fixture
  catalog as `packagesCatalog`. Runtime predicates only: every platform
  `same`. Exported on aarch64-darwin (m1) with `$REPROBUILD_PACKAGES_ROOT`
  pointing at the fixture catalog; `--check` and the evaluations do not
  depend on the exporting platform.

The snapshots are produced on x86_64-linux. `export.json`'s `provenance`
records the producing `repro`; `--check` never compares provenance, so a
`repro` upgrade does not make them stale, only a change in what they say.
