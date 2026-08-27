## A hook that refuses because its OWN interpreter is stale must hand the
## operator a remedy they can run — and must not hand them one that disarms the
## check.
##
## Background. ``t_managed_hooks_refuse_a_repro_that_does_not_speak_their_contract``
## already pins the HANDSHAKE: a ``repro`` that does not confirm the hook's
## contract never gets to dispatch, and ``pre-push`` refuses. That is the
## correct verdict and this suite does not relitigate it.
##
## What this suite pins is the REMEDY the refusal prints, because the first
## version of it was observed doing active harm in the field. It read:
##
##   repro hooks: diagnostics would not describe this hook. Set REPROBUILD_REPRO to the
##   repro hooks: matching binary, or reinstall these hooks with '<that binary> hooks
##   repro hooks: ensure --vcs <repo root>'.
##
## Three defects, all reproduced on a real workstation before this suite was
## written:
##
##   1. NOTHING IS RUNNABLE. ``<that binary>`` is a placeholder. An operator
##      whose only ``repro`` is the stale one has no command to copy.
##   2. THE NAMED REMEDY DISARMS THE GATE. Read literally with the only binary
##      the operator has, "reinstall these hooks with '<that binary> hooks
##      ensure --vcs <root>'" means ``repro hooks ensure --vcs .`` run by the
##      STALE build. Doing exactly that was measured to rewrite
##      ``pre-push.repro-managed`` with the stale build's own pre-contract body:
##      the ``--hook-contract=`` token disappears from the file entirely, and
##      from then on no handshake happens at all and no diagnostic is ever
##      printed again. The refusal talked the operator into silencing itself.
##   3. IT READS AS A VERDICT. "the resolved 'repro' does not speak this hook's
##      contract" is a true statement about tooling, but an operator reads a
##      blocked push as "the hook rejected my push". The next move is
##      ``git push --no-verify``, which also disables the CORRECT refusals — the
##      ones about unpublished heads and missing locks. That is how a tooling
##      mismatch turns into a mainline of unlocked heads.
##
## So the obligation is narrow and stated positively: when a hook refuses
## because it could not EVALUATE the policy, the refusal must (a) say the policy
## was not evaluated, (b) identify the interpreter well enough to act on —
## including its version, (c) offer at least one command with no placeholder in
## it, (d) never instruct a reinstall by the unconfirmed binary, and (e) name
## ``--no-verify`` as the wrong escape.
##
## The fixture uses a STUB ``repro``, justified for the same reason the sibling
## suite justifies one: the defect is specifically about an interpreter the
## workspace did NOT build, and no second real build can be produced
## hermetically inside a test. The stub is behavioural, not an interface mock —
## it answers the bare ``--require=2`` probe exactly as every pre-contract build
## does and rejects the flag it predates. Every other participant (the hooks,
## the real binary, git) is real.
##
## Assertions, each falsifiable and each killed by a distinct mutation:
##
##   (R1) the refusal names the resolved interpreter's VERSION, not only its path
##   (R2) the refusal says the policy was NOT evaluated (tooling fault framing)
##   (R3) the refusal contains no ``<placeholder>`` and does contain a runnable
##        ``REPROBUILD_REPRO=<path> git push`` line carrying this repo's root
##   (R4) ``hooks ensure`` never appears as an instruction — every line
##        mentioning it also warns against it
##   (R5) ``--no-verify`` is named as unsafe
##   (R6) the push is still REFUSED and the stub's dispatch is still never
##        reached (this suite must not weaken the sibling suite's gate)
##   (R7) control: with the REAL binary none of this text appears
##   (R8) the opposite mismatch gets the opposite advice: a binary that DOES
##        speak the handshake and merely generates a different hook is handed
##        the reinstall command, because for it the reinstall is the fix
##
## Hermetic: one ``createTempDir``, a local bare remote, no network.
## Skip rule: ``git`` missing on PATH — announced, not silent.

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

const staleStubVersion = "repro 0.0.0-pre-contract"

proc writeStaleStub(path, marker: string) =
  ## A ``repro`` that predates the hook-contract handshake: it answers the bare
  ## ``--require=2`` probe (as every v2-era build does), rejects the flag it
  ## does not know, and reports a version when asked. If it is ever asked to
  ## DISPATCH it records the fact.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo \"" & staleStubVersion & "\"\n" &
    "  exit 0\n" &
    "fi\n" &
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
    "  exit 1\n" &
    "fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc linesMentioning(text, needle: string): seq[string] =
  for line in text.splitLines:
    if needle in line:
      result.add(line)

suite "a stale repro's refusal names a remedy that does not disarm the gate":

  test "t_stale_repro_refusal_names_a_remedy_that_does_not_disarm_the_gate":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      checkpoint("SKIPPED: git is not on PATH; this suite drives real pushes " &
        "through real managed hooks and cannot run without it")
      skip()
    else:
      let scratch = createTempDir("repro-stale-remedy-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()

      # ---- upstream + repo --------------------------------------------
      let origin = scratch / "origin.git"
      let repoPath = scratch / "repo"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(repoPath))
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.email tester@example.invalid")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) &
        " config user.name \"Stale Remedy Tester\"")
      writeFile(repoPath / "README.md", "stale remedy fixture\n")
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
      check fileExists(managedPrePush)
      check "--hook-contract=" in readFile(managedPrePush)

      # ---- drive a push through a stale interpreter --------------------
      let staleStub = scratch / "stale-repro"
      let staleMarker = scratch / "stale-dispatched.marker"
      writeStaleStub(staleStub, staleMarker)
      let refused = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      let msg = refused.output
      checkpoint("refusal output:\n" & msg)

      # (R6) the gate itself is unchanged: still refused, never dispatched.
      check refused.code != 0
      check not fileExists(staleMarker)
      check staleStub in msg

      # (R1) the interpreter is identified by VERSION, not only by path. A path
      # under /nix/store is opaque; the version is what an operator compares
      # against the workspace and what belongs in a bug report.
      check staleStubVersion in msg

      # (R2) the refusal states that the policy was NOT evaluated. Without this
      # the operator reads a blocked push as a verdict on the push.
      check ("could not be evaluated" in msg) or ("was not evaluated" in msg)

      # (R3) every command offered is runnable. No angle-bracket placeholder
      # survives anywhere in the message, and the escape hatch names a REAL
      # path: the binary that generated this hook knows its own location and
      # bakes it in at ``hooks ensure`` time, so the refusal can hand over a
      # command instead of the shape of one. ``<that binary>`` was never
      # something an operator could run.
      for line in msg.splitLines:
        if line.startsWith("repro hooks:"):
          check '<' notin line
          check '>' notin line
      check ("REPROBUILD_REPRO=" & reproBin) in msg
      check "git push" in msg

      # (R4) the refusal must never TELL the operator to reinstall the hooks
      # with the binary that just failed the handshake. Measured harm: that
      # rewrites the managed hook with the stale build's pre-contract body and
      # the '--hook-contract=' token vanishes, permanently silencing this very
      # diagnostic. Every line that mentions the command must warn against it.
      # Stated as two positive facts rather than a scan, because the text this
      # replaced wrapped the instruction across a line break ("... with '<that
      # binary> hooks" / "ensure --vcs ...") and any per-line scan for "hooks
      # ensure" would have found nothing and passed while the harm was on
      # screen.
      check "reinstall these hooks" notin msg
      check "Do NOT run 'repro hooks ensure'" in msg
      # Whatever else it says, the warning and the command must not both be
      # offered: no line may present the reinstall as a step to take.
      for line in linesMentioning(msg, "hooks ensure"):
        check ("do not" in line.toLowerAscii) or
          ("disarm" in line.toLowerAscii) or
          ("silence" in line.toLowerAscii)

      # (R5) the escape the operator would otherwise reach for is named as the
      # wrong one, because it disables the correct refusals too.
      check "--no-verify" in msg

      # ---- (R8) the OPPOSITE mismatch gets the OPPOSITE advice ----------
      # A binary that DOES speak the handshake and merely generates a
      # different hook (the newer-build-meets-older-hook case) is in the one
      # situation where ``hooks ensure`` is exactly right. A refusal that
      # forbade it unconditionally would be just as wrong as one that
      # recommended it unconditionally, so the message must branch on which
      # mismatch this is — the probe's exit status 3 is what says so.
      let differentStub = scratch / "different-build-repro"
      writeFile(differentStub,
        "#!/usr/bin/env sh\n" &
        "if [ \"${1:-}\" = \"--version\" ]; then\n" &
        "  echo \"repro 9.9.9-newer\"\n" &
        "  exit 0\n" &
        "fi\n" &
        "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
        "  for a in \"$@\"; do\n" &
        "    case $a in --hook-contract=*)\n" &
        "      echo \"repro hooks: this build generates something else\" >&2\n" &
        "      exit 3 ;;\n" &
        "    esac\n" &
        "  done\n" &
        "  echo 2\n" &
        "  exit 0\n" &
        "fi\n" &
        "exit 0\n")
      inclFilePermissions(differentStub,
        {fpUserExec, fpGroupExec, fpOthersExec})
      let differentPush = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: differentStub)]))
      let dmsg = differentPush.output
      checkpoint("(R8) contract-aware-different-build output:\n" & dmsg)
      check differentPush.code != 0
      # Here the reinstall IS the remedy, and it is offered as a command that
      # names the binary and this repository — not forbidden, not templated.
      check (differentStub & " hooks ensure --vcs " & repoPath) in dmsg
      # ... and the "it predates the handshake" story must NOT be told about a
      # binary that just proved it does not.
      check "predates this handshake" notin dmsg

      # ---- (R7) control: the REAL binary trips none of this -------------
      let realPush = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "push", "origin", "main"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("(R7) real-binary push output:\n" & realPush.output)
      check "could not be evaluated" notin realPush.output
      check "--no-verify" notin realPush.output
