## PG-15 — "wired and refusing" and "wired and working" must not be the same
## bytes on disk.
##
## THE DEFECT, AS MEASURED. The generated managed-hook body's contract refusal
## was 33 lines of which 24 were `echo … >&2`, and it performed ZERO file
## writes: no redirection to a file, no `tee`, no `touch`, no `mkdir`.
## Meanwhile EVERY dispatch path writes
## `<workspace>/.repro/build/reports/post-commit-report.json`. So the only
## durable artefact a managed hook leaves behind could not distinguish
##
##   * a hook that dispatched and was serviced, from
##   * a hook that fired, was refused by its own interpreter, and exited 0
##     without touching anything.
##
## Observed on the development workspace itself: that report was dated
## 2026-09-30T11:45:49Z — and 2026-10-02T11:35:04Z when it was re-measured two
## days later, with the SAME `"outcome": "no-lock-dirty-siblings"` — from the
## last run that was SERVICED, while every commit in the days since had fired
## a refusing hook. Both dates are kept deliberately: the date moved while the
## finding did not, so quoting only the first would date a defect that is
## still live. Nothing updated, invalidated or deleted it. An operator
## introspecting "the latest outcome" — which the dispatcher's own doc comment
## tells them to do — read a report of a run that did not happen.
##
## Stderr alone cannot close this, and the reason is measured too
## (`Push-Gateway-Wiring-And-Policy.md` §1.6b): whether a managed hook refuses
## depends on WHICH SHELL it fires in, because the body takes the first `repro`
## on `PATH` and direnv changes what that is. The shells that refuse are
## exactly the ones with nobody watching — CI steps, `ssh` one-liners,
## editor-spawned subprocesses, agent harnesses. A diagnostic that exists only
## in a terminal that was never attached is not a diagnostic.
##
## WHAT THIS CASE PINS, in the order the milestone prescribes (a refusal, then
## a servicing dispatch, and — first — a servicing dispatch BEFORE the refusal,
## because the previous run's report is the thing that must survive):
##
##   (A) The trap is real. A serviced commit leaves `post-commit-report.json`
##       with a dispatch outcome. Without this, (C) and (D) prove nothing:
##       there would be no stale report for the refusal to be confused with.
##   (B) The refusal leaves a DURABLE RECORD of its own, keyed by hook name,
##       whose `outcome` is its own tag (`refused-contract-mismatch`) and NOT
##       a member of the dispatch vocabulary. It carries the resolved binary,
##       HOW it was resolved, that binary's version, the contract the body
##       demanded (byte-equal to the token in the installed body), the probe's
##       exit status, and the probe's own words.
##   (C) THE LAST-GOOD OUTCOME SURVIVES. `post-commit-report.json` is still
##       there and byte-identical after the refusal. This is the record-over-
##       delete choice asserted rather than asserted in prose: deleting the
##       stale report would also have ended the ambiguity, and would have
##       destroyed the only surviving description of the last run that worked.
##   (D) THE TWO OUTCOMES ARE DISTINGUISHABLE. The durable state of the report
##       directory — every file, by name and by content digest — differs
##       between "after a serviced dispatch" and "after a refusal". THIS IS
##       THE ARM THAT MUST FAIL BEFORE PG-15: the refusing case left the
##       previous run's report in place, unmodified, and wrote nothing, so the
##       two snapshots were equal.
##   (E) The refusal is a refusal, not a failed dispatch: the stub records
##       every `hooks dispatch` it is asked for, and it is never asked.
##   (F) Deliverable 3 — the probe's stderr is no longer discarded
##       (`>/dev/null 2>&1`). The foreign build's own words reach the terminal
##       under our prefix AND reach the record, so a diagnostic cannot be
##       misattributed to a build that did not produce it
##       (`CLI/hooks.md` §"Contract Handshake And Stand-Down").
##   (G) The record does not outlive the state it describes. A SERVICING fire
##       after the refusal removes it and refreshes the report. Without this
##       the fix is the same defect with the sign flipped — under §1.6b's
##       shell-dependence the two outcomes alternate on one machine, so a
##       record left behind by yesterday's bare shell would describe today's
##       dev-shell commit exactly as wrongly as the stale report described a
##       refusal.
##   (H) Deliverable 2 — the write goes through `commitHookReportDir`'s guard
##       rather than around it. Hooks installed into a plain git repository
##       that is NOT an initialized workspace bake an EMPTY destination, say so
##       on stderr, and manufacture nothing: no `.repro/` appears. A refusing
##       hook is the worst caller that guard has — it is writing into a
##       workspace whose `repro` it has just established it cannot trust — and
##       a recursive `mkdir -p` at a disclaimed root forges the `.repro/`
##       marker that makes a lock record store be misread as a workspace,
##       which is the field defect the guard was written for.
##   (I) THE SELF-HEALING SWEEP, which is retained behaviour and therefore owed
##       a guard of its own. The guard's answer is MUTABLE STATE: it is `""`
##       until the workspace's `.repro/` shell exists. So the destination can
##       change after hooks are installed, and a changed destination IS drift —
##       `ensure` re-anchors it. That is wanted, and the alternative (excluding
##       the destination from the drift comparison) leaves a hook recording
##       nowhere forever with nothing able to repair it. Three `ensure` runs
##       over a workspace whose shell materializes between runs 1 and 2 must
##       report `installed` → `refreshed-drifted` → `already-up-to-date`, the
##       baked destination must move from `''` to the report directory, and a
##       refusal must then record where it previously could not. The direction
##       is asserted, not just the inequality: ONE sweep, not a perpetual one,
##       and nowhere → somewhere, never the reverse.
##   (J) THE PER-REPO KEYING of the install-time memo. Resolving the
##       destination costs an ancestor walk with a manifest test at each level,
##       so it is memoised — but keyed by REPO ROOT, never once per guard. Two
##       repos of one workspace can legitimately resolve to different workspace
##       roots: a repo declared at a nested path under a directory that is
##       itself a workspace. A guard-wide memo bakes the FIRST repo's
##       destination into the second, which sends one repository's refusal
##       records into another workspace's report directory — and every other
##       case in this file stays green while it does, which is why this arm
##       exists.
##
## THE FIXTURE USES A STUB `repro`, and that is the whole point rather than a
## shortcut: the defect is about an interpreter the workspace did NOT build,
## and no second real build can be produced hermetically inside a test. The
## stub is BEHAVIOURAL, not a mock of an interface — it answers the bare
## `--require=2` probe exactly as every pre-handshake build does, rejects the
## flag it predates with a two-line diagnostic containing a quote and a
## backslash (so the record's JSON escaping is exercised by the test rather
## than assumed), answers `--version`, and records any dispatch it is asked
## for. Every other participant is real: real `git init`/`clone`/`commit`/
## `push`, the real `repro hooks ensure --vcs` installer, the real generated
## hook bodies, the real `repro hooks dispatch` entry point.
##
## Hermetic: one `createTempDir`, a local `git init --bare` upstream, no
## network. Skip rule: `git` missing on PATH.

import std/[algorithm, json, os, osproc, sha1, strutils, tempfiles, unittest]

import repro_test_support
# `skip("...")` on BOTH unittests the suite is built with: the CodeTracer fork
# declares `skip*(reason = "")`, the stock compiler Windows uses declares only
# `skip*()`, and calling the first form against the second does not compile at
# all — losing every case in this file, not only the skipped one. See that
# module for why dropping the reason is not the cure.
import repro_test_support/reasoned_skip
import repro_workspace_manifests

proc q(value: string): string = quoteShell(value)
## For text that goes INTO an `sh` script (the stub below). `quoteShell`
## quotes for the host's command line — cmd.exe on Windows, which leaves
## `C:\...` bare — and `sh` then eats every backslash.
proc qsh(value: string): string = quoteShellPosix(value)

proc runCmd(command: string; cwd = ""): tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
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
    " config user.name \"Refusal Record Tester\"")

const
  # The stub's own refusal, as a pre-handshake build phrases it. The quote and
  # the backslash are deliberate: they are the two characters a hand-rolled
  # JSON writer gets wrong, and this diagnostic travels through one on its way
  # into the record.
  stubProbeLine1 = "repro hooks protocol requires exactly --require=2"
  stubProbeLine2 = "it saw a \"flag\" it predates, under C:\\no\\such\\path"

proc writeStaleStub(path, marker: string) =
  ## A `repro` that predates the hook-contract handshake. It answers the bare
  ## `--require=2` probe (as every v2-era build does), rejects the flag it does
  ## not know with a two-line diagnostic, answers `--version`, and records any
  ## dispatch it is asked to perform so (E) can assert it was never asked.
  writeFile(path,
    "#!/usr/bin/env sh\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"protocol\" ]; then\n" &
    "  if [ \"$#\" -eq 3 ] && [ \"${3:-}\" = \"--require=2\" ]; then\n" &
    "    echo 2\n" &
    "    exit 0\n" &
    "  fi\n" &
    "  echo " & qsh(stubProbeLine1) & " >&2\n" &
    "  echo " & qsh(stubProbeLine2) & " >&2\n" &
    "  exit 1\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"hooks\" ] && [ \"${2:-}\" = \"dispatch\" ]; then\n" &
    "  : > " & qsh(marker) & "\n" &
    "  exit 1\n" &
    "fi\n" &
    "if [ \"${1:-}\" = \"--version\" ]; then\n" &
    "  echo 'repro 0.1.3'\n" &
    "  exit 0\n" &
    "fi\n" &
    "exit 0\n")
  inclFilePermissions(path, {fpUserExec, fpGroupExec, fpOthersExec})

proc durableSnapshot(dir: string): seq[string] =
  ## Every file in the report directory, by name and by content digest.
  ##
  ## A snapshot rather than a hand-picked list of filenames, because the claim
  ## under test is about the WHOLE of what a fire leaves behind: a fix that
  ## wrote a record but also silently rewrote the report, or that deleted the
  ## report instead of recording the refusal, must be visible here too.
  if not dirExists(dir):
    return @[]
  for kind, path in walkDir(dir):
    if kind != pcFile:
      continue
    result.add(extractFilename(path) & "\t" &
      $secureHash(readFile(path)))
  result.sort()

proc writeFlatMembership(workspaceRoot, originUrl: string;
                         repos: openArray[tuple[name, path: string]]) =
  ## A FLAT-layout membership manifest — `projects/p.toml` plus one fragment
  ## per repo — and deliberately NOTHING under `.repro/`.
  ##
  ## The absence is the fixture in (I). `hasResolvedManifestCheckout` requires
  ## the `.repro/` shell beside the flat `projects/*.toml`, so such a root
  ## RESOLVES (`ensure` enumerates every repo from it) and is still not an
  ## `isInitializedWorkspace`. That is the state in which
  ## `commitHookReportDir` answers "nowhere", and the state the destination
  ## later heals out of.
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  var includes = ""
  for r in repos:
    includes.add("  \"repos/" & r.name & ".toml\",\n")
    writeFile(workspaceRoot / "repos" / (r.name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
      "[repo]\nname = \"" & r.name & "\"\npath = \"" & r.path & "\"\n" &
      "remote = \"o\"\nrevision = \"main\"\n")
  writeFile(workspaceRoot / "projects" / "p.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"p\"\ndefault_revision = \"main\"\n" &
    "trunk = \"main\"\n\n" &
    "[[remote]]\nname = \"o\"\nfetch = \"" & originUrl & "\"\n\n" &
    "includes = [\n" & includes & "]\n")

proc ensureOutcomes(reproBin, workspaceRoot: string):
    tuple[code: int; outcomes: seq[string]; diagnostic: string] =
  ## `hooks ensure --vcs --workspace-root=<root> --json`, reduced to the set of
  ## distinct per-hook outcomes.
  ##
  ## `--json` AND NOT `--write-report`, and the distinction is the whole reason
  ## (I) can be written at all: `--write-report` files its report under
  ## `<root>/.repro/build/reports/`, which CREATES the `.repro/` shell and so
  ## makes the root an initialized workspace as a side effect of the command
  ## under test. `t_workspace_hooks_ensure_is_idempotent_across_three_runs` was
  ## built that way and two of its cases measured the side effect rather than
  ## the installer. `--json` writes to stdout and touches nothing.
  let res = runShellSplit(shellCommand(@[
    reproBin, "hooks", "ensure", "--vcs",
    "--workspace-root=" & workspaceRoot, "--json"]))
  result.code = res.code
  result.diagnostic = res.stderr
  var seen: seq[string] = @[]
  try:
    let doc = parseJson(res.stdout)
    for entry in doc{"entries"}:
      let tag = entry{"outcome"}.getStr()
      if tag.len > 0 and tag notin seen:
        seen.add(tag)
  except CatchableError as e:
    result.diagnostic.add("\nJSON parse failed: " & e.msg &
      "\nstdout was: " & res.stdout)
  seen.sort()
  result.outcomes = seen

proc bakedRecordDir(repoPath, hookName: string): string =
  ## The destination an installed body advertises, read back out of the body
  ## the way `managedHookRefusalRecordDirAdvertised` does: a whole-line prefix
  ## match on the column-zero assignment, so the three indented places that
  ## merely READ the variable cannot be mistaken for it.
  const assign = "REPRO_REFUSAL_RECORD_DIR="
  let body = readFile(
    repoPath / ".git" / "hooks" / (hookName & ".repro-managed"))
  for line in body.splitLines():
    if line.startsWith(assign):
      let quoted = line[assign.len .. ^1]
      if quoted.len >= 2 and quoted[0] == '\'' and quoted[^1] == '\'':
        return quoted[1 .. ^2]
      return quoted
  ""

suite "a contract refusal is distinguishable from a successful dispatch":

  test "t_a_contract_refusal_is_distinguishable_from_a_successful_dispatch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — this case builds real repositories, fires " &
        "the real managed hooks against two different interpreters and " &
        "compares what each left on disk, none of which has a substitute " &
        "that would still prove the claim")
    else:
      let scratch = createTempDir("repro-refusal-record-", "")
      defer: removeDirEventually(scratch)
      let reproBin = reproBinary()

      # ---- upstream + seed commit for the participating repo ------------
      let origin = scratch / "origin.git"
      let seedPath = scratch / "seed"
      discard requireGit(q(gitBin) & " init --bare -b main " & q(origin))
      discard requireGit(q(gitBin) & " init -b main " & q(seedPath))
      configIdentity(gitBin, seedPath)
      writeFile(seedPath / "README.md", "refusal record fixture\n")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " add README.md")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " commit -m base")
      discard requireGit(q(gitBin) & " -C " & q(seedPath) &
        " remote add origin " & q(origin))
      discard requireGit(q(gitBin) & " -C " & q(seedPath) & " push origin main")
      let originUrl = fileUrl(origin)

      # ---- an INITIALIZED workspace, so there is somewhere to file ------
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")
      writeFile(workspaceRoot / "projects" / "lib-a.toml",
        "schema = \"reprobuild.workspace.project.v1\"\n\n" &
        "[project]\nname = \"lib-a\"\ndefault_revision = \"main\"\n" &
        "trunk = \"main\"\n\n" &
        "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" &
          originUrl & "\"\n\n" &
        "includes = [\n  \"repos/lib-a.toml\",\n]\n")
      writeFile(workspaceRoot / "repos" / "lib-a.toml",
        "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
        "[repo]\nname = \"lib-a\"\npath = \"lib-a\"\n" &
        "remote = \"lib-a-origin\"\nrevision = \"main\"\n")
      writeWorkspaceBranch(workspaceRoot, project = "lib-a", branch = "main")
      check fileExists(workspaceRoot / ".repro" / "workspace-state.toml")

      # A manifest-backed lock route must be DECLARED, not inferred, so the
      # manifest layer is a real git checkout of its own. Without it the
      # serviced dispatch in (A) has no route to write a lock record through
      # and the "trap" half of this case proves nothing.
      let lockStore = workspaceRoot / ".repro" / "manifests"
      createDir(lockStore)
      discard requireGit(q(gitBin) & " init -b main " & q(lockStore))
      configIdentity(gitBin, lockStore)
      writeFile(lockStore / ".gitkeep", "")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) & " add -A")
      discard requireGit(q(gitBin) & " -C " & q(lockStore) &
        " commit -m \"seed lock store\"")

      let repoPath = workspaceRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(repoPath))
      configIdentity(gitBin, repoPath)

      # Declare the TEAM route explicitly, so the locking layer does not emit
      # its one-time migration guidance into the durable state this case
      # snapshots.
      let adopted = runShell(shellCommand(@[
        reproBin, "locking", "adopt-manifest",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("locking adopt-manifest output: " & adopted.output)
      check adopted.code == 0

      let ensured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs",
        "--workspace-root=" & workspaceRoot]))
      checkpoint("hooks ensure output: " & ensured.output)
      check ensured.code == 0

      let managedPostCommit =
        repoPath / ".git" / "hooks" / "post-commit.repro-managed"
      check fileExists(managedPostCommit)
      let managedBody = readFile(managedPostCommit)
      # The token the INSTALLED body demands, read out of the body rather than
      # recomputed: (B) asserts the record reports this exact string, and a
      # recomputation would compare the build against itself.
      var installedContract = ""
      let flagAt = managedBody.find("--hook-contract=")
      if flagAt >= 0:
        let rest = managedBody[flagAt + "--hook-contract=".len .. ^1]
        installedContract = rest.split({' ', '\n', '\t', '"'})[0]
      checkpoint("installed post-commit contract: " & installedContract)
      check installedContract.len > 0

      let reportDir = workspaceRoot / ".repro" / "build" / "reports"
      let reportPath = reportDir / "post-commit-report.json"
      let refusalPath = reportDir / "post-commit-contract-refusal.json"

      # ---- (A) THE TRAP: a serviced dispatch, and its report ------------
      writeFile(repoPath / "first.txt", "serviced work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add first.txt")
      let servicedCommit = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "serviced fire"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("(A) serviced commit output: " & servicedCommit.output)
      check servicedCommit.code == 0
      check fileExists(reportPath)
      var servicedOutcome = ""
      if fileExists(reportPath):
        let report = parseFile(reportPath)
        servicedOutcome = report{"outcome"}.getStr()
        checkpoint("(A) serviced outcome: " & servicedOutcome)
        # Any dispatch tag will do; what matters is that it is NOT the refusal
        # tag, so the two vocabularies cannot be confused.
        check servicedOutcome.len > 0
        check servicedOutcome != "refused-contract-mismatch"
      let servicedReportBytes =
        if fileExists(reportPath): readFile(reportPath) else: ""
      let afterServiced = durableSnapshot(reportDir)
      checkpoint("(A) durable state after a serviced dispatch: " &
        afterServiced.join(", "))
      check afterServiced.len > 0
      # Nothing has refused yet, so no record may exist.
      check not fileExists(refusalPath)

      # ---- the refusing interpreter -------------------------------------
      let staleStub = scratch / "stale-repro"
      let staleMarker = scratch / "stale-dispatched.marker"
      writeStaleStub(staleStub, staleMarker)

      writeFile(repoPath / "second.txt", "refused work\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add second.txt")
      let refusedCommit = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "refused fire"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      checkpoint("(B) refused commit output: " & refusedCommit.output)
      # post-commit is non-blocking by design: the commit still succeeds.
      check refusedCommit.code == 0

      # ---- (B) the refusal's durable record -----------------------------
      check fileExists(refusalPath)
      if fileExists(refusalPath):
        let record = parseFile(refusalPath)
        checkpoint("(B) refusal record: " & pretty(record, indent = 2))
        check record{"schema"}.getStr() ==
          "reprobuild.managed-hook.contract-refusal.v1"
        # Its own tag. Falsifiable against the two cheap alternatives: an
        # overwrite of the report would have carried a dispatch tag, and a
        # delete would have left no document to read.
        check record{"outcome"}.getStr() == "refused-contract-mismatch"
        check record{"hook"}.getStr() == "post-commit"
        check record{"dispatched"}.getBool() == false
        # WHICH binary, and HOW it was resolved — never the version alone: on
        # the development host three builds all report `0.1.3` and disagree
        # about this very flag, so the version string partitions nothing.
        check record{"resolvedBinary"}.getStr() == staleStub
        check record{"resolvedFrom"}.getStr() == "REPROBUILD_REPRO"
        check record{"resolvedVersion"}.getStr().contains("0.1.3")
        # The contract the BODY demanded, byte-for-byte.
        check record{"hookContract"}.getStr() == installedContract
        check record{"repoRoot"}.getStr() == repoPath
        check record{"timestamp"}.getStr().endsWith("Z")
        check record{"probeExit"}.kind == JInt
        check record{"probeExit"}.getInt() != 0
        # (F) the probe's own words, kept rather than discarded, and escaped
        # correctly on the way in: the second line carries a quote and a
        # backslash.
        check record{"probeDiagnostic"}.getStr().contains(stubProbeLine1)
        check record{"probeDiagnostic"}.getStr().contains(stubProbeLine2)

      # READABLE BY SOMEBODY OTHER THAN THE WRITER, which is the only reason
      # the record exists at all. `mktemp` creates 0600 and the first live
      # record inherited it, landing 0600 beside nine 0644 siblings in the same
      # directory; a shared workspace is routinely touched by more than one
      # uid, so the mode is CHOSEN rather than taken from `mktemp` or from
      # whichever shell's umask fired the hook. POSIX only: on Windows the
      # permission bits Nim reports are not the access control.
      when not defined(windows):
        if fileExists(refusalPath):
          let recordPerms = getFilePermissions(refusalPath)
          checkpoint("(B) record permissions: " & $recordPerms)
          check fpGroupRead in recordPerms
          check fpOthersRead in recordPerms
          # Readable, not writable: it is a diagnostic, not a channel.
          check fpGroupWrite notin recordPerms
          check fpOthersWrite notin recordPerms

      # ---- (C) THE LAST-GOOD OUTCOME SURVIVED ---------------------------
      # The record-over-delete choice, asserted. Deleting the stale report
      # would also have ended the ambiguity; it would have taken the only
      # surviving description of the last working run with it.
      check fileExists(reportPath)
      if fileExists(reportPath):
        check readFile(reportPath) == servicedReportBytes

      # ---- (D) THE ARM THAT MUST FAIL BEFORE PG-15 ----------------------
      let afterRefused = durableSnapshot(reportDir)
      checkpoint("(D) durable state after a refusal: " &
        afterRefused.join(", "))
      check afterRefused != afterServiced

      # ---- (E) it was a refusal, not a failed dispatch ------------------
      check not fileExists(staleMarker)

      # ---- (F) and the same words reached the terminal ------------------
      check refusedCommit.output.contains(stubProbeLine1)
      check refusedCommit.output.contains(stubProbeLine2)
      # Attributed, so they cannot be read as ours.
      check refusedCommit.output.contains(staleStub)

      # ---- (G) the record does not outlive the state it describes -------
      writeFile(repoPath / "third.txt", "serviced again\n")
      discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add third.txt")
      let revivedCommit = runShell(shellCommand(@[
        gitBin, "-C", repoPath, "commit", "-m", "serviced again"],
        @[(name: "REPROBUILD_REPRO", value: reproBin)]))
      checkpoint("(G) serviced-again commit output: " & revivedCommit.output)
      check revivedCommit.code == 0
      check not fileExists(refusalPath)
      check fileExists(reportPath)
      let afterRevived = durableSnapshot(reportDir)
      checkpoint("(G) durable state after servicing again: " &
        afterRevived.join(", "))
      check afterRevived != afterRefused

      # ---- (H) the guard is REUSED, not bypassed ------------------------
      # Hooks installed into a plain git repository that is not an initialized
      # workspace must bake an EMPTY destination and manufacture nothing. A
      # mutation that derived `<repo>/.repro/build/reports` directly, or that
      # re-asked the question with a shell test, creates the directory here.
      let plainRepo = scratch / "plain"
      discard requireGit(q(gitBin) & " init -b main " & q(plainRepo))
      configIdentity(gitBin, plainRepo)
      writeFile(plainRepo / "a.txt", "no workspace here\n")
      discard requireGit(q(gitBin) & " -C " & q(plainRepo) & " add a.txt")
      discard requireGit(q(gitBin) & " -C " & q(plainRepo) & " commit -m seed")
      let plainEnsured = runShell(shellCommand(@[
        reproBin, "hooks", "ensure", "--vcs", plainRepo]))
      checkpoint("(H) plain-repo hooks ensure output: " & plainEnsured.output)
      check plainEnsured.code == 0
      let plainBody = readFile(
        plainRepo / ".git" / "hooks" / "post-commit.repro-managed")
      check "REPRO_REFUSAL_RECORD_DIR=''\n" in plainBody
      writeFile(plainRepo / "b.txt", "still no workspace\n")
      discard requireGit(q(gitBin) & " -C " & q(plainRepo) & " add b.txt")
      let plainRefused = runShell(shellCommand(@[
        gitBin, "-C", plainRepo, "commit", "-m", "refused outside a workspace"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      checkpoint("(H) plain-repo refused commit output: " & plainRefused.output)
      check plainRefused.code == 0
      # It says so, rather than failing silently or inventing a destination.
      check plainRefused.output.contains("NOT RECORDED")
      # And the forged workspace marker never appears.
      check not dirExists(plainRepo / ".repro")
      check not fileExists(plainRepo / "post-commit-contract-refusal.json")

      # ---- (I) the SELF-HEALING sweep, which is retained behaviour --------
      # Retained deliberately, so it is guarded deliberately. Three `ensure`
      # runs over a workspace whose `.repro/` shell appears between runs 1 and
      # 2 must go `installed` -> `refreshed-drifted` -> `already-up-to-date`:
      # one sweep that repairs the destination, then convergence. Both ends
      # matter. No re-anchor at all means a hook that records nowhere forever,
      # with nothing able to repair it; a re-anchor on every run means the
      # ambient `hooks ensure` rewrites every hook in the workspace on every
      # shell entry and the drift report stops meaning anything.
      let lateRoot = scratch / "late-workspace"
      createDir(lateRoot)
      writeFlatMembership(lateRoot, originUrl, [(name: "lib-a", path: "lib-a")])
      let lateRepo = lateRoot / "lib-a"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(lateRepo))
      configIdentity(gitBin, lateRepo)

      let lateFirst = ensureOutcomes(reproBin, lateRoot)
      checkpoint("(I) run 1 outcomes: " & lateFirst.outcomes.join(",") &
        " | " & lateFirst.diagnostic)
      check lateFirst.code == 0
      check lateFirst.outcomes == @["installed"]
      # Premise: the root resolved (hooks were installed) and is NOT yet an
      # initialized workspace, so the guard answered "nowhere" — and `--json`
      # did not manufacture the shell behind our back.
      check not dirExists(lateRoot / ".repro")
      check bakedRecordDir(lateRepo, "post-commit") == ""

      # The shell materializes. This is what `repro workspace init` writes, and
      # what any first `--write-report` into this root would have created.
      writeWorkspaceBranch(lateRoot, project = "p", branch = "main")
      check fileExists(lateRoot / ".repro" / "workspace-state.toml")

      let lateSecond = ensureOutcomes(reproBin, lateRoot)
      checkpoint("(I) run 2 outcomes: " & lateSecond.outcomes.join(",") &
        " | " & lateSecond.diagnostic)
      check lateSecond.code == 0
      # ONE repair sweep, reported as drift rather than silently.
      check lateSecond.outcomes == @["refreshed-drifted"]
      # DIRECTION, not merely difference: nowhere -> the report directory.
      check bakedRecordDir(lateRepo, "post-commit") ==
        lateRoot / ".repro" / "build" / "reports"

      let lateThird = ensureOutcomes(reproBin, lateRoot)
      checkpoint("(I) run 3 outcomes: " & lateThird.outcomes.join(",") &
        " | " & lateThird.diagnostic)
      check lateThird.code == 0
      # Converged. The sweep is one sweep.
      check lateThird.outcomes == @["already-up-to-date"]

      # And the healing is observable in behaviour, not only in the body: a
      # refusal now records where the same refusal could not before.
      writeFile(lateRepo / "healed.txt", "after the shell appeared\n")
      discard requireGit(q(gitBin) & " -C " & q(lateRepo) & " add healed.txt")
      let lateRefused = runShell(shellCommand(@[
        gitBin, "-C", lateRepo, "commit", "-m", "refused after healing"],
        @[(name: "REPROBUILD_REPRO", value: staleStub)]))
      checkpoint("(I) post-heal refused commit: " & lateRefused.output)
      check lateRefused.code == 0
      check fileExists(lateRoot / ".repro" / "build" / "reports" /
        "post-commit-contract-refusal.json")
      check "NOT RECORDED" notin lateRefused.output

      # ---- (J) the memo is keyed per REPO ROOT, not per guard -------------
      # One `ensure` sweep, one guard, two repos whose enclosing workspace
      # roots differ: `lib-a` at the root, and `lib-b` declared at a nested
      # path under a directory that is itself a workspace. Caching one answer
      # for the whole guard bakes the first repo's destination into the second,
      # which files one repository's refusals into another workspace's report
      # directory — and every other case in this file stays green while it
      # does.
      let twoRoot = scratch / "two-workspaces"
      createDir(twoRoot)
      writeFlatMembership(twoRoot, originUrl, [
        (name: "lib-a", path: "lib-a"),
        (name: "lib-b", path: "nested/lib-b")])
      writeWorkspaceBranch(twoRoot, project = "p", branch = "main")
      createDir(twoRoot / "nested")
      # The nested directory is a workspace in its own right. Not contrived:
      # this workspace carries fourteen such checkouts under `references/`,
      # which is the measured case the memo's doc comment cites.
      writeWorkspaceBranch(twoRoot / "nested", project = "p", branch = "main")
      let outerRepo = twoRoot / "lib-a"
      let innerRepo = twoRoot / "nested" / "lib-b"
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(outerRepo))
      discard requireGit(q(gitBin) & " clone --branch main " & q(originUrl) &
        " " & q(innerRepo))
      let twoEnsured = ensureOutcomes(reproBin, twoRoot)
      checkpoint("(J) outcomes: " & twoEnsured.outcomes.join(",") & " | " &
        twoEnsured.diagnostic)
      check twoEnsured.code == 0
      let outerBaked = bakedRecordDir(outerRepo, "post-commit")
      let innerBaked = bakedRecordDir(innerRepo, "post-commit")
      checkpoint("(J) outer baked: " & outerBaked)
      checkpoint("(J) inner baked: " & innerBaked)
      # Each names ITS OWN workspace. Asserted as equalities and not merely as
      # `outerBaked != innerBaked`: a guard-wide memo keyed on the wrong repo
      # would make them equal, but so would two unrelated bugs, and only the
      # equalities say which directory is right.
      check outerBaked == twoRoot / ".repro" / "build" / "reports"
      check innerBaked == twoRoot / "nested" / ".repro" / "build" / "reports"
