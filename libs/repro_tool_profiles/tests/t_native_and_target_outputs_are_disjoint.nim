## A native build and a `--target` build of one recipe never read or
## overwrite each other's `.repro/output/` entries.
##
## ReproOS-Add-On-Mode A15. The install mirror was keyed by the target first
## (`install@<triple>`); the per-artifact staging directories the from-source
## resolver falls back to (`.repro/output/<name>/<name>`), the realization
## sidecar (`.realization-info`) and the propagated-libdir remap in the rpath
## script were not, so a cross build left ARM bytes where a later native
## consumer looked, and the last build's sidecar marked the other build's
## mirror stale. Every one of them now goes through `targetKeyedOutputName`.
##
## Nothing is mocked: the cases build a real recipe directory on disk and
## drive the resolver, the sidecar writer/reader and the tool-profile
## enumeration over it, with the target set the way `--target` sets it
## (`REPRO_VARIANTS`). Each case reads one side after the other side wrote,
## in both orders.

import std/[os, strutils, unittest]

import repro_project_dsl/install_mirror_resolver
import repro_project_dsl/install_mirror_runtime
import repro_tool_profiles

const
  Triple = "armv7-unknown-linux-musleabihf"
  Hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

proc withVariants(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", value) else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved) else: delEnv("REPRO_VARIANTS")

proc native(body: proc()) = withVariants("", body)
proc cross(body: proc()) = withVariants("targetTriple=" & Triple, body)

proc freshRecipes(): string =
  result = getTempDir() / ("t_disjoint_outputs_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result / "openssl" / ".repro" / "output")
  writeFile(result / "openssl" / "repro.nim", "")

proc stage(recipes, entry, name, content: string) =
  let dir = recipes / "openssl" / ".repro" / "output" / entry
  createDir(dir)
  writeFile(dir / name, content)
  # A staged executable is executable; the probe accepts a bare name only
  # with an exec bit.
  setFilePermissions(dir / name, {fpUserRead, fpUserWrite, fpUserExec})

proc resolvedPaths(recipeDir: string): seq[string] =
  for c in m9r14dEnumerateArtifacts(recipeDir):
    if c.resolvedPath.len > 0:
      result.add(c.resolvedPath)

suite "one rule for every entry a build writes under .repro/output":

  test "native names are unchanged, target names carry the triple":
    native(proc() =
      check targetKeyedOutputName("openssl") == "openssl"
      check targetKeyedOutputName(RealizationInfoFileName) == ".realization-info")
    cross(proc() =
      check targetKeyedOutputName("openssl") == "openssl@" & Triple
      check targetKeyedOutputName(RealizationInfoFileName) ==
        ".realization-info@" & Triple)

  test "an entry name splits back into its name and its target":
    check outputEntryTarget("openssl") == ("openssl", "")
    check outputEntryTarget("openssl@" & Triple) == ("openssl", Triple)
    check outputEntryTarget("install@" & Triple) == ("install", Triple)

  test "the stage-copy candidate the convention reads is keyed too":
    native(proc() =
      check fromSourceArtifactCandidate("/r", "openssl", "openssl") ==
        "/r/openssl/.repro/output/openssl/openssl")
    cross(proc() =
      check fromSourceArtifactCandidate("/r", "openssl", "openssl") ==
        "/r/openssl/.repro/output/openssl@" & Triple & "/openssl")

suite "the per-artifact staging directories":

  test "each build enumerates only its own artifacts, in both orders":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    let recipeDir = recipes / "openssl"
    stage(recipes, "openssl", "openssl", "x86-64")
    stage(recipes, "openssl@" & Triple, "openssl", "armv7")
    native(proc() =
      let got = resolvedPaths(recipeDir)
      check got.len == 1
      check readFile(got[0]) == "x86-64"
      check ("@" & Triple) notin got[0])
    cross(proc() =
      let got = resolvedPaths(recipeDir)
      check got.len == 1
      check readFile(got[0]) == "armv7"
      check got[0].contains("openssl@" & Triple))

  test "a target build alone leaves nothing for a native read":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    stage(recipes, "openssl@" & Triple, "openssl", "armv7")
    native(proc() =
      check resolvedPaths(recipes / "openssl").len == 0
      check not fileExists(fromSourceArtifactCandidate(recipes, "openssl",
        "openssl")))

  test "a native build alone leaves nothing for a target read":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    stage(recipes, "openssl", "openssl", "x86-64")
    cross(proc() =
      check resolvedPaths(recipes / "openssl").len == 0
      check not fileExists(fromSourceArtifactCandidate(recipes, "openssl",
        "openssl")))

  test "a nativeBuildDeps read under --target sees the native artifact":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    stage(recipes, "openssl", "openssl", "x86-64")
    stage(recipes, "openssl@" & Triple, "openssl", "armv7")
    cross(proc() =
      withInstallMirrorTarget(""):
        let got = resolvedPaths(recipes / "openssl")
        check got.len == 1
        check readFile(got[0]) == "x86-64")

suite "the realization sidecar":

  test "native then target: two files, the native one untouched":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    var nativePath, nativeBefore = ""
    native(proc() =
      writeRealizationInfoFile(recipes, "openssl", "3.4.0", Hash)
      nativePath = realizationInfoPath(recipes, "openssl")
      nativeBefore = readFile(nativePath)
      check realizationInfoMatchesCurrentPlatform(recipes / "openssl"))
    cross(proc() =
      writeRealizationInfoFile(recipes, "openssl", "3.4.0", Hash)
      let crossPath = realizationInfoPath(recipes, "openssl")
      check crossPath != nativePath
      check crossPath.endsWith(".realization-info@" & Triple)
      check readFile(crossPath).contains("@" & Triple)
      check realizationInfoMatchesCurrentPlatform(recipes / "openssl"))
    check readFile(nativePath) == nativeBefore
    native(proc() =
      # The target build did not mark the native mirror stale.
      check realizationInfoMatchesCurrentPlatform(recipes / "openssl")
      check readRealizationInfoFile(recipes, "openssl").platformTag ==
        currentRealizationPlatformTag())

  test "target then native: the target sidecar survives the native build":
    let recipes = freshRecipes()
    defer: removeDir(recipes)
    var crossPath, crossBefore = ""
    cross(proc() =
      writeRealizationInfoFile(recipes, "openssl", "3.4.0", Hash)
      crossPath = realizationInfoPath(recipes, "openssl")
      crossBefore = readFile(crossPath))
    native(proc() =
      writeRealizationInfoFile(recipes, "openssl", "3.4.0", Hash)
      check realizationInfoPath(recipes, "openssl") != crossPath)
    check readFile(crossPath) == crossBefore
    cross(proc() =
      check realizationInfoMatchesCurrentPlatform(recipes / "openssl"))

suite "the propagated-libdir remap in the rpath script":

  test "a target build remaps into the target mirror, never the native one":
    var nativeScript, crossScript = ""
    native(proc() =
      nativeScript = m9r14fEmitRpathPatchScript("/dst/usr", @[],
        depManifestPaths = @["/m.txt"], recipesRoot = "/r"))
    cross(proc() =
      crossScript = m9r14fEmitRpathPatchScript("/dst/usr", @[],
        depManifestPaths = @["/m.txt"], recipesRoot = "/r"))
    check "*/.repro/output/install/*)" in nativeScript
    check ("@" & Triple) notin nativeScript
    check ("*/.repro/output/install@" & Triple & "/*)") in crossScript
    check ("/$m9r14f_dep/.repro/output/install@" & Triple & "/$m9r14f_rel") in
      crossScript
    check "/.repro/output/install/" notin crossScript


suite "no unkeyed fallback under --target":
  test "the sibling install-tree roots drop build/out under --target":
    withVariants("", proc() =
      let roots = fromSourceInstallTreeRoots()
      check "build/out/usr" in roots and "build/out" in roots)
    withVariants("targetTriple=armv7-unknown-linux-musleabihf", proc() =
      for root in fromSourceInstallTreeRoots():
        check not root.startsWith("build/out")
        check root.startsWith(".repro/output/install@armv7-unknown-linux-musleabihf"))

  test "no source spells the unkeyed install mirror path":
    # `.repro/output/install` written out instead of `installMirrorSubpath()`
    # is the native build's mirror whatever the target (the Qt and Mesa
    # helpers of package_result.nim and from_source_custom's mirror did).
    let libs = currentSourcePath().parentDir.parentDir.parentDir
    var offenders: seq[string]
    for f in walkDirRec(libs):
      if not f.endsWith(".nim") or "/tests/" in f: continue
      let lines = readFile(f).splitLines()
      for i in 0 ..< lines.len - 1:
        let joined = lines[i].strip() & " " & lines[i + 1].strip()
        if lines[i].strip().startsWith("#"): continue
        if "\"output\" /" in joined and "\"install\"" in joined and
            "\".repro\"" in lines[i]:
          offenders.add(f & ":" & $(i + 1))
    checkpoint($offenders)
    check offenders.len == 0
