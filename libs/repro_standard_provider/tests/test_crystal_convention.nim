## Verification for the crystal language convention (M60).
##
## The convention covers BOTH Mode 2 (shards-managed via ``shard.yml``
## + ``shard.lock``) AND Mode 3 (pure source, no ``shard.yml``) Crystal
## workspaces — Option A per the M60 hand-off (single convention with
## in-procedure mode detection).
##
## Coverage:
##   * ``recognize`` returns true for a Mode 2 fixture when
##     ``shard.yml`` + ``shard.lock`` are present, ``crystal`` and
##     ``shards`` are on PATH, ``uses:`` names ``crystal``, and at
##     least one executable resolves to a ``.cr`` source layout.
##   * ``recognize`` returns true for a Mode 3 fixture when there is
##     NO ``shard.yml``, ``crystal`` is on PATH, ``uses:`` names a
##     Crystal token, and at least one executable resolves to a ``.cr``
##     source layout.
##   * ``recognize`` returns false when ``uses:`` doesn't name a
##     Crystal toolchain token.
##   * ``recognize`` returns false when no executable members are
##     declared.
##   * ``recognize`` returns false in Mode 2 when ``shard.yml`` is
##     present but ``shard.lock`` is missing (HARD precondition).
##   * ``emitFragment`` against the Mode 2 fixture emits a chained
##     ``shards install`` → ``crystal build`` action graph.
##   * ``emitFragment`` against the Mode 3 fixture emits a single
##     ``crystal build`` action (monolithic — no per-source DAG per
##     the M60 honest-scope cut).

import std/[os, strutils, unittest]

import repro_core
import repro_provider_runtime
import repro_project_dsl
import repro_standard_provider/convention
import repro_standard_provider/conventions/crystal as crystal_convention

const
  ## ``parentDir`` four times lands at the ``reprobuild/`` repo root.
  ## The fixture lives under the sibling ``reprobuild-examples``.
  ReprobuildRoot = currentSourcePath.parentDir.parentDir.parentDir.parentDir
  MetacraftRoot = ReprobuildRoot.parentDir
  Mode2Fixture =
    MetacraftRoot / "reprobuild-examples" / "crystal-shards" / "hello-binary"
  Mode3Fixture =
    MetacraftRoot / "reprobuild-examples" / "crystal-mode3" / "hello-binary"

proc dummyRequest(projectRoot: string): ProviderGraphRequest =
  ProviderGraphRequest(
    kind: prkGraphInvocation,
    providerArtifactId: "test-provider",
    entryPointId: "standardProvider.root",
    entryPointBodyHash: "test-body-hash",
    reason: girExplicitUserRequest,
    arguments: projectRoot,
    namespace: "project")

proc inlineArgvOf(action: BuildActionDef): seq[string] =
  for arg in action.call.arguments:
    if arg.name == "argv":
      if arg.encodedValue.len == 0:
        return @[]
      return arg.encodedValue.split("\x1f")
  @[]

proc crystalOnPath(): bool =
  findExe("crystal").len > 0

proc shardsOnPath(): bool =
  findExe("shards").len > 0

proc makeScratch(name: string): string =
  result = getTempDir() / ("repro-crystal-test-" & name)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "crystal convention recognition":

  test "recognize: negative — uses lacks crystal token":
    let dir = makeScratch("no-crystal-token")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "nim >=2.2 <3.0"
  executable hello:
    discard
""")
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.cr",
      "puts \"hi\"\n")
    let conv = crystal_convention.crystalConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — no executable members declared":
    # M60: the convention's ``recognize`` returns false when no
    # executable members are declared. This precondition is checked
    # before the crystal-on-PATH gate so the test runs unconditionally
    # (it does NOT require crystal on PATH). Mirrors M55 / M56 / M57
    # negative-member tests in the sibling Tier 2b conventions.
    let dir = makeScratch("no-members")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "crystal"
""")
    let conv = crystal_convention.crystalConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: negative — Mode 2 missing shard.lock":
    # M60 HARD precondition: if shard.yml is present, shard.lock must
    # ALSO be present. Otherwise the convention defers (the user must
    # run ``shards install`` once with network access to populate the
    # lockfile). Mirror of M42 csharp-dotnet / M55 haskell-cabal / M56
    # ruby-bundler / M57 php-composer lockfile-required pattern.
    # The test runs unconditionally — the precondition logic is the
    # convention's responsibility regardless of whether crystal is on
    # PATH (and the M57 php-composer sibling tests this the same way).
    let dir = makeScratch("no-shard-lock")
    writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "crystal"
  executable hello:
    discard
""")
    writeFile(dir / "shard.yml",
      "name: hello\nversion: 1.0.0\n" &
      "targets:\n  hello:\n    main: src/hello.cr\n")
    # NB: NO shard.lock — should defer.
    createDir(dir / "src")
    writeFile(dir / "src" / "hello.cr",
      "puts \"hi\"\n")
    let conv = crystal_convention.crystalConvention()
    let request = dummyRequest(dir)
    check not conv.recognize(dir, request)
    removeDir(dir)

  test "recognize: positive — Mode 2 fixture (shard.yml + shard.lock + crystal + shards on PATH)":
    if not crystalOnPath() or not shardsOnPath():
      skip()
    elif not dirExists(Mode2Fixture):
      skip()
    else:
      let conv = crystal_convention.crystalConvention()
      let request = dummyRequest(Mode2Fixture)
      check conv.recognize(Mode2Fixture, request)

  test "recognize: positive — Mode 3 fixture (no shard.yml; crystal on PATH)":
    if not crystalOnPath():
      skip()
    elif not dirExists(Mode3Fixture):
      skip()
    else:
      let conv = crystal_convention.crystalConvention()
      let request = dummyRequest(Mode3Fixture)
      check conv.recognize(Mode3Fixture, request)

  test "recognize: positive — accepts ``shards`` token in uses":
    if not crystalOnPath():
      skip()
    else:
      let dir = makeScratch("shards-token")
      writeFile(dir / "repro.nim", """
import repro_project_dsl

package x:
  uses:
    "shards"
  executable hello:
    discard
""")
      createDir(dir / "src")
      writeFile(dir / "src" / "hello.cr",
        "puts \"hi\"\n")
      let conv = crystal_convention.crystalConvention()
      let request = dummyRequest(dir)
      check conv.recognize(dir, request)
      removeDir(dir)

suite "crystal convention emit shape":

  test "Mode 3: detectMode returns cmDirect without shard.yml":
    let dir = makeScratch("detect-mode-direct")
    let mode = crystal_convention.detectMode(dir)
    check mode == CrystalMode.cmDirect
    removeDir(dir)

  test "Mode 2: detectMode returns cmShards with shard.yml present":
    let dir = makeScratch("detect-mode-shards")
    writeFile(dir / "shard.yml",
      "name: x\nversion: 1.0.0\n")
    let mode = crystal_convention.detectMode(dir)
    check mode == CrystalMode.cmShards
    removeDir(dir)

  test "emitFragment Mode 3: single crystal-direct-build action":
    if not crystalOnPath():
      skip()
    elif not dirExists(Mode3Fixture):
      skip()
    else:
      let conv = crystal_convention.crystalConvention()
      let request = dummyRequest(Mode3Fixture)
      require conv.recognize(Mode3Fixture, request)
      let fragment = conv.emitFragment(Mode3Fixture, request)

      var sawCrystalDirectBuild = false
      var sawShardsInstall = false
      var buildActionArgv: seq[string] = @[]
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("crystal-direct-build-"):
          sawCrystalDirectBuild = true
          buildActionArgv = inlineArgvOf(action)
        elif action.id.startsWith("crystal-shards-install-"):
          sawShardsInstall = true

      check sawCrystalDirectBuild
      check not sawShardsInstall  # Mode 3 must NOT emit shards install

      # The crystal build argv carries: crystal, build, <entry.cr>,
      # -o, <out>, --release, --no-debug.
      var sawCrystal = false
      var sawBuild = false
      var sawO = false
      var sawRelease = false
      var sawNoDebug = false
      for token in buildActionArgv:
        let lower = token.toLowerAscii
        if lower.endsWith("crystal") or lower.endsWith("crystal.exe"):
          sawCrystal = true
        elif token == "build":
          sawBuild = true
        elif token == "-o":
          sawO = true
        elif token == "--release":
          sawRelease = true
        elif token == "--no-debug":
          sawNoDebug = true
      check sawCrystal
      check sawBuild
      check sawO
      check sawRelease
      check sawNoDebug

  test "emitFragment Mode 2: shards-install + shards-build actions chained":
    if not crystalOnPath() or not shardsOnPath():
      skip()
    elif not dirExists(Mode2Fixture):
      skip()
    else:
      let conv = crystal_convention.crystalConvention()
      let request = dummyRequest(Mode2Fixture)
      require conv.recognize(Mode2Fixture, request)
      let fragment = conv.emitFragment(Mode2Fixture, request)

      var sawShardsInstall = false
      var sawShardsBuild = false
      var shardsInstallActionId = ""
      var shardsBuildAction: BuildActionDef
      for node in fragment.nodes:
        if node.kind != gnkAction:
          continue
        let action = decodeBuildActionPayload(toBytes(node.payload))
        if action.id.startsWith("crystal-shards-install-"):
          sawShardsInstall = true
          shardsInstallActionId = action.id
        elif action.id.startsWith("crystal-shards-build-"):
          sawShardsBuild = true
          shardsBuildAction = action

      check sawShardsInstall
      check sawShardsBuild

      # The build action must list the install action in its deps
      # (the chained "shards install -> crystal build" ordering).
      var sawInstallDep = false
      for dep in shardsBuildAction.deps:
        if dep == shardsInstallActionId:
          sawInstallDep = true
      check sawInstallDep
