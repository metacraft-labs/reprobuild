## ``repro health``'s ``certificate-propagation`` row reports what in a
## repository's git configuration keeps its certificates from reaching a
## gateway. The hook body is linked, so the row does not ask whether a tool is
## present. It measures the two values a push would otherwise report only in its
## own output: an invalid scope declaration, which stops propagation (Tooling
## §3.1), and a notes ref the gateway does not read.
##
## Each case is a real workspace and a real clone whose real git configuration
## differs in one value, read back from a real ``repro health --json``. No mocks.
##
## A row reporting a constant fails: the same workspace is measured clean, then
## with the value set, and the row must change and name the repository.

import std/unittest

include certificate_push_fixture

proc propagationRow(fx: StoreFixture): JsonNode =
  let res = runArgv(@[fx.reproBin, "health", "--json",
    "--workspace-root=" & fx.workspaceRoot])
  checkpoint("health exit=" & $res.code & "\n" & res.output)
  for entry in parseJson(res.output)["checks"]:
    if entry["name"].getStr() == "certificate-propagation":
      return entry
  doAssert false, "health emitted no certificate-propagation row"

suite "repro health reports the configuration propagation reads":
  test "an invalid scope declaration is a warning naming the repo":
    let fx = setupStoreFixture("", "prop-health-scope")
    defer: removeDir(fx.scratch)
    let clean = propagationRow(fx)
    check clean["status"].getStr() == "ok"
    check clean["remedy"].getStr() == ""

    discard gitOut(fx.libAPath, "config", "testCertificatesScope.bad.path",
      "/not/a/scope/path/")
    let row = propagationRow(fx)
    check row["status"].getStr() == "warn"
    check "lib-a" in row["detail"].getStr()
    check "invalid scope declaration" in row["detail"].getStr()
    check "testCertificatesScope" in row["remedy"].getStr()

  test "a notes ref the gateway does not read is a warning naming it":
    let fx = setupStoreFixture("", "prop-health-ref")
    defer: removeDir(fx.scratch)
    discard gitOut(fx.libAPath, "config", "testCertificates.notesRef",
      "refs/notes/elsewhere")
    let row = propagationRow(fx)
    check row["status"].getStr() == "warn"
    check "lib-a" in row["detail"].getStr()
    check "refs/notes/elsewhere" in row["detail"].getStr()
    check "testCertificates.notesRef" in row["remedy"].getStr()
