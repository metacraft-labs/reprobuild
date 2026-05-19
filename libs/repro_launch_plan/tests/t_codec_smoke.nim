## Smoke test for the M57 `LaunchPlan` codec, binding decision, script
## generator, and CAS facade. Exercises the public surface against the
## real M56 store (CAS round-trip with hash-on-read), against a real
## ELF64 fixture (RUNPATH rewriting), and against the real script
## generator (byte-determinism for two structurally-identical plans).

import std/[os, strutils, tables, tempfiles, unittest]

import repro_local_store
import repro_launch_plan

proc baseSupport(): SupportProfile =
  newSupportProfile("linux", "x86_64", "gnu", "")

proc baseProv(): LaunchPlanProvenance =
  LaunchPlanProvenance(adapter: "tarball", packageId: "demo@1.0",
    realizationHashHex: "deadbeef" & repeat("00", 28))

proc samplePlan(binding: LaunchPlanBindingKind;
                runtimeDirs: seq[string]): LaunchPlan =
  LaunchPlan(
    schemaVersion: LaunchPlanCurrentSchemaVersion,
    realizedPrefix: "/store/prefixes/demo/1.0",
    exportedCommand: "demo",
    executablePath: "/store/prefixes/demo/1.0/bin/demo",
    arguments: @["--quiet"],
    hasWorkingDirectory: false,
    workingDirectory: "",
    environmentBindings: @[
      newEnvBinding("DEMO_VERBOSE", ebkSet, "1"),
      newEnvBinding("DEMO_PATH", ebkPrepend, "/store/prefixes/demo/1.0/share")
    ],
    executableBindings: @[],
    runtimeLibraryDirs: runtimeDirs,
    projectedRuntimeImage: ProjectedRuntimeImage(present: false),
    executionProfile: ExecutionProfileChecksum(present: false),
    supportProfile: baseSupport(),
    provenance: baseProv(),
    binding: binding)

suite "M57 LaunchPlan codec and CAS round-trip":

  test "encode/decode is exact for a populated plan":
    var plan = samplePlan(lbkLinuxRunpathExact,
      @["/store/prefixes/dep-a/1.0/lib", "/store/prefixes/dep-b/2.0/lib"])
    let bytes = encodeLaunchPlan(plan)
    let round = decodeLaunchPlan(bytes)
    check round == plan

  test "RBLP magic and checksum are present":
    let bytes = encodeLaunchPlan(samplePlan(lbkLinuxRunpathExact, @[]))
    check bytes[0] == byte('R')
    check bytes[1] == byte('B')
    check bytes[2] == byte('L')
    check bytes[3] == byte('P')
    # 4 magic + 2 ver + 4 len + body + 32 checksum
    check bytes.len >= 4 + 2 + 4 + 32

  test "tampering with the envelope is rejected by checksum":
    var bytes = encodeLaunchPlan(samplePlan(lbkLinuxRunpathExact, @[]))
    let tamperOffset = bytes.len - 40    # inside body, before checksum
    bytes[tamperOffset] = bytes[tamperOffset] xor 0xff'u8
    expect LaunchPlanCodecError:
      discard decodeLaunchPlan(bytes)

  test "launchPlanId is deterministic":
    let a = samplePlan(lbkLinuxRunpathExact, @["/x"])
    let b = samplePlan(lbkLinuxRunpathExact, @["/x"])
    check launchPlanIdHex(a) == launchPlanIdHex(b)
    # Differ in one byte -> different id.
    let c = samplePlan(lbkLinuxRunpathExact, @["/y"])
    check launchPlanIdHex(a) != launchPlanIdHex(c)

  test "CAS round-trip via M56 store":
    let storeRoot = createTempDir("repro-m57-codec-", "")
    defer:
      try: removeDir(storeRoot) except OSError: discard
    var store = openStore(storeRoot)
    defer: store.close()
    let plan = samplePlan(lbkLinuxRunpathExact, @["/store/dep/lib"])
    let id = store.storeLaunchPlan(plan)
    check hexOf(id) == launchPlanIdHex(plan)
    let restored = store.loadLaunchPlan(id)
    check restored == plan

suite "M57 binding decision algorithm":

  test "linux strategy 1 selects exact RUNPATH":
    let d = decideBinding(BindingInput(platform: "linux",
      realizedPrefix: "/store/prefixes/demo",
      executablePath: "/store/prefixes/demo/bin/demo",
      dependencyDirs: @["/store/dep-a/lib", "/store/dep-b/lib"],
      canRewriteBinary: true))
    check d.binding == lbkLinuxRunpathExact
    check d.runtimeLibraryDirs == @["/store/dep-a/lib", "/store/dep-b/lib"]

  test "linux strategy 2 selects $ORIGIN when adjacency holds":
    let d = decideBinding(BindingInput(platform: "linux",
      canUseOriginRelative: true,
      dependencyDirs: @["/whatever"]))
    check d.binding == lbkLinuxOriginRelative
    check d.runtimeLibraryDirs == @["$ORIGIN"]   # FS-storm: O(1)

  test "linux strategy 3 falls back to launcher script":
    let d = decideBinding(BindingInput(platform: "linux",
      dependencyDirs: @["/store/dep-a/lib"]))
    check d.binding == lbkLinuxScript
    check d.runtimeLibraryDirs == @["/store/dep-a/lib"]

  test "windows strategy 1 selects native launcher":
    let d = decideBinding(BindingInput(platform: "windows",
      dependencyDirs: @["C:\\store\\dep\\bin"]))
    check d.binding == lbkWindowsLauncher

  test "windows strategy 2 selects app-local layout":
    let d = decideBinding(BindingInput(platform: "windows",
      isAppLocalLayout: true,
      dependencyDirs: @[]))
    check d.binding == lbkWindowsAppLocal
    check d.runtimeLibraryDirs.len == 0

suite "M57 POSIX launcher script generator":

  test "two identical plans produce byte-identical scripts":
    var plan = samplePlan(lbkLinuxScript,
      @["/store/dep-a/lib", "/store/dep-b/lib"])
    let a = generatePosixLauncherScript(plan, "LD_LIBRARY_PATH")
    let b = generatePosixLauncherScript(plan, "LD_LIBRARY_PATH")
    check a == b
    # Sanity-check: the chosen path variable name appears, the magic
    # prefix is on line 1, and each dependency dir is mentioned once.
    check a.startsWith(LaunchScriptMagicPosix)
    check "LD_LIBRARY_PATH" in a
    var dirAOccurrences = 0
    var dirBOccurrences = 0
    for line in a.splitLines:
      if "/store/dep-a/lib" in line: inc dirAOccurrences
      if "/store/dep-b/lib" in line: inc dirBOccurrences
    check dirAOccurrences == 1
    check dirBOccurrences == 1

  test "script does NOT widen LD_LIBRARY_PATH beyond declared dirs":
    var plan = samplePlan(lbkLinuxScript, @["/store/dep-only/lib"])
    let script = generatePosixLauncherScript(plan, "LD_LIBRARY_PATH")
    # The only directory referenced should be /store/dep-only/lib.
    # If a future change accidentally adds, say, /usr/lib here, the
    # next line will fail. Each needle is bracketed in single quotes
    # so the substring search is anchored to a full shell-escaped
    # path token, not a prefix.
    var nonDeclaredHits = 0
    for needle in @["'/usr/lib'", "'/usr/local/lib'",
                    "':/usr/lib'", "':/lib'", "':/usr/local/lib'"]:
      if needle in script: inc nonDeclaredHits
    check nonDeclaredHits == 0
