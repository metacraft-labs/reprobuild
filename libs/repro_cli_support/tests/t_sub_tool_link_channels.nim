## A typed tool's sub-tool hands the edge its compile and link channels, and
## those channels are in the edge's key.
##
## THE DEFECT. The stdlib `cargo` declares `subTools "rustc", "gcc",
## "clang"`: rustc links through a C compiler driver found by bare name. The
## lowering put each declared sub-tool's directory on the cargo edge's
## `PATH`, but handed the engine only the edge's `toolIdentityRefs`, and the
## engine derives `CPATH` and `LIBRARY_PATH` from those alone. A sub-tool
## compiler therefore ran without its profile's include and library
## directories. On macOS a Nix clang's profile names the Apple SDK's
## split-out `libiconv` only through its library path, so every cargo build
## script failed with `ld: library not found for -liconv`, while a recipe
## that attached clang to the edge as a ref linked.
##
## THE CONTRACT. A sub-tool the edge does not name as a ref is lowered to
## `BuildAction.subToolIdentityRefs`, not to `toolIdentityRefs` (which would
## make the edge's `PATH` hermetic and hand it every channel). The engine
## takes its `includeDirs` onto `CPATH` and its `libDirs` onto `LIBRARY_PATH`
## only. Its profile fingerprint enters the weak fingerprint whenever the
## profile carries either channel, so a change to those channels misses the
## cache; a sub-tool without channels leaves the key alone.
##
## Nothing is mocked. The snapshot, tool profiles and action identities are
## plain values of the production types (as in
## `t_lowered_action_key_covers_its_argv`), lowering is the production
## `lowerProviderSnapshot`, the resolver is the production
## `mkToolIdentityResolver`, and the channels are projected by the
## production `collectResolvedAuxPaths` / `applyResolvedAuxPathsArgv`. No
## action is executed; the engine's own suite runs one
## (`test_tool_identity_env_plumbing`).

import std/[os, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_provider_runtime
import repro_tool_profiles

const
  ClangDir = "/nix/store/00000000000000000000000000000000-clang-wrapper/bin"
  IconvLib = "/nix/store/11111111111111111111111111111111-libiconv/lib"
  IconvInclude = "/nix/store/11111111111111111111111111111111-libiconv/include"
  ResolvLib = "/nix/store/22222222222222222222222222222222-libresolv/lib"

proc snapshotOf(declared: BuildActionDef): ProviderGraphSnapshot =
  ProviderGraphSnapshot(fragments: @[StoredGraphFragment(
    namespace: "sub-tool-channels", nodes: @[GraphNode(id: declared.id,
      kind: gnkAction, stableName: declared.id,
      payload: actionPayload(declared))])])

proc lowerOne(declared: BuildActionDef; projectRoot: string;
              identity: PathOnlyBuildIdentity): BuildAction =
  let lowered = lowerProviderSnapshot(snapshotOf(declared), identity,
    projectRoot, @[declared.id])
  require lowered.actions.len == 1
  lowered.actions[0]

proc cargoEdge(subTools: seq[string]; refs: seq[string] = @[]):
    BuildActionDef =
  ## A typed `subtoolcargo build` edge whose tool declares `subTools`, the
  ## way the generated wrapper records it.
  resetBuildActionRegistry()
  result = buildAction("sub-tool-channels.cargo",
    publicCliCall("subtoolcargo", "subtoolcargo", "build",
      "subtoolcargo.build", @[]),
    cacheable = true)
  result.subToolRefs = subTools
  result.toolIdentityRefs = refs

proc identityWith(includeDirs, libDirs: seq[string]): PathOnlyBuildIdentity =
  ## The edge's own tool, plus a `clang` whose profile carries the given
  ## compile and link channels. Profiles are sealed, as every production
  ## construction site seals them; an unsealed profile has the zero
  ## fingerprint and would make every key comparison here vacuous.
  var cargo = PathOnlyToolProfile(packageSelector: "subtoolcargo",
    executableName: "subtoolcargo",
    resolvedExecutablePath: "/opt/cargo/bin/subtoolcargo")
  refreshProfileIdentity(cargo)
  var clang = PathOnlyToolProfile(packageSelector: "clang",
    executableName: "clang", installMethod: "nix",
    resolvedExecutablePath: ClangDir / "clang",
    cpathList: includeDirs, libraryPathList: libDirs)
  refreshProfileIdentity(clang)
  result.profiles = @[cargo, clang]
  result.actionIdentities = @[ToolActionIdentity(packageSelector: "clang",
    executableName: "clang", installMethod: "nix",
    resolvedExecutablePath: ClangDir / "clang",
    cpathList: includeDirs, libraryPathList: libDirs)]

proc envValue(env: openArray[string]; name: string): string =
  for entry in env:
    if entry.startsWith(name & "="):
      return entry[name.len + 1 .. ^1]

suite "a sub-tool hands the edge its compile and link channels":

  test "a sub-tool reaches the engine apart from the edge's refs":
    let root = createTempDir("repro-subtool-refs-", "")
    defer: removeDir(root)
    let lowered = lowerOne(cargoEdge(@["rustc", "clang"]), root,
      identityWith(@[IconvInclude], @[IconvLib]))
    check lowered.subToolIdentityRefs == @["rustc", "clang"]
    # Not a ref: the edge's PATH stays inherited, exactly as before.
    check lowered.toolIdentityRefs.len == 0
    check "PATH" in lowered.envPassthrough

  test "a sub-tool's include and library dirs reach CPATH and LIBRARY_PATH only":
    let root = createTempDir("repro-subtool-env-", "")
    defer: removeDir(root)
    let identity = identityWith(@[IconvInclude], @[IconvLib])
    let lowered = lowerOne(cargoEdge(@["clang"]), root, identity)
    let paths = collectResolvedAuxPaths(lowered,
      mkToolIdentityResolver(identity))
    check paths.includeDirs == @[IconvInclude]
    check paths.linkOnlyLibDirs == @[IconvLib]
    # Not a run-time library dir, and none of a ref's other channels.
    check paths.libDirs.len == 0
    check paths.pkgConfigDirs.len == 0
    check paths.cmakePrefixDirs.len == 0
    check paths.prefixVars.len == 0
    let env = applyResolvedAuxPathsArgv(
      @["LIBRARY_PATH=", "CPATH=", "LD_LIBRARY_PATH=", "DYLD_LIBRARY_PATH="],
      paths)
    check envValue(env, "LIBRARY_PATH") == IconvLib
    check envValue(env, "CPATH") == IconvInclude
    check envValue(env, "LD_LIBRARY_PATH") == ""
    check envValue(env, "DYLD_LIBRARY_PATH") == ""

  test "a ref's channels precede a sub-tool's, and a sub-tool named as a ref is a ref":
    let root = createTempDir("repro-subtool-order-", "")
    defer: removeDir(root)
    let identity = identityWith(@[IconvInclude], @[IconvLib])
    let lowered = lowerOne(cargoEdge(@["clang"], refs = @["clang"]), root,
      identity)
    # Named by the edge, clang is a ref and gets every channel as one;
    # listing it as a sub-tool too would add nothing.
    check lowered.subToolIdentityRefs.len == 0
    let paths = collectResolvedAuxPaths(lowered,
      mkToolIdentityResolver(identity))
    check paths.libDirs == @[IconvLib]
    check paths.linkOnlyLibDirs.len == 0

  test "a change to a sub-tool's channels changes the edge's key":
    let root = createTempDir("repro-subtool-key-", "")
    defer: removeDir(root)
    let declared = cargoEdge(@["clang"])
    let base = lowerOne(declared, root,
      identityWith(@[IconvInclude], @[IconvLib]))
    # The control: the same inputs keep the key, or the cases below would
    # pass for the wrong reason.
    check base.weakFingerprint == lowerOne(declared, root,
      identityWith(@[IconvInclude], @[IconvLib])).weakFingerprint
    # Same clang directory, same PATH; only the link channel moves. This is
    # the change a release that adds the SDK's split-out libraries makes.
    let moreLibs = lowerOne(declared, root,
      identityWith(@[IconvInclude], @[IconvLib, ResolvLib]))
    check envValue(base.env, "PATH") == envValue(moreLibs.env, "PATH")
    check base.weakFingerprint != moreLibs.weakFingerprint
    let noInclude = lowerOne(declared, root, identityWith(@[], @[IconvLib]))
    check base.weakFingerprint != noInclude.weakFingerprint

  test "a sub-tool without compile or link channels adds nothing to the key":
    var identity = identityWith(@[], @[])
    var index = initTable[string, PathOnlyToolProfile]()
    for profile in identity.profiles:
      index[profile.executableName] = profile
    check subToolChannelKeyText(index, ["clang"], []) == ""
    # ... and one with channels that the edge names as a ref is not a
    # sub-tool of this edge at all (``channelSubToolRefs``).
    identity = identityWith(@[IconvInclude], @[IconvLib])
    index.clear()
    for profile in identity.profiles:
      index[profile.executableName] = profile
    check subToolChannelKeyText(index, ["clang"], ["clang"]) == ""
    check subToolChannelKeyText(index, ["clang"], []).startsWith("clang=")
