## An ignored-input prefix must still fire when the kernel reports the
## path under a different, equivalent spelling.
##
## No mocks: this builds a real symlinked directory on the real
## filesystem and asks `cacheInputPaths` — a pure fold — what it keeps.
## The defect is entirely about two spellings of one directory, so a
## fake filesystem would have to invent the very behaviour under test.
##
## macOS ships `/tmp` as a symlink to `private/tmp`. A recipe or engine
## helper that derives an ignored root from `getTempDir()` gets
## `/tmp/...`, while every path the monitor observes has already been
## resolved by the kernel to `/private/tmp/...`. The two name one
## directory, but neither is a component prefix of the other, so the
## ignore never fired and the edge kept the very paths it had declared
## uninteresting.
##
## Where this bit, it was not marginal: the provider compile's ignore
## list exists to keep the SHARED provider nimcache — reused across
## recipes and sessions, rewritten by every compile — out of the key.
## With the ignore inert, 514 nimcache paths sat in that edge's key and
## it could never hit on an unchanged project.
##
## The positive direction is asserted alongside, because widening a root
## to a second spelling must not widen what it covers: a sibling of the
## ignored directory, reached through the same symlink, stays in the key.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core/dependency_gathering

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

suite "an ignored root fires through a symlinked spelling":

  test "a prefix written one way still ignores paths reported the other":
    # real/            <- the physical directory
    #   cache/         <- the ignored root
    #   kept/          <- a sibling that must survive
    # link -> real/    <- the alternative spelling
    let base = getTempDir() / "repro-symlink-root-" & $getCurrentProcessId()
    removeDir(base)
    createDir(base)
    defer: removeDir(base)
    let real = base / "real"
    createDir(real)
    createDir(real / "cache")
    createDir(real / "kept")
    let link = base / "link"
    createSymlink(real, link)

    # The action names the ignored root through the SYMLINK, the way a
    # helper deriving it from `getTempDir()` would on macOS.
    let viaLink = link / "cache"
    # The monitor reports the RESOLVED spelling, the way the kernel does.
    let observedIgnored = expandFilename(real) / "cache" / "@m.nim.c.o"
    let observedKept = expandFilename(real) / "kept" / "source.nim"

    let workRoot = base / "proj"
    createDir(workRoot)
    let act = action("compile", ["nim", "c"],
      cwd = workRoot,
      inputs = @[],
      outputs = @["out/provider"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      dependencyPolicy = automaticMonitorGatheringPolicy(@[viaLink]))

    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [observedIgnored, observedKept])

    let inputs = act.cacheInputPaths(evidence)

    # The defect: the ignored root was named through one spelling and the
    # path observed through the other, so the ignore did not fire.
    check not inputs.hasPath(observedIgnored)

    # Widening the root to a second spelling must not widen its reach.
    check inputs.hasPath(observedKept)

  test "a physical prefix ignores logical existing and missing observations":
    let base = getTempDir() / "repro-symlink-opposite-" & $getCurrentProcessId()
    removeDir(base)
    createDir(base / "real" / "cache")
    createDir(base / "real" / "cache-sibling")
    defer: removeDir(base)
    let physical = expandFilename(base / "real")
    let logical = base / "link"
    createSymlink(physical, logical)
    writeFile(physical / "cache" / "existing", "scratch")
    require logical != physical
    require expandFilename(logical) == physical
    let existing = logical / "cache" / "existing"
    let missing = logical / "cache" / "absent" / "extract_runner"
    let kept = logical / "cache-sibling" / "source"
    let declared = logical / "cache" / "declared"
    let act = action("compile", ["nim", "c"], cwd = physical,
      inputs = @[declared], outputs = @["out/provider"], cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph(),
      dependencyPolicy = automaticMonitorGatheringPolicy(@[physical / "cache"]))
    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [existing, missing, kept, declared])
    evidence.depfileInputs.observeAll(evidence.evidenceProvenance,
      evcToolReportedDepfile, [missing])
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [missing])
    evidence.monitorDirectoryEnumerations.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [logical / "cache", logical / "cache-sibling"])
    let inputs = act.cacheInputPaths(evidence)
    check not inputs.hasPath(existing)
    check not inputs.hasPath(missing)
    check inputs.hasPath(kept)
    check inputs.hasPath(declared)
    let enumerations = act.cacheEnumeratedDirectories(evidence)
    check not enumerations.hasPath(logical / "cache")
    check enumerations.hasPath(logical / "cache-sibling")
