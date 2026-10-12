## TC-8c — every certificate ``repro test`` issues is delivered to the
## standard per-user local certificate store (test-certificates Transport §2,
## operator decisions D1/D1a), and nowhere in the repository.
##
## Driven through the real issuance path (``repro test --certify`` on a passing
## fixture, signed by a registered daemon key) in a real workspace:
##
##   1. With ``TEST_CERTIFICATES_DIR`` pointed at a scratch directory, the
##      certificate appears at ``v1/git-tree-sha1/<tree>/<payload>.toml``:
##      ``<tree>`` is HEAD's tree as git reports it, ``<payload>`` the SHA-256
##      of the record's canonical payload as ``sha256sum`` computes it. The
##      file is the record, signature included. Directories the writer
##      created are owner-only.
##   2. Nothing is written under the repository (``git status`` stays empty)
##      and no certificate under ``.repro/workspace/certificates`` — the
##      registered-keys file there is untouched (D11). Nothing is written to
##      the system root.
##   3. A RELATIVE ``TEST_CERTIFICATES_DIR`` is ignored: the certificate goes
##      to ``$XDG_STATE_HOME/test-certificates`` and nothing appears at the
##      relative path.
##   4. Two issuances of the same claim produce ONE file; a second platform's
##      certificate is a second file in the same directory.
##   5. A file whose record's content does not match its directory is
##      reported and ignored by a reader.
##   6. A user root INSIDE the repository is refused, and nothing is written
##      there; ``--certificate-out`` naming a tracked path is refused.
##
## Falsifiability: write the store under the repository → 2 and 6 fail; name
## the file by the file's bytes instead of the canonical payload → 1 fails
## (and the walker's signed/unsigned twins); honour a relative root → 3 fails;
## drop the directory check in the reader → 5 fails.
##
## Hermetic: local repos, the built ``repro``; no network. Requires git,
## ssh-keygen and sha256sum.

import std/[algorithm, os, osproc, sequtils, strutils, unittest]

include tc8c_store_fixture

proc sha256sumOf(path: string): string =
  let res = execCmdEx(quoteShellCommand(@["sha256sum", path]))
  doAssert res.exitCode == 0, "sha256sum failed: " & res.output
  res.output.splitWhitespace()[0]

proc filesUnder(dir: string): seq[string] =
  if not dirExists(dir): return
  for path in walkDirRec(dir):
    result.add(path.relativePath(dir))
  result.sort()

suite "TC-8c — issued certificates land in the standard local store":

  test "t_issued_certificate_lands_in_the_standard_local_store":
    let fx = setupStoreFixture("", "lands")
    defer: removeDir(fx.scratch)
    seedLock(fx)
    let keysDir = fx.workspaceRoot / ".repro" / "workspace" / "certificates"
    let keysBefore = filesUnder(keysDir)
    check "registered-keys.toml" in keysBefore

    # ---- 1. the path, the name, the bytes, the modes ----------------------
    let issued = issueViaReproTest(fx)
    checkpoint("repro test: " & issued.output)
    check issued.code == 0
    let head = gitOut(fx.libAPath, "rev-parse", "HEAD")
    let tree = gitOut(fx.libAPath, "rev-parse", "HEAD^{tree}")
    let contentDir = fx.userRoot / "v1" / "git-tree-sha1" / tree
    let files = storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree)
    check files.len == 1
    check filesUnder(fx.userRoot).len == 1   # nothing else in the store
    let cert = readCertificateFile(files[0])
    check cert.vcs.content == "git-tree-sha1:" & tree
    check cert.vcs.base == head
    check cert.isSigned
    check files[0].parentDir == contentDir
    # The name is the SHA-256 of the canonical payload, computed here by
    # sha256sum over the payload bytes rather than by the library's hasher.
    let payloadFile = fx.scratch / "payload.bin"
    writeFile(payloadFile, canonicalCertificatePayload(cert))
    check files[0].extractFilename == sha256sumOf(payloadFile) & ".toml"
    # The file is the whole record, signature block included.
    check "[certificate.signature]" in readFile(files[0])
    check readCertificateFile(files[0]).signature.value == cert.signature.value
    check ("→ " & files[0]) in issued.output
    # Owner-only directories, from the root down.
    when not defined(windows):
      for dir in [fx.userRoot, fx.userRoot / "v1",
                  fx.userRoot / "v1" / "git-tree-sha1", contentDir]:
        check getFilePermissions(dir) ==
          {fpUserRead, fpUserWrite, fpUserExec}

    # ---- 2. nothing in the repository, nothing in .repro/workspace --------
    check gitOut(fx.libAPath, "status", "--porcelain",
      "--untracked-files=all", "--ignored") == ""
    check filesUnder(keysDir) == keysBefore
    check not dirExists(fx.systemDir)

    # ---- 4. the same claim is one file; another platform, a second -------
    let again = publishCertificateToLocalStore(cert, fx.libAPath)
    check again.error == ""
    check again.path == files[0]
    check storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree) == files
    # Re-running the tests for the same content is the no-op: still one file.
    let rerun = issueViaReproTest(fx)
    check rerun.code == 0
    check "no-op" in rerun.output
    check storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree) == files
    var other = signedCertFor(fx, cert.vcs.content, head,
      platform = "linux/tc8c-second")
    let second = publishCertificateToLocalStore(other, fx.libAPath)
    check second.error == ""
    let both = storedCertificateFiles(fx.userRoot, "git-tree-sha1:" & tree)
    check both.len == 2
    check both.allIt(it.parentDir == contentDir)

    # ---- 5. a record filed under the wrong directory is reported ---------
    let wrongTree = "0123456789abcdef0123456789abcdef01234567"
    let wrongDir = fx.userRoot / "v1" / "git-tree-sha1" / wrongTree
    createDir(wrongDir)
    copyFile(files[0], wrongDir / files[0].extractFilename)
    let lookup = findCertificatesInLocalStore(stateWithKnownContent(
      [KnownContentId(algorithm: "git-tree-sha1",
        id: "git-tree-sha1:" & wrongTree)]))
    check lookup.found.len == 0
    check lookup.problems.len == 1
    check ("filed under git-tree-sha1:" & wrongTree) in
      lookup.problems.join("\n")
    check "ignored" in lookup.problems.join("\n")
    removeDir(wrongDir)

  test "a relative TEST_CERTIFICATES_DIR is ignored":
    let fx = setupStoreFixture("", "relative")
    defer: removeDir(fx.scratch)
    seedLock(fx)
    let stateHome = fx.scratch / "xdg-state"
    let issued = issueViaReproTest(fx, env = @[
      (name: "TEST_CERTIFICATES_DIR", value: "relative-store"),
      (name: "XDG_STATE_HOME", value: stateHome)])
    checkpoint("repro test: " & issued.output)
    check issued.code == 0
    let tree = gitOut(fx.libAPath, "rev-parse", "HEAD^{tree}")
    check storedCertificateFiles(stateHome / "test-certificates",
      "git-tree-sha1:" & tree).len == 1
    # Not at the relative path, from the directory the run started in.
    check not dirExists(fx.workspaceRoot / "relative-store")
    check not dirExists(fx.userRoot)

  test "a store inside the repository, or a tracked --certificate-out, is refused":
    let fx = setupStoreFixture("", "inside")
    defer: removeDir(fx.scratch)
    seedLock(fx)
    let inside = fx.libAPath / "certs"
    let refused = issueViaReproTest(fx, env = @[
      (name: "TEST_CERTIFICATES_DIR", value: inside)])
    checkpoint("repro test: " & refused.output)
    check "no certificate" in refused.output
    check "inside the repository" in refused.output
    check not dirExists(inside)
    check gitOut(fx.libAPath, "status", "--porcelain",
      "--untracked-files=all") == ""
    # --certificate-out at a tracked path: refused before anything runs.
    let tracked = issueViaReproTest(fx,
      extra = @["--certificate-out=" & (fx.libAPath / "README.md")])
    checkpoint("repro test: " & tracked.output)
    check tracked.code != 0
    check "refusing --certificate-out" in tracked.output
    check readFile(fx.libAPath / "README.md") == "TC-8c fixture\n"
    check not dirExists(fx.userRoot / "v1")
