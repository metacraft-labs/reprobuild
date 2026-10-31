## ``repro health``'s ``lock-writer`` row reports the OUTCOME of the managed
## ``post-commit`` lock writer, and goes ``fail`` when the writer has refused
## on two or more consecutive runs.
##
## Spec: reprobuild-pm ``spec/CLI/health.md``, the **Lock writer**
## (``lock-writer``) bullet. Issue: reprobuild-pm
## ``issues/2026-10-02-nothing-checks-the-post-commit-lock-writers-outcome.md``.
##
## THE DEFECT. The post-commit writer never fails a commit; it appends one
## ``<timestamp> <outcome> <diagnostic>`` line per run to
## ``<workspace>/.repro/build/reports/post-commit-lock.log`` and says so in one
## stderr line. In one workspace it refused on every commit for eighteen days
## (``no-lock-dirty-siblings``, with a second refusal hidden behind the first)
## while ``repro health`` stayed green, because the only rows that look at the
## hook — ``vcs-hooks`` and ``hook-interpreter`` — ask whether it is
## INSTALLED, never what it DID. Against the unfixed build every case below
## that looks for a ``lock-writer`` row fails on its absence.
##
## WHAT THIS SUITE GUARDS:
##
##   (A) The headline: a refusal trace PRODUCED BY THE REAL WRITER — two
##       commits over a dirty sibling, then a third whose only obstacle is a
##       lock store the writer cannot write — makes the row ``fail`` with a
##       run of three, and names BOTH distinct refusal reasons, newest first.
##       Listing every reason is the masking guard: the newest line alone
##       (``no-lock-failed``) would hide the dirty-sibling refusal that
##       accounts for most of the run.
##   (B) A run of ONE refusal is ``warn``, not ``fail``.
##   (C) A written record after refusals ends the run: ``ok``.
##   (D) No trace at all is ``ok`` (whether the hook is installed is the
##       ``vcs-hooks`` row's question, not this one's).
##   (E) ``skipped-membership-repo`` lines neither START nor END a run, and
##       non-outcome lines (``evidence``, malformed) are ignored.
##   (F) A PUBLIC-ONLY workspace (no manifest lock route declared) stays
##       ``ok``: the real writer logs ``no-manifest-record`` on each commit,
##       which is the designed steady state there, not a refusal. The first
##       draft of the spec classed it as a refusal; this case, measured end to
##       end, is what showed every such workspace going ``fail`` after its
##       second commit.
##   (G) A trace that EXISTS but cannot be read (mode 000) is ``warn`` naming
##       the path and the OS error — never ``ok``, which would say "nothing
##       ran" about a file that plainly records runs.
##
## WHY (E) SEEDS THE TRACE INSTEAD OF PRODUCING IT. Every other case drives
## the real ``repro hooks dispatch post-commit`` and lets the real writer append
## the lines. (E) needs a ``skipped-membership-repo`` line, which only a commit
## in a workspace whose root is itself the membership git checkout produces —
## a second, unrelated fixture shape — plus an ``evidence`` line and a
## malformed line, which the writer produces only for an evidence-only repo
## and never on purpose, respectively. The row's contract for those lines is
## purely about how a READER classifies text, so the trace for (E) is written
## in the exact format ``appendPostCommitLog`` emits. The health command that
## reads it is the real binary.
##
## Hermetic: one ``createTempDir`` per case, local bare origins only, no
## network. Skip rule: ``git`` missing on PATH; (A) and (G) also skip as root
## (root bypasses POSIX permission bits, so the chmod fault injection cannot
## fire) and on Windows, where ``setFilePermissions`` does not remove read or
## directory-write access (see the M19 suite's identical rule in
## ``t_workspace_post_commit_lock_refresh_is_best_effort``).

import std/[json, os, osproc, sequtils, strutils, tempfiles, unittest]

when defined(posix):
  import std/posix

import repro_test_support
import repro_test_support/reasoned_skip
import repro_workspace_manifests

const
  NoGitReason = "git not on PATH; every case drives a real git workspace"
  ChmodReason = "git not on PATH, or running as root or on Windows, where " &
    "removing permission bits does not make the path unreadable or " &
    "unwritable, so the fault cannot be injected"

# ---- helpers --------------------------------------------------------------

proc q(value: string): string = quoteShell(value)

proc requireGit(command: string; cwd = ""): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    # stderr, not ``checkpoint``: ``quit`` ends the process before any check
    # fails, so a checkpoint would never be printed.
    stderr.writeLine("command failed: " & command & "\nexit=" &
      $res.exitCode & "\n" & res.output)
    quit 1
  res.output

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedGitOrigin(gitBin, originPath, workPath: string) =
  ## One bare origin plus a seed checkout pushed into it. The README carries
  ## the repo's own name so the seeds are distinct trees (and distinct SHAs)
  ## even when created inside the same clock second.
  let tag = workPath.lastPathPart
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Lock Writer Tester\"")
  writeFile(workPath / "README.md", "lock-writer fixture: " & tag & "\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " commit -m " & q("seed " & tag))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")

proc projectToml(libAUrl, libBUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"lib-a\"\n" &
    "\n" &
    "[[remote]]\nname = \"lib-a-origin\"\nfetch = \"" & libAUrl & "\"\n\n" &
    "[[remote]]\nname = \"lib-b-origin\"\nfetch = \"" & libBUrl & "\"\n\n" &
    "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"" & name &
    "-origin\"\nmainline = \"main\"\n"

type
  Fixture = object
    scratch: string
    reproBin: string
    gitBin: string
    workspaceRoot: string

proc setupFixture(gitBin, slug: string; declareLockStore = true): Fixture =
  ## A two-repo initialized workspace whose lock store
  ## (``.repro/manifests``) is a real git checkout, so the post-commit writer
  ## has a DECLARED manifest route and a clean commit really writes a record
  ## (Unified-Locking-And-Hooks.md §10, "No implicit team route").
  ##
  ## ``declareLockStore = false`` leaves that route undeclared: the
  ## workspace is then PUBLIC-ONLY (its in-repo ``repro.lock`` is the
  ## record), and the writer logs ``no-manifest-record`` on every commit.
  result.scratch = createTempDir("repro-lock-writer-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.gitBin = gitBin
  for name in ["lib-a", "lib-b"]:
    seedGitOrigin(gitBin, result.scratch / ("origin-" & name & ".git"),
      result.scratch / ("seed-" & name))
  let ws = result.scratch / "workspace"
  result.workspaceRoot = ws
  createDir(ws / "projects")
  createDir(ws / "repos")
  writeFile(ws / "projects" / "lib-a.toml", projectToml(
    fileUrl(result.scratch / "origin-lib-a.git"),
    fileUrl(result.scratch / "origin-lib-b.git")))
  for name in ["lib-a", "lib-b"]:
    writeFile(ws / "repos" / (name & ".toml"), fragmentToml(name))
  if declareLockStore:
    let store = ws / ".repro" / "manifests"
    createDir(store)
    discard requireGit(q(gitBin) & " init -b main " & q(store))
    discard requireGit(q(gitBin) & " -C " & q(store) &
      " config user.email tester@example.invalid")
    discard requireGit(q(gitBin) & " -C " & q(store) &
      " config user.name \"Lock Store Tester\"")
    writeFile(store / ".gitkeep", "")
    discard requireGit(q(gitBin) & " -C " & q(store) & " add -A")
    discard requireGit(q(gitBin) & " -C " & q(store) &
      " commit -m \"seed lock store\"")
  for name in ["lib-a", "lib-b"]:
    let target = ws / name
    discard requireGit(q(gitBin) & " clone " &
      q(fileUrl(result.scratch / ("origin-" & name & ".git"))) & " " &
      q(target))
    discard requireGit(q(gitBin) & " -C " & q(target) &
      " config user.email tester@example.invalid")
    discard requireGit(q(gitBin) & " -C " & q(target) &
      " config user.name \"Lock Writer Tester\"")
  writeWorkspaceBranch(ws, project = "lib-a", branch = "main")

proc tracePath(fx: Fixture): string =
  fx.workspaceRoot / ".repro" / "build" / "reports" / "post-commit-lock.log"

proc commitInLibA(fx: Fixture; fileName: string) =
  ## A real commit in lib-a, made with hooks pointed at an empty directory so
  ## the commit itself does not fire whichever ``repro`` is first on the
  ## developer's PATH: every post-commit run in this suite is the explicit
  ## dispatch below, by the binary this checkout built, so the trace holds
  ## exactly the lines the case means it to.
  let repo = fx.workspaceRoot / "lib-a"
  writeFile(repo / fileName, fileName & "\n")
  discard requireGit(q(fx.gitBin) & " -C " & q(repo) & " add " & q(fileName))
  let noHooks = fx.scratch / "no-hooks"
  createDir(noHooks)
  discard requireGit(q(fx.gitBin) & " -C " & q(repo) & " -c core.hooksPath=" &
    q(noHooks) & " commit -m " & q("commit " & fileName))

proc dispatchPostCommit(fx: Fixture) =
  ## The exact argv the managed hook dispatcher uses. Best-effort by
  ## contract, so exit 0 whatever the writer decided.
  let res = runShell(shellCommand(@[fx.reproBin, "hooks", "dispatch",
    "post-commit", "--repo-root", fx.workspaceRoot / "lib-a", "--"]))
  checkpoint("post-commit dispatch: " & res.output)
  check res.code == 0

proc commitAndDispatch(fx: Fixture; fileName: string) =
  commitInLibA(fx, fileName)
  dispatchPostCommit(fx)

proc lockWriterRow(fx: Fixture): JsonNode =
  ## Run the real ``repro health --json`` and return its ``lock-writer`` row,
  ## or nil when there is none — the unfixed build's answer. ``REPROBUILD_REPRO``
  ## is pinned to the real binary so the neighbouring ``hook-interpreter`` row
  ## is not what the suite happens to measure.
  let res = runShell(shellCommand(
    @[fx.reproBin, "health", "lib-a", "--json",
      "--workspace-root=" & fx.workspaceRoot],
    @[(name: "REPROBUILD_REPRO", value: fx.reproBin)]))
  checkpoint("health --json output:\n" & res.output)
  let start = res.output.find("{\n")
  doAssert start >= 0, "health --json printed no JSON object"
  let report = parseJson(res.output[start .. ^1])
  for entry in report["checks"]:
    if entry["name"].getStr() == "lock-writer":
      return entry
  nil

proc showTrace(fx: Fixture) =
  if fileExists(fx.tracePath):
    checkpoint("post-commit-lock.log:\n" & readFile(fx.tracePath))
  else:
    checkpoint("post-commit-lock.log: absent")

# ---- the suite -------------------------------------------------------------

suite "lock-writer — health reports the post-commit writer's outcome":

  test "t_health_fails_when_the_post_commit_lock_writer_keeps_refusing":
    let gitBin = findExe("git")
    let isRoot =
      when defined(posix): geteuid() == 0
      else: false
    if gitBin.len == 0 or isRoot or defined(windows):
      skip(ChmodReason)
    else:
      let fx = setupFixture(gitBin, "refusing")
      defer: removeDir(fx.scratch)

      # Two commits over a dirty sibling: the eighteen-day state.
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt", "uncommitted\n")
      commitAndDispatch(fx, "one.txt")
      commitAndDispatch(fx, "two.txt")

      # The operator cleans lib-b, and the NEXT refusal surfaces: a lock store
      # the writer cannot write into. The newest line now names a different
      # reason, which is exactly how the first one used to disappear from view.
      removeFile(fx.workspaceRoot / "lib-b" / "scratch.txt")
      let store = fx.workspaceRoot / ".repro" / "manifests"
      var perms = getFilePermissions(store)
      perms.excl({fpUserWrite, fpGroupWrite, fpOthersWrite})
      setFilePermissions(store, perms)
      try:
        commitAndDispatch(fx, "three.txt")
      finally:
        var restored = getFilePermissions(store)
        restored.incl(fpUserWrite)
        setFilePermissions(store, restored)
      showTrace(fx)

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "fail"
        check not row["fixable"].getBool()
        let detail = row["detail"].getStr()
        check "3" in detail
        check "no-lock-dirty-siblings" in detail
        check "no-lock-failed" in detail
        # Newest reason first: the store refusal is the latest line.
        check detail.find("no-lock-failed") <
          detail.find("no-lock-dirty-siblings")
        check "no lock record ever written" in detail
        let remedy = row["remedy"].getStr()
        # Health spells `repro` in remedies as the running binary's own path
        # (copy-pasteable without PATH), so match the verb, not the prefix.
        check " workspace lock`" in remedy
        check fx.tracePath in remedy
        check "no-lock-failed" in remedy

        let data = row["data"]
        check data["runLength"].getInt() == 3
        check data["runStartedAt"].getStr().len > 0
        check data["runNewestAt"].getStr().len > 0
        check data["newestWrittenAt"].kind == JNull
        let reasons = data["reasons"]
        check reasons.len == 2
        if reasons.len == 2:
          check reasons[0]["outcome"].getStr() == "no-lock-failed"
          check reasons[0]["count"].getInt() == 1
          check reasons[1]["outcome"].getStr() == "no-lock-dirty-siblings"
          check reasons[1]["count"].getInt() == 2
          check "lib-b" in reasons[1]["diagnostic"].getStr()
          # Timestamps are stripped from the reason: it is the diagnostic as
          # the writer wrote it, not a log line.
          check not reasons[1]["diagnostic"].getStr().startsWith("20")

  test "t_health_warns_on_a_single_post_commit_lock_refusal":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip(NoGitReason)
    else:
      let fx = setupFixture(gitBin, "single")
      defer: removeDir(fx.scratch)
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt", "uncommitted\n")
      commitAndDispatch(fx, "one.txt")
      showTrace(fx)

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "warn"
        check row["data"]["runLength"].getInt() == 1
        check "no-lock-dirty-siblings" in row["detail"].getStr()
        check " workspace lock`" in row["remedy"].getStr()

  test "t_health_is_ok_once_the_post_commit_lock_writer_writes_again":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip(NoGitReason)
    else:
      let fx = setupFixture(gitBin, "recovered")
      defer: removeDir(fx.scratch)
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt", "uncommitted\n")
      commitAndDispatch(fx, "one.txt")
      commitAndDispatch(fx, "two.txt")
      removeFile(fx.workspaceRoot / "lib-b" / "scratch.txt")
      commitAndDispatch(fx, "three.txt")
      showTrace(fx)
      # Control: the trace really does hold the refusals AND a later write,
      # so an ``ok`` below is the run ending, not an empty trace.
      let trace = readFile(fx.tracePath)
      check "no-lock-dirty-siblings" in trace
      check " written-" in trace

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "ok"
        check row["data"]["runLength"].getInt() == 0
        check row["data"]["newestWrittenAt"].kind == JString
        check "written-" in row["detail"].getStr()

  test "t_health_is_ok_when_no_post_commit_run_is_recorded":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip(NoGitReason)
    else:
      let fx = setupFixture(gitBin, "no-trace")
      defer: removeDir(fx.scratch)
      check not fileExists(fx.tracePath)
      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "ok"
        check "no post-commit run recorded" in row["detail"].getStr()

  test "t_health_lock_writer_ignores_membership_skips_and_non_outcome_lines":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip(NoGitReason)
    else:
      let fx = setupFixture(gitBin, "membership")
      defer: removeDir(fx.scratch)
      createDir(fx.tracePath.parentDir)
      # A written record, then a membership skip (must not START a run), then
      # a refusal, a membership skip (must not END the run), an evidence line
      # and a malformed line (both ignored), and a second, DIFFERENT refusal.
      writeFile(fx.tracePath,
        "2026-10-01T10:00:00Z written-local-only wrote /x.toml\n" &
        "2026-10-01T10:05:00Z skipped-membership-repo membership commit\n" &
        "2026-10-02T09:00:00Z no-lock-dirty-siblings NO lock written: " &
          "dirty sibling(s): lib-b\n" &
        "2026-10-02T09:30:00Z skipped-membership-repo membership commit\n" &
        "2026-10-02T09:31:00Z evidence refreshed lib-a\n" &
        "not a trace line at all\n" &
        "2026-10-03T08:00:00Z no-lock-failed NO lock written: store " &
          "unwritable\n")

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "fail"
        let data = row["data"]
        check data["runLength"].getInt() == 2
        check data["runStartedAt"].getStr() == "2026-10-02T09:00:00Z"
        check data["runNewestAt"].getStr() == "2026-10-03T08:00:00Z"
        check data["newestWrittenAt"].getStr() == "2026-10-01T10:00:00Z"
        check data["reasons"].len == 2
        if data["reasons"].len == 2:
          check data["reasons"][0]["outcome"].getStr() == "no-lock-failed"
          check data["reasons"][1]["outcome"].getStr() ==
            "no-lock-dirty-siblings"
        let detail = row["detail"].getStr()
        check "skipped-membership-repo" notin detail
        check "evidence" notin detail

  test "t_health_is_ok_for_a_public_only_workspace_logging_no_manifest_record":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip(NoGitReason)
    else:
      let fx = setupFixture(gitBin, "public-only", declareLockStore = false)
      defer: removeDir(fx.scratch)
      commitAndDispatch(fx, "one.txt")
      commitAndDispatch(fx, "two.txt")
      showTrace(fx)
      # Control: the REAL writer produced exactly the lines this case is
      # about. Without it an ``ok`` below could be an empty trace.
      let outcomes = readFile(fx.tracePath).splitLines().filterIt(
        it.split(' ').len > 1).mapIt(it.split(' ')[1])
      check outcomes == @["no-manifest-record", "no-manifest-record"]

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "ok"
        check row["data"]["runLength"].getInt() == 0
        check row["data"]["outcomeLines"].getInt() == 2
        check "no-manifest-record" in row["detail"].getStr()

  test "t_health_warns_when_the_post_commit_trace_cannot_be_read":
    let gitBin = findExe("git")
    let isRoot =
      when defined(posix): geteuid() == 0
      else: false
    if gitBin.len == 0 or isRoot or defined(windows):
      # As root the mode-000 file stays readable, so the state cannot be
      # produced; see the header's skip rule.
      skip(ChmodReason)
    else:
      let fx = setupFixture(gitBin, "unreadable")
      defer: removeDir(fx.scratch)
      # A real trace from the real writer, then made unreadable.
      writeFile(fx.workspaceRoot / "lib-b" / "scratch.txt", "uncommitted\n")
      commitAndDispatch(fx, "one.txt")
      commitAndDispatch(fx, "two.txt")
      check fileExists(fx.tracePath)
      setFilePermissions(fx.tracePath, {})
      defer: setFilePermissions(fx.tracePath, {fpUserRead, fpUserWrite})

      let row = lockWriterRow(fx)
      check not row.isNil
      if not row.isNil:
        check row["status"].getStr() == "warn"
        let detail = row["detail"].getStr()
        check fx.tracePath in detail
        check "cannot be read" in detail
        check "Permission denied" in detail
        check row["data"]["readError"].getStr().len > 0
        check fx.tracePath in row["remedy"].getStr()
        check not row["fixable"].getBool()
