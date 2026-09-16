## ``repro workspace sync`` — a failed pre-classification fetch is REFUSED,
## never reported as "clean at locked revision".
##
## WHY THIS TEST EXISTS
##
## The sync path fetches every existing checkout before the planner
## classifies, precisely so ``origin/<branch>`` reflects the remote rather
## than whatever was last seen. When that fetch failed, the dispatcher wrote
## one line to stderr — "pre-classification fetch failed … non-fatal" — and
## let the planner classify the STALE refs anyway.
##
## Classifying unfetched data is not a degraded answer. It answers a
## different question ("where was the remote the last time anyone looked")
## in the voice of the one that was asked. A checkout whose stale
## ``origin/<branch>`` still equals its HEAD is byte-for-byte
## indistinguishable from a current one, so the planner reported the
## reassuring one of two indistinguishable states as fact.
##
## Measured at ca49246a, on a checkout rebuilt from a real pre-force-push
## mirror — 175 commits of history the remote no longer had, an EMPTY
## merge-base with the new history:
##
##   syncCase = clean_at_locked_revision, action = none,
##   executionStatus = noop, summary.noop = 1, exitCode = 0
##
## A 175-commit-dead checkout declared current, with exit 0.
##
## The fixture here makes the fetch fail the way the field does — the remote
## is not reachable — and asserts the repo is REFUSED with a ``fetch_failed``
## verdict and a non-zero exit.
##
## THE NEGATIVE CONTROL IS LOAD-BEARING. A build that refused every repo
## would satisfy the first half of this test and be a different, equally bad
## defect. So the workspace carries a second repo whose remote is perfectly
## reachable, and that repo must still come back ``clean_at_locked_revision``
## in the same run. The counts are asserted, not just the presence of a tag.
##
## Skip rule: ``git`` missing on PATH (the convention this suite follows).

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
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc seedOrigin(gitBin, originPath, workPath: string): string =
  discard requireGit(q(gitBin) & " init --bare -b main " & q(originPath))
  discard requireGit(q(gitBin) & " init -b main " & q(workPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.email tester@example.invalid")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " config user.name \"Fetch Tester\"")
  writeFile(workPath / "README.md", "fetch fixture\n")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " add README.md")
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " commit -m fixture")
  discard requireGit(q(gitBin) & " -C " & q(workPath) &
    " remote add origin " & q(originPath))
  discard requireGit(q(gitBin) & " -C " & q(workPath) & " push origin main")
  requireGit(q(gitBin) & " -C " & q(workPath) & " rev-parse HEAD").strip()

proc repoFragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v1\"\n\n" &
  "[repo]\n" &
  "name = \"" & name & "\"\n" &
  "path = \"" & name & "\"\n" &
  "remote = \"" & name & "\"\n" &
  "revision = \"main\"\n"

proc projectToml(remotes: seq[(string, string)]): string =
  result =
    "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\n" &
    "name = \"fetchproject\"\n" &
    "default_revision = \"main\"\n" &
    "trunk = \"main\"\n\n"
  for (name, url) in remotes:
    result.add("[[remote]]\nname = \"" & name & "\"\nfetch = \"" & url &
      "\"\n\n")
  result.add("includes = [\n")
  for (name, _) in remotes:
    result.add("  \"repos/" & name & ".toml\",\n")
  result.add("]\n")

proc entryFor(doc: JsonNode; name: string): JsonNode =
  for entry in doc["repos"]:
    if entry["name"].getStr() == name:
      return entry
  nil

suite "repro workspace sync — a failed fetch is refused, not called clean":

  test "t_workspace_sync_refuses_to_classify_on_a_failed_fetch":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip()
    else:
      let scratch = createTempDir("repro-sync-fetchfail-", "")
      defer: removeDir(scratch)
      let reproBin = reproBinary()
      let workspaceRoot = scratch / "workspace"
      createDir(workspaceRoot / "projects")
      createDir(workspaceRoot / "repos")

      # ``reachable`` keeps its origin. ``unreachable`` will lose it.
      var remotes: seq[(string, string)]
      var heads: seq[(string, string)]
      for name in ["reachable", "unreachable"]:
        let origin = scratch / ("origin-" & name & ".git")
        let head = seedOrigin(gitBin, origin, scratch / ("seed-" & name))
        discard requireGit(q(gitBin) & " clone " & q(fileUrl(origin)) & " " &
          q(workspaceRoot / name))
        writeFile(workspaceRoot / "repos" / (name & ".toml"),
          repoFragmentToml(name))
        remotes.add((name, fileUrl(origin)))
        heads.add((name, head))
      writeFile(workspaceRoot / "projects" / "fetchproject.toml",
        projectToml(remotes))

      # Make the fetch for ONE repo fail, the way it fails in the field: the
      # remote the manifest names is not there any more. The checkout and
      # every one of its remote-tracking refs stay exactly as they were —
      # which is the whole point. Locally, this repo is indistinguishable
      # from a healthy one; only the fetch can tell them apart, and the
      # fetch is what failed.
      moveDir(scratch / "origin-unreachable.git",
        scratch / "origin-unreachable.git.moved-away")

      # ``--write-report`` rather than ``--json``: the failing fetch writes
      # progress and diagnostics to stderr, which ``runShell`` folds into
      # the same stream as stdout. The persisted report is the same document
      # and is not interleaved with anything.
      let res = runShell(shellCommand(@[
        reproBin, "workspace", "sync", "fetchproject", "--write-report",
        "--workspace-root=" & workspaceRoot,
      ]))
      let reportPath = workspaceRoot / ".repro" / "build" / "reports" /
        "sync-report.json"
      if not fileExists(reportPath):
        checkpoint("no sync report written; exit=" & $res.code & "; " &
          res.output)
      check fileExists(reportPath)
      let doc = parseFile(reportPath)

      let bad = entryFor(doc, "unreachable")
      check not bad.isNil
      if not bad.isNil:
        # THE assertion. Anything in the "nothing to do" family here is the
        # defect: the planner would be stating, as fact, a conclusion it
        # drew from refs the fetch never refreshed.
        check bad["syncCase"].getStr() == "fetch_failed"
        check bad["syncCase"].getStr() != "clean_at_locked_revision"
        check bad["executionStatus"].getStr() == "refused"
        check bad["executionStatus"].getStr() != "noop"
        # Principle 2: the refusal names the repo AND what to do about it.
        let reason = bad["refusalReason"].getStr()
        check reason.len > 0
        check "unreachable" in reason
        check "fetch" in reason

      # NEGATIVE CONTROL: the healthy repo in the SAME run is still
      # classified normally. Without this, "refuse everything" passes.
      let good = entryFor(doc, "reachable")
      check not good.isNil
      if not good.isNil:
        check good["syncCase"].getStr() == "clean_at_locked_revision"
        check good["executionStatus"].getStr() == "noop"

      # COUNTS, not just tags: exactly one refusal and exactly one noop.
      let summary = doc["summary"]
      check summary["total"].getInt() == 2
      check summary["refused"].getInt() == 1
      check summary["noop"].getInt() == 1

      # A refuse-and-report run exits 2 — the documented "the operator has
      # manual work to do" code, distinct from 1 ("sync blew up"). Under the
      # unfixed executor this run exited 0.
      check doc["exitCode"].getInt() == 2
      check res.code == 2

      # And nothing moved: a refusal does not touch the working tree.
      for (name, head) in heads:
        let now = requireGit(q(gitBin) & " -C " & q(workspaceRoot / name) &
          " rev-parse HEAD").strip()
        check now == head
