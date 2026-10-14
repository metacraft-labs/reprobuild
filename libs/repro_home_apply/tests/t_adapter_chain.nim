## GM4b — selection-policy unit tests for profile package resolution.
##
## This file used to test the M65 per-platform adapter chain. GM4b removed
## the chain: a profile reference now
## resolves through `package_catalog.resolveProfilePackage`, which projects the
## reference as a `uses:` and selects with `realization_selection.
## selectRealization` under a SELECTION POLICY — an ordered list of realization
## kinds (Provisioning-Contributions.md §"Profile Package References").
##
## What the chain tests guarded is restated for the policy:
##
##   1. The default policy is ONE order on every platform
##      (`DefaultSelectionPolicy` = tarball, nix, scoop, path); kinds a
##      platform cannot use are not removed, their records are ineligible.
##      jdk on x86_64-windows resolves to its Windows archive; jdk on
##      aarch64-macos (no macOS archive) resolves to its nixPackage.
##   2. A custom policy is honoured in order: `[scoop, tarball]` on Windows
##      records the scoop step FIRST (jdk declares no scoopApp) and then
##      selects the archive.
##   3. A package not in any definition but on the host's PATH resolves through
##      the `path` kind, from the host inventory, as an ambient selection.
##   4. A name nobody defines and PATH does not carry is an
##      `EMissingRealization` that knows it is an unknown package, and its
##      `steps` record every kind consulted, each with a reason.
##   5. `adapterPreference:` → policy: `selectionPolicyFor` maps an entry
##      (with `builtin` as the former spelling of `tarball`) and falls back to
##      the default for a missing OS key.
##
## Hermetic: every target is synthetic (`realizationTargetFor`), nothing is
## downloaded (selection is static metadata), and the only host fact used is a
## stub executable this test drops on PATH. No mocks.

import std/[options, os, strutils, tables, unittest]
from repro_core/paths import extendedPath
from repro_test_support import testCaseScratchSlug

import repro_home_apply/package_catalog
import repro_dsl_stdlib/package_registry

let FixtureRoot = "build/test-tmp/t-adapter-chain-" & testCaseScratchSlug()

proc resetDir(path: string) =
  if dirExists(extendedPath(path)):
    removeDir(extendedPath(path))
  createDir(extendedPath(path))

proc dropStubOnPath(name, body: string): string =
  ## Drop a stub executable named `name` into the fixture's `bin` dir and
  ## prepend that dir to PATH. Returns its absolute path.
  let binDir = absolutePath(FixtureRoot / "stub-bin")
  createDir(extendedPath(binDir))
  let exe =
    when defined(windows): binDir / (name & ".cmd")
    else: binDir / name
  let content =
    when defined(windows): "@echo " & body & "\n"
    else: "#!/bin/sh\necho " & body & "\n"
  writeFile(extendedPath(exe), content)
  when not defined(windows):
    discard execShellCmd("chmod +x " & quoteShell(exe))
  putEnv("PATH", binDir & PathSep & getEnv("PATH"))
  exe

let windowsX64 = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)
let macosArm = realizationTargetFor(pcAArch64, poMacos)

proc hostWithPath(): tuple[target: RealizationTarget; inv: HostInventory] =
  (hostRealizationTarget(), HostInventory(probePath: pathInventoryProbe()))

suite "GM4b — selection policy":

  test "the default policy is one order on every platform":
    check DefaultSelectionPolicy == @[rkTarball, rkNix, rkScoop, rkPath]
    for os in [poWindows, poLinux, poMacos]:
      let p = selectionPolicyFor(initOrderedTable[string, seq[string]](), os)
      check p.policy == DefaultSelectionPolicy
      check p.source == "default"

  test "jdk on x86_64-windows selects its Windows archive":
    let r = resolveProfilePackage("jdk", windowsX64, DefaultSelectionPolicy)
    check r.selection.kind == rkTarball
    check r.selection.tarball.os == "windows"
    check r.selection.version == "21.0.5"
    check r.selection.trace.len == 1
    check r.selection.trace[0].kind == rkTarball
    check r.selection.trace[0].selected
    # The jdk archive flattens an inner dir: the home archive realizer
    # owns it, and its projection carries the realization inputs.
    check r.archiveRoute == arInstaller
    check r.archive.urlUsed == r.selection.tarball.url
    check r.archive.digestAlgorithm == "sha256"
    check r.archive.extractPath == "jdk-21.0.5+11"
    check r.archive.envSubstitutions.len == 1
    check r.archive.envSubstitutions[0].name == "JAVA_HOME"

  test "jdk on aarch64-macos (no macOS archive) selects its nixPackage":
    let r = resolveProfilePackage("jdk", macosArm, DefaultSelectionPolicy)
    check r.selection.kind == rkNix
    check r.selection.nix.selector == "nixpkgs#jdk21"
    check r.selection.trace.len == 2
    check r.selection.trace[0].kind == rkTarball
    check not r.selection.trace[0].selected
    check "aarch64-macos" in r.selection.trace[0].reason
    check r.selection.trace[1].kind == rkNix
    check r.selection.trace[1].selected

  test "custom policy [scoop, tarball] is walked in order":
    let r = resolveProfilePackage("jdk", windowsX64, @[rkScoop, rkTarball])
    check r.selection.kind == rkTarball
    check r.selection.trace.len == 2
    check r.selection.trace[0].kind == rkScoop
    check not r.selection.trace[0].selected
    check r.selection.trace[0].reason.len > 0
    check r.selection.trace[1].kind == rkTarball
    check r.selection.trace[1].selected

  test "an undefined package on PATH resolves through the path kind":
    resetDir(FixtureRoot)
    let savedPath = getEnv("PATH")
    defer: putEnv("PATH", savedPath)
    let toolName = "gm4b-policy-stub-tool"
    let exe = dropStubOnPath(toolName, "hi from stub")
    let host = hostWithPath()
    let r = resolveProfilePackage(toolName, host.target,
      DefaultSelectionPolicy, inventory = host.inv)
    check r.selection.kind == rkPath
    check r.selection.ambient
    check r.selection.pathExecutable == exe or
      r.selection.pathExecutable.endsWith(extractFilename(exe))
    check r.cacheHit
    # Every declared kind was consulted (and declined) first.
    check r.selection.trace.len == 4
    for i in 0 ..< 3:
      check not r.selection.trace[i].selected
    check r.selection.trace[3].kind == rkPath
    check r.selection.trace[3].selected

  test "an unknown package not on PATH is an unknown-package miss":
    let toolName = "definitely-not-a-real-tool-xyz-789"
    let host = hostWithPath()
    var raised = false
    try:
      discard resolveProfilePackage(toolName, host.target,
        @[rkTarball, rkPath], inventory = host.inv)
    except EMissingRealization as err:
      raised = true
      check not err.definitionKnown
      check err.packageName == toolName
      check "unknown package '" & toolName & "'" in err.msg
      check err.steps.len == 2
      check err.steps[0].kind == rkTarball
      check err.steps[1].kind == rkPath
      check "not found on PATH" in err.steps[1].reason
    check raised

  test "every consulted kind records a reason":
    let host = hostWithPath()
    var steps: seq[KindOutcome]
    try:
      discard resolveProfilePackage("another-missing-tool", host.target,
        DefaultSelectionPolicy, inventory = host.inv)
    except EMissingRealization as err:
      steps = err.steps
    check steps.len == DefaultSelectionPolicy.len
    for step in steps:
      check step.reason.len > 0
      check not step.selected

  test "jdk is a linked definition; an unknown name is not":
    check isLinkedPackage("jdk")
    check not isLinkedPackage("definitely-not-registered-tool")

  test "adapterPreference maps to the policy, builtin = tarball":
    var pref = initOrderedTable[string, seq[string]]()
    pref["windows"] = @["scoop", "builtin", "path"]
    let w = selectionPolicyFor(pref, poWindows)
    check w.policy == @[rkScoop, rkTarball, rkPath]
    check w.source == "adapterPreference.windows"
    # A missing OS key falls back to the one default.
    let l = selectionPolicyFor(pref, poLinux)
    check l.policy == DefaultSelectionPolicy
    check l.source == "default"
    # An unknown kind is refused, never dropped.
    pref["darwin"] = @["homebrew"]
    expect ValueError:
      discard selectionPolicyFor(pref, poMacos)
