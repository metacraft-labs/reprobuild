## The monitor's own drop-in tool directory is NOT one of an action's inputs.
##
## No mocks. The evidence below is a literal `PathSetEvidence` because
## `cacheInputPaths` is a pure fold over one — the same construction
## `test_s5_own_output_is_not_a_cache_input.nim` uses, and the reason that
## file gives applies unchanged: the property under test is which paths the
## fold keeps, so handing it the path-set directly tests the rule rather
## than a capture's shape.
##
## On macOS the interpose backend cannot inject into a system-protected
## platform binary, so it drops injectable copies of the shells and core
## utilities into a temporary directory and points the monitored process at
## it. Absent an operator-supplied bundle that directory is created fresh
## per monitored run, and its NAME carries the creating pid and a
## nanosecond timestamp. Every action whose command runs a shell probes
## `<dir>/bin/sh`, so one value in the probe set was new on every
## invocation.
##
## The weak fingerprint was unaffected, which is what made this durable
## rather than noisy: every run landed in the same per-edge directory and
## wrote ANOTHER record under a fresh strong fingerprint, instead of
## converging on one as `Action-Cache-Per-Edge-Store.md` §5.1 requires.
## Measured on an unchanged fixture project, three consecutive
## `repro exec` runs each reported `cdMiss` and re-ran the dev-env
## introspection edge, and the second and third runs' probe sets differed
## from the first in exactly this one path and nothing else.
##
## `Tool-Owned-Caches.md` §What The Cache Key May Observe states the rule:
## whatever the engine allocates to back a path "MUST NOT appear in any
## cache key. It MAY change between runs without invalidating anything."
##
## Both directions are asserted, for the reason S5 states: dropping a
## genuine input from the key serves a stale result, which is strictly
## worse than the miss being fixed. So the negative direction is paired
## with a positive one that an over-broad filter would fail — a real input
## living under the SAME temp root as the scratch directory, and one whose
## own name merely contains the scratch prefix as a substring.

import std/[os, strutils, unittest]

import repro_build_engine

const
  UnitRoot =
    when defined(windows): "C:/repro-monitor-scratch-unit"
    else: "/repro-monitor-scratch-unit"
  TmpRoot = UnitRoot / "tmp"
  # The real shape: `<tmp>/repro-fs-snoop-sandbox-tools-<pid>-<sec>-<nsec>-<pid>`.
  ScratchDir = TmpRoot / "repro-fs-snoop-sandbox-tools-14903-1790238815-616887000-14905"

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

suite "the monitor's drop-in tool directory is not a cache input":

  test "cacheInputPaths drops monitor scratch and keeps its neighbours":
    let workRoot = UnitRoot / "proj"
    let scratchShell = ScratchDir / "bin" / "sh"
    let scratchTool = ScratchDir / "bin" / "cp"
    let declaredInput = workRoot / "src" / "main.nim"
    let realInput = workRoot / "src" / "shared.nim"
    # A genuine input that lives under the same temp root as the scratch
    # directory. A filter written against the temp root would take it.
    let tmpNeighbour = TmpRoot / "generated-config.json"
    # A genuine input whose own name merely CONTAINS the scratch prefix.
    # A substring filter would take this one.
    let lookalike = workRoot / "repro-fs-snoop-sandbox-tools-notes.md"

    let act = action("introspect", ["repro", "__repro-dev-env-introspect"],
      cwd = workRoot,
      inputs = ["src/main.nim"],
      outputs = ["out/dev-env.rbde"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.declaredOutputs = act.outputs
    evidence.monitorReads = @[declaredInput, realInput, scratchTool,
                              tmpNeighbour, lookalike]
    evidence.monitorProbes = @[scratchShell, realInput]
    evidence.depfileInputs = @[scratchShell, realInput]

    let inputs = act.cacheInputPaths(evidence)

    # The defect: neither the probed shell nor any other file under the
    # per-run scratch directory may key the action.
    check not inputs.hasPath(scratchShell)
    check not inputs.hasPath(scratchTool)

    # The cardinal-sin guard: every genuine input survives.
    check inputs.hasPath(declaredInput)
    check inputs.hasPath(realInput)
    check inputs.hasPath(tmpNeighbour)
    check inputs.hasPath(lookalike)

  test "two runs whose only difference is the scratch directory agree":
    ## The property the defect actually broke, stated directly: the key's
    ## input path-set must CONVERGE across runs. Same action, same real
    ## evidence, two different per-run scratch directories — the fold must
    ## produce the same answer, or the strong fingerprint moves and the
    ## action can never hit.
    let workRoot = UnitRoot / "proj"
    let realInput = workRoot / "src" / "shared.nim"

    let act = action("introspect", ["repro", "__repro-dev-env-introspect"],
      cwd = workRoot,
      inputs = ["src/main.nim"],
      outputs = ["out/dev-env.rbde"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    proc foldWith(scratch: string): seq[string] =
      var evidence: PathSetEvidence
      evidence.declaredInputs = act.inputs
      evidence.declaredOutputs = act.outputs
      evidence.monitorReads = @[realInput]
      evidence.monitorProbes = @[scratch / "bin" / "sh"]
      act.cacheInputPaths(evidence)

    # The two directory names measured from consecutive runs.
    let first = foldWith(
      TmpRoot / "repro-fs-snoop-sandbox-tools-14903-1790238815-616887000-14905")
    let second = foldWith(
      TmpRoot / "repro-fs-snoop-sandbox-tools-16330-1790238827-451170000-16332")

    check first == second
    check first.hasPath(realInput)
