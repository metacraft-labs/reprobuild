## TC-8c — the client pre-push gate finds certificates in the local store,
## in BOTH roots (test-certificates Transport §2.1/§2.4, operator decisions D1a
## and D2), under the content id of the commit it judges, never in notes.
##
## With ``TEST_CERTIFICATES_DIR`` and ``TEST_CERTIFICATES_SYSTEM_DIR`` pointed
## at scratch directories and a ``required`` policy, the real ``repro check
## --mode=pre-push`` gate:
##
##   1. passes on a certificate that sits ONLY under the system root
##      (``<dir>/<uid>/v1/...``), as a privileged producer would have left it;
##   2. reads a certificate present in BOTH roots once (byte-identical copies
##      collapse), while a NON-identical copy — the same claim unsigned — is
##      evaluated too and does not hide the signed one;
##   3. with a system root that exists but cannot be read, REPORTS it and
##      still passes on the certificate in the user root;
##   4. refuses when the only certificate is attached as a git note — the
##      client gate does not read notes (D2).
##
## Falsifiability: search only the user root → 1 fails; stop after the first
## copy of a name → 2's unsigned-first case fails; treat an unreadable system
## root as fatal (or as empty without a report) → 3 fails; read notes in the
## client gate → 4 fails.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git and
## ssh-keygen.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, unittest]

include tc8c_store_fixture

proc moveStore(fromRoot, toRoot: string) =
  createDir(toRoot.parentDir)
  moveDir(fromRoot, toRoot)

suite "TC-8c — client gates search both store roots":

  test "t_client_gates_search_both_store_roots":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "roots")
    defer: removeDir(fx.scratch)
    seedLock(fx)
    let head = gitOut(fx.libAPath, "rev-parse", "HEAD")
    let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      "HEAD^{tree}")

    # Nothing anywhere: refused.
    let none = checkPrePush(fx, head)
    check none.code == 2
    check "certificate-coverage" in failureProperties(none.report)

    # Issue through the real path (it lands in the user root), then move the
    # whole store to the SYSTEM root, as if a privileged producer wrote it.
    let issued = issueViaReproTest(fx)
    check issued.code == 0
    let signedFile = issuedCertificate(fx.userRoot, content,
      currentPlatformTag()).path
    let signedBytes = readFile(signedFile)
    moveStore(fx.userRoot, fx.systemRoot)
    check not dirExists(fx.userRoot)
    check storedCertificateFiles(fx.systemRoot, content).len == 1

    # ---- 1. found under the system root alone ----------------------------
    let systemOnly = checkPrePush(fx, head)
    checkpoint("system-only: " & systemOnly.output)
    check systemOnly.code == 0
    check "certificate-coverage" notin failureProperties(systemOnly.report)

    # ---- 2. both roots: identical copies once, non-identical both --------
    let state = commitUnderEvaluation(fx.libAPath, head)
    let relative = signedFile.relativePath(fx.userRoot)
    createDir((fx.userRoot / relative).parentDir)
    writeFile(fx.userRoot / relative, signedBytes)
    let identical = findCertificatesInLocalStore(state)
    check identical.found.len == 1
    check identical.problems.len == 0
    check identical.searched.len == 2
    # The user root now holds the same claim UNSIGNED, under the same name.
    var unsigned = readCertificateFile(signedFile.replace(fx.userRoot,
      fx.systemRoot))
    unsigned.signature = TestCertificateSignature()   # key_id stays: payload
    writeFile(fx.userRoot / relative, serializeCertificateToToml(unsigned))
    check certificateStoreRelativePath(unsigned) ==
      relative.replace(DirSep, '/')
    let twins = findCertificatesInLocalStore(state)
    check twins.found.len == 2
    # The user root is listed first, so the unsigned copy is read first; the
    # signed copy in the system root must still count.
    let withTwins = checkPrePush(fx, head)
    checkpoint("twins: " & withTwins.output)
    check withTwins.code == 0

    # ---- 3. an unreadable system root is reported; the user root counts --
    when defined(windows):
      skip("POSIX permission bits are what make the system root unreadable")
    else:
      # The certificate goes back to the user root, signed.
      writeFile(fx.userRoot / relative, signedBytes)
      setFilePermissions(fx.systemRoot, {})
      defer: setFilePermissions(fx.systemRoot,
        {fpUserRead, fpUserWrite, fpUserExec})
      var readable = true
      try:
        for _ in walkDir(fx.systemRoot, checkDir = true): discard
      except OSError:
        readable = false
      if readable:
        skip("this process can read a mode-000 directory (it runs as " &
          "root), so an unreadable system root cannot be constructed here")
      else:
        let lookup = findCertificatesInLocalStore(state)
        check lookup.found.len == 1
        # The search could not cover the system root, so it is INCOMPLETE
        # (Transport §2.1/§5) — but the certificate it did find covers the
        # commit, so the gate still passes.
        check lookup.searchIncomplete
        check lookup.searchFailed
        check lookup.problems.anyIt("system root" in it and
          "could not be read" in it)
        let gate = checkPrePush(fx, head)
        checkpoint("unreadable system root: " & gate.output)
        check gate.code == 0
        check "system root" in noticesText(gate.report)
        check "could not be read" in noticesText(gate.report)

        # ---- 3b. ... and with nothing in the user root, the gate says the
        # search was INCOMPLETE — an unverifiable outcome, not "no
        # certificate found" (Tooling §2 find exit 3 vs 1): the system root
        # it could not read may hold the certificate.
        let aside = fx.scratch / "user-root-aside"
        moveDir(fx.userRoot, aside)
        defer:
          if dirExists(aside) and not dirExists(fx.userRoot):
            moveDir(aside, fx.userRoot)
        let incomplete = checkPrePush(fx, head)
        checkpoint("incomplete search: " & incomplete.output)
        check incomplete.code == 2
        let properties = failureProperties(incomplete.report)
        check "certificate-unverifiable" in properties
        check "certificate-coverage" notin properties
        check "search INCOMPLETE" in $incomplete.report
        check "no certificate found in the local store" notin
          $incomplete.report

  test "the client gate does not read certificate notes":
    let fx = setupStoreFixture(
      requiredPolicy(@["t-unit"], @[currentPlatformTag()]), "nonotes")
    defer: removeDir(fx.scratch)
    seedLock(fx)
    let head = gitOut(fx.libAPath, "rev-parse", "HEAD")
    let content = "git-tree-sha1:" & gitOut(fx.libAPath, "rev-parse",
      "HEAD^{tree}")
    # A genuine, registered-signed certificate — attached as a note only.
    let cert = signedCertFor(fx, content, head)
    check attachCertificate("git", fx.libAPath, cert).ok
    check readAttachedCertificates("git", fx.libAPath, head).len == 1
    let refused = checkPrePush(fx, head)
    checkpoint("note only: " & refused.output)
    check refused.code == 2
    check "certificate-coverage" in failureProperties(refused.report)
    # The same certificate in the local store is enough.
    check publishCertificateToLocalStore(cert, fx.libAPath).written
    let passed = checkPrePush(fx, head)
    check passed.code == 0
