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
| A | `fs.systemFile` external sources (`sourceUrl + sha256`, `sourceLocal`) | pending | — | |
| B | `windows.service` schema extension (displayName, binPath, recoveryActions, recoveryResetSeconds) | pending | — | |
| C | `windows.scheduledTask` new resource | pending | — | |
| D | `fs.systemDirectory` ACL apply (carry-over from reprobuild#7's TODO) | pending | — | |
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
