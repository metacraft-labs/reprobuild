## The self-written set is DERIVED from the action's own output declaration,
## never listed a second time beside it.
##
## Spec: `Filesystem-Policy-And-Observed-Inputs.md` §"Enumerations And Probes
## Under Writable Areas" / §"The self-written set is derived, never listed",
## and the testable consequence it states in as many words:
##
##   "For any action, the set of ignored input prefixes contains every
##    declared output write-root. A conformance check can assert that without
##    running a build, and it fails today."
##
## That is the first test below, asserted against `enumerationIgnoredRoots`.
##
## NO MOCKS. The evidence handed to the folds is a literal `PathSetEvidence`
## for the same reason `t_monitor_scratch_is_not_a_cache_input.nim` and
## `test_s5_own_output_is_not_a_cache_input.nim` give: `cacheInputPaths` and
## `cacheEnumeratedDirectories` are pure folds over one path-set, so handing
## them the path-set directly tests the rule under test rather than the shape
## of some capture. `action()` is the real constructor and the declarations
## are the real fields the rest of the engine reads.
##
## WHAT THE MEASURED DEFECT WAS. `__repro_interface_extract` declares four
## output FILES under `<project>/.repro/build/repro` and no write root, and
## the membership digest of that directory landed in its own key. Measured
## on `examples/hello-world-c` with a fresh action-cache root, macOS aarch64,
## `--daemon=off --tool-provisioning=path`: five quiescent builds converge at
## build 3 (0.66 s), and then `touch`ing ONE unrelated file into
## `<project>/.repro/build/repro/` re-executed the extraction — 6.77 s and a
## third `.rec` under the same per-edge directory — because the edge's key
## carried the entry list of a directory it publishes into. The last two
## tests here are that observation reduced to the fold.
##
## BOTH DIRECTIONS, every time. Dropping a genuine input from a key serves a
## stale result, which is strictly worse than the miss being fixed, so every
## negative below is paired with a positive an over-broad filter would fail:
## a read and a probe under the same write root (the shipped
## `autotools_package` shape), a sibling directory, the output directory's
## PARENT, a SUBdirectory of it, and a directory the author declared as an
## input.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine

const
  UnitRoot =
    when defined(windows): "C:/repro-derived-selfwritten-unit"
    else: "/repro-derived-selfwritten-unit"

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

proc writeRootAction(destRoot: string): BuildAction =
  ## An action shaped like `cmake_package`'s install edge: a stamp file as its
  ## `outputs`, the staged tree as its `declaredOutputs` write root, and NO
  ## explicit `ignoredInputPrefixes` — the omission the spec says must stop
  ## being possible.
  result = action("stage", ["cmake", "--install", "build"],
    cwd = UnitRoot / "proj",
    inputs = [],
    outputs = [UnitRoot / "proj" / ".repro" / "install.stamp"],
    cacheable = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.declaredOutputs = @[destRoot]

suite "the self-written set is derived from the output declaration":

  test "ignored prefixes contain every declared output write-root":
    ## The spec's conformance check, verbatim, and the one that failed before
    ## the derivation existed: the action declares the write root and names
    ## NOTHING in `ignoredInputPrefixes`.
    let destRoot = UnitRoot / "proj" / "build" / "out"
    let act = writeRootAction(destRoot)

    check act.dependencyPolicy.ignoredInputPrefixes.len == 0
    for root in act.declaredOutputs:
      check act.enumerationIgnoredRoots().hasPath(root)

  test "an explicit prefix that is NOT a declared output survives":
    ## The legitimate exception the spec keeps: a per-invocation scratch tree
    ## outside any write-root, or machine-local derived state the action reads
    ## back but does not own. The derivation must ADD to the explicit set, not
    ## replace it.
    let destRoot = UnitRoot / "proj" / "build" / "out"
    let scratch = UnitRoot / "scratch" / "m7-temp"
    var act = writeRootAction(destRoot)
    act.dependencyPolicy.ignoredInputPrefixes = @[scratch]

    let roots = act.enumerationIgnoredRoots()
    check roots.hasPath(scratch)
    check roots.hasPath(destRoot)

  test "a declared write root's enumerations leave the key, siblings stay":
    ## The membership digest of a directory the action writes is derived
    ## state. The membership of a directory it only reads is not.
    let destRoot = UnitRoot / "proj" / "build" / "out"
    let nested = destRoot / "usr" / "lib"
    let sibling = UnitRoot / "proj" / "build" / "cmake-generated"
    let act = writeRootAction(destRoot)

    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    evidence.monitorDirectoryEnumerations.observeAll(
      evidence.evidenceProvenance, evcMonitorCapture,
      [destRoot, nested, sibling])

    let enumerated = act.cacheEnumeratedDirectories(evidence)
    check not enumerated.hasPath(destRoot)
    check not enumerated.hasPath(nested)
    check enumerated.hasPath(sibling)

  test "reads and probes under a declared write root STAY in the key":
    ## The soundness bound, and the reason the derivation is applied to the
    ## enumeration channel alone. `autotools_package`'s configure edge
    ## declares the build tree as a write root unconditionally but runs
    ## BEFORE the cleanup when there are source patches, and then genuinely
    ## reads the previous tree (`test ! -f build/input || cp build/input
    ## src/settings`). Deriving the ignore for reads and probes would hand
    ## that edge a hit on a tree it had consumed.
    let destRoot = UnitRoot / "proj" / "build" / "out"
    let consumedRead = destRoot / "input"
    let consumedProbe = destRoot / "settings"
    let act = writeRootAction(destRoot)

    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    evidence.monitorReads.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [consumedRead])
    evidence.monitorProbes.observeAll(evidence.evidenceProvenance,
      evcMonitorCapture, [consumedProbe])

    let inputs = act.cacheInputPaths(evidence)
    check inputs.hasPath(consumedRead)
    check inputs.hasPath(consumedProbe)

  test "the restore gate does not honour a DERIVED prefix":
    ## The two readings of `ignoredInputPrefixes` are not the same claim.
    ## `honouredDerivedPrefixes` answers "are the bytes under here NOT my
    ## product", and a declared write root is the opposite of that answer.
    ## Feeding it the derived set would also be unsound by construction,
    ## because the gate disqualifies a prefix by comparing it against
    ## `declaredOutputs` in their DECLARED spelling, so the symlink-resolved
    ## derived spelling would slip past the disqualification — which is why
    ## the write root below is spelled through a symlinked parent where the
    ## platform has one.
    let destRoot = UnitRoot / "proj" / "build" / "out"
    let act = writeRootAction(destRoot)
    check act.honouredDerivedPrefixes().len == 0

    when not defined(windows):
      # macOS: `/tmp` is a symlink to `/private/tmp`, so a root derived from
      # a `/tmp` declaration carries BOTH spellings and only one of them can
      # be matched against the declaration.
      let linked = createTempDir("repro-derived-gate-", "")
      defer: removeDir(linked)
      let resolved = expandFilename(linked)
      var linkedAct = writeRootAction(linked)
      check linkedAct.honouredDerivedPrefixes().len == 0
      if resolved != linked:
        check linkedAct.enumerationIgnoredRoots().hasPath(resolved)

suite "an output file's own directory is derived state too":

  test "the directory holding a declared output is not an enumerated input":
    ## The `__repro_interface_extract` shape: output FILES, no write root.
    ## The directory it publishes into changed membership because this action
    ## added an entry to it.
    let outDir = UnitRoot / "proj" / ".repro" / "build" / "repro"
    let parent = UnitRoot / "proj" / ".repro" / "build"
    let nested = outDir / "provider"
    let sibling = UnitRoot / "proj" / "src"

    var act = action("extract",
      ["repro", "__repro-extract-interface", "--artifact",
       outDir / "project-interface.rbsz"],
      cwd = UnitRoot / "proj",
      inputs = [],
      outputs = [outDir / "project-interface.rbsz",
                 outDir / "project-interface.nim"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    check act.declaredOutputs.len == 0

    var evidence: PathSetEvidence
    evidence.declaredOutputs = act.outputs
    evidence.monitorDirectoryEnumerations.observeAll(
      evidence.evidenceProvenance, evcMonitorCapture,
      [outDir, parent, nested, sibling])

    let enumerated = act.cacheEnumeratedDirectories(evidence)
    # The defect.
    check not enumerated.hasPath(outDir)
    # The narrowness: an output FILE's directory is derived EXACTLY, not as a
    # prefix. Its parent and its subdirectories are somebody else's business
    # and an over-broad filter would swallow both.
    check enumerated.hasPath(parent)
    check enumerated.hasPath(nested)
    check enumerated.hasPath(sibling)

  test "a DECLARED input directory keeps its membership":
    ## Declaration outranks every filter — the same principle
    ## `cacheInputPaths`' `declaredMaterialized` retention encodes. An author
    ## who declares the directory they also write into has said its entry
    ## list matters, and the derived rule must not overrule them.
    let outDir = UnitRoot / "proj" / ".repro" / "build" / "repro"

    var act = action("extract", ["repro", "__repro-extract-interface"],
      cwd = UnitRoot / "proj",
      inputs = [outDir],
      outputs = [outDir / "project-interface.rbsz"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    var evidence: PathSetEvidence
    evidence.declaredInputs = act.inputs
    evidence.declaredOutputs = act.outputs
    evidence.monitorDirectoryEnumerations.observeAll(
      evidence.evidenceProvenance, evcMonitorCapture, [outDir])

    check act.cacheEnumeratedDirectories(evidence).hasPath(outDir)

  test "two runs that differ only in the output directory's membership agree":
    ## The property the defect broke, stated directly. Same action, same real
    ## evidence; the only difference is a neighbour appearing in the action's
    ## own output directory, which is what a `touch` of one unrelated file
    ## did to the real extraction edge. The enumerated set must converge, or
    ## the strong fingerprint moves and the edge can never hit.
    let outDir = UnitRoot / "proj" / ".repro" / "build" / "repro"
    let sibling = UnitRoot / "proj" / "src"

    var act = action("extract", ["repro", "__repro-extract-interface"],
      cwd = UnitRoot / "proj",
      inputs = [],
      outputs = [outDir / "project-interface.rbsz"],
      cacheable = true,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())

    proc foldWith(extra: openArray[string]): seq[string] =
      var evidence: PathSetEvidence
      evidence.declaredOutputs = act.outputs
      var dirs = @[outDir, sibling]
      for e in extra: dirs.add(e)
      evidence.monitorDirectoryEnumerations.observeAll(
        evidence.evidenceProvenance, evcMonitorCapture, dirs)
      act.cacheEnumeratedDirectories(evidence)

    check foldWith([]) == foldWith([outDir])
    check foldWith([]) == @[sibling]
