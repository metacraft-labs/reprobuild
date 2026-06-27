## Workspace-Manifest-Optional MO-3 — every ``LockStore`` backend genuinely
## persists a lock record and reads it back through the abstract interface.
##
## For EACH of the five backends — committed-file, git-checkout, git-notes,
## separate-branch, external-CLI — we write a ``StoreLockRecord`` through the
## ``LockStore`` interface (``putLock``) and read it back (``latestLock`` /
## ``latestLockAny``), asserting the FULL record (project / repo / sha + the
## verbatim lock body) round-trips. Each backend persists to its own medium:
## repo-local files, a committed ``locks/...`` git layout, ``refs/notes/...``,
## a gh-pages-style orphan branch, and an external KV program.
##
## Falsifiable: each backend's round-trip asserts both identity AND body. If a
## backend's ``putLock`` were a no-op (or wrote nothing real), ``latestLock``
## returns ``none`` and the ``isSome`` assertion fails; if it persisted the
## body wrongly, the body-equality assertion fails. (Confirmed by breaking the
## committed-file writer — its round-trip then fails.)
##
## Skip rule: ``git`` missing on PATH (the four VCS-backed backends need it).

import std/[options, os, osproc, strutils, tempfiles, unittest]

import repro_lock_store
import repro_cli_support
import git_tool

proc run(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = run(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc q(value: string): string = quoteShell(value)

proc initGitRepo(gitBin, path: string) =
  createDir(path)
  discard requireGit(q(gitBin) & " init -b main " & q(path))
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(path) &
    " config user.name \"MO-3 Tester\"")

proc seedCommit(gitBin, path: string): string =
  ## Create one commit so its SHA can anchor a git-notes record.
  writeFile(path / "seed.txt", "seed\n")
  discard requireGit(q(gitBin) & " -C " & q(path) & " add seed.txt")
  discard requireGit(q(gitBin) & " -C " & q(path) & " commit -m seed")
  requireGit(q(gitBin) & " -C " & q(path) & " rev-parse HEAD").strip()

proc sampleBody(sha: string): string =
  ## A realistic lock body (multi-line, ``=``-bearing) so the framing/round
  ## trip is exercised on a body that is NOT a trivial scalar.
  "[[repo]]\npath = \"demo\"\nrevision = \"" & sha & "\"\n# note = value\n"

template assertRoundtrip(store: LockStore; rec: StoreLockRecord) =
  ## A template (not a proc) so the ``check`` failures register against the
  ## enclosing ``test`` block's status rather than being swallowed.
  block:
    let put = store.putLock(rec)
    if put.outcome != spoOk:
      checkpoint(store.backendId() & " putLock failed: " & put.diagnostic)
    check put.outcome == spoOk
    let got = store.latestLock(rec.key.project, rec.key.repo)
    check got.isSome
    if got.isSome:
      check got.get().key.project == rec.key.project
      check got.get().key.repo == rec.key.repo
      check got.get().key.sha == rec.key.sha
      check got.get().body == rec.body
    # latestLockAny must resolve the same record across the project's repos.
    let anyGot = store.latestLockAny(rec.key.project)
    check anyGot.isSome
    if anyGot.isSome:
      check anyGot.get().key.sha == rec.key.sha
      check anyGot.get().body == rec.body

proc writeStubCli(path: string) =
  ## External-CLI stub honoring ``ExternalCliContractSchemaV1``: a shell KV
  ## store under ``$DB_DIR``. ``put <KEY>`` reads the request JSON on stdin
  ## and persists the base64 ``value`` keyed by KEY; ``get <KEY>`` writes the
  ## hit/miss JSON to stdout. Base64 values carry no ``"`` so a sed extract is
  ## lossless — no interpreter dependency.
  writeFile(path, """#!/usr/bin/env bash
set -euo pipefail
db="${DB_DIR:?DB_DIR unset}"
op="$1"; key="$2"
safe=$(printf '%s' "$key" | tr '/' '_')
if [ "$op" = "put" ]; then
  json=$(cat)
  val=$(printf '%s' "$json" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
  printf '%s' "$val" > "$db/$safe"
  exit 0
elif [ "$op" = "get" ]; then
  if [ -f "$db/$safe" ]; then
    val=$(cat "$db/$safe")
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":true,"value":"%s"}' "$val"
  else
    printf '{"schema":"reprobuild.lockstore.external-cli.v1","found":false}'
  fi
  exit 0
fi
echo "unknown op: $op" >&2
exit 1
""")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

suite "MO-3 — LockStore backends round-trip a lock record":

  test "t_lock_store_backend_roundtrip_each_backend":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-mo3-roundtrip-", "")
      defer: removeDir(scratch)

      # ---- Backend 1: committed-file -----------------------------------
      block:
        let store: LockStore =
          newCommittedFileLockStore(scratch / "committed")
        check store.backendId() == "committed-file"
        let sha = "1111111111111111111111111111111111111111"
        assertRoundtrip(store,
          StoreLockRecord(
            key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
            body: sampleBody(sha)))

      # ---- Backend 2: git-checkout (the .repo/manifests locks layout) --
      block:
        let work = scratch / "gc"
        initGitRepo(gitBin, work)
        discard seedCommit(gitBin, work)
        let identity = ensureGitToolResolvable(tpmPathOnly, gitBin.parentDir)
        let store: LockStore = newGitCheckoutLockStore(identity, work)
        check store.backendId() == "git-checkout"
        let sha = "2222222222222222222222222222222222222222"
        assertRoundtrip(store,
          StoreLockRecord(
            key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
            body: sampleBody(sha)))

      # ---- Backend 3: git-notes ----------------------------------------
      block:
        let work = scratch / "gn"
        initGitRepo(gitBin, work)
        # A git note attaches to a real commit, so the record SHA must name
        # one: anchor on the seed commit.
        let sha = seedCommit(gitBin, work)
        let store: LockStore = newGitNotesLockStore(gitBin, work)
        check store.backendId() == "git-notes"
        assertRoundtrip(store,
          StoreLockRecord(
            key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
            body: sampleBody(sha)))

      # ---- Backend 4: separate-branch (orphan branch) ------------------
      block:
        let work = scratch / "sb"
        initGitRepo(gitBin, work)
        discard seedCommit(gitBin, work)
        let store: LockStore = newSeparateBranchLockStore(gitBin, work)
        check store.backendId() == "separate-branch"
        let sha = "4444444444444444444444444444444444444444"
        assertRoundtrip(store,
          StoreLockRecord(
            key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
            body: sampleBody(sha)))

      # ---- Backend 5: external-CLI -------------------------------------
      block:
        let db = scratch / "ec-db"
        createDir(db)
        let stub = scratch / "ec-stub.sh"
        writeStubCli(stub)
        putEnv("DB_DIR", db)
        let store: LockStore = newExternalCliLockStore(stub)
        check store.backendId() == "external-cli"
        let sha = "5555555555555555555555555555555555555555"
        assertRoundtrip(store,
          StoreLockRecord(
            key: StoreLockKey(project: "demo", repo: "demo", sha: sha),
            body: sampleBody(sha)))
        delEnv("DB_DIR")
