## M69 — apply pipeline phase A unit gate.
##
## Fixture: a `home.nim` with three package references — two known
## (`jdk@21.0.5`, `maven`) and one unknown (`nonexistent-tool-xyz`).
## Drive the planner + the profile resolver (GM4b: `resolveProfilePackage`,
## which replaced M69's catalog lookup) for an x86_64-windows target and
## verify:
##
##   1. The planner extracts the three package references with the
##      correct `requestedVersion` strings.
##   2. The resolver selects the right realization for the two known
##      packages (jdk at the pinned version, maven at its default).
##   3. The unknown package fails closed as an unknown package.
##   4. The synthesized env-binding plan (M69 step 5) includes one
##      PATH record per known package, so a downstream apply WOULD
##      add both bin dirs to the user's PATH.
##
## This is the PLAN-LEVEL gate. The full apply (which would actually
## download JDK + Maven into a sandboxed CAS) is the e2e test under
## `tests/e2e/m69/`. Splitting plan-from-execute keeps this gate fast
## and side-effect-free (no HKCU writes, no GBs of downloads).

import std/[os, strutils, tables, unittest]

import repro_home_intent
import repro_home_resources
import repro_home_apply/plan
import repro_home_apply/package_catalog
import repro_home_apply/env_binding
import repro_home_apply/realize
import repro_home_apply/builtin_adapter
from repro_test_support import testCaseScratchSlug

let TmpDir = "build/test-tmp/m69-apply-e2e" / testCaseScratchSlug()

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

let windowsX64 = realizationTargetFor(pcX86_64, poWindows, mlX86_64_v1)

proc resolveForWindows(packageId: string; version = ""):
    ProfilePackageResolution =
  resolveProfilePackage(packageId, windowsX64, DefaultSelectionPolicy,
    requestedVersion = version)

proc fakeRealized(r: ProfilePackageResolution): RealizedRecord =
  ## Fake the realize outcome WITHOUT downloading anything: a synthetic
  ## prefix holding stub executables at the selected realization's paths,
  ## and its `env` with `${prefix}` substituted as both realizers do
  ## (`builtin_adapter.substituteEnv`). The realizers themselves are
  ## exercised by `t_builtin_adapter*.nim` and
  ## `t_realize_honors_requested_version.nim`.
  let record = r.selection.tarball
  let prefix = TmpDir / "fake-prefix" / r.packageId & "-" & r.selection.version
  createDir(prefix)
  for bin in @[record.executablePath] & record.detail.extraExecutables:
    let rel = bin.replace('\\', '/')
    createDir(prefix / rel.parentDir)
    writeFile(prefix / rel, "stub")
  result.packageId = r.packageId
  result.adapter = akBuiltin
  result.prefixAbsolutePath = prefix
  result.resolvedExecutablePath = prefix / record.executablePath.replace('\\', '/')
  result.resolvedVersion = r.selection.version
  var raw: seq[tuple[name, value: string]] = @[]
  for binding in record.detail.env:
    let eq = binding.find('=')
    raw.add((name: binding[0 ..< eq], value: binding[eq + 1 .. ^1]))
  result.envBindings = substituteEnv(raw, prefix)

suite "M69 apply pipeline (plan + resolve phase)":

  test "planner extracts three references with correct versions":
    resetTmp()
    let profilePath = TmpDir / "home.nim"
    writeFile(profilePath, """import repro/profile

profile "rt":
  activity dev:
    package(jdk, "21.0.5")
    package(maven)
    package(nonexistent-tool-xyz)
  hosts:
    "test-host": [dev]
""")
    let parsed = loadProfile(profilePath)
    let plan = buildPlan(parsed, TmpDir, "test-host")
    check plan.packages.len == 3
    var byName: seq[(string, string)]
    for p in plan.packages:
      byName.add((p.packageId, p.requestedVersion))
    check ("jdk", "21.0.5") in byName
    check ("maven", "") in byName
    check ("nonexistent-tool-xyz", "") in byName

  test "the resolver selects realizations for the two known packages":
    let jdk = resolveForWindows("jdk", "21.0.5")
    check jdk.selection.kind == rkTarball
    check jdk.selection.version == "21.0.5"
    let maven = resolveForWindows("maven")
    check maven.selection.kind == rkTarball
    check maven.selection.version.len > 0
    check maven.packageId == "maven"

  test "the resolver fails closed on the unknown package":
    var raised = false
    try:
      discard resolveForWindows("nonexistent-tool-xyz")
    except EMissingRealization as err:
      raised = true
      check err.packageName == "nonexistent-tool-xyz"
      check not err.definitionKnown
    check raised

  test "synthesized env-binding plan carries PATH for both realized packages":
    resetTmp()
    let realized = @[
      fakeRealized(resolveForWindows("jdk", "21.0.5")),
      fakeRealized(resolveForWindows("maven")),
    ]
    let bindings = planEnvBindings(realized)
    var pathAddresses: seq[string]
    for r in bindings.resources:
      if r.kind == rkEnvUserPath:
        pathAddresses.add r.address
    check "home.package.jdk.bin" in pathAddresses
    check "home.package.maven.bin" in pathAddresses
    # Both bin dirs are recorded for the downstream PATH binding.
    check bindings.binDirs.len >= 2
    var binDirsJoined = ""
    for d in bindings.binDirs:
      binDirsJoined.add(d & "|")
    check "jdk-21.0.5" in binDirsJoined
    check "maven-" in binDirsJoined
    # JDK's realization declares JAVA_HOME in its env; verify the
    # synthesized env.userVariable record carries the substituted
    # value (i.e. the realized prefix, not the literal `${prefix}`).
    var foundJavaHome = false
    for r in bindings.resources:
      if r.kind == rkEnvUserVariable and r.envVarName == "JAVA_HOME":
        foundJavaHome = true
        let bytes = r.envVarPayload.bytes
        var asStr = ""
        for b in bytes:
          if b > 0 and b < 128:
            asStr.add(char(b))
        # The value is UTF-16LE encoded for REG_SZ. ASCII chars
        # appear at even indices (LE encoding); odd-index zeros are
        # the high bytes. The decoded value contains the realized
        # prefix path.
        check "jdk-21.0.5" in asStr
    check foundJavaHome
