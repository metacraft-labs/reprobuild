## ``pushCertificateNotes`` (the notes leg of ``repro push``) merges a remote
## notes ref that moved, instead of failing on the non-fast-forward
## (test-certificates Tooling §3 ``notes push``; Transport §3.1 "Merging two
## notes"; Conformance §6 live-repository cases), at spec 9ebbcb3.
##
## Two clones of one bare remote attach certificates to the SAME tree:
##
##   1. clone A publishes a note whose last record lacks its final LF (a
##      foreign writer's unterminated blob), plus a SIGNED record;
##   2. clone B, which never fetched A's note, attaches a different record
##      and an altered signed copy of A's signed record, then pushes.
##
## B's push is refused by the remote, so the library fetches the remote ref,
## union-merges it with the published (remote) side as the base and pushes
## again. The result on the remote: A's bytes in A's order, with exactly one
## LF supplied before B's appended record — and that LF repair REPORTED in
## the push's remarks — A's signed copy kept over B's differently signed one
## (a reported tie, since neither side made the signature), and B's new
## record present. A repeated push changes nothing.
## Last, the push runs the git it is given (``gitBin``), the library's
## commands included: a git that cannot run fails the push instead of
## reading as "no certificate notes", and a logging wrapper sees the push.
##
## Falsifiability: the previous ``git push`` body fails step 2 outright
## (non-fast-forward) and loses B's record; a merge that lets the incoming
## side win replaces A's signed copy; one that does not repair the boundary
## glues B's delimiter onto A's last line, so B's record disappears into A's.
## Letting the library run the `git` on PATH leaves the wrapper's log
## without a `push`; treating any probe failure as "no notes" passes the
## broken git as ok.
##
## Real git, a real bare remote, two real clones. No mocks.

import repro_test_support/reasoned_skip
import std/[os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_cli_support

proc git(dir: string; args: varargs[string]): string =
  var argv = @["git", "-C", dir]
  for a in args: argv.add(a)
  let res = execCmdEx(quoteShellCommand(argv))
  doAssert res.exitCode == 0, argv.join(" ") & " failed:\n" & res.output
  res.output.strip()

proc certFor(tree, issuer: string): TestCertificate =
  TestCertificate(schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId, project: "p",
    platform: "linux/amd64", targets: @["t"], result: tcrPassed,
    issuedAt: "2026-10-29T00:00:00Z", issuer: issuer,
    vcs: TestCertificateVcs(repo: "p", content: "git-tree-sha1:" & tree),
    commands: @[TestCertificateCommand(argv: @["true"])])

proc attachRawNote(repo, tree, blob: string) =
  ## Attach ``blob`` VERBATIM (no message clean-up, no added LF).
  let file = repo / ".raw-note"
  writeFile(file, blob)
  let oid = git(repo, "hash-object", "-w", "--", file)
  removeFile(file)
  discard git(repo, "notes", "--ref", certificateNotesRef, "add", "-f",
    "-C", oid, tree)

suite "certificate notes push merges a moved remote":

  test "t_certificate_notes_push_merges_a_moved_remote":
    let scratch = createTempDir("repro-notes-merge-push-", "")
    defer: removeDir(scratch)
    let remote = scratch / "remote.git"
    discard execCmdEx(quoteShellCommand(["git", "init", "-q", "--bare", "-b",
      "main", remote]))
    let seed = scratch / "seed"
    createDir(seed)
    discard git(seed, "init", "-q", "-b", "main")
    discard git(seed, "config", "user.email", "a@example.invalid")
    discard git(seed, "config", "user.name", "A")
    writeFile(seed / "f.txt", "f\n")
    discard git(seed, "add", "f.txt")
    discard git(seed, "commit", "-q", "-m", "f")
    discard git(seed, "remote", "add", "origin", remote)
    discard git(seed, "push", "-q", "origin", "main")
    let tree = git(seed, "rev-parse", "HEAD^{tree}")
    let cloneA = seed
    let cloneB = scratch / "b"
    discard execCmdEx(quoteShellCommand(["git", "clone", "-q", remote,
      cloneB]))
    discard git(cloneB, "config", "user.email", "b@example.invalid")
    discard git(cloneB, "config", "user.name", "B")

    # ---- 1. A publishes: a signed record, then an unterminated one -------
    var signedA = certFor(tree, "signer-a")
    signedA.keyId = "key-a"
    signedA.signature = TestCertificateSignature(algorithm: "ed25519",
      value: "QUFBQQ==")
    let unterminated = certificateNoteRecord(certFor(tree, "foreign"))
    let blobA = certificateNoteDelimiter & "\n" & certificateNoteRecord(signedA) &
      certificateNoteDelimiter & "\n" & unterminated[0 ..< ^1]
    check not blobA.endsWith("\n")
    attachRawNote(cloneA, tree, blobA)
    let pushedA = pushCertificateNotes("git", cloneA, "origin")
    checkpoint("A: " & pushedA.diagnostic)
    check pushedA.ok and pushedA.pushed

    # ---- 2. B, which never fetched A's note, attaches and pushes ---------
    var alteredA = signedA
    alteredA.signature.value = "QkJCQg=="
    check attachCertificate("git", cloneB, alteredA).ok
    let recordB = certificateNoteRecord(certFor(tree, "runner-b"))
    check attachCertificate("git", cloneB, certFor(tree, "runner-b")).ok
    let pushedB = pushCertificateNotes("git", cloneB, "origin")
    checkpoint("B: " & pushedB.diagnostic & " remarks: " &
      pushedB.remarks.join(" | "))
    check pushedB.ok
    check pushedB.pushed
    check pushedB.remarks.anyIt(noteMergeReportKind(it) == nmrLfRepair)
    check pushedB.remarks.anyIt(noteMergeReportKind(it) == nmrSignedConflict)

    # What the remote now holds on the tree.
    let inspect = scratch / "inspect"
    discard execCmdEx(quoteShellCommand(["git", "clone", "-q", remote,
      inspect]))
    discard git(inspect, "fetch", "-q", "origin",
      certificateNotesRef & ":" & certificateNotesRef)
    let note = readNoteBlob("git", inspect, tree, certificateNotesRef)
    require note.status == gorPresent
    # A's bytes first and unchanged, exactly one LF supplied, then B's new
    # record. B's altered signed copy is NOT there: A's signed copy won.
    check note.body == blobA & "\n" & certificateNoteDelimiter & "\n" & recordB
    check certificateNoteRecord(alteredA) notin note.body
    let entries = readCertificateNote(note.body)
    check entries.len == 3
    check entries.allIt(it.read.status == crsOk)

    # ---- 3. pushing again changes nothing --------------------------------
    let again = pushCertificateNotes("git", cloneB, "origin")
    check again.ok
    let noteAgain = readNoteBlob("git", inspect, tree, certificateNotesRef)
    check noteAgain.body == note.body

    # ---- 4. the push runs the git it was given, and only that git --------
    # ``gitBin`` is the git ``repro push`` resolved; the library's fetch,
    # merge and push must run it too, not whatever `git` is first on PATH.
    # A git that cannot run is a failure, never "no certificate notes".
    let broken = pushCertificateNotes(scratch / "no-such-git", cloneB,
      "origin")
    checkpoint("broken git: " & broken.diagnostic)
    check not broken.ok
    check not broken.pushed
    check "no-such-git" in broken.diagnostic
    when not defined(windows):
      # A logging wrapper around the real git (a shell script, which
      # Windows cannot run as an executable): every command it sees is one
      # the push ran through ``gitBin``.
      let log = scratch / "git-calls.log"
      let wrapper = scratch / "logging-git"
      writeFile(wrapper, "#!/bin/sh\nprintf '%s\\n' \"$*\" >> " &
        quoteShell(log) & "\nexec " & quoteShell(findExe("git")) &
        " \"$@\"\n")
      setFilePermissions(wrapper, {fpUserRead, fpUserWrite, fpUserExec})
      check attachCertificate("git", cloneB,
        certFor(tree, "runner-b-again")).ok
      let viaWrapper = pushCertificateNotes(wrapper, cloneB, "origin")
      checkpoint("wrapper: " & viaWrapper.diagnostic)
      check viaWrapper.ok and viaWrapper.pushed
      let calls = readFile(log).splitLines()
      check calls.anyIt(it.startsWith("push "))
      check calls.anyIt("rev-parse" in it)
