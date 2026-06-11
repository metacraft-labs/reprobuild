# nim-check: skip
#
# Linux-Distro-Recipe-Validation M9 — generation switch + rollback
# demo, profile A.
#
# M9 exercises Reprobuild's M83 generation registry end-to-end on a
# non-NixOS distro: apply A -> apply B -> rollback to A -> verify A's
# state restored -> run `repro home gc` and `repro store gc`. The
# fixture pair (m9_profile_a.nim / m9_profile_b.nim) declares the
# SAME resource address ("rollbackFile") with DIFFERENT content so
# the test driver can byte-compare the live file's contents after
# each transition and assert the generation digest changes.
#
# Both fixtures use a single `fs.userFile` resource — no
# `env.userVariable` (gated `when defined(windows):` per M6's
# documented finding, no-op on Linux), no `env.userPath` (which
# uses a managed-block writer whose rollback semantics are covered
# by the round-trip e2e test inside the Nim suite, not here), no
# package realization (the M64 round-trip e2e covers that path via
# `REPRO_TEST_PACKAGE_SOURCE`; the harness shell-test gate stays
# package-free so it runs against the exact `repro` binary M1-M4
# build, no test-only seam). The fs.userFile primitive is the
# minimum sufficient surface to exercise the four state transitions
# the M9 brief calls out: apply A, apply B, rollback to A, gc.
#
# Host: `m9-test-host` (same pattern as M6 / M7). The test driver
# pins REPRO_HOST so the fixture's `default` activity resolves
# deterministically across all repro-* WSL instances regardless of
# the kernel hostname.

import repro_profile

profile "m9-rollback-profile":

  activity default:
    discard

  resources:
    # Single managed file. Profile A's content is the recognisable
    # marker `m9-profile-A` so the test driver can byte-compare
    # against the live file after each apply / rollback to confirm
    # the right generation is on disk.
    fsUserFile(hostFile = "~/.config/m9-test/rollback-target.txt",
      content = "m9-profile-A\n",
      mode = "0644",
      address = "rollbackFile")

  hosts:
    "m9-test-host": [default]
