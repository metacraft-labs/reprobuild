## `repro health` says which row and which checkout it is in while it runs, and
## a large reference tree in the workspace does not hold it up.
##
## The defect (observed 2026-11-22 on a 154-repository workspace):
## `timeout 420 repro health > log 2>&1` left a log of ZERO lines. The
## command was blocked in one git call in one checkout — the publication probe on the llvm-project
## reference tree — and nothing it had done so far was visible, so the
## operator had to attach to the process to learn even which row it was in.
##
## Three cases against the production binary and real repositories:
##
##   1. **A stuck probe is named.** A workspace holds a small repo and a
##      synthetic large reference tree. The publication probe in the large
##      tree is made to block, and while it is blocked the test reads what
##      the command has written to stderr: the last line must name the row
##      (`unpublished-heads`) and the checkout (`refs-tree`). Before the fix
##      nothing had been written at that moment — the issue, reproduced.
##   2. **Off a terminal, every row and checkout gets a line; `--json` stays
##      clean.** Text mode writes a `repro health: ` line per row and per
##      checkout to stderr and none to stdout; `--json` off a terminal writes
##      no progress at all, so a consumer that merges the streams still
##      parses one document.
##   3. **The report is right on the large tree.** The tree's HEAD is a
##      commit on no remote branch whose parent is near the root, with 4,000
##      remote-tracking branches and no commit-graph — the shape that made the
##      per-ref probe unbounded. The `unpublished-heads` row must name it, and
##      the published small repo must not be named.
##
## One stand-in, justified: in case 1 a `git` wrapper first on `PATH` blocks
## the ONE call that is the publication probe in the large tree (`rev-list …
## --glob=refs/remotes/…`, and `branch -r --contains` for a build that still
## asks that way) and passes every other call to the real git. The hang it
## models is real and is measured in
## ``t_publication_probe_is_one_walk_on_a_large_reference_tree.nim``; what
## this case needs is a probe that is still running at a moment the test
## chooses, which no real repository provides deterministically. Cases 2 and 3
## use the real git with no wrapper.

import std/[json, os, osproc, strtabs, strutils, tempfiles, times, unittest]

import repro_core/process_env
import repro_test_support
import repro_test_support/large_reference_tree
import repro_test_support/reasoned_skip

proc run(args: string; cwd = ""): string =
  let r = execCmdEx(args, workingDir = cwd)
  doAssert r.exitCode == 0, args & "\n" & r.output
  r.output.strip()

type Fixture = object
  root, ws, bin, gitBin: string

const largeTree = LargeReferenceTree(commits: 100_000, branches: 4_000,
  mainRef: "refs/heads/main", branchPrefix: "refs/heads/")

proc setup(): Fixture =
  result.root = createTempDir("health-progress-", "")
  result.ws = result.root / "workspace"
  result.gitBin = findExe("git")
  result.bin = requireBinary(getEnv("REPRO_HEALTH_TEST_BINARY",
    currentSourcePath().parentDir.parentDir.parentDir / "build/bin/repro"),
    "reprobuild.apps.repro")
  let (root, ws) = (result.root, result.ws)
  createDir(ws / "projects")
  createDir(ws / "repos")
  createDir(ws / ".repro")
  # lib-a: small, published.
  discard run("git init -q --bare -b main " & quoteShell(root / "lib-a.git"))
  discard run("git clone -q " & quoteShell(root / "lib-a.git") & " " &
    quoteShell(ws / "lib-a"))
  discard run("git config user.email tester@example.invalid", ws / "lib-a")
  discard run("git config user.name Tester", ws / "lib-a")
  writeFile(ws / "lib-a" / "file", "a")
  discard run("git add file", ws / "lib-a")
  discard run("git commit -q -m a", ws / "lib-a")
  discard run("git push -q -u origin main", ws / "lib-a")
  # refs-tree: the large reference tree, cloned so its 4,000 branches are
  # remote-tracking refs, then parked on a commit on no remote branch.
  discard run("git init -q --bare -b main " & quoteShell(root / "refs-tree.git"))
  buildLargeReferenceTree(result.gitBin, root / "refs-tree.git", largeTree)
  discard run("git clone -q " & quoteShell(root / "refs-tree.git") & " " &
    quoteShell(ws / "refs-tree"))
  discard run("git config core.commitGraph false", ws / "refs-tree")
  discard commitOffOldBase(result.gitBin, ws / "refs-tree", largeTree,
    "refs/heads/pinned", 100)
  discard run("git checkout -q pinned", ws / "refs-tree")
  writeFile(ws / "projects/lib-a.toml", """schema = "reprobuild.workspace.project.v1"
[project]
name = "lib-a"
[[remote]]
name = "lib-a-origin"
fetch = "LIBA"
[[remote]]
name = "refs-tree-origin"
fetch = "REFS"
includes = ["repos/lib-a.toml", "repos/refs-tree.toml"]
""".replace("LIBA", root / "lib-a.git").replace("REFS", root / "refs-tree.git"))
  for (name, remote) in [("lib-a", "lib-a-origin"),
                         ("refs-tree", "refs-tree-origin")]:
    writeFile(ws / "repos" / (name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v2\"\n[repo]\nmainline = \"main\"\n" &
      "name = \"" & name & "\"\npath = \"" & name & "\"\nremote = \"" &
      remote & "\"\nrevision = \"main\"\n")

proc isolatedEnv(fx: Fixture; pathPrefix = ""): StringTableRef =
  result = inheritedEnvTable()
  for (key, value) in [("HOME", fx.root / "home"),
      ("XDG_DATA_HOME", fx.root / "data"),
      ("XDG_CONFIG_HOME", fx.root / "config"),
      ("XDG_CACHE_HOME", fx.root / "cache"),
      ("XDG_STATE_HOME", fx.root / "state"),
      ("REPRO_DAEMON_ENDPOINT", fx.root / "absent.sock"),
      ("REPRO_DAEMON_STATE_DIR", fx.root / "daemon"),
      ("REPRO_WORKSPACE_CLONES", fx.root / "clones"),
      ("REPROBUILD_REPRO", fx.bin)]:
    result[key] = value
  if pathPrefix.len > 0:
    result["PATH"] = pathPrefix & $PathSep & getEnv("PATH")

proc startHealth(fx: Fixture; extra: seq[string]; stdoutPath,
                 stderrPath: string; env: StringTableRef): Process =
  ## The production command with stdout and stderr each sent to a FILE —
  ## neither is a terminal, as in the issue's `> log 2>&1` — read back
  ## while it is still running.
  startProcess("/bin/sh", args = @["-c",
    "exec \"$0\" \"$@\" >" & quoteShell(stdoutPath) & " 2>" &
    quoteShell(stderrPath), fx.bin, "health", "lib-a",
    "--workspace-root=" & fx.ws] & extra, env = env)

proc nonEmptyLines(text: string): seq[string] =
  for line in text.splitLines:
    if line.strip().len > 0:
      result.add(line)

suite "repro health progress":

  test "a run stuck in one checkout's probe has already named the row and the checkout":
    if findExe("git").len == 0:
      skip("git is not on PATH; the fixture is git repositories")
    else:
      var fx = setup()
      defer: removeDir(fx.root)
      let tools = fx.root / "tools"
      createDir(tools)
      let marker = fx.root / "probe-blocked.pid"
      writeFile(tools / "git", """#!/bin/sh
# Blocks the publication probe in the large tree; every other call is git's.
case "$*" in
  *refs-tree*)
    case "$*" in
      *" rev-list "*"--glob=refs/remotes/"*|*" branch -r --contains "*)
        echo $$ > "$HANG_MARKER"
        exec sleep 600 ;;
    esac ;;
esac
exec "$REAL_GIT" "$@"
""")
      setFilePermissions(tools / "git", {fpUserRead, fpUserWrite, fpUserExec})
      let env = isolatedEnv(fx, tools)
      env["REAL_GIT"] = fx.gitBin
      env["HANG_MARKER"] = marker
      let (outPath, errPath) = (fx.root / "out.txt", fx.root / "err.txt")
      let health = startHealth(fx, @[], outPath, errPath, env)
      defer: health.close()
      let deadline = epochTime() + 600.0
      while not fileExists(marker) and health.running and
          epochTime() < deadline:
        sleep(100)
      require fileExists(marker)
      # Give the marker's writer a moment to have written the pid.
      sleep(200)
      let written = readFile(errPath)
      let blockedPid = readFile(marker).strip()
      if blockedPid.len > 0:
        discard execCmdEx("kill " & blockedPid)
      health.terminate()
      discard health.waitForExit()
      checkpoint("stderr while the probe was blocked:\n" & written)
      let lines = nonEmptyLines(written)
      # The issue: nothing at all had been written at this moment.
      check lines.len > 0
      check "repro health: checking unpublished-heads" in lines
      check lines.len > 0 and
        lines[^1] == "repro health: unpublished-heads: refs-tree (2/2)"

  test "off a terminal every row and checkout is a stderr line; --json writes none":
    if findExe("git").len == 0:
      skip("git is not on PATH; the fixture is git repositories")
    else:
      var fx = setup()
      defer: removeDir(fx.root)
      let env = isolatedEnv(fx)
      for (mode, extra) in [("text", newSeq[string]()), ("json", @["--json"])]:
        let outPath = fx.root / (mode & "-out.txt")
        let errPath = fx.root / (mode & "-err.txt")
        let health = startHealth(fx, extra, outPath, errPath, env)
        let code = health.waitForExit()
        health.close()
        check code in [0, 1]
        let (stdoutText, stderrText) = (readFile(outPath), readFile(errPath))
        checkpoint(mode & " stderr:\n" & stderrText)
        let progress = block:
          var found: seq[string]
          for line in nonEmptyLines(stderrText):
            if line.startsWith("repro health: "):
              found.add(line)
          found
        # Progress never reaches stdout.
        for line in nonEmptyLines(stdoutText):
          check not line.startsWith("repro health: checking ")
        if mode == "text":
          for row in ["manifest", "siblings", "vcs-hooks",
                      "unpublished-heads", "disjoint-local-branches",
                      "shared-clone-leaves"]:
            check ("repro health: checking " & row) in progress
          for item in ["repro health: unpublished-heads: lib-a (1/2)",
                       "repro health: unpublished-heads: refs-tree (2/2)",
                       "repro health: unpublished-heads: refs-tree " &
                         "(fetching to confirm) (1/1)"]:
            check item in progress
          # Each line is written before the work it names, so the rows
          # appear in the order they run.
          let first = progress.find("repro health: checking unpublished-heads")
          let next = progress.find(
            "repro health: checking disjoint-local-branches")
          check first >= 0 and next > first
        else:
          check progress.len == 0
          # The whole of stdout is the one document.
          let report = parseJson(stdoutText)
          check report["checks"].len > 0

  test "the report on a large reference tree names its unpublished HEAD":
    if findExe("git").len == 0:
      skip("git is not on PATH; the fixture is git repositories")
    else:
      var fx = setup()
      defer: removeDir(fx.root)
      let (outPath, errPath) = (fx.root / "out.json", fx.root / "err.txt")
      let health = startHealth(fx, @["--json"], outPath, errPath,
        isolatedEnv(fx))
      discard health.waitForExit()
      health.close()
      let report = parseJson(readFile(outPath))
      var row = newJNull()
      for c in report["checks"]:
        if c["name"].getStr == "unpublished-heads":
          row = c
      require row.kind != JNull
      checkpoint($row)
      check row["status"].getStr == "warn"
      let detail = row["detail"].getStr
      check "refs-tree (branch 'pinned'" in detail
      check "lib-a" notin detail
