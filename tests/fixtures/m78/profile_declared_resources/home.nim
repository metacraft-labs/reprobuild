# nim-check: skip
#
# M78 gate fixture: a home profile that declares home-scope resources
# through a top-level `resources:` block. `repro home apply` parses
# this block in the intent layer and materializes every reachable
# entry through the M68 resource drivers — exactly as a
# REPRO_TEST_RESOURCES test-seam entry is materialized.

import repro/profile

profile "m78-profile-declared-resources":

  activity default:
    m78-fixture

  resources:
    # A cross-platform PATH contribution: puts a launcher directory on
    # the user's PATH. On Windows this drives the `env.userVariable`
    # write to HKCU\Environment\Path; pre-existing entries are
    # preserved (the M68 env.userPath non-destructive invariant).
    env.userPath launcherDir:
      entries = "C:\\repro-m78-profile-bin"

    # A managed block in a partially-owned home file, written with
    # repro-managed sentinels.
    fs.managedBlock shellRc:
      hostFile = "~/.m78-profile-rc"
      blockId = "m78-profile-block"
      content = "export REPRO_M78_PROFILE=1"

    # A Windows-only resource: it must materialize on this Windows
    # host and be absent under a non-matching predicate. Kept as an
    # isolated `$HOME` file so the gate never touches the real
    # registry for the predicate check.
    when windows:
      fs.managedBlock windowsOnly:
        hostFile = "~/.m78-windows-only-rc"
        blockId = "m78-windows-block"
        content = "windows-only profile resource"

    # A resource guarded by a predicate that does NOT match this host
    # (Windows). It must NOT be materialized here.
    when linux:
      fs.managedBlock linuxOnly:
        hostFile = "~/.m78-linux-only-rc"
        blockId = "m78-linux-block"
        content = "this must never appear on Windows"

  hosts:
    "m78-gate-host": [default]
