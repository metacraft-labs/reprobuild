## Lock coherence is a DIFF, and it never blocks.
##
## Spec: CLI/README.md §"Lock Coherence" (the shared advisory), surfaced from
## CLI/sync.md, CLI/workspace.md §`status` and CLI/check.md.
##
## A workspace can hold several locks that each claim a revision for the same
## node: every participating repo may carry a committed ``repro.lock``, and the
## manifests DB carries the private pins. Nothing forces those claims to agree
## with each other or with what is checked out. Finding a set of revisions that
## satisfies every constraint is the SOLVER's job; this check only reports where
## the claims and reality differ, which is why it is cheap enough to run on every
## ``sync`` / ``status`` / ``check`` and why it is advisory rather than a gate.
##
## Sub-cases:
##
##   1. ``coherent_workspace_is_silent`` — every lock claims the checked-out
##      revision. The advisory prints NOTHING. The common case must cost the
##      operator no attention.
##   2. ``lagging_lock_is_informational`` — one repo's lock claims an ANCESTOR
##      of its checkout (the normal state of a repo under active development).
##      Reported as ``ancestor``, classified informational, remedy "re-pin".
##   3. ``divergent_claim_is_interrupting`` — a lock claims a revision on a
##      divergent history. Reported ``unreachable``, classified as needing
##      attention, and the remedies are offered cheapest-first with the extra
##      sibling + ``develop --into`` override LAST.
##   4. ``two_locks_disagreeing_about_one_node`` — two sibling repos' locks
##      claim DIFFERENT revisions for the same node. Both claims are listed and
##      the output says plainly that the locks contradict EACH OTHER, because no
##      single re-pin satisfies both.
##   5. ``advisory_never_blocks`` — in every case above ``sync`` and
##      ``status`` keep their own exit codes, and the output states which
##      revision the build will actually use (the checkout, in develop mode).
##   6. ``surfaced_from_three_commands`` — the same finding appears from
##      ``sync``, from ``status``, and from ``check --mode=pre-push`` (on the
##      ``notices`` channel, which is documented never to touch the exit code).
##
## Assertions: as enumerated above — the relation tags, the interrupting vs
## informational classification, the remedy ordering, the explicit
## "the build uses the CHECKOUT" statement, unchanged exit codes, and the
## presence of the finding on all three surfaces.
##
## Falsifiability:
##   - If the check involved the solver it could not report case 4 at all: two
##     contradictory constraints have no solution, so a solver-based
##     implementation would fail rather than describe the difference.
##   - If it classified by equality instead of reachability, case 2 would be
##     reported as needing attention — the lagging lock of a repo under
##     development would interrupt on every sync, which is precisely the
##     behaviour that makes such a check get switched off.
##   - If it blocked, case 5 fails: the exit codes would change.
##   - If it were silent on agreement, case 1 catches a regression to noisy
##     output; if it were silent on disagreement, cases 2-4 catch it.
##
## Skip rule: ``git`` missing on PATH.

import std/[json, os, osproc, strutils, tempfiles, unittest]

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
  result = currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc git(gitBin, repoPath, argv: string): string =
  requireGit(q(gitBin) & " -C " & q(repoPath) & " " & argv)

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b dev " & q(originPath))
  discard requireGit(q(gitBin) & " init -b dev " & q(workPath))
  discard git(gitBin, workPath, "config user.email tester@example.invalid")
  discard git(gitBin, workPath, "config user.name \"Coherence Tester\"")
  writeFile(workPath / "README.md", "coherence fixture\n")
  discard git(gitBin, workPath, "add README.md")
  discard git(gitBin, workPath, "commit -m base")
  discard git(gitBin, workPath, "remote add origin " & q(originPath))
  discard git(gitBin, workPath, "push origin dev")
  git(gitBin, workPath, "rev-parse HEAD").strip()

proc cloneInto(gitBin, originPath, targetPath: string) =
  discard requireGit(q(gitBin) & " clone " & q(fileUrl(originPath)) & " " &
    q(targetPath))
  discard git(gitBin, targetPath, "config user.email tester@example.invalid")
  discard git(gitBin, targetPath, "config user.name \"Coherence Tester\"")

proc commitInto(gitBin, repoPath, file, content: string): string =
  writeFile(repoPath / file, content)
  discard git(gitBin, repoPath, "add " & file)
  discard git(gitBin, repoPath, "commit -m \"" & file & "\"")
  git(gitBin, repoPath, "rev-parse HEAD").strip()

proc headSha(gitBin, repoPath: string): string =
  git(gitBin, repoPath, "rev-parse HEAD").strip()

# ---- manifest + lock fixtures ---------------------------------------------

proc projectToml(aUrl, bUrl: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\n" &
  "[project]\n" &
  "name = \"myproject\"\n" &
  "default_revision = \"dev\"\n" &
  "trunk = \"dev\"\n\n" &
  "[[remote]]\nname = \"a-origin\"\nfetch = \"" & aUrl & "\"\n\n" &
  "[[remote]]\nname = \"b-origin\"\nfetch = \"" & bUrl & "\"\n\n" &
  "includes = [\n  \"repos/lib-a.toml\",\n  \"repos/lib-b.toml\",\n]\n"

proc repoToml(name, remote: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & remote & "\"\n" &
  "revision = \"dev\"\n"

proc depInline(name, path, revision: string): string =
  "{ name = \"" & name & "\", path = \"" & path & "\", coord_kind = \"vcs\"" &
  ", url = \"\", ref = \"dev\", revision = \"" & revision & "\"" &
  ", integrity = \"\", version = \"\", visibility = \"public\"" &
  ", participation = \"\", depends = \"\", groups = \"\" }"

proc committedLock(deps: openArray[string]): string =
  ## A minimal ``reprobuild.solved-graph-lock.v2`` body carrying only the
  ## ``deps`` claims the coherence diff reads.
  var body = "schema = \"reprobuild.solved-graph-lock.v2\"\n\n" &
    "[lock]\n" &
    "platform = \"\"\n" &
    "optimal = true\n" &
    "inputs_digest = \"\"\n" &
    "variants = []\n" &
    "packages = []\n" &
    "deps = ["
  for i, dep in deps:
    if i > 0: body.add(", ")
    body.add(dep)
  body.add("]\n")
  body

type
  Fixture = object
    scratch: string
    reproBin: string
    workspaceRoot: string
    originA, originB: string
    libA, libB: string

proc setupFixture(gitBin, slug: string): Fixture =
  result.scratch = createTempDir("repro-coherence-" & slug & "-", "")
  result.reproBin = reproBinary()
  result.originA = result.scratch / "origin-lib-a.git"
  result.originB = result.scratch / "origin-lib-b.git"
  discard seedOrigin(gitBin, result.originA, result.scratch / "seed-lib-a")
  discard seedOrigin(gitBin, result.originB, result.scratch / "seed-lib-b")

  let workspaceRoot = result.scratch / "workspace"
  createDir(workspaceRoot)
  createDir(workspaceRoot / "projects")
  createDir(workspaceRoot / "repos")
  writeFile(workspaceRoot / "projects" / "myproject.toml",
    projectToml(fileUrl(result.originA), fileUrl(result.originB)))
  writeFile(workspaceRoot / "repos" / "lib-a.toml",
    repoToml("lib-a", "a-origin"))
  writeFile(workspaceRoot / "repos" / "lib-b.toml",
    repoToml("lib-b", "b-origin"))
  # ``check`` needs either a project positional (it has none) or the workspace
  # metadata marker; the marker also gives sync/status a recorded branch.
  createDir(workspaceRoot / ".repro")
  writeFile(workspaceRoot / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n" &
    "[workspace]\n" &
    "project = \"myproject\"\n" &
    "branch = \"dev\"\n")
  result.workspaceRoot = workspaceRoot
  result.libA = workspaceRoot / "lib-a"
  result.libB = workspaceRoot / "lib-b"
  cloneInto(gitBin, result.originA, result.libA)
  cloneInto(gitBin, result.originB, result.libB)

proc invokeSync(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "sync", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeStatus(fx: Fixture): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "workspace", "status", "myproject",
    "--workspace-root=" & fx.workspaceRoot,
  ]))

proc invokeCheck(fx: Fixture; currentRepo, refsFile: string): CmdResult =
  runShell(shellCommand(@[
    fx.reproBin, "check", "--mode=pre-push", "--json",
    "--workspace-root=" & fx.workspaceRoot,
    "--current-repo=" & currentRepo,
    "--pushed-refs=" & refsFile,
  ]))

suite "lock coherence reports a difference and never blocks":

  test "t_lock_coherence_reports_the_diff_advisory_only":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let fx = setupFixture(gitBin, "main")
      defer: removeDir(fx.scratch)

      let headA = headSha(gitBin, fx.libA)
      let headB = headSha(gitBin, fx.libB)

      # ---- (1) every claim matches: the advisory is SILENT. --------------
      writeFile(fx.libA / "repro.lock",
        committedLock([depInline("lib-a", ".", headA)]))
      var syncOut = invokeSync(fx)
      check "lock coherence" notin syncOut.output
      var statusOut = invokeStatus(fx)
      check "lock coherence" notin statusOut.output
      let coherentSyncCode = syncOut.code
      let coherentStatusCode = statusOut.code

      # ---- (2) the lock lags behind the checkout: INFORMATIONAL. ---------
      # A repo under active development is in this state constantly, so it
      # must not interrupt.
      let advancedA = commitInto(gitBin, fx.libA, "work.txt", "local work\n")
      check advancedA != headA
      writeFile(fx.libA / "repro.lock",
        committedLock([depInline("lib-a", ".", headA)]))
      syncOut = invokeSync(fx)
      check "lock coherence" in syncOut.output
      check "(ancestor)" in syncOut.output
      check "0 needing attention, 1 informational" in syncOut.output
      check "remedy: `repro workspace lock`" in syncOut.output
      # Says plainly what the build will use, rather than leaving it inferred.
      check "the build uses the CHECKOUT" in syncOut.output
      check "ADVISORY" in syncOut.output
      # (5) advisory: the host command's exit code is untouched.
      check syncOut.code == coherentSyncCode

      # ---- (3) a claim on a divergent history: INTERRUPTING. -------------
      # Build a commit that is genuinely unreachable from the checkout by
      # committing on a side branch and then returning.
      discard git(gitBin, fx.libA, "checkout -b sidetrack " & headA)
      let divergent = commitInto(gitBin, fx.libA, "other.txt", "other\n")
      discard git(gitBin, fx.libA, "checkout dev")
      check headSha(gitBin, fx.libA) == advancedA
      writeFile(fx.libA / "repro.lock",
        committedLock([depInline("lib-a", ".", divergent)]))
      syncOut = invokeSync(fx)
      check "(unreachable)" in syncOut.output
      check "1 needing attention" in syncOut.output
      # Remedies cheapest-first: re-pin, then move the checkout, then the
      # extra-sibling override LAST.
      let repin = syncOut.output.find("re-pin the lagging lock")
      let point = syncOut.output.find("point the")
      let sibling = syncOut.output.find("develop --into")
      check repin >= 0
      check point > repin
      check sibling > point
      check syncOut.code == coherentSyncCode

      # ---- (4) two locks claiming DIFFERENT revisions for one node. ------
      # lib-b's lock claims lib-a at the base commit; lib-a's own lock claims
      # the divergent one. No single re-pin satisfies both.
      writeFile(fx.libB / "repro.lock",
        committedLock([depInline("lib-a", "../lib-a", headA),
                       depInline("lib-b", ".", headB)]))
      syncOut = invokeSync(fx)
      check "contradict EACH OTHER" in syncOut.output
      check "lib-a/repro.lock claims " & divergent in syncOut.output
      check "lib-b/repro.lock claims " & headA in syncOut.output
      check syncOut.code == coherentSyncCode

      # ---- (6) the same finding from status and from check. --------------
      statusOut = invokeStatus(fx)
      check "contradict EACH OTHER" in statusOut.output
      check statusOut.code == coherentStatusCode

      let refsFile = fx.scratch / "pushed-refs.txt"
      writeFile(refsFile, "refs/heads/dev " & advancedA &
        " refs/heads/dev 0000000000000000000000000000000000000000\n")
      let checkOut = invokeCheck(fx, fx.libA, refsFile)
      # ``check`` carries it on the advisory ``notices`` channel, which is
      # documented never to touch the exit code.
      # ``check`` may prefix its JSON with human-facing diagnostic lines, so
      # take the document from the first brace.
      var parsed: JsonNode
      let braceIdx = checkOut.output.find('{')
      if braceIdx < 0:
        checkpoint("check emitted no JSON document: " & checkOut.output)
        fail()
      try:
        parsed = parseJson(checkOut.output[braceIdx .. ^1])
      except JsonParsingError:
        checkpoint("check did not emit JSON: " & checkOut.output)
        fail()
      var noticeText = ""
      for notice in parsed["notices"]:
        noticeText.add(notice.getStr() & "\n")
      check "lock coherence" in noticeText
      check "contradict EACH OTHER" in noticeText
