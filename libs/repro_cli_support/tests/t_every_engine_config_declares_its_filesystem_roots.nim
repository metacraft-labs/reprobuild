## No engine configuration may be left without the workspace's root
## classification, and a new one may not quietly opt out.
##
## Spec: `Incremental-Invalidation.md` §"Validation Criteria", the second
## mandatory exemption. The exemption is derived from
## `BuildEngineConfig.filesystemRoots`, and an EMPTY `filesystemRoots`
## exempts nothing — which is the fail-closed default and is exactly why a
## missing wire-up is invisible. The edge simply keeps the immediate
## membership of `/`, of `$HOME` and of every other ancestor its tool
## searched upward through, in its key, forever, and nothing fails.
##
## A BEHAVIOURAL TEST CANNOT CATCH THAT, which is why this is a structural
## audit over the source and is that shape on purpose — the same shape, and
## the same argument, as `t_s7_build_paths_reach_the_restore_config.nim`:
## "assert over the population, so a newly added member cannot opt out by
## not being looked at." If someone adds an eighth engine config for a new
## entry point and forgets the call, every existing behavioural test still
## passes.
##
## AND THIS CAMPAIGN HAS THE SPECIFIC HISTORY THAT MAKES IT WORTH THE FILE.
## Two landed changes to this same proc family were silently discarded in
## cross-session merge conflict resolution and no gate noticed
## (`reprobuild-specs/issues/2026-10-15-a-merge-can-drop-a-landed-change-and-
## no-gate-notices.md`); `--check-declared-sources` asserts that a test is
## enrolled, not that it compiles, and `check_nim_sources` compiles app
## entrypoints, not tests. A merge that dropped one of the seven calls below
## would leave a tree that builds, a suite that passes, and one build path
## keying on the user's home directory again. This file is the thing that
## would go red.
##
## WHAT THIS DOES NOT COVER, stated because an audit that reads as complete
## and is not is worse than none. The population is the EXPLICIT `var … =
## BuildEngineConfig(` constructions in `repro_cli_support.nim` — seven
## today. It does not reach the roughly twenty `defaultBuildEngineConfig(…)`
## sites in the same file (workspace and VCS plumbing: `cloneForDevelop`,
## `executeWorkspaceSync`, `executeBranchCreate`, `executeWorkspaceSwitch`),
## the two inline `BuildEngineConfig(` arguments passed straight to
## `runBuild`, or the engine configs in `repro_profile_compile`,
## `repro_lock_gen` and `repro_tool_profiles`. None of those declares a
## classification today; all of them therefore keep the pre-exemption
## behaviour, which is the fail-closed direction. `t_s7_…` has the same
## blind spot and says so for the same reason — "a build entry point can opt
## out without constructing anything". This file is a FLOOR under the
## population that exists, not a statement that the population is complete.
##
## NO MOCKS AND NO BUILD: it reads `repro_cli_support.nim` as text. The
## end-to-end behaviour — that a declared classification actually removes
## the membership digests and that an ancestor change then stops re-running
## an edge — is
## `libs/repro_build_engine/tests/t_untracked_ancestor_change_does_not_re_run_an_edge.nim`.

import std/[os, strutils, unittest]

const RepoMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

proc cliSupportSource(): string =
  readFile(findRepoRoot() / "libs" / "repro_cli_support" / "src" /
    "repro_cli_support.nim")

type ConfigSite = object
  variableName: string
  line: int

proc configSites(source: string): seq[ConfigSite] =
  ## Every `var <name> = BuildEngineConfig(` construction, by the same
  ## lexical rule `t_s7_build_paths_reach_the_restore_config.nim` uses.
  let lines: seq[string] = source.splitLines()
  for i, raw in lines:
    let line = raw.strip()
    if not line.endsWith("= BuildEngineConfig("):
      continue
    if not line.startsWith("var "):
      continue
    let name = line["var ".len ..< line.find(" =")]
    result.add(ConfigSite(variableName: name.strip(), line: i + 1))

suite "every engine config declares the workspace root classification":

  test "every construction site is wired to the classification":
    ## The load-bearing assertion. Each construction must be followed,
    ## within its own wiring block, by `wireFilesystemRoots(<name>, …)` or
    ## by `wirePortableCache(<name>, …)` — which declares the classification
    ## unconditionally and only then decides about the portable identity, so
    ## either call satisfies this.
    let source = cliSupportSource()
    let lines = source.splitLines
    let sites = configSites(source)
    # Seven today. A FLOOR and not an equality, so adding an engine config
    # is not by itself a failure — failing to wire it is.
    check sites.len >= 7
    var unwired: seq[string] = @[]
    for site in sites:
      var wired = false
      # The wiring follows the construction; 90 lines clears the longest
      # construction-plus-wiring block in this file and stops well short of
      # the next site.
      for i in site.line ..< min(site.line + 90, lines.len):
        let line = lines[i].strip()
        if line.startsWith("wireFilesystemRoots(" & site.variableName & ",") or
            line.startsWith("wirePortableCache(" & site.variableName & ","):
          wired = true
          break
        if line.endsWith("= BuildEngineConfig("):
          break
      if not wired:
        unwired.add(site.variableName & " at line " & $site.line)
    checkpoint("engine configs with no root classification: " &
      unwired.join(", "))
    check unwired.len == 0

  test "the wiring is unconditional, not gated on the portable cache":
    ## `Incremental-Invalidation.md` forbids the exemption being
    ## configurable from the environment, and `wirePortableCache` returns
    ## early on `REPRO_PORTABLE_CACHE`. So the classification has to be
    ## declared BEFORE that early return, or every call site that uses
    ## `wirePortableCache` declares nothing unless the variable is set.
    let text = readFile(findRepoRoot() / "libs" / "repro_cli_support" /
      "src" / "repro_cli_support" / "portable_cache.nim")
    let lines = text.splitLines
    var wireLine = -1
    var guardLine = -1
    var inWirePortableCache = false
    for i, raw in lines:
      let line = raw.strip()
      if line.startsWith("proc wirePortableCache*("):
        inWirePortableCache = true
        continue
      if not inWirePortableCache:
        continue
      if line.startsWith("proc "):
        break
      if wireLine < 0 and line.startsWith("wireFilesystemRoots(config,"):
        wireLine = i
      if guardLine < 0 and line == "if not portableCacheEnabled():":
        guardLine = i
    checkpoint("wire at " & $wireLine & ", env guard at " & $guardLine)
    check wireLine >= 0
    check guardLine >= 0
    check wireLine < guardLine
