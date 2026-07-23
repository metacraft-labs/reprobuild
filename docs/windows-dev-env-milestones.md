# Windows dev-env enablement — milestone tracker

Goal: make `repro exec` / `repro shell` / the direnv-like hook work on Windows
for the metacraft sibling repos (which carry `repro.nim` recipes tested on Linux
only), with source/tarball provisioning backed by a binary cache, and
configurable dev-env trust policies. Driven serially by sub-agents; one commit
per confirmed fix.

Windows build/test primer (agents):
- Build the CLI: `just bootstrap` in `D:\m\codetracer-reprobuild\reprobuild`
  (needs siblings `runquota` + `nim-bearssl`, present; Nim 2.2.8 at
  `D:\metacraft-dev-deps\nim`). Output `build/bin/repro.exe`.
- Run a single Nim test: `nim c -r --hints:off tests/integration/<t>.nim` from
  the repo root (config.nims applies the lib `--path`s).
- Full suite: `bash ./scripts/run_tests.sh` (heavy). Known pre-existing Windows
  flake: engine-cache `.rbar` handles keep temp dirs busy so
  `removeDirEventually` teardown can raise "directory is not empty" — this is
  NOT a regression; distinguish it from real failures.
- Exec/shell manual check: put `build/bin` + Nim on PATH, set
  `REPRO_DEV_ENV_AUTO_ALLOW=1`, run inside a sibling repo, e.g.
  `repro exec -- echo hi`.

Status legend: TODO / IN-PROGRESS / IMPLEMENTED (impl agent) / VERIFIED (review
agent) / DONE (my plan-conformance review passed).

---

## M0 — Interface-extraction `package` collision  ·  DONE
Renamed the zero-caller `package` proc in `packages/nim.nim` → `nimPackage` so
recipes importing `packages/nim` (io-mon, recorders) stop failing interface
extraction with "undeclared identifier: '<pkgname>'". Committed to dev
(`fix(dsl): rename colliding nim package proc ...`). Baseline for M1+.

## M1 — Derive an implicit dev-env from `uses:`  ·  VERIFIED
A recipe with a `uses:` toolchain floor but NO explicit `devEnv:` block must
still expose a dev-env introspection entry point, so `repro exec`/`shell`/hook
resolve the toolchain floor as the dev environment. Today `hasDevEnv`
(`repro_project_dsl/.../macros_a.nim:1411`) is set only inside an explicit
`devEnv:` block, and `runtime_provider.nim:36` gates the `gpkDevEnvIntrospection`
entry on it, so `uses:`-only recipes (nim-acp + ~67, incl. reprobuild's own)
fail exec/shell with "provider manifest does not expose dev-env introspection".
Acceptance:
- A `uses:`-only package's compiled provider manifest exposes a
  `gpkDevEnvIntrospection` entry; introspection returns the toolchain-floor env.
- `repro exec -- <cmd>` / `repro shell --print-env` succeed on a `uses:`-only
  recipe whose floor tools are resolvable (e.g. nim-acp: nim/nimble on PATH).
- Explicit-`devEnv:` recipes keep their richer behavior (regression-free).
- New automated tests cover: provider manifest has the entry for a uses:-only
  package; exec/shell resolves it. No weakened/ignored existing tests.

### Implementation (IMPLEMENTED 2026-07-22)
Design — an IMPLICIT dev-env derived from the `uses:` floor that reuses the
existing dev-env derivation with an empty "extra" body (no parallel code path):

- The dev-env introspection body (`buildPackageDevEnv`,
  `runtime_provider.nim`) ALREADY appends `pkg.toolUses` to the result's
  `toolRequirements` for the explicit path. So the toolchain floor is already
  the substance of the dev-env env; the implicit case is just "run no extra
  devEnv body, keep the floor append". The floor tool requirements flow into
  the same downstream `computePublicDevEnv` / RBDE machinery unchanged, so the
  env `repro exec`/`shell` resolve is identical to what an explicit-`devEnv:`
  recipe with the same floor would derive (minus the block's extra tasks/env).

Files changed:
- `libs/repro_project_dsl/src/repro_project_dsl/types.nim` — added
  `exposesDevEnvIntrospection*(pkg): bool = pkg.hasDevEnv or pkg.toolUses.len > 0`
  (the M1 "equivalent gate"). `hasDevEnv` is intentionally NOT flipped, so it
  keeps meaning "explicit `devEnv:` block present" for every other reader
  (interface extraction, the standard-provider convention literals that set
  `hasDevEnv: false`, etc.); the new predicate is the single gate for exposing
  the entry point.
- `libs/repro_project_dsl/src/repro_project_dsl/runtime_provider.nim` — the
  manifest gate (`providerManifest`) now uses `exposesDevEnvIntrospection(pkg)`
  instead of `pkg.hasDevEnv`, so a non-empty `uses:` floor exposes the
  `gpkDevEnvIntrospection` entry. `buildPackageDevEnv` no longer raises on a
  nil `devEnvProc`; a nil proc is the implicit case (the DSL emits no
  `devEnv<Package>` proc when there is no `devEnv:` block), so it just skips
  running the extra body and lets the `pkg.toolUses` append carry the floor.
- `libs/repro_project_dsl/src/repro_project_dsl/macros_a.nim` — in
  `parsePackageDef`, after `m9r15pAutoInjectQt6Transitive`, when there is no
  explicit `devEnv:` block but `toolUses` is non-empty, set a deterministic,
  content-derived `devEnvBodyHash` computed from the floor (rawConstraint /
  selector / executable / policyPath / gate of each `PackageUseDef`). This
  gives the implicit manifest entry a stable, floor-derived body hash that
  re-keys when the floor changes (the engine cross-checks the request/result
  body hash against the manifest).

Note: the DSL only emits a provider serve loop (`runPackageProvider`) when a
package has a `build:` OR `devEnv:` body (`buildCode` in `macros_b.nim`
early-returns otherwise). All real uses:-only leaf recipes (nim-acp,
reprobuild's own) carry a `build:` block, so they get the serve loop; a recipe
with neither block produces no provider binary at all (unchanged, out of scope).

Tests added:
- `tests/e2e/dev-env/t_e2e_provider_dev_env_implicit_floor.nim` (modeled on the
  existing `t_e2e_provider_dev_env_introspection.nim`; compiles a real provider
  binary from a `uses:`-only fixture — floor `nim`/`gcc`, a `library`, and a
  minimal `build: discard`, no `devEnv:` block):
  1. `uses_only_manifest_exposes_dev_env_introspection` — asserts the compiled
     provider manifest exposes exactly one `gpkDevEnvIntrospection` entry with
     id `floorfixture.dev-env` and a non-empty (floor-derived) body hash.
  2. `uses_only_introspection_returns_toolchain_floor` — asserts
     `invokeProviderDevEnvIntrospection` resolves the recipe and the result's
     `toolRequirements` carry the floor (`nim`, `gcc`), while `tasks` /
     `services` / `declaredActivities` are empty (no extra `devEnv:` body), and
     the provider source is still recorded as an evaluation input / source
     fingerprint.

Validation observed (Windows, `build/bin` + Nim on PATH,
`REPRO_DEV_ENV_AUTO_ALLOW=1`):
- `nim-acp` (`uses:`-only): `repro exec -- echo hi` → prints `hi`, exit 0.
  `repro shell --print-env=powershell` → prints the dev-env env block
  (`REPRO_DEV_ENV_ARTIFACT`, `..._PROJECT_ROOT`, `..._SELECTED_ACTIVITIES=default`,
  empty `..._TASKS`/`..._SERVICES`), exit 0. Previously both failed with
  "provider manifest does not expose dev-env introspection".
- `io-mon` (explicit `devEnv:`): `repro shell --print-env` now fails LATER with
  `build graph made no progress; pending actions:` (the M2 provisioning concern)
  — it gets PAST introspection, i.e. no regression at the introspection stage.
- New test: both cases `[OK]`. Existing
  `t_e2e_provider_dev_env_introspection.nim`: both cases `[OK]` (regression-free).

### Review (VERIFIED 2026-07-22)
Adversarial review agent. Ran (Windows, `build/bin` + Nim 2.2.8 on PATH,
`clingo.dll` staged in `build/bin`, `REPRO_DEV_ENV_AUTO_ALLOW=1`):
- Diff review: the three source edits are a minimal, principled reuse of the
  existing dev-env derivation (new `exposesDevEnvIntrospection` gate;
  `buildPackageDevEnv` tolerates a nil `devEnvProc`; implicit floor-derived
  `devEnvBodyHash`). Confirmed the `pkg.toolUses` floor-append at
  `runtime_provider.nim:276` runs unconditionally, so the implicit case reuses
  the exact same `DevEnvResult` construction — no parallel path. No existing
  test weakened/skipped/disabled; no out-of-scope changes.
- Clean rebuild via `scripts/build_apps.sh`: `build/bin/repro.exe` builds green,
  `repro --version` → `repro 0.1.2`.
- New test `t_e2e_provider_dev_env_implicit_floor.nim`: both cases `[OK]`. It
  compiles a REAL provider from a `uses:`-only fixture and asserts exactly one
  `gpkDevEnvIntrospection` entry (`floorfixture.dev-env`, non-empty floor body
  hash) and that introspection returns `nim`/`gcc` as `toolRequirements` with
  empty tasks/services/declaredActivities — a genuine exercise of the
  uses:-only path.
- Reference `t_e2e_provider_dev_env_introspection.nim`: both cases `[OK]`
  (explicit-`devEnv:` path regression-free). Provider integration tests
  `t_rp1_provider_compile_edge_materializes`, `t_rp2_provider_session_invoke`
  (all 3 cases) `[OK]`. `t_e2e_dev_env_deactivate_per_shell` (7 cases) `[OK]`.
  All seven `libs/repro_project_dsl/tests` macro tests `[OK]`.
- Acceptance E2E: nim-acp (`uses:`-only) `repro exec -- echo hi` → `hi` (exit 0);
  `repro shell --print-env=powershell` prints the env block
  (`REPRO_DEV_ENV_ARTIFACT`, `..._PROJECT_ROOT`, `..._SELECTED_ACTIVITIES=default`,
  empty `..._TASKS`/`..._SERVICES`), exit 0. io-mon (explicit `devEnv:`) gets
  PAST introspection and fails later at provisioning ("build graph made no
  progress") — expected M2 scope, not a regression.
- Regression analysis: the e2e tests that spawn the real binary against the
  explicit-`devEnv:` fixture (export bash/fish/nushell/pwsh/zsh, deactivate
  round-trip/tampered, edge_cache, develop_overrides) fail at the M2
  provisioning gap ("build graph made no progress"); `performance_gates` hits
  the known `.rbar` `removeDirEventually` teardown flake; the integration test
  `t_l3_build_block_public_interface_tagged_in_provider_mode` fails at a
  pre-existing Windows subprocess quirk (`execCmdEx` cannot resolve bare `nim`).
  Confirmed PRE-EXISTING by `git stash`ing the M1 changes, rebuilding, and
  reproducing `export_bash` + `deactivate_round_trip` with byte-identical
  failures on the clean baseline (and the introspection test still green there),
  then `git stash pop` + rebuild. M1's only behavioral change is exposing
  introspection for `uses:`-only recipes; the explicit-`devEnv:` path is
  provably untouched (`hasDevEnv` unchanged, `devEnvProc` non-nil, the implicit
  hash block skipped), so none of these are regressions.

## M2 — Windows provisioning policy: default off `path`  ·  TODO
On Windows, do not honor `defaultToolProvisioning "path"`; provision the
toolchain floor from source or scoop-like tarballs instead. Add a real policy
lever (config file and/or `REPRO_TOOL_PROVISIONING`, with a Windows default) and
wire it into `~/dotfiles`. Also: (a) `parseDevEnvToolProvisioning`
(`repro_dev_env_engine.nim:171`) must accept `from-source` (today `normalize()`
keeps the hyphen; only `source`/`fromsource` parse); (b) a failing dev-env
provisioning action must surface a real diagnostic instead of collapsing to
"build graph made no progress; pending actions:" (empty) — see
`repro_build_engine.nim:5657`.
Acceptance:
- On Windows a `path`-defaulted recipe is provisioned via source/tarball per
  policy (validated by exec/build actually provisioning, not erroring).
- `from-source` parses; a provisioning failure reports the offending action.
- Automated tests for the policy resolution + parsing + the surfaced diagnostic.

### M2a — surface the swallowed no-progress failure (VERIFIED 2026-07-22)
Sub-item (b) above ONLY. When the build graph can advance no further —
nothing running/ready/launchable yet `completed < total` — the engine raised
`build graph made no progress; pending actions:` with an EMPTY list, because the
stall is caused by a FAILED action whose dependents were cascaded to `asBlocked`
(none are `asPending`, so the old pending-only list was empty and hid the cause).

Fix (`libs/repro_build_engine/src/repro_build_engine.nim`, the no-progress raise
at ~5650): the raise path now reconstructs the terminal failures. It walks
`buildGraph.actions` and, for each, keys off `statuses[id]`: `asFailed` actions
are listed with their `stderr` (falling back to `reason`, then `exit <code>`);
`asBlocked` actions are listed with their `blockedBy` blocker; `asPending`
actions keep the historical list. The message keeps the
`build graph made no progress` prefix and a trailing `pending actions:` segment
so existing prefix/substring consumers still match, but now leads with
`failed actions: <id> (<reason>); blocked actions: <id> (blocked by <id>)`. This
is diagnostic-surfacing only — the miscounting offender (a failing built-in's
`inc completed` at ~5471, analogous to the already-fixed broker path) is
deliberately left as-is; the raise now names the failure regardless.

Test: `libs/repro_build_engine/tests/test_no_progress_diagnostic.nim` — builds a
2-node graph with a deliberately failing built-in (`bakCopyFile` with zero
inputs → `asFailed` with a real message) and a dependent (cascaded `asBlocked`),
runs `runBuild`, and asserts the raised `BuildEngineError` names the failing
action id, carries its reason, lists the blocked dependent, and does NOT collapse
to the empty pending-only message. Passes under `nim c -r --hints:off`. Existing
`test_elevated_inline_exec_hook.nim` assertions unaffected (its Windows failures
are the documented `.rbar` `removeDirEventually` teardown flake, reproduced
byte-identically on the git-stash baseline — not a regression).

ACTUAL io-mon dev-env failure now revealed (verbatim, `repro shell
--print-env=powershell`, `REPRO_DEV_ENV_AUTO_ALLOW=1`), the key M2 driver:

```
repro shell: error: build graph made no progress; failed actions: nix-provision.nim (bakForeignProvision is not supported on Windows); nix-provision.nimble (bakForeignProvision is not supported on Windows); nix-provision.sh (bakForeignProvision is not supported on Windows); nix-provision.gcc (bakForeignProvision is not supported on Windows); blocked actions: __repro_provider_compile (blocked by nix-provision.nim); pending actions:
```

Root cause for M2b/M2c: io-mon's toolchain floor (`nim`, `nimble`, `sh`, `gcc`)
is provisioned via `bakForeignProvision` (nix-daemon-backed) actions, and
`executeBuiltinAction` hard-raises `bakForeignProvision is not supported on
Windows` (`repro_build_engine.nim:3889`). So the Windows provisioning policy (M2)
must replace/avoid the nix-`bakForeignProvision` path for the floor tools
(source/tarball provisioning), not merely re-key it. Follow-up noted, NOT fixed
in this cycle (scope): the nix daemon path in `executeBuiltinAction` is also
POSIX-only (`connectUnix` to `/tmp/...`), so even off the hard-raise it could not
serve Windows as-is.

## Sequencing decision (2026-07-23)
User chose: primary Windows provisioner = **from-source** (cache-backed), and **cache (M3) first**, then M2c on top. Order now: M3 → M2c → M2b → M4 → M5.

## M3 — high-mem-server binary cache  ·  IN-PROGRESS (Commit A done)
Architecture (verified): the "repro binary cache" is a **reprobuild-native** server at `https://repro-cache.metacraft-labs.com` (nginx → `127.0.0.1:7878`, NetBird-gated, publish gated by an allowed-signers allowlist; reads need only the VPN + a trusted-key match, no token). This host (eli-pc) is on NetBird and resolves it. Client reads INI `caches.conf` (`REPRO_CACHES_CONFIG` env → `%PROGRAMDATA%\repro\caches.conf` → `%XDG_CONFIG_HOME%\repro\caches.conf` else `~/.config`); trust is declarative via `trusted-public-keys`. CI push is already wired (`reprobuild/.github/workflows/ci.yml` → that endpoint, signed with `REPRO_PUBLISH_KEY`/`_CERT` secrets which exist). Server service + fleet config currently live only on infra branch `repro-cache/workstation-publisher-nixfmt` (not merged to `live`).
- **Commit A (DONE, dotfiles 83b905a, not pushed):** dotfiles manage `stow/repro/.config/repro/caches.conf` + `REPRO_CACHES_CONFIG` env (fixes the `XDG_CONFIG_HOME=%APPDATA%` mis-placement so local installs substitute from the cache). Validated: config-load + real server-reached MISS over NetBird + `home plan` 51/0. Bundled with the earlier reprobuild-Windows dotfiles integration (install + native pwsh hook + direnv retirement).
- **Commit C (RESOLVED — already-done):** the cache service + fleet config are already on the latest `metacraft-labs/live`; the deployed server matches. Only a cosmetic (nixfmt) formatting commit from `repro-cache/workstation-publisher-nixfmt` remains unmerged, which does not change service behavior. No functional action outstanding.
- **Commit D (OPEN, verify):** confirm the reprobuild CI publish job runs on a NetBird-connected self-hosted runner (else `POST /publish` to the NetBird-only endpoint silently no-ops; publish is best-effort so CI stays green while populating nothing).
- **Commit B (SKIPPED unless requested):** workstation publisher keypair as age secret (optional; only needed to publish FROM the workstation).

## M3 (original text) — high-mem-server binary cache
Configure the repro binary cache on high-mem-server (managed in
`d:\m\dev\infra`) as a trusted substituter in `~/dotfiles`; configure CI to push
built binaries to it; make local installs/provisioning fetch from it and be
fast. Investigate `d:\m\dev\infra` first for the cache URL/public key + push
auth; propose exact dotfiles + CI changes; nothing secret committed without
confirmation.
Acceptance: local provisioning demonstrably fetches from the cache; CI push
path configured; validated end-to-end.

## M3-E — Per-platform CI publish to the repro binary cache  ·  VERIFIED (2026-07-23)
Goal: make reprobuild CI publish per-platform `repro build` outputs to the fleet
binary cache (`https://repro-cache.metacraft-labs.com`) from every platform
builder — not just Linux — so the cache holds artifacts for all OS×arch targets.
This is the prerequisite that lets from-source dev-env provisioning (M2c) *fetch*
prebuilt Windows/ARM tools instead of building them locally.

### Before (publish coverage)
- `.github/workflows/ci.yml` → job "test" (Linux bare-metal), step "Build
  codetracer ct (via reprobuild)" already sets `REPRO_PUBLISH_KEY`/`_CERT` from
  secrets, writes them to `$RUNNER_TEMP`, exports the three `REPRO_BINARY_CACHE_*`
  env vars, and runs `repro build ct`. This publishes the **linux-x64 ct** build
  only.
- `.github/workflows/release.yml` → job "build-release" builds `.#reprobuild.build_apps`
  on a per-platform matrix (linux, macOS-arm64, windows) but did NOT set any
  publish env — so those platform builds populated **nothing**.

### Change (what was implemented)
- New composite action `.github/actions/setup-repro-publish/action.yml` — factors
  the ci.yml inline publish snippet into ONE reusable, cross-platform step:
  writes the signing key/cert from the `REPRO_PUBLISH_KEY`/`REPRO_PUBLISH_CERT`
  secrets to `$RUNNER_TEMP` and exports `REPRO_BINARY_CACHE_URL`/`_KEY_PATH`/`_CERT_PATH`
  to `$GITHUB_ENV`. It runs a **bash** leg on Linux/macOS and a **pwsh** leg on
  Windows (selected via `runner.os`), so the identical wiring works on every
  matrix leg. The pwsh leg writes the PEM bytes with `System.IO.File.WriteAllText`
  + UTF8-no-BOM so the key/cert parse byte-exact.
- `release.yml` gains one step, "Configure repro binary-cache publish", before the
  Bootstrap-and-Build steps (POSIX + Windows). The build steps inherit the
  exported `REPRO_BINARY_CACHE_*` env vars from `$GITHUB_ENV`, so reprobuild's
  in-process engine publisher (`mkBinaryCachePublisher`, wired into
  `BuildEngineConfig.binaryCachePublisher` by `executeBuildTarget`) signs and
  POSTs each platform's `build_apps` outputs. The publisher is independent of the
  repro-daemon, so it works under the release build's `--daemon=off`.
- ci.yml is left as-is (its inline snippet is functionally identical to the
  composite; not refactored to avoid churn on the delicate ct build step).

### Best-effort / non-fatal (unchanged semantics)
- Publish is gated on BOTH secrets being present. Fork PRs receive no secrets →
  the composite exports nothing → the publisher self-generates a local (non-
  allowlisted) keypair and any POST is rejected best-effort; the build stays
  green. Matches the existing "key-empty disables" behavior.
- A publish failure at runtime (e.g. a runner not on the NetBird VPN that fronts
  the cache) is non-fatal: the engine wraps the publisher in try/except and, on a
  non-`ok` result, only increments a "repro binary-cache publish failures"
  stats counter — it does NOT abort the build (`repro_build_engine.nim` ~4368;
  `BinaryCachePublishResult` doc ~626: "the engine logs the diagnostic into stats
  but does NOT abort the build").

### Coverage matrix (os × arch → runner → publishes now?)
| os × arch      | runner label(s)                       | workflow leg                      | runs `repro build`? | publishes now? |
|----------------|---------------------------------------|-----------------------------------|---------------------|----------------|
| linux x64      | `eph-linux-x64`                       | release.yml (build_apps) + ci.yml (ct on Linux bare-metal) | yes | **YES** |
| macos arm64    | `eph-macos-arm64`                     | release.yml (build_apps)          | yes                 | **YES** |
| windows x64    | `[eph-win-x64, eph-win-arm64]`        | release.yml (build_apps)          | yes                 | **YES** |
| linux arm64    | — (no runner class)                   | —                                 | no                  | **MISSING runner** |
| macos x64      | — (no runner class)                   | —                                 | no                  | **MISSING runner** |
| windows arm64  | — (no dedicated matrix row/runner)    | —                                 | no                  | **MISSING runner** |

Notes on the gaps (no runners fabricated — see task rule 3):
- **linux-arm64** and **macos-x64** have no `eph-linux-arm64` / `eph-macos-x64`
  runner class today. Adding one matrix row per target (runner + `arch`) to
  `release.yml` is all that's needed — the publish step is generic per `runner.os`
  and activates automatically on the new leg with no change to the composite.
- **windows-arm64**: `release.yml`'s single windows matrix row declares
  `runner: [eph-win-x64, eph-win-arm64]` (a labels-AND requirement) with
  `arch: x86_64`, so it produces exactly one **x86_64** windows artifact. A
  distinct windows-arm64 build needs its own matrix row (its own runner + an
  `aarch64` arch tag). This label/arch shape is PRE-EXISTING and left untouched
  (out of scope: "only the CI publish wiring"). The publish wiring will cover it
  the moment such a row exists.

### Post-CI verification plan (cannot fully validate without a CI run)
A push to `dev` does not run `release.yml` (it triggers on `v*` tags /
`workflow_dispatch`). To exercise the new publish paths:
1. Trigger `release.yml` via `workflow_dispatch` (or push a `v*` tag). Each matrix
   leg's "Configure repro binary-cache publish" step logs
   `repro binary-cache publish ENABLED -> https://repro-cache.metacraft-labs.com`
   when the secrets are present, and the following Bootstrap-and-Build step's
   `repro build .#reprobuild.build_apps` fires the engine publisher for the
   install/stage-copy actions tagged `publishToBinaryCache`.
2. Expected cache entries after a full run: `build_apps` outputs for
   **linux-x86_64** (eph-linux-x64), **darwin-aarch64** (eph-macos-arm64), and
   **windows-x86_64** (windows runner) — plus the existing **linux-x64 ct**
   entry from ci.yml on `main`/`dev` pushes.
3. Verify server-side by either (a) checking the cache access log on the server
   (eli-pc, `127.0.0.1:7878` behind nginx) for `POST /publish` from each runner's
   allowlisted publisher pubkey, or (b) from a NetBird-connected workstation, run
   `repro cache lookup <entry-key>` / walk the cache
   (`tools/binary-cache/walk.sh`) for a just-built per-platform entry.
4. Caveat: the `eph-*` release runners are NOT guaranteed to be on NetBird. If a
   given runner cannot reach the NetBird-only `/publish` endpoint, its publish
   soft-fails (stats counter only) and populates nothing — the build still passes.
   Confirming actual population therefore also confirms that runner's NetBird
   connectivity; a green build alone does not. (This is the same open concern
   tracked as M3 "Commit D".)

## M4 — Dev-env trust-level policies  ·  TODO
Configurable trust levels for `repro dev-env`: (a) strict — refuse to execute any
file not previously approved, using the precise set of files executed during
dev-env evaluation; (b) directory-approved gate (current default). User picks the
level at `repro allow` time and controls default-allow behavior via config.
Acceptance: strict mode refuses an unapproved executed file and approves the
exact set; directory gate unchanged; level chosen at allow time; config default.
Automated tests for each level + the config default.

## M5 — End-to-end validation  ·  TODO
`repro exec` / `repro shell` / the hook work on a representative set of metacraft
repos (at least one `uses:`-only leaf and one `devEnv:` recorder), provisioned
per the Windows policy and served by the cache. Record the validated repos +
commands here.

---

## Log
- 2026-07-22: M0 done (package-proc rename, pushed to dev). Milestones drafted.
- 2026-07-22: M1 IMPLEMENTED. Implicit floor-derived dev-env: `uses:`-only
  recipes now expose `gpkDevEnvIntrospection` via
  `exposesDevEnvIntrospection(pkg)`; `buildPackageDevEnv` tolerates a nil
  devEnvProc; implicit `devEnvBodyHash` is content-derived from the floor.
  Added `t_e2e_provider_dev_env_implicit_floor.nim`. Validated: nim-acp
  `repro exec -- echo hi` → `hi` (exit 0), `repro shell --print-env` prints env;
  io-mon gets past introspection (later M2 "no progress"); existing dev-env
  introspection test still green. Left uncommitted for the review agent.
- 2026-07-22: M1 VERIFIED by review agent. New implicit-floor test + reference
  introspection test + provider RP1/RP2 integration tests + deactivate-per-shell
  + all DSL macro tests green; nim-acp exec/shell acceptance reproduced. All
  observed dev-env/provider failures confirmed PRE-EXISTING via git-stash
  baseline rebuild (M2 provisioning gap, `.rbar` teardown flake, and a Windows
  `execCmdEx` bare-`nim` resolution quirk) — no regression. Committed to dev.
- 2026-07-22: M2a IMPLEMENTED. The "build graph made no progress" raise path now
  reconstructs terminal failures (failed actions + reason/stderr; blocked actions
  + blocker) instead of an empty pending list. New test
  `test_no_progress_diagnostic.nim` (green). Rebuilt CLI via `just bootstrap`;
  io-mon `repro shell --print-env=powershell` now reveals the real cause verbatim:
  the toolchain floor is provisioned via `bakForeignProvision` which
  `executeBuiltinAction` hard-raises as "bakForeignProvision is not supported on
  Windows" (`repro_build_engine.nim:3889`) — the root cause that drives the M2
  provisioning policy. Diagnostic-surfacing only; provisioning policy/from-source
  parse left for M2b/M2c. Left uncommitted for the review agent.
- 2026-07-22: M2a VERIFIED (review agent). Reviewed the diff (minimal, confined to
  the `runBuild` no-progress raise branch; no success-path or existing-test change;
  the `inc completed` miscount deliberately left as documented). `just bootstrap`
  rebuilt `build/bin/repro.exe` clean. `test_no_progress_diagnostic.nim` passes
  under `nim c -r --hints:off` and exercises the real raise path (failing
  `bakCopyFile` + cascaded `asBlocked` dependent; asserts the failing id, its
  reason substring, the blocked dependent, and that it does NOT collapse to the
  empty pending-only message). io-mon `repro shell --print-env=powershell`
  (`REPRO_DEV_ENV_AUTO_ALLOW=1`) reproduces the recorded verbatim diagnostic
  byte-for-byte. Ran the full `libs/repro_build_engine/tests/*` group plus the
  `t_e2e_provider_dev_env_introspection` e2e (green). Failures are all
  pre-existing, confirmed byte-identical on the git-stash baseline: the `.rbar`
  `removeDirEventually` teardown flake (`test_binary_cache_publisher_hook`,
  `test_elevated_inline_exec_hook`), a `duplicate implicit target name` fixture
  error (`m1_fixtures_ambiguity`, `m1_fixtures_basename`), and a `clingo.dll`
  load-path environment issue (resolved by putting clingo 5.8.0 on PATH). No
  regression. Committed to dev.
- 2026-07-23: M3-E IMPLEMENTED. Per-platform CI publish to the repro binary
  cache. New composite action `.github/actions/setup-repro-publish` (bash + pwsh
  legs, selected by `runner.os`) factors the ci.yml publish snippet into one
  reusable step; `release.yml` now runs it before each Bootstrap-and-Build leg so
  the linux-x64 / macos-arm64 / windows-x64 `build_apps` builds publish their
  outputs (previously only ci.yml's linux-x64 ct build did). Best-effort
  unchanged: gated on `REPRO_PUBLISH_KEY`/`_CERT`; a publish failure only bumps a
  stats counter (`repro_build_engine.nim` ~4368), never fails the build. Missing
  os×arch runners (linux-arm64, macos-x64, windows-arm64) documented as gaps — no
  runners fabricated; the wiring activates automatically when a matrix row/runner
  is added. Both YAML files parse; pwsh/bash legs reviewed shell-correct. Runtime
  push unverifiable without a `release.yml` run (workflow_dispatch / `v*` tag) —
  post-CI verification plan recorded in the M3-E section. Left uncommitted for the
  review agent. M3 "Commit C" reclassified RESOLVED (already-done): cache service
  is on latest `metacraft-labs/live`; only a cosmetic nixfmt commit remains
  unmerged.
- 2026-07-23: M3-E VERIFIED by review agent. Composite action
  `.github/actions/setup-repro-publish/action.yml` compared byte-for-intent
  against the proven inline publish snippet in `ci.yml` (~407-427): SAME three env
  vars (`REPRO_BINARY_CACHE_URL`/`_KEY_PATH`/`_CERT_PATH`), SAME endpoint
  (`https://repro-cache.metacraft-labs.com`), SAME secrets
  (`REPRO_PUBLISH_KEY`/`_CERT`), SAME both-secrets-present gate; bash leg uses
  `printf '%s'` (no trailing newline), pwsh leg writes PEM via
  `System.IO.File.WriteAllText` + UTF8-no-BOM (no BOM/CRLF), and — unlike ci.yml's
  single-step `export` — correctly exports via `$GITHUB_ENV` so the separate
  Bootstrap-and-Build step inherits it. Non-fatal claim spot-checked:
  `repro_build_engine.nim` 4364-4369 wraps the publisher in try/except and only
  `addCounterMetric("repro binary-cache publish failures", 1)` on `not res.ok` —
  never raises. Wiring: the new step sits after checkout / setup-dev-env and
  before both Bootstrap-and-Build legs, with no `if:` guard so it runs on every
  matrix leg; the composite selects bash (`runner.os != 'Windows'`) vs pwsh
  internally. Coverage matrix reconciled against the actual `release.yml` matrix
  (linux/eph-linux-x64, macos/eph-macos-arm64, windows/[eph-win-x64,eph-win-arm64]
  arch x86_64) — accurate, gaps not fabricated. Both YAML files parse; `actionlint`
  v1.7.12 reports only the two PRE-EXISTING self-hosted `runner-label` warnings
  (lines 21/27), nothing on the new step or composite. Composite schema valid
  (`runs.using: composite`; each step sets `shell:`). No secret bytes committed
  (only `${{ secrets.* }}` refs). Committed to dev.
