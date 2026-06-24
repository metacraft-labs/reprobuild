# Windows-System-Resources implementation status

Tracks the per-phase status of the spec at
`metacraft-labs/reprobuild-specs/Windows-System-Resources.md` (merged
as commit `f030bf512824e7b4287b0d31632d6526377d9265`).

This file is **append-only per phase** — the implementation agent
updates the relevant row when a phase moves to "implemented (awaiting
review)"; the review agent updates it again to "reviewed + committed"
once the commit lands. Do not delete or rewrite past rows.

## Phase status

| # | Phase | Status | Commit | Notes |
|---|-------|--------|--------|-------|
| A | `fs.systemFile` external sources (`sourceUrl + sha256`, `sourceLocal`) | reviewed + committed | `d7ea49c8` | Ran all five spec-mandated test files; each is the only suite in its own binary, so the `[OK]` count IS the pass count. `libs/repro_profile/tests/t_smoke_repro_profile.nim`: 104 OK / 0 FAILED. `libs/repro_infra/tests/t_smoke_repro_infra.nim`: 163 OK / 0 FAILED. `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`: 273 OK / 0 FAILED. `libs/repro_profile_compile/tests/t_smoke_system_apply_integration.nim`: 12 OK / 0 FAILED. `tests/e2e/m83/t_e2e_repro_profile_compile.nim`: 9 OK / 0 FAILED. Reviewer reproduced all five pass-counts and ran the wider regression sweep across `libs/repro_profile/tests/`, `libs/repro_infra/tests/`, `libs/repro_elevation/tests/`, `libs/repro_profile_compile/tests/` (incl. `t_m2_nixos_darwin_modules`, `t_sandbox_m1_fhssandbox_driver`, `t_smoke_apply_integration`, `t_smoke_module_imports`, `t_smoke_profile_adapter`, `t_smoke_repro_profile_compile`, `t_template_in_template_named_args`) — no regressions. |
| B | `windows.service` schema extension (displayName, binPath, recoveryActions, recoveryResetSeconds) | reviewed + committed | `23c54537` | Ran all five spec-mandated test files; each is the only suite in its own binary, so the `[OK]` count IS the pass count. `libs/repro_profile/tests/t_smoke_repro_profile.nim`: 113 OK / 0 FAILED. `libs/repro_infra/tests/t_smoke_repro_infra.nim`: 173 OK / 0 FAILED. `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`: 295 OK / 0 FAILED. `libs/repro_profile_compile/tests/t_smoke_system_apply_integration.nim`: 16 OK / 0 FAILED. `tests/e2e/m83/t_e2e_repro_profile_compile.nim`: 10 OK / 0 FAILED. Reviewer reproduced all five pass-counts and ran the wider regression sweep across `libs/repro_profile/tests/`, `libs/repro_infra/tests/`, `libs/repro_elevation/tests/`, `libs/repro_profile_compile/tests/` (incl. `t_m2_nixos_darwin_modules` 20 OK, `t_sandbox_m1_fhssandbox_driver` 35 OK, `t_smoke_apply_integration` 3 OK, `t_smoke_module_imports` 12 OK, `t_smoke_profile_adapter` 88 OK, `t_smoke_repro_profile_compile` 16 OK, `t_template_in_template_named_args` 2 OK) — no regressions. |
| C | `windows.scheduledTask` new resource | reviewed + committed | `23c18351` | All five spec-mandated test files run cleanly; each is the only suite in its own binary, so the `[OK]` count IS the pass count. `libs/repro_profile/tests/t_smoke_repro_profile.nim`: 133 OK / 0 FAILED. `libs/repro_infra/tests/t_smoke_repro_infra.nim`: 185 OK / 0 FAILED. `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`: 322 OK / 0 FAILED. `libs/repro_profile_compile/tests/t_smoke_system_apply_integration.nim`: 20 OK / 0 FAILED. `tests/e2e/m83/t_e2e_repro_profile_compile.nim`: 11 OK / 0 FAILED. Fix applied after first review pass: `windowsScheduledTask` template `runWithHighestPrivileges` is now sentinel-aware (parameter type `Option[bool]`, default `none(bool)`) so the text parser's principal-dependent default applies when unset. Added three tests covering LOCAL_SERVICE default -> false, SYSTEM default -> true, SYSTEM explicit-false round-trip. (Per-suite pass-counts above reflect post-fix totals: +3 in `t_smoke_repro_profile` template-surface tests, +3 in `t_smoke_repro_infra` end-to-end tests.) Reviewer reproduced all five pass-counts and ran the wider regression sweep across `libs/repro_profile/tests/`, `libs/repro_infra/tests/`, `libs/repro_elevation/tests/`, `libs/repro_profile_compile/tests/` (incl. `t_m2_nixos_darwin_modules` 20 OK, `t_sandbox_m1_fhssandbox_driver` 35 OK, `t_smoke_apply_integration` 3 OK, `t_smoke_module_imports` 12 OK, `t_smoke_profile_adapter` 88 OK, `t_smoke_repro_profile_compile` 16 OK, `t_template_in_template_named_args` 2 OK) — no regressions. Reviewer audit confirmed: zero pre-existing test assertions were modified (1235 insertions / 0 deletions across all test files); the fix is pure addition. |
| D | `fs.systemDirectory` ACL apply (carry-over from reprobuild#7's TODO) | reviewed + committed | `2228c183` | All five spec-mandated test files run cleanly; each is the only suite in its own binary, so the `[OK]` count IS the pass count. `libs/repro_profile/tests/t_smoke_repro_profile.nim`: 137 OK / 0 FAILED. `libs/repro_infra/tests/t_smoke_repro_infra.nim`: 189 OK / 0 FAILED. `libs/repro_elevation/tests/t_smoke_repro_elevation.nim`: 344 OK / 0 FAILED. `libs/repro_profile_compile/tests/t_smoke_system_apply_integration.nim`: 21 OK / 0 FAILED. `tests/e2e/m83/t_e2e_repro_profile_compile.nim`: 12 OK / 0 FAILED. New m83 fixture `tests/fixtures/m83/system_fssystemdirectory_acl.nim` covers every documented `aclInheritance` value, the Allow + Deny ACE pivot, and an owner-unset stanza. Phase D shipped pure argv assemblers (`renderTakeownDirCommandArgs`, `renderIcaclsSetOwnerCommandArgs`, `renderIcaclsInheritanceCommandArgs`, `renderIcaclsGrantCommandArgs`) + the `splitDirAclEntry` Allow/Deny splitter + the drift digest contribution (`canonicalDirAclDesired`, `canonicalDirAclObserved`, `dirAclMatchesDesired`, `fsSystemDirectoryDigestPayload`, `normalizeDirAclEntry`) in `posix_system_parse.nim`. `observeFsSystemDirectory` now folds the live `icacls <path>` observation into the digest when `dirAclPresent == true` (cross-platform pure when false, byte-identical to PR #7's legacy `BLAKE3("fs.systemDirectory:present")` form). `applyFsSystemDirectory` reuses the pure assemblers via `renderArgvAsShellCmd` for the Windows shell-out + adds a strict post-apply re-probe asserting the live ACL digest matches desired. Reviewer reproduced all five pass-counts and ran the wider regression sweep across `libs/repro_profile/tests/`, `libs/repro_infra/tests/`, `libs/repro_elevation/tests/`, `libs/repro_profile_compile/tests/` (incl. `t_m2_nixos_darwin_modules` 20 OK, `t_sandbox_m1_fhssandbox_driver` 35 OK, `t_smoke_apply_integration` 3 OK, `t_smoke_module_imports` 12 OK, `t_smoke_profile_adapter` 88 OK, `t_smoke_repro_profile_compile` 16 OK, `t_template_in_template_named_args` 2 OK) — no regressions. Reviewer audit confirmed: zero pre-existing test assertions were modified (568 insertions / 0 deletions across all test files); the new tests are pure addition. Spec said "PR #7's stub" but PR #7 was not a stub — icacls was actually invoked inline; the implementer correctly identified + closed three real gaps (no pure argv assemblers, no ACL in observation digest, no post-apply ACL re-probe). LoC: spec said ~100, landed ~363 production LoC — the expansion is justified gap-filling (pure assemblers + canonical-digest helpers + drift comparison), not gold-plating. The `protected-clear-inherited` ↔ `disabled-replace` distinction is real: the narrower `windows.acl` validator rejects `protected-clear-inherited`; only the wider `DirectoryAclInheritanceModes` set accepts it; the codec round-trip preserves the operator's choice + each value digests distinctly. Parallel `canonicalDir*` helpers (vs reusing `windows.acl`'s `canonicalAcl*`) are justified: wider inheritance vocabulary, cross-platform driver, and the canonical-key prefix differs (`dirAcl:...` vs `acl:<path>:...`) so a stray shared call cannot accidentally collide. |
| E | Build-engine `requiresElevation = true` edge attribute + `@FILE:<path>` argv preprocessor | pending | — | |
| F | `expandArchive` stdlib package (platform-native tool dispatch) | pending | — | |

## Status vocabulary

  * **pending** — not started.
  * **in progress** — implementer agent is mid-flight on this phase.
  * **implemented (awaiting review)** — implementer reports done; tests
    they ran are listed in Notes; commit field remains `—`.
  * **review failed: <summary>** — reviewer found issues; fix agent
    needed.
  * **reviewed + committed** — reviewer ran the full required test
    suite + a regression sweep, status update verified, commit landed.
    Commit SHA recorded.

## Per-phase test gates

Each phase MUST satisfy at minimum:

  * The spec's stated test plan for that phase (see §7 of the spec).
  * No regressions in any of the smoke test suites the spec mentions:
    `t_smoke_repro_profile`, `t_smoke_repro_infra`,
    `t_smoke_repro_elevation`, `t_smoke_system_apply_integration`,
    and the relevant `tests/e2e/m83/` fixture run.

The review agent must run these explicitly and quote the
pass/fail/test-count line for each suite in their report.
