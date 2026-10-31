## A certificate note read keeps git's stderr OUT of the note text.
##
## test-certificates-spec Transport §3.1 frames a note as records, each
## preceded by ``# --- test-certificate ---``, and reports a non-empty piece
## before the first delimiter as a FRAMING fault. The note is the BLOB git
## stores, not the output of the command that fetched it: anything git writes
## to stderr while showing a note (a ``safe.directory`` notice, a
## replace-object warning, a lazy-fetch message in a partial clone) must not
## land ahead of the first delimiter and be reported as a carrier fault that
## does not exist (reprobuild-pm
## ``issues/2026-10-12-note-reads-merge-git-stderr-into-the-note-text.md``).
##
## ``GIT_TRACE_SETUP=2`` makes every git command that sets up a repository
## print ``setup: git_dir:`` lines on stderr and succeed otherwise unchanged,
## which is the realistic shape: a well-formed note, shown successfully, with
## git noise beside it. ``rev-parse`` does its own setup and prints none of
## them, so ``GIT_TRACE=2`` is set as well: it makes EVERY command, rev-parse
## included, print a ``trace:`` line on stderr.
##
## Sub-cases:
##   1. Positive control: with the trace set, ``git notes show`` and
##      ``git rev-parse`` really write to stderr — so the rest of the test
##      cannot pass vacuously.
##   2. The ref-NAME path (``notes show``) and the raw notes-COMMIT path (the
##      pre-receive tree walk) both read the note with NO framing fault, find
##      the certificate, and return a body byte-identical to the blob as
##      ``git cat-file blob`` gives it. The commit-keyed read the gateway
##      makes (``readAttachedCertificatesFrom``, which resolves
##      ``<commit>^{tree}`` first) finds it too, rather than reporting the
##      tree as unresolvable.
##   3. Exit status still drives the absent / unreadable distinction: no note
##      is ``gorAbsent``; a note whose blob is gone is ``gorUnreadable`` on
##      both paths, and its diagnostic still carries what git said on stderr.
##   4. The body is the blob BYTE FOR BYTE on both paths, including a blob
##      with no trailing newline and one with CRLF line endings — shapes a
##      line-by-line capture of stdout changes.
##
## Falsifiability: merge stderr into the captured note again → 2 fails with a
## framing fault and a body that is not the blob, and merging it into the
## ``<commit>^{tree}`` resolution fails 2's commit-keyed read as unreadable;
## rebuild stdout line by line
## → 4 fails (a newline added, a ``\r`` dropped); drop stderr instead of
## keeping it for the diagnostic → 3's diagnostic assertions fail; fold a
## failed read into "absent" → 3's status assertions fail.
##
## Hermetic: local ``git init`` repos only; no network, no mocks — the real
## git binary and the real reader. Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_cli_support
import ./certificate_note_seed
import repro_test_support/reasoned_skip

proc gitOut(repo: string; args: varargs[string]): string =
  ## Run git in ``repo`` with stdout only (stderr is not captured), failing the
  ## test on a non-zero exit. Used to compute expectations by git itself.
  var argv = @["git", "-C", repo]
  for a in args: argv.add(a)
  let res = execCmdEx(quoteShellCommand(argv), options = {poUsePath})
  if res.exitCode != 0:
    checkpoint("git failed: " & argv.join(" ") & "\n" & res.output)
    fail()
  res.output

proc gitExact(repo: string; args: varargs[string]): string =
  ## git's stdout, byte for byte (no line re-assembly), read from a file.
  let (f, outPath) = createTempFile("t-note-stdout-", ".bin")
  f.close()
  defer: removeFile(outPath)
  var argv = @["git", "-C", repo]
  for a in args: argv.add(a)
  let code = execCmd(quoteShellCommand(argv) & " >" & quoteShell(outPath))
  check code == 0
  readFile(outPath)

proc certFor(content: string): TestCertificate =
  TestCertificate(
    schema: testCertificateSchemaV1,
    framework: reprobuildFrameworkId,
    project: "lib-a",
    platform: "linux/amd64",
    targets: @["t-unit"],
    result: tcrPassed,
    issuedAt: "2026-10-18T10:00:00Z",
    issuer: "repro-test@note-stderr",
    vcs: TestCertificateVcs(repo: "lib-a", content: content, untracked: false,
      base: ""),
    commands: @[TestCertificateCommand(argv: @["repro", "test"])])

proc initRepo(path: string): string =
  ## A one-commit repository; returns the commit's tree oid.
  discard gitOut(path.parentDir, "init", "-q", "-b", "main", path)
  discard gitOut(path, "config", "user.email", "tester@example.invalid")
  discard gitOut(path, "config", "user.name", "Note Tester")
  writeFile(path / "a.txt", "a\n")
  discard gitOut(path, "add", "a.txt")
  discard gitOut(path, "commit", "-q", "-m", "a")
  gitOut(path, "rev-parse", "HEAD^{tree}").strip()

const traceVars = ["GIT_TRACE_SETUP", "GIT_TRACE"]

template withGitTrace(body: untyped) =
  ## ``GIT_TRACE_SETUP=2`` and ``GIT_TRACE=2`` for the reads in ``body`` only;
  ## the previous values (or their absence) are restored afterwards.
  var saved: seq[tuple[name: string; had: bool; value: string]]
  for name in traceVars:
    saved.add((name: name, had: existsEnv(name), value: getEnv(name)))
    putEnv(name, "2")
  try:
    body
  finally:
    for s in saved:
      if s.had: putEnv(s.name, s.value)
      else: delEnv(s.name)

suite "a certificate note read keeps git's stderr apart":

  test "t_certificate_note_read_keeps_git_stderr_apart":
    if findExe("git").len == 0:
      skip("git not on PATH; this case reads notes from a real repository")
    else:
      let scratch = createTempDir("repro-note-stderr-", "")
      defer: removeDir(scratch)
      let repo = scratch / "lib-a"
      let tree = initRepo(repo)
      let content = "git-tree-sha1:" & tree
      check seedCertificateNote("git", repo, certFor(content)).ok

      # Expectations computed by git itself, with no trace in the environment.
      let blobOid = gitOut(repo, "notes", "--ref", certificateNotesRef,
        "list", tree).strip()
      check blobOid.len == 40
      let blob = gitExact(repo, "cat-file", "blob", blobOid)
      check blob.startsWith("# --- test-certificate ---")
      let notesCommit = gitOut(repo, "rev-parse", certificateNotesRef).strip()
      check notesCommit.len == 40

      withGitTrace:
        # ---- 1. positive control: git really writes to stderr ------------
        let errPath = scratch / "control-stderr.txt"
        let ctl = execCmd(quoteShellCommand(@["git", "-C", repo, "notes",
          "--ref", certificateNotesRef, "show", tree]) & " >" &
          quoteShell(scratch / "control-stdout.txt") & " 2>" &
          quoteShell(errPath))
        check ctl == 0
        let ctlErr = readFile(errPath)
        checkpoint("control stderr: " & ctlErr)
        check "setup: git_dir:" in ctlErr
        check readFile(scratch / "control-stdout.txt") == blob
        let revErr = scratch / "control-rev-parse-stderr.txt"
        let rev = execCmd(quoteShellCommand(@["git", "-C", repo, "rev-parse",
          "--verify", "--quiet", "HEAD^{tree}"]) & " >" &
          quoteShell(scratch / "control-rev-parse-stdout.txt") & " 2>" &
          quoteShell(revErr))
        check rev == 0
        check "trace:" in readFile(revErr)
        check readFile(scratch / "control-rev-parse-stdout.txt").strip() == tree

        # ---- 2. both read paths: no framing fault, the exact blob ---------
        for notesRef in [certificateNotesRef, notesCommit]:
          checkpoint("notesRef = " & notesRef)
          let raw = readNoteBlob("git", repo, tree, notesRef)
          check raw.status == gorPresent
          check raw.body == blob
          let noted = readNotedCertificates("git", repo, tree, notesRef)
          checkpoint("framing faults: " & noted.framingFaults.join(" | "))
          check noted.status == gorPresent
          check noted.framingFaults.len == 0
          check noted.misattached.len == 0
          check noted.certs.len == 1
          if noted.certs.len == 1:
            check noted.certs[0].vcs.content == content
          # The commit-keyed read the gateway's pre-receive verify makes:
          # ``<commit>^{tree}`` is resolved first, and git's stderr must not
          # turn that resolution into an unreadable note either.
          let attached = readAttachedCertificatesFrom("git", repo, "HEAD",
            notesRef)
          checkpoint("attached diagnostic: " & attached.diagnostic)
          check attached.status == gorPresent
          check attached.framingFaults.len == 0
          check attached.certs.len == 1

        # ---- 3. absent and unreadable keep their meaning -------------------
        let otherTree = gitOut(repo, "mktree").strip()  # the empty tree
        check readNoteBlob("git", repo, otherTree,
          certificateNotesRef).status == gorAbsent
        check readNoteBlob("git", repo, otherTree,
          notesCommit).status == gorAbsent

      # ---- 4. the body is the blob's bytes, not a line-by-line rebuild ----
      # Two blobs a line-oriented capture would change: no trailing newline
      # (a rebuild appends one) and CRLF line endings (a rebuild folds them
      # to LF). Stored with ``hash-object -w`` and attached with
      # ``notes add -f -C``, which keeps the blob verbatim.
      let shapes = [
        ("no-trailing-newline", blob[0 ..< blob.len - 1]),
        ("crlf", blob.replace("\n", "\r\n"))]
      check not shapes[0][1].endsWith("\n")
      check "\r\n" in shapes[1][1]
      var shaped: seq[tuple[label, annotated, raw: string]]
      for (label, raw) in shapes:
        let payload = scratch / (label & ".note")
        writeFile(payload, raw)
        let target = scratch / (label & ".target")
        writeFile(target, label & "\n")
        let annotated = gitOut(repo, "hash-object", "-w", "--", target).strip()
        let oid = gitOut(repo, "hash-object", "-w", "--", payload).strip()
        discard gitOut(repo, "notes", "--ref", certificateNotesRef, "add",
          "-f", "-C", oid, annotated)
        # git itself confirms the stored bytes are the ones written.
        check gitExact(repo, "cat-file", "blob", oid) == raw
        shaped.add((label: label, annotated: annotated, raw: raw))
      let shapedNotesCommit = gitOut(repo, "rev-parse",
        certificateNotesRef).strip()
      withGitTrace:
        for entry in shaped:
          for notesRef in [certificateNotesRef, shapedNotesCommit]:
            checkpoint(entry.label & " via " & notesRef)
            let read = readNoteBlob("git", repo, entry.annotated, notesRef)
            check read.status == gorPresent
            check read.body.len == entry.raw.len
            check read.body == entry.raw

      # The blob goes; the notes tree still names it.
      let objPath = repo / ".git" / "objects" / blobOid[0 .. 1] /
        blobOid[2 .. ^1]
      check fileExists(objPath)
      removeFile(objPath)
      withGitTrace:
        for notesRef in [certificateNotesRef, notesCommit]:
          checkpoint("notesRef = " & notesRef)
          let gone = readNoteBlob("git", repo, tree, notesRef)
          checkpoint("diagnostic: " & gone.diagnostic)
          check gone.status == gorUnreadable
          check gone.body.len == 0
          # What git said on stderr is kept for the diagnostic.
          check "fatal" in gone.diagnostic.toLowerAscii() or
            "error" in gone.diagnostic.toLowerAscii()
          check blobOid in gone.diagnostic
