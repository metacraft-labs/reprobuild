## The `.#prefix` source-staging edge declares every tool its scripts run.
##
## reprobuild-pm Distribution-And-Packaging.md §5.3, "The sources": the edge
## `reprobuild.prefix.sources@<triple>` in `repro.nim` stages
## `share/repro/source` and the source-only inputs with
## `scripts/release/stage_release_sources.sh`, which sources
## `scripts/lib/stage_source_root.sh` and `stage_package_nimble.sh` and runs
## `stage_release_catalog.sh` and, through it, `scripts/lib/release_git.sh`.
## In path mode an edge's PATH holds what its tool identities name and
## nothing else, so a tool the scripts call and the edge does not declare is
## "command not found" there. That happened: `stage_release_catalog.sh`
## started reading the catalog pin out of `repro.lock` with `grep`
## (reprobuild `34f15c40b`), the edge did not declare `grep`, and the armv7
## prefix stopped building ("repro.lock does not pin exactly one 40-hex
## reprobuild-packages revision (found: none)", measured 2026-11-12 at
## `7928e5a0f`).
##
## NO MOCKS. The real scripts run against this checkout and its catalog
## sibling, with a PATH that is a directory of links to exactly the tools
## `PrefixSourcesTools` names, each resolved from the ambient PATH. That is
## stricter than path mode, which puts each tool's whole directory on PATH:
## on a host where the coreutils share one directory, an undeclared `env`
## or `basename` is found by accident, and here it is not.
##
## Each case first runs the script with the ambient PATH. When that control
## fails (no catalog checkout holding the pinned revision, or no dev shell
## to supply the source inputs), the case skips with the control's output,
## and fails in a gate run: the farm run would prove nothing then.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support/reasoned_skip
import repro_dsl_stdlib/packaging/reprobuild_dist

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir

proc toolFarm(root: string): string =
  ## A directory holding a link to each declared tool and nothing else.
  result = root / "bin"
  createDir(result)
  for tool in PrefixSourcesTools:
    let exe = findExe(tool)
    doAssert exe.len > 0, tool & " is not on the ambient PATH"
    createSymlink(exe, result / tool)

proc run(script, dest: string; path = ""): tuple[output: string, code: int] =
  ## Run `bash <script> <dest>` from the repository root, with the ambient
  ## environment and, when `path` is given, PATH replaced by it.
  createDir(dest)
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  var bash = findExe("bash")
  if path.len > 0:
    env["PATH"] = path
    bash = path / "bash"
  let r = execCmdEx(quoteShell(bash) & " " & quoteShell(script) & " " &
    quoteShell(dest), workingDir = RepoRoot, env = env)
  (r.output, r.exitCode)

template withControl(script: string; body: untyped) =
  let controlDir = createTempDir("prefix-sources-control-", "")
  defer: removeDir(controlDir)
  let control = run(script, controlDir)
  if control.code != 0:
    let reason = "the control run of " & script &
      " with the ambient PATH failed:\n" & control.output
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint(reason)
      check false
    else:
      skip(reason)
  else:
    body

suite "the prefix source-staging edge declares its scripts' tools":
  test "stage_release_catalog.sh runs on the declared tools alone":
    withControl("scripts/release/stage_release_catalog.sh"):
      let root = createTempDir("prefix-sources-catalog-", "")
      defer: removeDir(root)
      let r = run("scripts/release/stage_release_catalog.sh", root / "pkg",
        toolFarm(root))
      checkpoint(r.output)
      check r.code == 0
      check "command not found" notin r.output
      check fileExists(root / "pkg" / "share" / "repro" /
        "reprobuild-packages" / "catalog-revision")

  test "stage_release_sources.sh runs on the declared tools alone":
    withControl("scripts/release/stage_release_sources.sh"):
      let root = createTempDir("prefix-sources-all-", "")
      defer: removeDir(root)
      let r = run("scripts/release/stage_release_sources.sh", root / "pkg",
        toolFarm(root))
      checkpoint(r.output)
      check r.code == 0
      check "command not found" notin r.output
      check dirExists(root / "pkg" / "share" / "repro" / "source")
