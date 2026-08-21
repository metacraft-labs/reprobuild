## A managed hook must never let an unidentified ``repro`` build speak for it.
##
## The managed hook bodies resolve their interpreter as ``$REPROBUILD_REPRO``
## else whatever ``repro`` is on PATH. That fallback is silent, so a workstation
## whose PATH ``repro`` is an outdated install runs the outdated build's
## dispatch logic against hooks a newer build generated. The failure mode is not
## a clean version error — it is a refusal whose stated cause is false. An
## outdated build that cannot read the current workspace manifests refused a
## push with:
##
##   .repro-workspace.toml … TOML parser raised with no message; common cause:
##   unescaped backslash
##
## There are no backslashes in that file, and it parses under a current binary.
## Nothing in the message names the binary that produced it, so the operator
## debugs the manifest instead of the interpreter.
##
## Two things fix that, and this suite pins both:
##
##   1. HANDSHAKE. Each generated hook body carries the contract token of the
##      build that generated it and asks its resolved binary to confirm it
##      (``repro hooks protocol --require=2 --hook-contract=<token>``). A build
##      that does not confirm never gets to run the hook at all. ``pre-push``
##      REFUSES (a gate an unidentified build decides is not a gate);
##      ``post-commit`` announces and exits 0 (a hook must not fail a commit
##      after the fact).
##   2. ATTRIBUTION. Whenever the dispatch itself fails, the hook names the
##      binary that produced the refusal and how it was resolved, so no
##      diagnostic can be read as coming from a build other than the one that
##      emitted it.
##
## The fixture uses a STUB ``repro`` — justified because the defect is
## specifically about a binary the workspace did NOT build: the point is to
## observe what the hook does with an interpreter whose behaviour it cannot
## trust, and no real second build can be produced hermetically inside a test.
## The stub is behavioural, not a mock of an interface: it reproduces exactly
## what an older CLI does (answers the bare ``--require=2`` probe, rejects
## flags it predates) and records whether it was ever asked to dispatch. Every
## other participant — the hooks, the real binary, git — is real.
##
## Assertions, each falsifiable:
##
##   (A) pre-push + stale stub → the push is REFUSED, the message names the
##       stub path and how it was resolved, and the stub's dispatch was NEVER
##       reached (so no bogus diagnostic of its could be the stated cause).
##   (B) post-commit + stale stub → the commit SUCCEEDS (exit 0) and the same
##       attributable diagnostic reaches the terminal; the stub's dispatch was
##       never reached.
##   (C) attribution: a stub that DOES confirm the contract but fails the
##       dispatch has its failure attributed to it by path.
##   (D) control: with the REAL binary the contract-mismatch diagnostic never
##       appears — the handshake does not fire on a matching build.
##
## Hermetic: one ``createTempDir``, local bares only, no network.
## Skip rule: ``git`` missing on PATH.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd,
    options = {poStdErrToStdOut, poUsePath})
  (code: res.exitCode, output: res.output)

proc requireGit(command: string; cwd = ""): string =
  let res = runCmd(command, cwd)
  if res.code != 0:
    checkpoint("command failed: " & command & "\nexit=" & $res.code &
      "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc configIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Hook Contract Tester\"")

const bogusDiagnostic =
  ".repro-workspace.toml: TOML parser raised with no message; " &
  "common cause: unescaped backslash"

proc writeStaleStub(path, marker: string) =
  ## A ``repro`` that predates the hook-contract handshake: it answers the bare
  ## ``--require=2`` probe (as every v2-era build does) and rejects the flag it
  ## does not know. If it is ever asked to DISPATCH it records the fact and
  ## emits the bogus refusal an outdated build produces.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  if [ \"$#\" -eq 3 ] && [ \"${3:-}\" = \"--require=2\" ]; then\n" &
    "    echo 2\n" &
    "    exit 0\n" &
    "  fi\n" &
    "  echo \"repro hooks protocol requires exactly --require=2\" >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"dispatch\" ]; then\n" &
    "  : > " & q(marker) & "\n" &
    "  echo \"" & bogusDiagnostic & "\" >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc writeContractAwareFailingStub(path, realRepro, marker: string) =
  ## A ``repro`` that DOES confirm the hook contract (it forwards the probe to
  ## the real binary) but fails the dispatch. Used to prove the attribution
  ## line: a refusal must name the binary that produced it.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  exec " & q(realRepro) & " \"$@\"\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"dispatch\" ]; then\n" &
    "  : > " & q(marker) & "\n" &
    "  echo \"" & bogusDiagnostic & "\" >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

suite "managed hooks refuse a repro that does not speak their contract":

  test "t_managed_hooks_refuse_a_repro_that_does_not_speak_their_contract":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-hook-contract-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- upstream + repo --------------------------------------------
      let origin = scratch / "origin.git"
      let repoPath = scratch / "repo"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(repoPath))
      configIdentity(gitBin, repoPath)
      writeFile(repoPath / "README.md", "hook contract fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " commit -m seed")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " remote add origin " & q(origin))

      # ---- install the REAL managed hooks with the REAL binary ---------
      let ensured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs", repoPath]))
      checkpoint("hooks ensure output: " & ensured.output)
      check ensured.code == 0
      let managedPrePush = repoPath / ".git" / "hooks" / "pre-push.repro-managed"
      let managedPostCommit = repoPath / ".git" / "hooks" /
        "post-commit.repro-managed"
      check fileExists(managedPrePush)
      check fileExists(managedPostCommit)
      # The generated body must actually carry a contract token — without it
      # there is nothing for the binary to confirm and (A)-(D) prove nothing.
      check "--hook-contract=" in readFile(managedPrePush)
      check "--hook-contract=" in readFile(managedPostCommit)

      # ---- (A) pre-push + a stale interpreter → REFUSED ----------------
      let staleStub = scratch / "stale-repro"
      let staleMarker = scratch / "stale-dispatched.marker"
      writeStaleStub(staleStub, staleMarker)
      let stalePush = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      checkpoint("(A) stale-stub push output: " & stalePush.output)
      # Falsifiable: without the handshake the stub's dispatch runs, the push
      # is refused for the stub's stated (false) reason, and the marker exists.
      check stalePush.code != 0
      check staleStub in stalePush.output
      check "hook-contract" in stalePush.output or
        "contract" in stalePush.output
      check not fileExists(staleMarker)
      check bogusDiagnostic notin stalePush.output
      # The refusal must be attributable: nothing reached the upstream either.
      let upstreamAfterStale = runCmd(q(gitBin) & " -C " & q(origin) &
        " rev-parse --verify --quiet refs/heads/main")
      check upstreamAfterStale.code != 0

      # ---- (B) post-commit + the same stale interpreter -----------------
      # A commit must still succeed; the diagnostic must still be attributable.
      writeFile(repoPath / "second.txt", "more work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add second.txt")
      let staleCommit = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "second"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      checkpoint("(B) stale-stub commit output: " & staleCommit.output)
      check staleCommit.code == 0
      check staleStub in staleCommit.output
      check not fileExists(staleMarker)

      # ---- (C) attribution for a dispatch that DOES run ----------------
      let failingStub = scratch / "contract-aware-repro"
      let failingMarker = scratch / "contract-aware-dispatched.marker"
      writeContractAwareFailingStub(failingStub, reproBin, failingMarker)
      let attributedPush = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: failingStub)]))
      checkpoint("(C) contract-aware push output: " & attributedPush.output)
      check attributedPush.code != 0
      # The dispatch DID run this time (the contract matched) ...
      check fileExists(failingMarker)
      # ... and the refusal names the binary that produced it, next to the
      # binary's own diagnostic. Falsifiable: without the attribution line the
      # bogus diagnostic appears alone, exactly as it did in the field.
      check bogusDiagnostic in attributedPush.output
      check failingStub in attributedPush.output

      # ---- (D) control: the REAL binary never trips the handshake -------
      let realPush = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("(D) real-binary push output: " & realPush.output)
      # We assert only the ABSENCE of the contract-mismatch refusal: the gate
      # itself may legitimately accept or refuse this push on its own merits.
      check "does not speak" notin realPush.output
