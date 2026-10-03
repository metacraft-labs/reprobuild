## The pre-push gate refuses a committed `repro.lock` whose sibling pins do
## not match the observable siblings (Unified-Locking-And-Hooks.md §13.5,
## "The `repro.lock` stage").
##
## WHY. CI builds the committed pins (§14.5). A push whose lock names a sibling
## commit other than the one checked out beside it publishes a revision that
## was built and tested against something CI will not build — the stale-pin
## failure §13.5 records for codetracer, where CI survived only by ignoring
## the lock.
##
## Fixture: `committed_lock_siblings_fixture.nim` (a real manifest workspace,
## app → lib-b → lib-c, lib-d unrelated). The lock is written by the explicit
## `repro lock refresh` and published; the gate runs as the managed pre-push
## hook runs it (`repro check --mode=pre-push --current-repo=<app>`).
##
## Cases:
##   1. Fresh lock → the gate passes.
##   2. lib-b advanced (published) after the lock was committed → exit 2,
##      property `committed_lock_sibling_pin_stale`, evidence naming lib-b and
##      both commits, remediation naming `repro lock refresh`.
##   3. After `repro lock refresh` is committed and pushed → passes again.
##   4. The manifest gains app → lib-d, the lock does not carry it → refused
##      naming lib-d as unpinned.
##
## Falsifiability (observed): before the stage existed, case 2 exits 0.
##
## NO MOCKS: real repositories, real manifest, the built `repro`.

import std/[json, os, strutils, unittest]
import repro_test_support/reasoned_skip
import ./committed_lock_siblings_fixture

proc gate(fx: SiblingFixture): tuple[code: int; output: string; report: JsonNode] =
  let refs = fx.scratch / "refs.txt"
  let head = fx.headOf(fx.app)
  writeFile(refs, "refs/heads/main " & head & " refs/heads/main " &
    "0000000000000000000000000000000000000000\n")
  let r = runCmd(q(fx.repro) & " check --mode=pre-push --write-report" &
    " --workspace-root=" & q(fx.ws) & " --current-repo=" & q(fx.app) &
    " --pushed-refs=" & q(refs))
  let reportPath = fx.ws / ".repro" / "build" / "reports" / "check-report.json"
  let report =
    if fileExists(reportPath): parseFile(reportPath) else: newJObject()
  (code: r.code, output: r.output, report: report)

proc staleFailure(report: JsonNode): JsonNode =
  let failures = report{"failures"}
  if failures == nil or failures.kind != JArray: return nil
  for f in failures:
    if f{"property"}.getStr() == "committed_lock_sibling_pin_stale":
      return f
  nil

suite "pre-push refuses stale committed sibling pins":

  test "t_pre_push_refuses_stale_committed_sibling_pin":
    if findExe("git").len == 0:
      skip("git is not on PATH; every fixture here is a real git repository")
    else:
      var fx = setupSiblingFixture("stale-pin-gate")
      defer: removeDir(fx.scratch)
      fx.refreshAndPublishLock()

      # 1. fresh lock passes.
      let g1 = fx.gate()
      checkpoint(g1.output)
      check g1.code == 0

      # 2. a sibling moved after the lock was committed.
      let libBPin = fx.headOf(fx.ws / "lib-b")
      let libBNext = fx.advance("lib-b")
      let g2 = fx.gate()
      checkpoint(g2.output)
      check g2.code == 2
      let f2 = staleFailure(g2.report)
      check not f2.isNil
      if not f2.isNil:
        let ev = f2{"evidence"}.getStr()
        check "lib-b" in ev
        check libBPin in ev
        check libBNext in ev
        check "repro lock refresh" in f2{"remediation"}.getStr()

      # 3. refreshed and committed: passes again.
      fx.refreshAndPublishLock()
      let g3 = fx.gate()
      checkpoint(g3.output)
      check g3.code == 0

      # 4. a declared sibling the lock does not carry.
      fx.setAppDepends(@["lib-b", "lib-d"])
      let g4 = fx.gate()
      checkpoint(g4.output)
      check g4.code == 2
      let f4 = staleFailure(g4.report)
      check not f4.isNil
      if not f4.isNil:
        check "lib-d" in f4{"evidence"}.getStr()
