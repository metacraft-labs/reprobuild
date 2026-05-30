## M69 — apply pipeline phase A unit gate.
##
## Fixture: a `home.nim` with three package references — two known
## (`jdk@21.0.5`, `maven`) and one unknown (`nonexistent-tool-xyz`).
## Drive the planner + the catalog-lookup resolver and verify:
##
##   1. The planner extracts the three package references with the
##      correct `requestedVersion` strings.
##   2. The catalog-lookup resolver picks the right slice for the
##      two known packages.
##   3. The unknown package fails closed with `EUnknownPackageId`.
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
import repro_home_apply/catalog_lookup
import repro_home_apply/env_binding
import repro_home_apply/realize

const TmpDir = "build/test-tmp/m69-apply-e2e"

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

proc fakeRealizedFromCatalog(packageId: string;
                             slice: LookedUpSlice): RealizedRecord =
  ## Fake the M64 cakBuiltin realize outcome WITHOUT downloading
  ## anything. The fields the apply pipeline cares about post-realize
  ## (`packageId`, `prefixAbsolutePath`, `resolvedExecutablePath`,
  ## `envBindings`) are all derivable from the lookup result plus a
  ## synthetic prefix dir. The full M64 realizer is exercised by
  ## `t_builtin_adapter.nim` (existing M64 unit gate).
  let prefix = TmpDir / "fake-prefix" / packageId & "-" & slice.resolvedVersion
  createDir(prefix)
  for bin in slice.slice.bin_relpath:
    createDir(prefix / bin.parentDir)
    writeFile(prefix / bin, "stub")
  result.packageId = packageId
  result.adapter = akBuiltin
  result.prefixAbsolutePath = prefix
  if slice.slice.bin_relpath.len > 0:
    result.resolvedExecutablePath = prefix / slice.slice.bin_relpath[0]
  result.resolvedVersion = slice.resolvedVersion
  for k, v in slice.slice.env.pairs:
    var sub = v
    sub = sub.replace("${prefix}", prefix)
    result.envBindings.add((name: k, value: sub))

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

  test "catalog-lookup resolves the two known packages":
    let jdkSlice = lookupCatalogSlice("jdk", "21.0.5")
    check jdkSlice.resolvedVersion == "21.0.5"
    let mavenSlice = lookupCatalogSlice("maven")
    check mavenSlice.resolvedVersion.len > 0
    check mavenSlice.packageId == "maven"

  test "catalog-lookup fails closed on the unknown package":
    var raised = false
    try:
      discard lookupCatalogSlice("nonexistent-tool-xyz")
    except EUnknownPackageId as err:
      raised = true
      check err.packageId == "nonexistent-tool-xyz"
    check raised

  test "synthesized env-binding plan carries PATH for both realized packages":
    resetTmp()
    let jdkSlice = lookupCatalogSlice("jdk", "21.0.5")
    let mavenSlice = lookupCatalogSlice("maven")
    let realized = @[
      fakeRealizedFromCatalog("jdk", jdkSlice),
      fakeRealizedFromCatalog("maven", mavenSlice),
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
    # JDK declares JAVA_HOME in its catalog env block; verify the
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
