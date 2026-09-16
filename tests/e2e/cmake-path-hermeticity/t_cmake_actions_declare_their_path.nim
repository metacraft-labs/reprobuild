## A CMake-generated build must not be a function of the caller's `$PATH`.
##
## ## The property under test
##
## THE SAME PROJECT, BUILT FROM TWO SHELLS WITH DIFFERENT `PATH`s, MUST
## RECORD THE SAME INPUTS AND COMPUTE THE SAME CACHE KEYS. That is the
## whole claim. Everything below is a way of making it fail when it is
## false.
##
## It was false. Before the CMake Reprobuild generator declared a `PATH`,
## every action it emitted named `PATH` in its passthrough set and ran on
## whatever the developer's login shell happened to offer. The engine's
## own census said so, on the zlib benchmark:
##
##   PATH: 0 hermetic (keyed by value), 37 inherited (passthrough), 0 EMPTY
##
## 37 of 37. And the consequence was measurable rather than theoretical:
## `clang` probes every `PATH` entry for its linker driver
## `<triple>-ld` before falling back to plain `ld`, and every one of
## those misses is RECORDED as an observed input of the link edge. On the
## machine this was found on, `link-zlib` had
## `/home/zahary/.pixi/bin/arm64-apple-darwin-ld` in its recorded input
## set — a file that does not exist, under a directory that exists on one
## developer's machine, on a macOS autofs map that cost ~14 ms per no-op
## build to probe.
##
## ## Why the assertions are shaped the way they are
##
## The naive test — "assert the census says hermetic" — is a test of a
## NUMBER IN A HEADER, and it stays green under any change that reports
## the right number for the wrong reason. So the census is checked last
## and only as corroboration. The load-bearing assertions are:
##
##   1. Two builds of one configured project, from two shells whose
##      `PATH`s differ by one directory each, record the SAME inputs, and
##      in particular neither records anything under EITHER shell's
##      private directory.
##
##   2. A POSITIVE CONTROL that the mechanism assertion 1 relies on is
##      really there. `-DREPROBUILD_CMAKE_INHERIT_PATH=ON` is the
##      generator's documented opt-out, and it reproduces the pre-fix
##      behaviour exactly — so it is also the MUTATION, and it is run
##      here rather than described. Under it the same two builds MUST
##      diverge: arm A must record its own decoy and arm B must record
##      its own. If that control ever passes silently — because the
##      compiler stopped probing `PATH`, or because the monitor stopped
##      recording probes — then assertion 1 has become vacuous and this
##      suite says so instead of staying green.
##
##      This matters specifically here. Assertion 1 is an assertion that
##      something is ABSENT, and an absence is what every broken
##      measurement also reports.
##
##   3. The declared `PATH` is keyed BY VALUE. Changing only the declared
##      value — same sources, same compiler, same everything else — must
##      invalidate the cached actions. Under a passthrough `PATH` the key
##      renders the NAME and deliberately not the value, so this
##      assertion is what fails if the declaration is ever downgraded
##      back to passthrough while still looking declared.
##
## ## MOCKS
##
## None. This drives the real forked `cmake`, the real `repro` CLI, the
## real compiler and the real process monitor, and reads the recorded
## input sets out of the monitor's own `.iomon` depfiles. The defect
## being closed lives precisely in the interaction between those parts,
## so a test that mocked any of them would be a test of the mock.

import std/[algorithm, os, sets, strutils, times, unittest]

import io_mon
from repro_test_support import CmdResult, requireBinary, runShell,
  shellCommand, workspaceRootForRepo

const
  DecoyA = "repro-path-decoy-A"
  DecoyB = "repro-path-decoy-B"
  # What `clang` looks for on `PATH` before falling back to plain `ld`.
  # The decoy directories stay EMPTY: the recorded input is the failed
  # probe, not a file, which is exactly the shape that made the original
  # defect expensive (a miss is still an observation, and it is still in
  # the key-bearing evidence).
  ProbeWitness = "arm64-apple-darwin-ld"

proc findForkedCMake(repoRoot: string): string =
  let explicit = getEnv("REPROBUILD_FORKED_CMAKE")
  if explicit.len > 0 and fileExists(explicit):
    return explicit
  let cmakeRoot = workspaceRootForRepo(repoRoot) / "reprobuild-cmake"
  var candidates = @[
    cmakeRoot / "build" / "bin" / "cmake",
    cmakeRoot / "_build" / "bin" / "cmake"
  ]
  when defined(windows):
    candidates = @[
      cmakeRoot / "build" / "bin" / "Release" / "cmake.exe",
      cmakeRoot / "build" / "bin" / "cmake.exe",
      cmakeRoot / "_build" / "bin" / "Release" / "cmake.exe",
      cmakeRoot / "_build" / "bin" / "cmake.exe"
    ] & candidates
  for candidate in candidates:
    if fileExists(candidate):
      return candidate
  ""

proc writeFixture(sourceDir: string) =
  ## Smallest project that still produces a LINK edge, because the link
  ## edge is the one that searches `PATH` for a linker driver. A compile
  ## edge alone would not exercise the property.
  createDir(sourceDir)
  writeFile(sourceDir / "CMakeLists.txt",
    "cmake_minimum_required(VERSION 3.20)\n" &
    "project(ReproPathHermeticity C)\n" &
    "add_library(rph_lib STATIC lib.c)\n" &
    "add_executable(rph_app app.c)\n" &
    "target_link_libraries(rph_app PRIVATE rph_lib)\n")
  writeFile(sourceDir / "lib.c",
    "int rph_value(void) { return 7; }\n")
  writeFile(sourceDir / "app.c",
    "int rph_value(void);\n" &
    "int main(void) { return rph_value() == 7 ? 0 : 1; }\n")

proc configure(cmakeBin, sourceDir, buildDir, reproBin: string;
               extraArgs: openArray[string] = []): CmdResult =
  var args = @[cmakeBin, "-S", sourceDir, "-B", buildDir, "-G", "Reprobuild",
    "-DCMAKE_MAKE_PROGRAM=" & reproBin, "-DCMAKE_BUILD_TYPE=Debug"]
  for extra in extraArgs:
    args.add(extra)
  runShell(shellCommand(args))

proc build(reproBin, buildDir, workRoot, pathValue: string;
           forceRebuild: bool): CmdResult =
  ## THE SHELL IS THE VARIABLE. `PATH` is overlaid per invocation, which
  ## is the whole experiment: two otherwise identical builds, two
  ## different login environments.
  var args = @[
    reproBin, "build", buildDir & "#all",
    "--tool-provisioning=path",
    "--work-root=" & workRoot
  ]
  if forceRebuild:
    args.add("--force-rebuild")
  runShell(shellCommand(args, @[(name: "PATH", value: pathValue)]))

proc censusLine(output: string): string =
  for line in output.splitLines:
    if line.startsWith("env: "):
      return line
  ""

proc monitorDepfileDir(workRoot: string): string =
  ## The engine writes one `<actionId>.iomon` per monitored action under
  ## the work root's engine cache. The worktree directory name is a hash
  ## of the project root, so it is discovered rather than constructed.
  for worktree in walkDir(workRoot / "worktrees"):
    if worktree.kind != pcDir:
      continue
    let candidate = worktree.path / "build" / "reprobuild" /
      "build-engine-cache" / "monitor-depfiles"
    if dirExists(candidate):
      return candidate
  ""

proc stripPrivate(path: string): string =
  ## macOS resolves `/tmp` and `/var` through `/private`, and the monitor
  ## records whichever form the syscall carried. Normalising here keeps a
  ## pure aliasing difference from reading as a real divergence.
  if path.startsWith("/private/"): path[len("/private") .. ^1] else: path

proc recordedInputs(depfile, workRoot: string): HashSet[string] =
  ## The recorded observation set of one action, normalised only for
  ## paths inside the ARM'S OWN work root — different between the arms by
  ## construction, since separate work roots are what makes them
  ## independent runs rather than one run plus a cache hit.
  ##
  ## NOTHING ELSE IS FILTERED HERE, and in particular nothing that could
  ## come from a `PATH` search is. The fixture is built inside the
  ## repository's `build/` tree rather than under `$TMPDIR` so that the
  ## decoy directories cannot be swept up by any normalisation rule.
  let armRoot = stripPrivate(workRoot)
  for record in readMonitorDepFile(depfile).records:
    if record.path.len == 0:
      continue
    let path = stripPrivate(record.path)
    if path.startsWith(armRoot & $DirSep):
      result.incl("<WORK-ROOT>" & path[armRoot.len .. ^1])
    else:
      result.incl(path)

proc mentioning(inputs: HashSet[string]; needle: string): seq[string] =
  for path in inputs:
    if path.contains(needle):
      result.add(path)

proc pathDirs(pathValue: string): HashSet[string] =
  for dir in pathValue.split(PathSep):
    if dir.len > 0:
      result.incl(stripPrivate(dir))

proc searchDerived(difference: HashSet[string];
                   exclusiveDirs: HashSet[string]): seq[string] =
  ## The elements of a between-arms difference that lie under a directory
  ## present on exactly ONE arm's `PATH`.
  ##
  ## ## Why this and not plain set equality
  ##
  ## Plain equality was tried first and is NOT a true statement about two
  ## runs of the same build, for reasons that have nothing to do with
  ## `PATH`. MEASURED, on the difference between two arms of this very
  ## fixture with the declared `PATH` in place and zero `PATH`-derived
  ## entries on either side:
  ##
  ##   mib:1.14.1.95649                     sysctl MIB, keyed on the pid
  ##   localfd:0:5826604354401893354        an anonymous descriptor
  ##   $TMPDIR/cc-params.YTsJdA             the cc wrapper's mktemp file
  ##   librph_lib.a.temp-archive-0cedba1.a  `ar`'s staging archive
  ##
  ## Four families, all with a per-process or per-`mktemp` component, all
  ## of which differ between two runs IN THE SAME SHELL. A test that
  ## demanded equality would have to enumerate and suppress them, and
  ## every suppression rule is a place a real `PATH`-derived difference
  ## could hide — which is the failure mode this whole defect is an
  ## instance of.
  ##
  ## So the assertion is made about the thing actually claimed: the
  ## recorded input set IS NOT A FUNCTION OF THE CALLER'S `$PATH`. Any
  ## observation under a directory that only one of the two shells had is
  ## a counterexample, and nothing else in the difference is evidence
  ## either way. That is strictly stronger than naming the decoys: it
  ## covers every directory the two shells differ by, whatever it is.
  for path in difference:
    for dir in exclusiveDirs:
      if path == dir or path.startsWith(dir & $DirSep):
        result.add(path)
        break

proc modificationEpoch(path: string): float =
  getLastModificationTime(path).toUnixFloat()

suite "CMake-generated actions declare their PATH":
  let repoRoot = getCurrentDir()
  let reproBin = requireBinary(
    repoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")
  let forkedCMake = findForkedCMake(repoRoot)

  # The fixture lives under the repository's build tree, NOT under
  # `$TMPDIR`, so that no normalisation rule can reach a decoy directory.
  let testRoot = repoRoot / "build" / "cmake-path-hermeticity"
  let sourceDir = testRoot / "source"
  let decoyDirA = testRoot / DecoyA
  let decoyDirB = testRoot / DecoyB
  let basePath = getEnv("PATH")
  let pathA = decoyDirA & $PathSep & basePath
  let pathB = decoyDirB & $PathSep & basePath
  # The directories exactly one of the two shells has. Computed from the
  # two `PATH` values rather than written out, so the assertion covers
  # whatever the shells actually differ by — including anything a future
  # edit to this fixture adds.
  let exclusiveDirs = (pathDirs(pathA) - pathDirs(pathB)) +
    (pathDirs(pathB) - pathDirs(pathA))

  setup:
    # A stale tree from an earlier run would let an assertion pass on
    # evidence this run did not produce.
    removeDir(testRoot)
    createDir(testRoot)
    createDir(decoyDirA)
    createDir(decoyDirB)
    writeFixture(sourceDir)

  test "1. two shells with different PATHs record the same inputs":
    check exclusiveDirs.len == 2
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with the Reprobuild generator is unavailable")
    else:
      let buildDir = testRoot / "build-declared"
      let configured = configure(forkedCMake, sourceDir, buildDir, reproBin)
      checkpoint(configured.output)
      check configured.code == 0

      # ONE configure, TWO builds. The property is about the build
      # inheriting the shell, so the generated graph is held fixed and
      # only the shell varies.
      let workA = testRoot / "work-declared-A"
      let workB = testRoot / "work-declared-B"
      let armA = build(reproBin, buildDir, workA, pathA, forceRebuild = true)
      checkpoint(armA.output)
      check armA.code == 0
      let armB = build(reproBin, buildDir, workB, pathB, forceRebuild = true)
      checkpoint(armB.output)
      check armB.code == 0

      let dirA = monitorDepfileDir(workA)
      let dirB = monitorDepfileDir(workB)
      check dirA.len > 0
      check dirB.len > 0

      # The suite is worthless if no action was monitored at all, so the
      # set of monitored actions is asserted before anything is asserted
      # ABOUT it.
      var monitored: seq[string] = @[]
      for entry in walkFiles(dirA / "*.iomon"):
        monitored.add(extractFilename(entry))
      monitored.sort()
      checkpoint("monitored actions: " & $monitored)
      check monitored.len > 0
      check "link-rph_app.iomon" in monitored

      for name in monitored:
        check fileExists(dirB / name)
        if not fileExists(dirB / name):
          continue
        let inputsA = recordedInputs(dirA / name, workA)
        let inputsB = recordedInputs(dirB / name, workB)
        checkpoint(name & ": " & $inputsA.len & " / " & $inputsB.len &
          " recorded paths")

        # (a) Neither arm may have looked in EITHER shell's private
        #     directory. This is the direct statement of the defect:
        #     `link-zlib` used to record
        #     `/home/zahary/.pixi/bin/arm64-apple-darwin-ld`.
        for decoy in [DecoyA, DecoyB]:
          let hits = mentioning(inputsA, decoy)
          checkpoint(name & " arm A mentions " & decoy & ": " & $hits)
          check hits.len == 0
          let hitsB = mentioning(inputsB, decoy)
          checkpoint(name & " arm B mentions " & decoy & ": " & $hitsB)
          check hitsB.len == 0

        # (b) The general form of (a): NOTHING the two arms disagree
        #     about may come from a directory only one of them had on
        #     `PATH`. (a) names the decoys; this covers every directory
        #     the two shells differ by, so a divergence through some
        #     other entry is caught too. See `searchDerived` for why the
        #     assertion is shaped this way and not as set equality.
        let difference = (inputsA - inputsB) + (inputsB - inputsA)
        let derived = searchDerived(difference, exclusiveDirs)
        checkpoint(name & " difference size: " & $difference.len)
        checkpoint(name & " PATH-derived difference: " & $derived)
        check derived.len == 0

  test "2. POSITIVE CONTROL: with REPROBUILD_CMAKE_INHERIT_PATH the arms diverge":
    ## The mutation, executed rather than described. This is the exact
    ## pre-fix arrangement — the generator declares nothing and every
    ## action names `PATH` passthrough — and under it test 1's assertions
    ## MUST be false. If they are not, test 1 is not measuring anything.
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with the Reprobuild generator is unavailable")
    else:
      let buildDir = testRoot / "build-inherited"
      let configured = configure(forkedCMake, sourceDir, buildDir, reproBin,
        ["-DREPROBUILD_CMAKE_INHERIT_PATH=ON"])
      checkpoint(configured.output)
      check configured.code == 0

      let workA = testRoot / "work-inherited-A"
      let workB = testRoot / "work-inherited-B"
      let armA = build(reproBin, buildDir, workA, pathA, forceRebuild = true)
      checkpoint(armA.output)
      check armA.code == 0
      let armB = build(reproBin, buildDir, workB, pathB, forceRebuild = true)
      checkpoint(armB.output)
      check armB.code == 0

      # The census must agree that this is the inherited arrangement,
      # so a future change that makes the opt-out silently ineffective
      # fails HERE instead of quietly turning the control into a second
      # copy of test 1.
      let censusA = censusLine(armA.output)
      checkpoint("inherited census: " & censusA)
      check censusA.contains("0 hermetic (keyed by value)")
      check not censusA.contains("0 inherited (passthrough)")

      let dirA = monitorDepfileDir(workA)
      let dirB = monitorDepfileDir(workB)
      check dirA.len > 0
      check dirB.len > 0
      let linkDepfile = "link-rph_app.iomon"
      check fileExists(dirA / linkDepfile)
      check fileExists(dirB / linkDepfile)

      let inputsA = recordedInputs(dirA / linkDepfile, workA)
      let inputsB = recordedInputs(dirB / linkDepfile, workB)

      # Each arm searched ITS OWN shell's directory and not the other's.
      let aInA = mentioning(inputsA, DecoyA)
      let bInB = mentioning(inputsB, DecoyB)
      checkpoint("inherited arm A searched its own decoy: " & $aInA)
      checkpoint("inherited arm B searched its own decoy: " & $bInB)
      check aInA.len > 0
      check bInB.len > 0
      check mentioning(inputsA, DecoyB).len == 0
      check mentioning(inputsB, DecoyA).len == 0

      # And the probe really is the linker-driver search the declared
      # PATH is there to bound, not some incidental read.
      var sawProbeWitness = false
      for path in aInA:
        if path.endsWith(ProbeWitness):
          sawProbeWitness = true
      checkpoint("probe witness " & ProbeWitness & " seen: " &
        $sawProbeWitness)
      check sawProbeWitness

      # And the same predicate test 1 asserts is EMPTY is non-empty
      # here — measured with the same code, not with a second, weaker
      # rule that might be measuring something else.
      let difference = (inputsA - inputsB) + (inputsB - inputsA)
      let derived = searchDerived(difference, exclusiveDirs)
      checkpoint("inherited PATH-derived difference: " & $derived)
      check derived.len > 0

  test "3. two shells with different PATHs share one cache entry":
    ## The other half of the acceptance property: identical inputs AND
    ## identical cache keys.
    ##
    ## ## Read this before treating it as the proof of anything
    ##
    ## THIS TEST ALSO PASSED BEFORE THE FIX, and it is here anyway.
    ## Under the pre-fix arrangement `PATH` was PASSTHROUGH, and
    ## `actionEnvironmentKeyText` renders a passthrough variable as its
    ## NAME with the value deliberately omitted — so two shells agreed on
    ## the key then too. They just did not agree on what the action had
    ## actually read, which is the whole defect: a shared key backed by
    ## different recorded inputs is a STALE SERVE, not cache sharing.
    ##
    ## So this asserts the property, and test 1 is what makes the
    ## property mean something. An earlier draft of this test instead
    ## claimed to prove "the declared value is in the key" by changing
    ## `REPROBUILD_CMAKE_ACTION_PATH_EXTRA` and watching the artifact get
    ## rebuilt. It passed under a mutation that put `PATH` back in
    ## passthrough — because the inline-exec fingerprint already mixes in
    ## the whole encoded action payload, `env` included, so the rebuild
    ## happened for a reason that had nothing to do with the env keying.
    ## The keying claim is pinned where it can actually be isolated, in
    ## `tests/unit/t_tool_profile_keys_on_resolution_not_search_path.nim`
    ## ("a declared PATH is keyed by value; a passthrough PATH is not").
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with the Reprobuild generator is unavailable")
    else:
      let buildDir = testRoot / "build-key"
      let workRoot = testRoot / "work-key"
      let archive = buildDir / "librph_lib.a"

      check configure(forkedCMake, sourceDir, buildDir, reproBin).code == 0
      # TWO settling builds before the baseline is taken, because the
      # FIRST build of a freshly configured tree re-runs the CMake
      # regeneration edge (the generate stamp is stale until a build has
      # consulted it) and rewrites `reprobuild.nim` / `trycompile.rbsz`.
      # A graph rewritten between build 1 and build 2 invalidates the
      # actions for a reason that has nothing to do with `PATH`, and
      # taking the baseline before it lands makes the "unchanged" check
      # below fail for the wrong reason — MEASURED: it did, the first
      # time this test ran.
      check build(reproBin, buildDir, workRoot, pathA,
        forceRebuild = false).code == 0
      check build(reproBin, buildDir, workRoot, pathA,
        forceRebuild = false).code == 0
      check fileExists(archive)
      let afterSettle = modificationEpoch(archive)

      # Baseline: the SAME shell rebuilds and nothing is rewritten. If
      # this failed, the cross-shell check below would prove nothing —
      # it could just mean the build never caches at all.
      check build(reproBin, buildDir, workRoot, pathA,
        forceRebuild = false).code == 0
      let afterSameShell = modificationEpoch(archive)
      checkpoint("mtime after same-shell rebuild: " & $afterSameShell &
        " (settled: " & $afterSettle & ")")
      check afterSameShell == afterSettle

      # THE OTHER SHELL, against the SAME action cache. A cache hit here
      # is the engine stating that the two shells computed the same key.
      check build(reproBin, buildDir, workRoot, pathB,
        forceRebuild = false).code == 0
      let afterOtherShell = modificationEpoch(archive)
      checkpoint("mtime after other-shell rebuild: " & $afterOtherShell)
      check afterOtherShell == afterSettle

  test "4. the census reports every CMake action as hermetic":
    ## NOT decoration, despite looking like it. The build header's env
    ## census is how this defect was found — it reported
    ## `0 hermetic / 37 inherited` truthfully for the defect's whole
    ## life — and it is also the ONLY assertion in this suite that caught
    ## the subtlest mutation tried against the fix.
    ##
    ## MEASURED. Mutating the inline-exec lowering to append a declared
    ## `PATH` to the action's `env` AFTER the decision, instead of
    ## routing it through the decision (the obvious naive
    ## implementation), leaves the action carrying BOTH `PATH=<value>`
    ## and `PATH` in `envPassthrough`. Tests 1, 2 and 3 all stayed
    ## green — the spawned process still got the declared value, so the
    ## recorded inputs were still clean — while the action's DECLARATION
    ## said the opposite of what it did, and the key recorded only the
    ## name. This case is what failed, because `classifyActionPath`
    ## reads the artifact rather than the intent.
    check forkedCMake.len > 0
    if forkedCMake.len == 0:
      checkpoint("forked CMake with the Reprobuild generator is unavailable")
    else:
      let buildDir = testRoot / "build-census"
      check configure(forkedCMake, sourceDir, buildDir, reproBin).code == 0
      let built = build(reproBin, buildDir, testRoot / "work-census", pathA,
        forceRebuild = true)
      checkpoint(built.output)
      check built.code == 0
      let census = censusLine(built.output)
      checkpoint("declared census: " & census)
      check census.len > 0
      check census.contains("0 inherited (passthrough)")
      check census.contains("0 EMPTY")
      check not census.contains("0 hermetic (keyed by value)")
