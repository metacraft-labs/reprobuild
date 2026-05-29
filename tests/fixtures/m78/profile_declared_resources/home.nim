# nim-check: skip
#
# M78 gate fixture: a home profile that declares home-scope resources
# through a top-level `resources:` block. `repro home apply` parses
# this block in the intent layer and materializes every reachable
# entry through the M68 resource drivers — exactly as a
# REPRO_TEST_RESOURCES test-seam entry is materialized.
#
# M83 Phase F2 migration: built via the Phase A `repro_profile` macro
# library so `repro home apply` takes the compile-then-apply path
# (Phase D) end-to-end. The Phase A macro `resources:` block invokes
# constructor templates directly (no per-stanza `<kind> <addr>:`
# syntax), and the `defined(windows)` / `defined(linux)` compile-time
# guards replace the legacy parser's runtime `when windows:` /
# `when linux:` shapes. The fixture is exercised by the M78 gate
# (Windows-only — `when not defined(windows): skip()` in the test),
# so compile-time host detection on the build host matches the
# expected materialization set.

import repro_profile

profile "m78-profile-declared-resources":

  activity default:
    `m78-fixture`

  resources:
    # A cross-platform PATH contribution: puts a launcher directory on
    # the user's PATH. On Windows this drives the `env.userVariable`
    # write to HKCU\Environment\Path; pre-existing entries are
    # preserved (the M68 env.userPath non-destructive invariant).
    envUserPath(entries = "C:\\repro-m78-profile-bin",
      address = "launcherDir")

    # A managed block in a partially-owned home file, written with
    # repro-managed sentinels.
    fsManagedBlock(hostFile = "~/.m78-profile-rc",
      blockId = "m78-profile-block",
      content = "export REPRO_M78_PROFILE=1",
      address = "shellRc")

    # A Windows-only resource: it must materialize on this Windows
    # host and be absent under a non-matching predicate. Kept as an
    # isolated `$HOME` file so the gate never touches the real
    # registry for the predicate check.
    when defined(windows):
      fsManagedBlock(hostFile = "~/.m78-windows-only-rc",
        blockId = "m78-windows-block",
        content = "windows-only profile resource",
        address = "windowsOnly")

    # A resource guarded by a predicate that does NOT match this host
    # (Windows). It must NOT be materialized here.
    when defined(linux):
      fsManagedBlock(hostFile = "~/.m78-linux-only-rc",
        blockId = "m78-linux-block",
        content = "this must never appear on Windows",
        address = "linuxOnly")

  hosts:
    "m78-gate-host": [default]
