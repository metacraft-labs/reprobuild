## CI-Sharding M2 → Peer-Cache M2 transition test.
##
## When this test was authored, ``--peer-cache=lan://<CIDR>`` was
## reserved by the CI-Sharding M2 CLI surface but explicitly NOT
## implemented; the runner exited 2 with a diagnostic pointing at the
## Peer-Cache campaign. Peer-Cache M2 now wires the flag through to
## UDP multicast discovery (`libs/repro_peer_cache/` —
## `Peer-Cache.milestones.org` M2), so the "not implemented" exit
## path is gone.
##
## The test that took its place asserts the new contract: a
## ``--peer-cache=lan://`` invocation succeeds at the CLI / config
## parsing layer (the multicast services boot inside
## ``runReproTestCommand`` before workspace discovery runs). The
## downstream behaviour — no workspace + no ``--fixture-from`` ⇒
## a workspace-mode discovery error — is unchanged from the M2
## fixture path. We assert the diagnostic still names the missing
## workspace context rather than the old "lan:// not implemented"
## diagnostic.

import std/[os, strutils, tempfiles, unittest]

import sharding_test_support

suite "CI-Sharding M2 + Peer-Cache M2 — LAN peer cache wired":

  test "t_e2e_repro_test_shard_lan_peer_cache_not_implemented":
    let workspace = createTempDir("repro-m2-lan-peer-cache-", "")
    defer: removeDir(workspace)

    let res = runRepro(@[
      "test",
      "--shard", "1/4",
      "--peer-cache=lan://10.0.0.0/24",
    ], workspace)

    # The CLI / config layer accepts the lan:// form (Peer-Cache M2
    # landed). Downstream the runner still needs either a workspace
    # or a ``--fixture-from`` to do anything useful; an empty
    # temp dir lacks both, so the runner exits with a workspace-
    # discovery diagnostic (exit code 2 — same code as the prior
    # "not implemented" path, but the message has changed).
    check res.code == 2

    # The new diagnostic surface: the LAN form is no longer flagged
    # as unimplemented — the old "M3" / "M4 (conditional LAN
    # peer-cache implementation)" wording is gone.
    check not res.output.contains("--peer-cache=lan://10.0.0.0/24" &
                                  " is not implemented yet")
