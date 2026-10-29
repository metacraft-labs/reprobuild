## HL-10 — the lock-update node's ``flake.lock`` writer, end to end through
## ``repro test`` (Unified-Locking-And-Hooks.md §13.6, §13.7.3 item 2;
## Test-Certificates.md "The lock is refreshed by the certifying run").
##
## ``t_every_commit_time_writer_is_applied_by_the_lock_update_node`` case 2
## drives the node's shared step in-process in the NF-2 workspace, which has
## no certificate-producing project. This case runs the WHOLE path a developer
## runs: a plain ``repro test`` of a project whose ``flake.lock`` names a
## develop-mode sibling flake.
##
## Fixture: ``lock_update_node_fixture`` (a real manifest workspace, ``app``
## a real project whose ``test`` aggregate is implicitly
## certificate-producing, a committed ``repro.lock``, a scratch certificate
## store and a registered daemon key, the managed hooks installed by the real
## ``repro hooks ensure --vcs``). On top of it, ``lib-b`` becomes a flake with
## a committed ``repro.lock`` of its own (a repo enters the develop set — and
## develop mode substitutes its checkout for a flake input — only when a lock
## backend holds a record for it; without one the input keeps its pin and
## there is nothing for either writer to do) and
## ``app`` gets a ``flake.nix`` whose input ``lib-b-src`` names lib-b's
## origin, with a ``flake.lock`` pinning lib-b's current revision — the shape
## in which develop mode substitutes the sibling checkout for the input.
## Then lib-b advances and is published, and:
##
##   1. ``repro test`` refreshes ``flake.lock`` to lib-b's new revision
##      BEFORE the tests (the ``lockreader`` edge sees the lock of the same
##      run), stages it, and issues a certificate for the content that
##      carries it; ``repro.lock``'s pin of the same repository moves with it
##      (one plan over both locks, §16.3 H3);
##   2. a real ``git commit`` through the installed hook finds nothing to
##      refresh (``flake-lock up-to-date``), leaves both locks byte-identical,
##      and the commit's tree is the certified content.
##
## Falsifiability: a node that skipped the flake writer leaves ``flake.lock``
## at the old revision (step 1), and the hook then rewrites it at commit time,
## so the committed tree is not the certified one (step 2); a node that wrote
## without staging leaves the index stale (``git show :flake.lock``).
##
## NO MOCKS: real repositories, manifest and flakes, the built ``repro``, the
## real provider, engine and monitor, real ``git commit`` through the
## installed hooks. ``nix`` is real: recording the moved pin asks it for the
## new revision's ``narHash``. Skip rule: ``git``, ``ssh-keygen`` or ``nix``
## missing.

import std/[os, strutils, unittest]
import repro_test_support/reasoned_skip
import repro_cli_support
import ./lock_update_node_fixture

proc originOf(fx: WorkspaceCertifyFixture; name: string): string =
  for (n, origin) in fx.cf.sib.origins:
    if n == name: return origin
  doAssert false, "no origin for " & name

proc flakeLockText(url, rev: string): string =
  ## A ``flake.lock`` in nix's on-disk shape with one git input. The
  ## ``narHash`` / ``lastModified`` / ``revCount`` are fixed literals: nothing
  ## asks nix about a node that does not move, and the refresh recomputes all
  ## three for the node it moves.
  "{\n" &
  "  \"nodes\": {\n" &
  "    \"lib-b-src\": {\n" &
  "      \"locked\": {\n" &
  "        \"lastModified\": 1787946353,\n" &
  "        \"narHash\": \"sha256-fv2PzTwKsfeBptF8u/G0w9eh6GDsib/62l5cyuKNGYM=\",\n" &
  "        \"ref\": \"main\",\n" &
  "        \"rev\": \"" & rev & "\",\n" &
  "        \"revCount\": 1,\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & url & "\"\n" &
  "      },\n" &
  "      \"original\": {\n" &
  "        \"ref\": \"main\",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & url & "\"\n" &
  "      }\n" &
  "    },\n" &
  "    \"root\": {\n" &
  "      \"inputs\": {\n" &
  "        \"lib-b-src\": \"lib-b-src\"\n" &
  "      }\n" &
  "    }\n" &
  "  },\n" &
  "  \"root\": \"root\",\n" &
  "  \"version\": 7\n" &
  "}\n"

suite "HL-10 — the node's flake.lock writer through repro test":

  test "t_lock_update_node_refreshes_the_flake_lock_through_repro_test":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0 or
        findExe("nix").len == 0:
      skip("git, ssh-keygen or nix not on PATH; this test signs " &
        "certificates and records a flake.lock pin, which asks nix for the " &
        "moved revision's narHash")
    else:
      var fx = setupLockUpdateFixture("hl10-flake-e2e")
      defer: removeDir(fx.cf.sib.scratch)
      let libB = fx.cf.sib.ws / "lib-b"
      # lib-b becomes a flake (develop mode substitutes only a sibling that
      # is one) with its own committed lock (which puts it in the develop
      # set), published, and app's repro.lock re-pinned to it.
      writeFile(libB / "flake.nix", "{ outputs = _: { }; }\n")
      writeFile(libB / "repro.solver", "package lib-b\nversions: 0.1.0\n")
      writeFile(libB / ".gitignore", ".repro/\n")
      let libBLock = fx.reproIn(["lock", "refresh", libB])
      checkpoint("lib-b lock refresh:\n" & libBLock.output)
      require libBLock.code == 0
      discard fx.cf.sib.git(libB, "add -A")
      discard fx.cf.sib.git(libB, "commit -q -m flake")
      discard fx.cf.sib.git(libB, "push -q origin main")
      fx.cf.sib.refreshAndPublishLock()
      let pinned = fx.cf.sib.headOf(libB)
      let url = "file://" & fx.originOf("lib-b")
      writeFile(fx.app / "flake.nix",
        "{\n" &
        "  inputs = {\n" &
        "    lib-b-src.url = \"git+" & url & "?ref=main\";\n" &
        "  };\n" &
        "  outputs = _: { };\n" &
        "}\n")
      writeFile(fx.app / "flake.lock", flakeLockText(url, pinned))
      discard fx.cf.sib.git(fx.app, "add flake.nix flake.lock")
      discard fx.cf.sib.git(fx.app, "commit -q -m flake")
      discard fx.cf.sib.git(fx.app, "push -q origin main")
      fx.ensureHooks()

      # Nothing has moved yet: the node writes nothing and the run issues.
      let quiet = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("before the move:\n" & quiet.output)
      require quiet.code == 0
      check "the lock-update node failed" notin quiet.output
      check readFile(fx.app / "flake.lock") == flakeLockText(url, pinned)

      # ---- 1. lib-b advances; repro test refreshes and stages flake.lock ---
      let advanced = fx.cf.sib.advance("lib-b")
      check advanced notin readFile(fx.app / "flake.lock")
      let run = fx.reproIn(["test", "--tool-provisioning=path"])
      checkpoint("repro test after the move:\n" & run.output)
      check run.code == 0
      check "the lock-update node failed" notin run.output
      check "REFUSED" notin run.output
      let flakeAfter = readFile(fx.app / "flake.lock")
      check advanced in flakeAfter
      check pinned notin flakeAfter
      check fx.mustGitApp("show", ":flake.lock") == flakeAfter
      # §16.3 H3: the repository both locks resolve moved in both.
      check advanced in fx.lockText()
      check fx.stagedLock() == fx.lockText()
      # The tests ran on the refreshed state: lockreader saw this run's lock.
      check fx.lockSeenByTests() == fx.lockText()
      let content = fx.contentNow()
      check fx.certificatesFor(content, "test").len == 1

      # ---- 2. the commit finds nothing to refresh and is the certified tree
      let logBefore = fx.preCommitLog().len
      let commit = fx.gitApp("commit", "-a", "-m", "after the node")
      checkpoint("git commit:\n" & commit.output)
      check commit.code == 0
      check readFile(fx.app / "flake.lock") == flakeAfter
      check fx.mustGitApp("show", "HEAD:flake.lock") == flakeAfter
      check fx.headContent() == content
      let appended = fx.preCommitLog().lastLinesSince(logBefore)
      checkpoint("pre-commit log:\n" & appended)
      check "flake-lock up-to-date" in appended
      check "staged into this commit" notin appended
