## A profile compile driven by clang is published on its FIRST run, so an
## unchanged profile is an action-cache hit on run 2.
##
## Primary assertion -- `e2e_profile_compile_clang_first_run_published`:
## with `$REPRO_BOOTSTRAP_CC` naming a clang, the first `compileProfileToRbpi`
## executes the edge and the engine publishes its record (no
## `cachePublishSkipReason`); the second, on an unchanged profile, is `cdHit`
## with the edge not launched and no `nim` spawned.
##
## The defect (reprobuild-pm issue
## 2026-10-14-clang-profile-compile-is-not-published-on-its-first-run): clang
## writes each `-o` object through a temporary file whose random name comes
## from `arc4random`. io-mon reports the call, the profile-compile edge
## carries no entropy blessing, and the first run's publish was skipped
## (`reasons=unblessed-entropy`); only the determinism probe admitted the
## second identical run, so the unchanged profile hit on run 3. Measured
## before the fix (home-pc, clang 21): miss, miss, hit. The fix passes clang
## `-fno-temp-file` (`profileCompileCFlags`).
## Apple clang independently names its dependency-file temporary with entropy.
## The edge now routes that unused report to the OS null device. A second
## control restores just dependency-file output and must block publication;
## the primary also requires real objects and no dependency files. The C
## header case changes only a header under the same warm Nim cache and asserts
## the new value in the actual resource intent. No monitor records are ignored.
##
## SINCE THE 2026-10-22 SPLIT (reprobuild-pm
## `spec/Profile-Compilation-Model.md` §2.1) the profile compile is a compile
## edge that carries the provider compile's entropy blessing and an
## unblessed run edge. clang runs in the COMPILE edge, so its draw no longer
## withholds publication, and "is the first run published" stopped being
## evidence that the flag works. The flags stay -- a removed draw is better
## than a waived one (idiomatic-reprobuild.md §4.4) -- and this gate now
## reads their effect off the compile edge's own entropy evidence, record by
## record with the image that emitted it
## (`ProfileEdgeOutcome.entropyObservations`).
##
## NOT off the bare count of records. The edge's process tree draws entropy
## that is not clang's: a Nix clang is a wrapper script that runs coreutils
## `mktemp` (one `getrandom`, measured on NixOS with clang 21.1.8), which the
## per-image blessing table excuses. A count would fail the primary case on
## that draw and let the control pass on it alone, with clang drawing
## nothing. So each case asks two questions:
##
## * clang's draws -- records whose image is a clang driver (`clangDraws`).
##   None with the flags; at least one without them.
## * unexcused draws -- records no per-image blessing excuses
##   (`unexcusedDraws`): what would withhold publication if this edge carried
##   no action blessing, as it carried none before the split. None with the
##   flags (the pre-split gate's "first run is published"); at least one
##   without them (its `unblessed-entropy` skip reason).
##
## Vacuity guards: the compile really ran clang with the flag -- the `nim c`
## argv the spy logged names `--cc:clang`, the chosen clang as
## `--clang.exe:`, and `--passC:-fno-temp-file` -- and the published intent
## holds exactly the one resource the profile declares.
##
## Positive control: the same compile through a clang that DROPS
## `-fno-temp-file` (`exec_without_arg.nim`, a graph-built program that
## removes it and execs the same clang) has clang's draw in the compile
## edge's entropy evidence, attributed to the clang image -- and, the edge
## being blessed, is still published. So the primary case's absence of a
## clang draw is the flag's doing, and the monitor still sees clang's draw. The wrapper is a compiled program, not a `/bin/sh`
## script, so the monitor shim stays on the chain on macOS too (a SIP
## `/bin/sh` would drop it) and the control runs on Linux and macOS. On macOS
## it is also the evidence that io-mon reports that clang's `arc4random` at
## all: if it did not, the primary case would pass for the wrong reason.
##
## Falsifying mutation (performed when this gate was written, before the
## split): make `profileCompileCFlags` return no flags. The primary case
## failed: run 1 had `cachePublishSkipReason` `reasons=unblessed-entropy`, run
## 2 was a miss. After the split the same mutation fails the primary case at
## the compile edge's entropy evidence (a clang-image draw, unexcused).
##
## No mocks. The real `build/bin/repro`, the real Nim compiler, the real clang,
## the real io-mon shim; the `nim` on `PATH` is the pass-through counter
## justified in `profile_compile_edge_harness.nim`. The control's wrapper is
## not a stand-in either: it forwards to the real clang, minus one argument,
## which is the variable the control exists to vary.
##
## Platforms. Linux (home-pc) and macOS (m1, GM0m's
## `e2e_profile_compile_clang_first_run_published_macos`) -- each needs a clang
## on `PATH`, which reprobuild's dev shell provides on both. On macOS the
## harness's fail-closed arm applies (`EdgeMayFailClosed`, GM0m) for reasons
## other than entropy: a skipped publish is accepted only when its reason does
## not name entropy. Windows is skipped: Nim's default there is the MinGW gcc
## env.ps1 provisions, so the profile compile never picks a clang unless one
## is named explicitly, and the only clang env.ps1 can provision (the LLVM
## release, behind `WINDOWS_DIY_HCR_TESTS`) draws its temporary names from
## `CryptGenRandom`, not `arc4random` (llvm/lib/Support/Windows/Process.inc).
## The hosts that run this gate are home-pc (Linux) and m1 (macOS).

import std/[options, os, strutils, tables, unittest]

import repro_build_engine
import repro_profile_intent
import repro_profile_compile
from repro_core/c_compiler import cCompilerFamily, clangNoTempFileFlag
from repro_core/entropy_blessings import entropyBlessedTool,
  entropyBlessingImageKey

import repro_test_support/reasoned_skip

import ./profile_compile_edge_harness
from ./exec_without_arg import ExecWithoutArgConfName
from repro_test_support import requireBinary

const nullDevice = when defined(windows): "NUL" else: "/dev/null"

proc execWithoutArgBinary(): string =
  ## The graph-built argument-dropping wrapper (`exec_without_arg.nim`).
  requireBinary(ProjectRoot / "build" / "test-bin" /
    addFileExt("exec_without_arg", ExeExt),
    "reprobuild.test_helpers.exec_without_arg")

const ClangProfile = """
import repro_profile

template publishedFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources,
    hostFile = "~/clang-first-run.txt",
    content = "published")

profile "clangFirstRunPublished":
  resources:
    publishedFile()
"""

proc findClang(): string =
  ## Apple clang must exercise macOS's dependency-file implementation;
  ## a Nix clang would silently miss the regression on this platform.
  when defined(macosx):
    let apple = "/Library/Developer/CommandLineTools/usr/bin/clang"
    doAssert fileExists(apple) and cCompilerFamily(apple) == "clang",
      "this macOS gate needs Apple CommandLineTools clang"
    return apple
  else:
    ## Else the first clang on PATH (clang, else a cc that is clang).
    for name in ["clang", "cc"]:
      let exe = findExe(name)
      if exe.len > 0 and cCompilerFamily(exe) == "clang":
        return exe
    ""

proc isClangImage(image: string): bool =
  ## Whether `image` is a clang compiler driver: base name `clang`,
  ## `clang++`, or `clang-<major>` (how a Nix clang's unwrapped binary is
  ## named). Deliberately not a prefix match: the control's argument-dropping
  ## wrapper is `clang-without-no-temp-file`, and a draw of ITS would say
  ## nothing about clang.
  let key = entropyBlessingImageKey(image)
  if key in ["clang", "clang++"]:
    return true
  const versioned = "clang-"
  if key.startsWith(versioned) and key.len > versioned.len:
    for c in key[versioned.len .. ^1]:
      if c notin Digits:
        return false
    return true
  false

proc describe(observation: EntropyObservation): string =
  observation.source & " from " &
    (if observation.image.len > 0: observation.image else: "<unattributed>")

proc clangDraws(edge: ProfileEdgeOutcome): seq[string] =
  ## The edge's entropy records emitted by a clang driver.
  for observation in edge.entropyObservations:
    if isClangImage(observation.image):
      result.add(observation.describe())

proc unexcusedDraws(edge: ProfileEdgeOutcome): seq[string] =
  ## The edge's entropy records no per-image blessing (`EntropyBlessedTools`)
  ## excuses. An unattributed record (empty image) is one of them, as it is
  ## for the engine: a draw whose author cannot be named might be clang's.
  for observation in edge.entropyObservations:
    if entropyBlessedTool(observation.image).isNone:
      result.add(observation.describe())

proc allDraws(edge: ProfileEdgeOutcome): string =
  var parts: seq[string] = @[]
  for observation in edge.entropyObservations:
    parts.add(observation.describe())
  parts.join("; ")

proc checkIntent(art: ProfileCompileArtifact) =
  let intent = decodeRbpi(art.rbpiBytes)
  check intent.resources.len == 1
  if intent.resources.len == 1:
    check intent.resources[0].kind == "fs.userFile"
    check intent.resources[0].fields["content"].s == "published"

proc lastCompileLine(sb: ProfileSandbox): string =
  ## The most recent `nim c` argv the spy logged.
  if fileExists(sb.spyLog):
    for line in readFile(sb.spyLog).splitLines():
      if line.startsWith("nim c "):
        result = line

template withCompileEnv(sb: ProfileSandbox; cc: string; body: untyped) =
  ## The test process's environment, with the spy first on `PATH`, `cc` as
  ## `$REPRO_BOOTSTRAP_CC`, and no `$REPRO_NIM_COMPILER` (the edge would take
  ## it over the spy; the spy forwards to that compiler instead). Restored
  ## afterwards.
  let savedPath = getEnv("PATH")
  let hadBootstrap = existsEnv("REPRO_BOOTSTRAP_CC")
  let savedBootstrap = getEnv("REPRO_BOOTSTRAP_CC")
  let hadNim = existsEnv(ProfileNimCompilerEnvVar)
  let savedNim = getEnv(ProfileNimCompilerEnvVar)
  putEnv("PATH", sb.spyDir & $PathSep & savedPath)
  putEnv("REPRO_BOOTSTRAP_CC", cc)
  delEnv(ProfileNimCompilerEnvVar)
  try:
    body
  finally:
    putEnv("PATH", savedPath)
    if hadBootstrap: putEnv("REPRO_BOOTSTRAP_CC", savedBootstrap)
    else: delEnv("REPRO_BOOTSTRAP_CC")
    if hadNim: putEnv(ProfileNimCompilerEnvVar, savedNim)

suite "profile compile edge: a clang compile is published on its first run":

  test "e2e_profile_compile_clang_first_run_published":
    when defined(windows):
      skip("[platform N/A] Nim's default C compiler on Windows is MinGW gcc " &
        "and Windows LLVM names temporaries without arc4random; the defect " &
        "is POSIX clang's. Runs on home-pc (Linux) and m1 (macOS, GM0m)")
    else:
      let clang = findClang()
      doAssert clang.len > 0,
        "needs a clang on PATH (enter reprobuild's dev shell)"
      checkpoint("clang: " & clang)
      let sb = newProfileSandbox("clang-first-run", ClangProfile)
      defer: sb.dispose()
      let opts = ProfileCompileOptions(stateDir: sb.stateDir,
        publicCliPath: reproBinary(), repoRoot: ProjectRoot)
      withCompileEnv(sb, clang):
        let first = compileProfileToRbpi(sb.profilePath, opts)
        checkpoint("first: decision=" & $first.cacheDecision &
          " publishSkip=" & first.cachePublishSkipReason)
        check first.edgeLaunched
        checkIntent(first)
        let compileLine = sb.lastCompileLine()
        checkpoint("nim argv: " & compileLine)
        check ("--cc:clang") in compileLine
        check ("--clang.exe:" & clang) in compileLine
        check ("--passC:" & clangNoTempFileFlag) in compileLine
        check ("--passC:-MD -MT " & ProfileDepfileTarget &
          " -Xclang -dependency-file -Xclang " & nullDevice) in compileLine
        check "--forceBuild:on" in compileLine
        var objectCount = 0
        for path in walkDirRec(sb.stateDir / "profile-cache"):
          check not path.endsWith(".d")
          check not path.endsWith(".d.tmp")
          if path.endsWith(".o"): inc objectCount
        check objectCount > 0
        # The flags removed clang's draw: the compile edge -- where clang
        # runs -- observed none from a clang image, and none that only its
        # action blessing excuses. (The blessing would excuse a draw; this
        # checks there is none to excuse.) A Nix clang wrapper's `mktemp`
        # may draw here; the per-image table excuses that one.
        checkpoint("compile entropy: " & first.compileEdge.allDraws())
        check first.compileEdge.clangDraws().len == 0
        check first.compileEdge.unexcusedDraws().len == 0
        # Whatever else macOS monitoring may refuse, clang's entropy draw is
        # not a reason any more.
        check "entropy" notin first.cachePublishSkipReason
        let failedClosed = EdgeMayFailClosed and
          first.cachePublishSkipReason.len > 0
        if not failedClosed:
          check first.cachePublishSkipReason.len == 0

        let spawnsBefore = sb.nimSpawnCount()
        let second = compileProfileToRbpi(sb.profilePath, opts)
        checkpoint("second: decision=" & $second.cacheDecision &
          " miss=" & second.cacheMissReason)
        if failedClosed:
          echo "    [fail-closed, GM0m] clang first run: publish skipped (",
            first.cachePublishSkipReason, "); the unchanged run re-ran"
          check second.edgeLaunched
        else:
          check second.cacheDecision == cdHit
          check not second.edgeLaunched
          check sb.nimSpawnCount() == spawnsBefore
        checkIntent(second)

  test "positive control: a clang that drops -fno-temp-file draws entropy":
    when defined(windows):
      skip("[platform N/A] see the primary case: the defect is POSIX " &
        "clang's. Runs on home-pc (Linux) and m1 (macOS, GM0m)")
    else:
      let clang = findClang()
      doAssert clang.len > 0,
        "needs a clang on PATH (enter reprobuild's dev shell)"
      let sb = newProfileSandbox("clang-drops-flag", ClangProfile)
      defer: sb.dispose()
      # Removes the flag and execs the same clang with everything else. The
      # probe's compile goes through it too and succeeds, so nim is still
      # handed `--passC:-fno-temp-file`: the one difference from the primary
      # case is that clang never sees it.
      let wrapperDir = sb.root / "cc-bin"
      createDir(wrapperDir)
      let wrapper = wrapperDir / addFileExt("clang-without-no-temp-file",
        ExeExt)
      copyFileWithPermissions(execWithoutArgBinary(), wrapper)
      writeFile(wrapperDir / ExecWithoutArgConfName,
        clang & "\n" & clangNoTempFileFlag & "\n")
      let opts = ProfileCompileOptions(stateDir: sb.stateDir,
        publicCliPath: reproBinary(), repoRoot: ProjectRoot)
      withCompileEnv(sb, wrapper):
        let first = compileProfileToRbpi(sb.profilePath, opts)
        checkpoint("first: decision=" & $first.cacheDecision &
          " publishSkip=" & first.cachePublishSkipReason)
        check first.edgeLaunched
        checkIntent(first)
        check ("--passC:" & clangNoTempFileFlag) in sb.lastCompileLine()
        # The monitor sees clang's OWN draw in the compile edge, attributed
        # to the clang image -- not merely some draw, which a Nix clang
        # wrapper's `mktemp` would supply on its own ...
        checkpoint("compile entropy: " & first.compileEdge.allDraws())
        check first.compileEdge.clangDraws().len > 0
        # ... which no per-image blessing excuses (the pre-split gate's
        # `unblessed-entropy` publish skip) ...
        check first.compileEdge.unexcusedDraws().len > 0
        # ... and the compile edge's blessing excuses it.
        check "entropy" notin first.compileEdge.cachePublishSkipReason
        let failedClosed = EdgeMayFailClosed and
          first.compileEdge.cachePublishSkipReason.len > 0
        let second = compileProfileToRbpi(sb.profilePath, opts)
        checkpoint("second: decision=" & $second.cacheDecision &
          " miss=" & second.cacheMissReason)
        if not failedClosed:
          check second.compileEdge.cacheDecision == cdHit
          check not second.compileEdge.launched
        checkIntent(second)

  test "Apple clang dependency temporaries are independently observable":
    when defined(macosx):
      let clang = findClang()
      doAssert clang == "/Library/Developer/CommandLineTools/usr/bin/clang",
        "this macOS regression requires Apple CommandLineTools clang"
      let sb = newProfileSandbox("clang-depfile-control", ClangProfile)
      defer: sb.dispose()
      let wrapperDir = sb.root / "cc-bin"
      createDir(wrapperDir)
      let wrapper = wrapperDir / "clang-with-depfiles"
      copyFileWithPermissions(execWithoutArgBinary(), wrapper)
      writeFile(wrapperDir / ExecWithoutArgConfName,
        clang & "\n-Xclang\n-dependency-file\n" & nullDevice & "\n")
      let opts = ProfileCompileOptions(stateDir: sb.stateDir,
        publicCliPath: reproBinary(), repoRoot: ProjectRoot)
      withCompileEnv(sb, wrapper):
        let first = compileProfileToRbpi(sb.profilePath, opts)
        check first.edgeLaunched
        checkIntent(first)
        # Dependency-file output restored: Apple clang's temporary-name draw
        # is back in the compile edge's evidence, attributed to clang, and
        # excused by the edge's blessing.
        checkpoint("compile entropy: " & first.compileEdge.allDraws())
        check first.compileEdge.clangDraws().len > 0
        check "entropy" notin first.compileEdge.cachePublishSkipReason
        check ("--passC:" & clangNoTempFileFlag) in sb.lastCompileLine()
    else:
      skip("[platform N/A] dependency-file temporary entropy is Apple clang's " &
        "macOS behavior; this control runs against Apple clang on m1")

  test "C header changes reach intent with a warm Nim cache":
    let compiler = when defined(windows): findExe("gcc") else: findClang()
    doAssert compiler.len > 0, "needs the dev shell's real C compiler"
    let profileText = """
import repro_profile
{.compile: "value.c".}
proc currentValue(): cint {.importc: "current_value".}
template publishedFile(targetResources: var seq[ResourceIntent]) =
  fsUserFile(targetResources, hostFile = "~/header-value.txt",
    content = $currentValue())
profile "headerValue":
  resources:
    publishedFile()
"""
    let sb = newProfileSandbox("clang-header-warm", profileText)
    defer: sb.dispose()
    sb.writeProfileFile("value.c", "#include \"value.h\"\nint current_value(void) { return PROFILE_VALUE; }\n")
    sb.writeProfileFile("value.h", "#define PROFILE_VALUE 11\n")
    let opts = ProfileCompileOptions(stateDir: sb.stateDir,
      publicCliPath: reproBinary(), repoRoot: ProjectRoot)
    withCompileEnv(sb, compiler):
      let first = compileProfileToRbpi(sb.profilePath, opts)
      check first.edgeLaunched
      check decodeRbpi(first.rbpiBytes).resources[0].fields["content"].s == "11"
      var firstObservedHeader = false
      for path in first.observedInputs:
        if path.endsWith("value.h"): firstObservedHeader = true
      check firstObservedHeader
      let spawnCount = sb.nimSpawnCount()
      sb.writeProfileFile("value.h", "#define PROFILE_VALUE 22\n")
      let changed = compileProfileToRbpi(sb.profilePath, opts)
      check changed.edgeLaunched
      check sb.nimSpawnCount() > spawnCount
      check decodeRbpi(changed.rbpiBytes).resources[0].fields["content"].s == "22"
      var changedObservedHeader = false
      for path in changed.observedInputs:
        if path.endsWith("value.h"): changedObservedHeader = true
      check changedObservedHeader
      check "--forceBuild:on" in sb.lastCompileLine()
