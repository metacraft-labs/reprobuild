## HL-10 (push half) — a pushed commit whose tree differs from certified
## content ONLY in ``flake.lock`` is refused as uncovered, and the client
## pre-push gate names the certified content and ``flake.lock`` as the file
## that differs (Test-Certificates.md §"Gate integration — push
## requirement"). ``flake.lock`` is the second file the commit-time writers
## manage (the §13.6 refresh); this reddens if the gate's managed set is a
## private list that leaves it out.
##
## Fixture: ``lock_only_push_fixture.nim``, with a ``flake.nix`` and a
## ``flake.lock`` committed and published first (lib-a has no flake inputs,
## so nothing resolves them; the files are content). Then:
##
##   1. b.txt is added and the working tree certified (C1);
##   2. ``flake.lock`` is rewritten — the same lock, other bytes — and
##      committed and published as P1;
##   3. the real ``repro check --mode=pre-push`` refuses P1 with
##      ``certificate-coverage`` and names C1 and ``flake.lock`` (and not
##      ``repro.lock``, which did not change).
##
## NO MOCKS: real repositories, the built ``repro``, the production store
## writer and verifier. Skip rule: ``git`` or ``ssh-keygen`` missing.

import repro_test_support/reasoned_skip
import std/[json, os, osproc, strutils, unittest]

include lock_only_push_fixture

const
  flakeNix = "{\n  outputs = _: { };\n}\n"
  flakeLockV1 = "{\n  \"nodes\": {\n    \"root\": {}\n  },\n" &
    "  \"root\": \"root\",\n  \"version\": 7\n}\n"
  flakeLockV2 = "{\"nodes\":{\"root\":{}},\"root\":\"root\",\"version\":7}\n"

suite "HL-10 — a flake.lock-only push difference names the certified content":

  test "t_push_of_a_flake_lock_only_change_names_the_certified_content":
    if findExe("git").len == 0 or findExe("ssh-keygen").len == 0:
      skip("git or ssh-keygen not on PATH; this test signs certificates " &
        "in real repositories")
    else:
      let fx = setupLockOnlyFixture("hl10-flake-lock")
      defer: removeDir(fx.scratch)
      writeFile(fx.libAPath / "flake.nix", flakeNix)
      writeFile(fx.libAPath / "flake.lock", flakeLockV1)
      discard fx.commitAll("a flake")
      fx.publish()

      writeFile(fx.libAPath / "b.txt", "b\n")
      let (c1, b0) = fx.certifyWorkingTree()
      writeFile(fx.libAPath / "flake.lock", flakeLockV2)
      let p1 = fx.commitAll("flake.lock refreshed after testing")
      fx.publish()
      let gate = checkPrePush(fx, p1)
      checkpoint("gate:\n" & gate.output)
      check gate.code == 2
      check failureProperties(gate.report) == @["certificate-coverage"]
      let evidence = failureField(gate.report, "certificate-coverage",
        "evidence")
      check ("certified content " & c1 & " (tested on top of commit " &
        b0[0 ..< 12] & ") differs from the pushed tree only in flake.lock") in
        evidence
      check "only in repro.lock" notin evidence
      check lockOnlyCauseMarker in evidence
