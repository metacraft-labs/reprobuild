## CI-Sharding M2 verification — LAN peer cache is reserved.
##
## ``--peer-cache=lan://<CIDR>`` is recognised by the M2 parser but
## NOT implemented; the implementation lands (or is closed out) in M3
## (benchmark) + M4 (conditional implementation).  The contract:
## ``repro test --peer-cache=lan://10.0.0.0/24`` exits 2 with a
## diagnostic that names both follow-up milestones so users know where
## to look.

import std/[os, strutils, tempfiles, unittest]

import sharding_test_support

suite "CI-Sharding M2 — LAN peer cache reserved":

  test "t_e2e_repro_test_shard_lan_peer_cache_not_implemented":
    let workspace = createTempDir("repro-m2-lan-peer-cache-", "")
    defer: removeDir(workspace)

    let res = runRepro(@[
      "test",
      "--shard", "1/4",
      "--peer-cache=lan://10.0.0.0/24",
    ], workspace)

    # Exit code 2 — the documented "invalid / unsupported flag" exit.
    check res.code == 2

    # Diagnostic shape: must name BOTH M3 (benchmark) and M4
    # (conditional implementation) so the user can find the campaign.
    check res.output.contains("--peer-cache=lan://10.0.0.0/24")
    check res.output.contains("not implemented")
    check res.output.contains("M3")
    check res.output.contains("M4")
    check res.output.contains("CI-Sharding")
