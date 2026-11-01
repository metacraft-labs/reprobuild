## The certificate line of ``repro health`` (the ``certificate-propagation``
## row) says where certificates are kept and how they travel, and what the
## current repository's policy, pin and snapshot are.
##
## Each case is a real workspace and clone, read back from a real ``repro health
## --json`` run in that clone. No mocks. The current-snapshot half, which needs
## a recipe enacting a real policy package, is measured in
## ``t_certifying_run_records_the_policy_snapshot_the_hook_carries``.
##
## Each fact is shown to move: a row that reported constants would pass none of
## these, because the same workspace is read before and after one value changes.

import std/unittest

include certificate_push_fixture
from repro_cli_support/certificate_propagation import linkedCertificateLibraryVersion

proc certificateRow(fx: StoreFixture; cwd: string): JsonNode =
  let res = runArgv(@[fx.reproBin, "health", "--json",
    "--workspace-root=" & fx.workspaceRoot], cwd = cwd)
  checkpoint("health exit=" & $res.code & "\n" & res.output)
  for entry in parseJson(res.output)["checks"]:
    if entry["name"].getStr() == "certificate-propagation":
      return entry
  doAssert false, "health emitted no certificate-propagation row"

suite "repro health's certificate line":
  test "it names both store roots, the linked library and the carrier":
    let fx = setupStoreFixture("", "cert-line-store")
    defer: removeDir(fx.scratch)
    let row = certificateRow(fx, fx.libAPath)
    let detail = row["detail"].getStr()
    check row["status"].getStr() == "ok"
    check fx.userRoot in detail
    check fx.systemRoot in detail
    let version = linkedCertificateLibraryVersion()
    check version.len > 0
    check ("test_certificates " & version & " linked") in detail
    check "this build writes no notes" in detail
    let data = row["data"]
    check data["store_user_root"].getStr() == fx.userRoot
    check data["store_system_root"].getStr() == fx.systemRoot
    check data["reference_library_version"].getStr() == version
    check data["reprobuild_writes_notes"].getBool() == false

    # The roots are resolved, not remembered.
    putEnv("TEST_CERTIFICATES_DIR", fx.scratch / "another-root")
    let moved = certificateRow(fx, fx.libAPath)["detail"].getStr()
    check (fx.scratch / "another-root") in moved
    check fx.userRoot notin moved

  test "the carrier's hook is measured in the current repository":
    let fx = setupStoreFixture("", "cert-line-hook")
    defer: removeDir(fx.scratch)
    let before = certificateRow(fx, fx.libAPath)
    check "lib-a: pre-push hook MISSING" in before["detail"].getStr()
    check before["data"]["current_repository"][
      "pre_push_hook_installed"].getBool() == false
    fx.installHooks()
    let after = certificateRow(fx, fx.libAPath)
    check "lib-a: pre-push hook installed" in after["detail"].getStr()
    check after["data"]["current_repository"][
      "pre_push_hook_installed"].getBool() == true

  test "a repository with no policy says so and is not a warning":
    let fx = setupStoreFixture("", "cert-line-none")
    defer: removeDir(fx.scratch)
    let row = certificateRow(fx, fx.libAPath)
    check row["status"].getStr() == "ok"
    check "no policy" in row["detail"].getStr()
    check "STALE" notin row["detail"].getStr()
    check row["data"]["current_repository"]["policy_present"].getBool() == false

  test "the policy and its pin are read from the repository's own lock":
    # The snapshot names lib-a as the policy's package, and the fixture's lock
    # pins lib-a at this revision. It has no recipe enacting the policy, which
    # is a real way to be stale: the warning has to come with the remedy.
    let pin = "1".repeat(40)
    let fx = setupStoreFixture(everyBranchSnapshot(pmRequired, ["t-unit"],
      ["*"], name = "team-default", package = "lib-a"), "cert-line-pin",
      committedLock = true)
    defer: removeDir(fx.scratch)
    let row = certificateRow(fx, fx.libAPath)
    let detail = row["detail"].getStr()
    check "policy 'team-default'" in detail
    check ("from lib-a pinned at " & pin) in detail
    check "required" in detail
    check "snapshot STALE" in detail
    check row["status"].getStr() == "warn"
    check "repro lock refresh" in row["remedy"].getStr()
    let current = row["data"]["current_repository"]
    check current["policy"].getStr() == "team-default"
    check current["policy_package"].getStr() == "lib-a"
    check current["policy_pin"].getStr() == pin
    check current["snapshot_stale"].getBool() == true

  test "a policy package the lock does not pin is named as unpinned":
    let fx = setupStoreFixture(everyBranchSnapshot(pmRequired, ["t-unit"],
      ["*"], name = "team-default", package = "not-in-the-lock"),
      "cert-line-unpinned", committedLock = true)
    defer: removeDir(fx.scratch)
    let detail = certificateRow(fx, fx.libAPath)["detail"].getStr()
    check "from not-in-the-lock, which repro.lock does not pin" in detail

  test "a malformed policy is reported and warned about":
    let fx = setupStoreFixture(everyBranchSnapshot(pmRequired, ["t-unit"],
      ["*"], name = "team-default", package = "lib-a"), "cert-line-malformed",
      committedLock = true)
    defer: removeDir(fx.scratch)
    let lock = fx.libAPath / "repro.lock"
    writeFile(lock, readFile(lock).replace("gate_mode = \"required\"",
      "gate_mode = \"sometimes\""))
    let row = certificateRow(fx, fx.libAPath)
    check row["status"].getStr() == "warn"
    check "policy unreadable" in row["detail"].getStr()
    check "sometimes" in row["detail"].getStr()
    check row["data"]["current_repository"]["policy_malformed"].getBool() == true

  test "a working directory outside the workspace judges no repository":
    # The same stale workspace as above is not this row's business when health
    # is asked about it from elsewhere; the workspace-wide snapshot row reports
    # it, and a verdict on the unrelated checkout would be wrong.
    let fx = setupStoreFixture(requiredPolicy(@["t-unit"], @["*"]),
      "cert-line-outside", committedLock = true)
    defer: removeDir(fx.scratch)
    let row = certificateRow(fx, fx.scratch)
    check "no current repository in this workspace" in row["detail"].getStr()
    check row["status"].getStr() == "ok"
    check row["data"]["current_repository"].kind == JNull

  test "earlier-draft records change nothing and are left alone":
    let fx = setupStoreFixture("", "cert-line-legacy")
    defer: removeDir(fx.scratch)
    let before = certificateRow(fx, fx.libAPath)

    let legacyDir = fx.workspaceRoot / ".repro" / "workspace" / "certificates"
    createDir(legacyDir)
    let legacyFile = legacyDir / "earlier-draft.toml"
    const legacyBody = "[certificate]\nschema = \"test-certificate.v1\"\n" &
      "[certificate.vcs]\ncommit = \"abc\"\nclean = true\n"
    writeFile(legacyFile, legacyBody)
    const legacyRef = "refs/notes/reprobuild/certificates"
    discard gitOut(fx.libAPath, "notes", "--ref", legacyRef, "add", "-m",
      legacyBody, "HEAD")
    let note = gitOut(fx.libAPath, "notes", "--ref", legacyRef, "show", "HEAD")

    let after = certificateRow(fx, fx.libAPath)
    check after == before
    let wholeLine = after["detail"].getStr() & after["remedy"].getStr()
    check "earlier-draft" notin wholeLine
    check "delete" notin wholeLine.toLowerAscii()
    check readFile(legacyFile) == legacyBody
    check gitOut(fx.libAPath, "notes", "--ref", legacyRef, "show", "HEAD") == note
