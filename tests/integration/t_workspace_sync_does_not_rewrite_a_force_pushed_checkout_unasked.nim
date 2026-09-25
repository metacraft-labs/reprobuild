## ``repro sync`` does not rewrite a force-pushed checkout unasked — and,
## when it is asked to, it previews first, counts what it did, and never
## drops the operator's commits on the floor.
##
## WHY THIS TEST EXISTS
##
## ``parseWorkspaceSyncArgs`` defaulted ``rebaseOnForcePush`` to TRUE, and
## ``classifyRepoState``'s signature defaulted it to TRUE as well. So a bare
## ``repro sync`` — no ``--force-sync``, no ``--rebase-on-force-push`` —
## classified every checkout with a RECORDED force-push as
## ``saForcePushRebase``, and ``executeForcePushRebase``'s step "reset
## --hard <remote>/<branch>" ran with no RA-9 preview and no confirmation.
##
## Measured on a real workspace at reprobuild 2231901e: twelve recorder
## repos, each divergent from a rewritten remote, were reset to
## ``origin/dev`` by one plain ``repro sync``; the superseded tip of each was
## left reachable from no ref at all. The run's own digest read
##
##   updated 61, cloned 19, up-to-date 90, force-reset 0, skipped 0, refused 2, failed 0
##
## — ``force-reset 0, skipped 0`` while twelve checkouts were being reset,
## because ``summarize`` only tested ``action == "force_reset"`` and the
## rebase's action tag is ``force_push_rebase``, so all twelve were counted
## as ordinary updates.
##
## ``vm-harness``, divergent in exactly the same way, WAS refused in that
## same run. The discriminator was ``.repro/workspace/force-pushes.json``:
## the twelve recorders had a recorded superseded SHA (so
## ``forcePushedBaseSha`` was non-empty and ``canAutoRebase`` held), and
## ``vm-harness`` did not. A safety property that depends on whether the
## tool happened to be watching when the remote moved is not a safety
## property, so the gate is now the FLAG.
##
## WHAT EACH CASE PINS
##
## 1. ``refuses to rewrite a force-pushed checkout without the flag`` — the
##    headline defect. Bare sync must leave HEAD exactly where it found it,
##    report the repo, and count it.
## 2. ``previews and refuses an unconfirmed rewrite in a non-TTY`` — RA-9
##    applied to the rebase: the per-repo preview precedes any mutation, and
##    a non-interactive run without ``--yes`` declines cleanly.
## 3. ``a confirmed rewrite is performed, counted, and reversible`` — the
##    accounting fix (``rebased``, not ``succeeded``) plus the preservation
##    guarantee and the backup ref.
## 4. ``a conflicting replay leaves the checkout untouched`` — the data-loss
##    path: the reset precedes the replay, so a cherry-pick that conflicts
##    used to leave the branch on the remote tip with the operator's commits
##    gone.
## 5. ``--force-sync overwrites a force-pushed checkout`` — the planner's
##    own refusal text ends "or discard it with 'repro sync --force-sync'",
##    and that case was filtered out of the force-sync target set, so the
##    named remedy did nothing.
##
## Skip rule: ``git`` missing on PATH (the convention this suite follows).

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_test_support

proc q(value: string): string = quoteShell(value)

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

type
  RewriteFixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    libPath: string       ## the workspace checkout under test
    seedPath: string      ## the publisher that performs the rewrite
    originPath: string
    baseSha: string       ## the commit the rewrite re-roots onto
    localTip: string      ## the checkout's HEAD before any sync
    newRemoteTip: string  ## the remote tip after the force-push

proc configureIdentity(gitBin, repoPath: string) =
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(repoPath) &
    " config user.name \"Rewrite Tester\"")

proc commitFile(gitBin, repoPath, name, content, message: string): string =
  writeFile(repoPath / name, content)
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " add " & q(name))
  discard requireGit(q(gitBin) & " -C " & q(repoPath) & " commit -m " &
    q(message))
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc setupRewriteFixture(gitBin, slug: string;
                         localFile, localContent: string;
                         rewriteFile, rewriteContent: string;
                         secondLocalFile = ""): RewriteFixture =
  ## Build a workspace whose ONE repo is a checkout carrying genuine local
  ## commits over a remote that is then force-pushed onto a disjoint base.
  ##
  ## ``localFile``/``rewriteFile`` are parameters rather than constants so
  ## the same fixture produces both the clean-replay shape (different files,
  ## cherry-pick succeeds) and the conflicting shape (SAME file, different
  ## content, cherry-pick fails). The two cases differ only in that choice,
  ## which is what makes case 4 a statement about conflict handling and not
  ## about some other difference in setup.
  result.scratch = createTempDir("repro-rewrite-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.originPath = result.scratch / "origin-lib.git"
  result.seedPath = result.scratch / "seed-lib"
  result.workspaceRoot = result.scratch / "workspace"
  result.libPath = result.workspaceRoot / "lib"

  discard requireGit(q(gitBin) & " init --bare -b main " & q(result.originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(result.seedPath))
  configureIdentity(gitBin, result.seedPath)
  result.baseSha = commitFile(gitBin, result.seedPath, "README.md",
    "initial\n", "initial")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " remote add origin " & q(result.originPath))
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " push origin main")
  discard commitFile(gitBin, result.seedPath, "p0.txt", "p0\n", "P0")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " push origin main")

  createDir(result.workspaceRoot / "projects")
  createDir(result.workspaceRoot / "repos")
  writeFile(result.workspaceRoot / "repos" / "lib.toml",
    "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
    "[repo]\nname = \"lib\"\npath = \"lib\"\nremote = \"lib-origin\"\n" &
    "revision = \"main\"\n")
  writeFile(result.workspaceRoot / "projects" / "myproject.toml",
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"myproject\"\n" &
    "default_revision = \"main\"\ntrunk = \"main\"\n\n" &
    "[[remote]]\nname = \"lib-origin\"\nfetch = \"" &
    fileUrl(result.originPath) & "\"\n\nincludes = [\n  \"repos/lib.toml\",\n]\n")

  discard requireGit(q(gitBin) & " clone " & q(fileUrl(result.originPath)) &
    " " & q(result.libPath))
  configureIdentity(gitBin, result.libPath)
  result.localTip = commitFile(gitBin, result.libPath, localFile,
    localContent, "local C1")
  if secondLocalFile.len > 0:
    result.localTip = commitFile(gitBin, result.libPath, secondLocalFile,
      "c2\n", "local C2")

  # The rewrite: re-root onto ``baseSha`` (dropping P0), land a different
  # commit, force-push. HEAD's history is now disjoint from the remote's
  # below ``baseSha``'s child.
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " reset --hard " & q(result.baseSha))
  result.newRemoteTip = commitFile(gitBin, result.seedPath, rewriteFile,
    rewriteContent, "F1 rewritten")
  discard requireGit(q(gitBin) & " -C " & q(result.seedPath) &
    " push --force origin main")

proc getClingoEnv(): seq[tuple[name, value: string]] =
  var clingoLib = getEnv("CLINGO_LIB")
  var zstdLib = getEnv("ZSTD_LIB")
  if (clingoLib.len == 0 or zstdLib.len == 0) and dirExists("/nix/store"):
    for kind, path in walkDir("/nix/store", relative = false):
      if kind == pcDir:
        let name = path.lastPathPart
        if name.contains("clingo-5."):
          clingoLib = path / "lib"
        elif name.contains("zstd-1."):
          zstdLib = path / "lib"
  if clingoLib.len > 0 and zstdLib.len > 0:
    let dyld = clingoLib & ":" & zstdLib
    result.add(("DYLD_LIBRARY_PATH", dyld))
    result.add(("DYLD_FALLBACK_LIBRARY_PATH", dyld))
    result.add(("LD_LIBRARY_PATH", dyld))

proc invokeSync(fx: RewriteFixture;
                extraArgs: openArray[string] = []): CmdResult =
  ## Always run through ``runShell``, i.e. with stdin NOT a TTY. That is the
  ## context every CI job and every agent runs sync in, and it is the context
  ## in which the RA-9 gate must refuse rather than prompt.
  var cmdArgs = @[
    fx.reproBin, "workspace", "sync", "--write-report", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]
  for arg in extraArgs:
    cmdArgs.add(arg)
  runShell(shellCommand(cmdArgs, env = getClingoEnv()))

proc readReport(fx: RewriteFixture): JsonNode =
  let reportPath = fx.workspaceRoot / ".repro" / "build" / "reports" /
    "sync-report.json"
  check fileExists(reportPath)
  parseFile(reportPath)

proc onlyEntry(report: JsonNode): JsonNode =
  check report["repos"].len == 1
  report["repos"][0]

proc headOf(gitBin, repoPath: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " rev-parse HEAD").strip()

proc subjects(gitBin, repoPath: string): seq[string] =
  for line in requireGit(q(gitBin) & " -C " & q(repoPath) &
      " log --format=%s").strip().splitLines():
    result.add(line.strip())

proc backupRefs(gitBin, repoPath: string): seq[string] =
  # ``--format=%(refname)`` MUST be quoted: the parentheses are shell syntax
  # and an unquoted one is a parse error, not a git error, so the failure
  # would be attributed to the wrong layer entirely.
  for line in requireGit(q(gitBin) & " -C " & q(repoPath) &
      " for-each-ref " & q("--format=%(refname)") &
      " refs/repro/pre-rewrite/").strip().splitLines():
    if line.strip().len > 0:
      result.add(line.strip())

suite "repro workspace sync — a force-pushed checkout is not rewritten unasked":

  test "refuses to rewrite a force-pushed checkout without the flag":
    ## THE defect. No ``--force-sync``, no ``--rebase-on-force-push``: the
    ## checkout must come out of the sync byte-for-byte as it went in.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every case here drives real repositories")
    else:
      let fx = setupRewriteFixture(gitBin, "unasked",
        localFile = "c1.txt", localContent = "c1\n",
        rewriteFile = "f1.txt", rewriteContent = "f1\n",
        secondLocalFile = "c2.txt")
      defer: removeDir(fx.scratch)

      let res = invokeSync(fx)
      checkpoint("sync output: " & res.output)

      # (1) NOTHING MOVED. Asserted first and on the repository itself,
      # because every other assertion here is about how the run DESCRIBED
      # itself and a report can be right about a mutation that happened.
      check headOf(gitBin, fx.libPath) == fx.localTip
      check headOf(gitBin, fx.libPath) != fx.newRemoteTip

      # (2) The premise, asserted rather than assumed: the tool really did
      # detect the rewrite. Without this the case would also pass against a
      # build that simply failed to notice the force-push, which is a
      # different bug wearing this one's result.
      let entry = onlyEntry(readReport(fx))
      check entry["syncCase"].getStr() == "force_push_rebase"
      check entry["action"].getStr() == "none"
      check entry["executionStatus"].getStr() == "refused"
      check entry["refusalReason"].getStr().len > 0

      # (3) And it is COUNTED. A run that skips a repo and reports zero
      # skipped and zero refused is the defect class this closes.
      let summary = readReport(fx)["summary"]
      check summary["total"].getInt() == 1
      check summary["refused"].getInt() == 1
      check summary["rebased"].getInt() == 0
      check summary["succeeded"].getInt() == 0
      check summary["forceReset"].getInt() == 0
      check readReport(fx)["exitCode"].getInt() == 2

      # (4) The digest LINE, not just the JSON. That line is what a human
      # scans, and the measured failure was a digest that denied its own
      # work; a JSON-only assertion would not have caught it.
      check res.output.contains("refused 1")
      check res.output.contains("rebased 0")

  test "previews and refuses an unconfirmed rewrite in a non-TTY":
    ## RA-9, applied to the rebase: the per-repo preview is printed BEFORE
    ## any mutation, and a non-interactive run without ``--yes`` declines
    ## cleanly rather than prompting into a stdin nobody can answer.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every case here drives real repositories")
    else:
      let fx = setupRewriteFixture(gitBin, "unconfirmed",
        localFile = "c1.txt", localContent = "c1\n",
        rewriteFile = "f1.txt", rewriteContent = "f1\n")
      defer: removeDir(fx.scratch)

      let res = invokeSync(fx, ["--rebase-on-force-push"])
      checkpoint("sync output: " & res.output)

      check headOf(gitBin, fx.libPath) == fx.localTip

      # The PREVIEW happened, and it names this repo and both endpoints, so
      # an operator reading it knows what would move and to where.
      check res.output.contains("will RESET")
      check res.output.contains(fx.localTip)
      check res.output.contains(fx.newRemoteTip)
      # ... and the refusal names the flag that would proceed.
      check res.output.contains("--yes")

      let entry = onlyEntry(readReport(fx))
      check entry["action"].getStr() == "none"
      check entry["executionStatus"].getStr() == "refused"
      # The refusal must say WHY this one was refused — "not confirmed" is a
      # different remedy from "cannot be rebased", and conflating them sends
      # the operator to the wrong fix.
      check "not confirmed" in entry["refusalReason"].getStr().toLowerAscii()
      check readReport(fx)["summary"]["refused"].getInt() == 1
      check readReport(fx)["summary"]["rebased"].getInt() == 0

  test "a confirmed rewrite is performed, counted, and reversible":
    ## The opt-in path. It must actually rebase (that capability is not
    ## being removed), count itself as a rewrite rather than as an ordinary
    ## update, keep every local commit, and leave the superseded history
    ## reachable from a ref.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every case here drives real repositories")
    else:
      let fx = setupRewriteFixture(gitBin, "confirmed",
        localFile = "c1.txt", localContent = "c1\n",
        rewriteFile = "f1.txt", rewriteContent = "f1\n",
        secondLocalFile = "c2.txt")
      defer: removeDir(fx.scratch)

      let res = invokeSync(fx, ["--rebase-on-force-push", "--yes"])
      checkpoint("sync output: " & res.output)
      check res.code == 0

      # The preview still precedes the act when ``--yes`` is given: the flag
      # opts out of the PROMPT, not out of being told what happened.
      check res.output.contains("will RESET")

      # THE PRESERVATION GUARANTEE — and it is asserted as REPLAYED, never
      # as "still somewhere in the object database".
      #
      # This distinction is the whole point of the case. After the reset in
      # ``executeForcePushRebase`` the operator's commits are reachable from
      # the reflog whether or not the replay ran, so any assertion that a
      # ``git cat-file`` or ``git log --reflog`` can satisfy proves nothing:
      # an object reachable from no ref is a `gc`/expiry candidate, not
      # preserved work. Every check below is therefore made against refs and
      # the working tree only:
      #
      #   * ``git log`` with no ``--reflog`` walks from HEAD, so a subject
      #     appearing here is on the BRANCH.
      #   * ``rev-list <newRemoteTip>..HEAD`` counts what sits ON TOP of the
      #     rewritten upstream — reflog entries cannot contribute to it.
      #   * the files themselves are read off the checkout.
      check headOf(gitBin, fx.libPath) != fx.localTip
      check requireGit(q(gitBin) & " -C " & q(fx.libPath) &
        " rev-parse HEAD~2").strip() == fx.newRemoteTip
      # Exactly two commits sit on the new upstream — the two the operator
      # owned — so nothing was dropped and nothing was duplicated.
      check requireGit(q(gitBin) & " -C " & q(fx.libPath) &
        " rev-list --count " & q(fx.newRemoteTip & "..HEAD")).strip() == "2"
      let subj = subjects(gitBin, fx.libPath)
      check subj.count("local C1") == 1
      check subj.count("local C2") == 1
      check subj[0] == "local C2"
      check subj[1] == "local C1"
      # The WORK, not just the commit metadata: both files the local commits
      # introduced are present in the rebased checkout, alongside the file
      # the rewritten upstream brought. A replay that produced empty commits
      # would satisfy every subject assertion above and fail these.
      check readFile(fx.libPath / "c1.txt") == "c1\n"
      check readFile(fx.libPath / "c2.txt") == "c2\n"
      check readFile(fx.libPath / "f1.txt") == "f1\n"
      # NON-VACUITY of the "reachable from a ref" framing: the ORIGINAL local
      # tip is no longer on the branch (it was rewritten), so the two commits
      # above are genuinely replayed copies rather than the old history
      # having quietly survived in place.
      check runCmd(q(gitBin) & " -C " & q(fx.libPath) &
        " merge-base --is-ancestor " & q(fx.localTip) & " HEAD").code != 0

      # THE ACCOUNTING. ``rebased``, not ``succeeded``: a run that moves a
      # branch onto a history it did not have must not report that as an
      # ordinary update. Asserted on both sides so a double-count cannot
      # pass.
      let summary = readReport(fx)["summary"]
      check summary["total"].getInt() == 1
      check summary["rebased"].getInt() == 1
      check summary["succeeded"].getInt() == 0
      check summary["forceReset"].getInt() == 0
      check summary["refused"].getInt() == 0
      check summary["failed"].getInt() == 0
      check res.output.contains("rebased 1")

      # REVERSIBLE. The pre-rewrite tip is reachable from a ref, not merely
      # from the reflog (a 90-day expiry candidate). Twelve real checkouts
      # were left in exactly that unreferenced state by the run this test
      # was written from.
      let refs = backupRefs(gitBin, fx.libPath)
      check refs.len == 1
      check refs[0].endsWith(fx.localTip)
      check requireGit(q(gitBin) & " -C " & q(fx.libPath) &
        " rev-parse " & q(refs[0])).strip() == fx.localTip

      let entry = onlyEntry(readReport(fx))
      check entry["action"].getStr() == "force_push_rebase"
      check entry["executionStatus"].getStr() == "succeeded"
      # The row an operator reads names the recovery, so the reversibility
      # is discoverable without knowing the ref-naming scheme.
      check refs[0] in entry["executionDiagnostic"].getStr()

  test "a conflicting replay leaves the checkout untouched":
    ## ``executeForcePushRebase`` resets BEFORE it replays. A cherry-pick
    ## that conflicts therefore used to leave the branch sitting on the
    ## remote tip with the operator's commits dropped — a FAILED action that
    ## had nonetheless performed its destructive half. The work must survive
    ## a failure, in the working tree, not only in the reflog.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every case here drives real repositories")
    else:
      # Same file, different content, on both sides: the replay must conflict.
      let fx = setupRewriteFixture(gitBin, "conflict",
        localFile = "shared.txt", localContent = "mine\n",
        rewriteFile = "shared.txt", rewriteContent = "theirs\n")
      defer: removeDir(fx.scratch)

      let res = invokeSync(fx, ["--rebase-on-force-push", "--yes"])
      checkpoint("sync output: " & res.output)

      # THE PREMISE: the replay was attempted and it failed. Without this
      # the assertions below would also hold for a build that never tried.
      let entry = onlyEntry(readReport(fx))
      check entry["action"].getStr() == "force_push_rebase"
      check entry["executionStatus"].getStr() == "failed"
      check "cherry-pick" in entry["executionDiagnostic"].getStr()

      # THE GUARANTEE: the checkout is where it was, with the operator's
      # content, and no cherry-pick is left half-applied.
      check headOf(gitBin, fx.libPath) == fx.localTip
      check readFile(fx.libPath / "shared.txt") == "mine\n"
      check subjects(gitBin, fx.libPath).count("local C1") == 1
      check not fileExists(fx.libPath / ".git" / "CHERRY_PICK_HEAD")

      # A failure is a failure, and it is counted as one — not as a rebase.
      let summary = readReport(fx)["summary"]
      check summary["failed"].getInt() == 1
      check summary["rebased"].getInt() == 0
      check summary["succeeded"].getInt() == 0
      check readReport(fx)["exitCode"].getInt() == 1

  test "--force-sync overwrites a force-pushed checkout":
    ## The planner's refusal for a rewritten remote ends "or discard it with
    ## 'repro sync --force-sync'". ``scForcePushRebase`` was not in the
    ## force-sync target set, so that named remedy did nothing at all and
    ## the repo stayed refused however many times the operator ran it.
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH; every case here drives real repositories")
    else:
      let fx = setupRewriteFixture(gitBin, "forcesync",
        localFile = "c1.txt", localContent = "c1\n",
        rewriteFile = "f1.txt", rewriteContent = "f1\n")
      defer: removeDir(fx.scratch)

      let res = invokeSync(fx, ["--force-sync", "--yes"])
      checkpoint("sync output: " & res.output)
      check res.code == 0

      check res.output.contains("will OVERWRITE")
      check headOf(gitBin, fx.libPath) == fx.newRemoteTip

      let entry = onlyEntry(readReport(fx))
      check entry["action"].getStr() == "force_reset"
      check entry["executionStatus"].getStr() == "succeeded"
      let summary = readReport(fx)["summary"]
      check summary["forceReset"].getInt() == 1
      check summary["rebased"].getInt() == 0
      check summary["succeeded"].getInt() == 0
      check summary["refused"].getInt() == 0
