## A sibling source recipe resolves for its side of the host/target split.
##
## ReproOS-Add-On-Mode A15 / From-Source-Build-Recipes.md §"Package-level
## dependency declarations" and CLI/build.md §"Cross Targets: `--target`":
## under `repro build --target=<triple>` a consumer's `buildDeps:` /
## `runtimeDeps:` resolve to the sibling's TARGET build (its
## `.repro/output/install@<triple>` mirror) ahead of PATH, which can only
## hold a host build, and a `nativeBuildDeps:` entry stays PATH-first and
## reads the sibling's NATIVE build when PATH has nothing. A sibling with no
## verified target build is refused rather than answered from PATH, and a
## target mirror without its keyed `.realization-info@<triple>` sidecar is
## not a build. Without `--target` PATH answers every side.
##
## Every case goes through the dispatcher (`pathOnlyBuildIdentity`, the
## path-mode entry the CLI uses) with uses spelled by the DSL's own
## `DepKind*` constants, not string literals: the round-2 resolver compared
## `depKind` against "build", which the DSL never emits, so every library
## dependency silently went PATH-first under `--target`.
##
## Nothing is mocked: a real recipes root (`REPRO_FROM_SOURCE_ROOT`) with
## one sibling and its mirrors, and a real PATH directory holding a host
## `openssl`, are laid out in a temporary directory.

import std/[os, strutils, unittest]

import repro_interface_artifacts
import repro_project_dsl
import repro_project_dsl/install_mirror_resolver
import repro_tool_profiles

const Triple = "armv7-unknown-linux-musleabihf"

proc withEnv(name, value: string; body: proc()) =
  let had = existsEnv(name)
  let saved = getEnv(name)
  if value.len > 0: putEnv(name, value) else: delEnv(name)
  try: body()
  finally:
    if had: putEnv(name, saved) else: delEnv(name)

proc withTarget(triple: string; body: proc()) =
  withEnv("REPRO_VARIANTS",
    if triple.len > 0: "targetTriple=" & triple else: "", body)

proc writeTool(path, tag: string) =
  createDir(parentDir(path))
  writeFile(path, "#!/bin/sh\necho " & tag & "\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc writeSidecar(recipes, triple: string) =
  ## The sidecar a mirror action writes once the mirror passed the object
  ## check, in the producer's own spelling.
  withTarget(triple, proc() =
    let path = realizationInfoPath(recipes, "openssl")
    createDir(parentDir(path))
    writeFile(path, "platform=" & currentRealizationPlatformTag() & "\n"))

proc layOut(tmp: string; targetMirror, targetSidecar: bool): (string, string) =
  ## (recipes root, PATH dir). The sibling `openssl` with a native mirror
  ## and, optionally, a target mirror and its sidecar; PATH holds a host
  ## `openssl`. Each executable's text says which it is.
  let recipes = tmp / "packages" / "source"
  let dir = recipes / "openssl"
  createDir(dir)
  writeFile(dir / "repro.nim", "# the sibling recipe\n")
  writeTool(dir / ".repro/output/install/usr/bin/openssl", "native")
  writeSidecar(recipes, "")
  if targetMirror:
    writeTool(dir / (".repro/output/install@" & Triple) / "usr/bin/openssl",
      "target")
  if targetSidecar:
    writeSidecar(recipes, Triple)
  let pathDir = tmp / "path-bin"
  writeTool(pathDir / "openssl", "path")
  (recipes, pathDir)

proc use(kind: string): InterfaceToolUse =
  InterfaceToolUse(packageSelector: "openssl", executableName: "openssl",
                   rawConstraint: "openssl", depKind: kind)

proc resolve(kind, recipes, pathDir: string): string =
  ## The executable path-mode dispatch picks for one `openssl` use.
  var resolved = ""
  withEnv(FromSourceRootEnvVar, recipes, proc() =
    let identity = pathOnlyBuildIdentity(ProjectInterfaceArtifact(
      projectInterface: ProjectInterface(projectName: "consumer",
        toolUses: @[use(kind)])), pathDir)
    resolved = identity.profiles[0].resolvedExecutablePath)
  resolved

var counter = 0
proc freshTmp(): string =
  inc counter
  result = getTempDir() / ("t_sibling_split_" & $getCurrentProcessId() &
    "_" & $counter)
  createDir(result)

suite "path-mode dispatch resolves a sibling for its side of the split":
  test "the DSL's dep kinds are the ones the resolver tests":
    check DepKindTarget == "target"
    check DepKindNative == "native"
    check DepKindRuntime == "runtime"

  test "without --target, PATH answers every side":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = layOut(tmp, true, true)
    withTarget("", proc() =
      for kind in [DepKindTarget, DepKindNative, DepKindRuntime]:
        check resolve(kind, recipes, pathDir) == pathDir / "openssl")

  test "under --target a buildDeps / runtimeDeps library reads the target mirror ahead of PATH":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = layOut(tmp, true, true)
    withTarget(Triple, proc() =
      for kind in [DepKindTarget, DepKindRuntime]:
        check ("/.repro/output/install@" & Triple & "/usr/bin/openssl") in
          resolve(kind, recipes, pathDir))

  test "under --target a nativeBuildDeps tool stays PATH-first, then the native mirror":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = layOut(tmp, true, true)
    withTarget(Triple, proc() =
      check resolve(DepKindNative, recipes, pathDir) == pathDir / "openssl"
      let empty = tmp / "empty-path"
      createDir(empty)
      check "/.repro/output/install/usr/bin/openssl" in
        resolve(DepKindNative, recipes, empty))

  test "a sibling with no target build is refused, not answered from PATH":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = layOut(tmp, false, false)
    withTarget(Triple, proc() =
      try:
        discard resolve(DepKindTarget, recipes, pathDir)
        check false
      except OSError as e:
        check "has no build for --target '" & Triple & "'" in e.msg)

  test "a target mirror without its keyed sidecar is not a build":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = layOut(tmp, true, false)
    withTarget(Triple, proc() =
      expect OSError:
        discard resolve(DepKindTarget, recipes, pathDir))

  test "a catalog checkout is its own recipes root":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, _) = layOut(tmp, false, false)
    withEnv(FromSourceRootEnvVar, "", proc() =
      check fromSourceRecipeRoot(tmp) == recipes)

const ObjectFixtures = currentSourcePath().parentDir.parentDir.parentDir /
  "repro_project_dsl" / "tests" / "fixtures" / "target_object_check"

suite "a target mirror is verified when it is consumed":
  # The round-1 `--target` mirrored host bytes under `install@armv7-…`;
  # such a mirror can still be on disk. Neither its presence nor a sidecar
  # makes it a build for the target.
  proc stale(tmp: string; sidecar: bool; lib: string): (string, string) =
    result = layOut(tmp, true, sidecar)
    let libDir = result[0] / "openssl" / (".repro/output/install@" & Triple) /
      "usr" / "lib"
    createDir(libDir)
    copyFile(ObjectFixtures / lib, libDir / "libz.so")

  test "a stale x86-64 libz.so under install@armv7 with no sidecar needs a build":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = stale(tmp, false, "x86_64.o")
    withTarget(Triple, proc() =
      try:
        discard resolve(DepKindTarget, recipes, pathDir)
        check false
      except OSError as e:
        check "has no build for --target" in e.msg)

  test "with a sidecar it is refused by the object check, naming the file":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = stale(tmp, true, "x86_64.o")
    withTarget(Triple, proc() =
      try:
        discard resolve(DepKindTarget, recipes, pathDir)
        check false
      except ValueError as e:
        check "usr/lib/libz.so: x86-64 (EM_X86_64)" in e.msg
        check "consumed under --target" in e.msg)

  test "an armv7 hard-float libz.so with its sidecar resolves":
    let tmp = freshTmp()
    defer: removeDir(tmp)
    let (recipes, pathDir) = stale(tmp, true, "armhf.so")
    withTarget(Triple, proc() =
      check ("/.repro/output/install@" & Triple & "/usr/bin/openssl") in
        resolve(DepKindTarget, recipes, pathDir))
