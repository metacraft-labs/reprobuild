## A lowered DSL action's local cache key covers the argv it spawns.
##
## The local action cache files a record under the action's weak
## fingerprint and serves it to any later action with the same weak
## fingerprint whose recorded inputs still check out. The engine's
## `action()` constructor mixes the declared environment, the governing lock
## and the content-addressed root of `argv[0]` into the fingerprint its
## caller passes, but not the rest of argv. So two lowered actions whose
## caller-side fingerprint text is equal, while the argv they spawn differs,
## share one record: the second is served the first one's result without
## running.
##
## `lowerGraphAction` builds that caller-side text from the graph node's
## payload. Three branches spawn an argv that the payload does not spell out:
##
## * inline exec replaces every `@FILE:<path>` element with the file's
##   contents at lowering time, while the payload keeps the literal
##   `@FILE:<path>`;
## * the nim-unittest execute site resolves the test binary against the
##   project root, while the payload keeps the path as the recipe wrote it;
## * the typed-tool site takes `argv[0]` from the resolved tool profile.
##
## Each case below lowers ONE payload twice, changing only what decides one
## element of the spawned argv, and asserts that the argv differs (the
## precondition) and that the weak fingerprint differs (the property).
## Removing the argv from the lowering's fingerprint text turns every case
## red, because the payload, id, lock identity and environment are equal by
## construction.
##
## Nothing is mocked. The graph snapshot and the tool profile are plain
## values of the production types, built the way `t_m9r2_typed_cli_surfaces`
## builds them, and lowering is the production `lowerProviderSnapshot`. No
## action is executed: the property is a fact about the lowered key, and the
## stale hit it prevents follows from the local cache's documented lookup by
## weak fingerprint.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_provider_runtime
import repro_tool_profiles

proc snapshotOf(declared: BuildActionDef): ProviderGraphSnapshot =
  ProviderGraphSnapshot(fragments: @[StoredGraphFragment(
    namespace: "argv-key", nodes: @[GraphNode(id: declared.id,
      kind: gnkAction, stableName: declared.id,
      payload: actionPayload(declared))])])

proc lowerOne(declared: BuildActionDef; projectRoot: string;
              identity = PathOnlyBuildIdentity()): BuildAction =
  let lowered = lowerProviderSnapshot(snapshotOf(declared), identity,
    projectRoot, @[declared.id])
  require lowered.actions.len == 1
  lowered.actions[0]

suite "a lowered action's weak fingerprint covers its spawned argv":

  test "an @FILE: argument's contents are in the key":
    let root = createTempDir("repro-argv-key-argfile-", "")
    defer: removeDir(root)
    let argFile = root / "token.txt"
    resetBuildActionRegistry()
    let declared = buildAction("argv-key.argfile",
      inlineExecCall(@["/bin/echo", "--token", "@FILE:" & argFile]),
      cacheable = true)
    writeFile(argFile, "first-value\n")
    let first = lowerOne(declared, root)
    writeFile(argFile, "second-value\n")
    let second = lowerOne(declared, root)
    check first.argv == @["/bin/echo", "--token", "first-value"]
    check second.argv == @["/bin/echo", "--token", "second-value"]
    check first.weakFingerprint != second.weakFingerprint

  test "a nim-unittest binary resolved to another path is in the key":
    let rootA = createTempDir("repro-argv-key-unittest-a-", "")
    defer: removeDir(rootA)
    let rootB = createTempDir("repro-argv-key-unittest-b-", "")
    defer: removeDir(rootB)
    resetBuildActionRegistry()
    # The payload names the binary relative to the project root, so the two
    # lowerings carry byte-identical payloads and differ only in the path
    # `lowerGraphAction` resolves it to.
    let declared = buildAction("argv-key.unittest-run",
      publicCliCall("ct_test_nim_unittest.buildNimUnittest",
        "ct_test_nim_unittest.buildNimUnittest", "run",
        "ct_test_nim_unittest.buildNimUnittest.run",
        @[cliArg("binary", "build/t_unit")]),
      cacheable = true)
    let first = lowerOne(declared, rootA)
    let second = lowerOne(declared, rootB)
    check first.argv == @[rootA / "build/t_unit"]
    check second.argv == @[rootB / "build/t_unit"]
    check first.weakFingerprint != second.weakFingerprint

  test "a typed tool resolved to another executable is in the key":
    let root = createTempDir("repro-argv-key-typed-", "")
    defer: removeDir(root)
    resetBuildActionRegistry()
    let declared = buildAction("argv-key.typed",
      publicCliCall("argvkeytool", "argvkeytool", "", "argvkeytool",
        @[cliArg("verbose", true)]),
      cacheable = true)
    # Two profiles that differ ONLY in the resolved executable. Their
    # profile fingerprints are equal (both unset), so the profile fingerprint
    # the typed-tool site already keys cannot tell them apart; the spawned
    # argv must.
    proc identityAt(executable: string): PathOnlyBuildIdentity =
      PathOnlyBuildIdentity(profiles: @[PathOnlyToolProfile(
        packageSelector: "argvkeytool", executableName: "argvkeytool",
        resolvedExecutablePath: executable)])
    let first = lowerOne(declared, root, identityAt("/opt/tool-a/bin/argvkeytool"))
    let second = lowerOne(declared, root, identityAt("/opt/tool-b/bin/argvkeytool"))
    require first.argv.len > 0 and second.argv.len > 0
    check first.argv[0] == "/opt/tool-a/bin/argvkeytool"
    check second.argv[0] == "/opt/tool-b/bin/argvkeytool"
    check first.weakFingerprint != second.weakFingerprint

  test "an unchanged argv keeps its key":
    # The control: lowering the same payload twice against the same inputs
    # must not move the key, or every case above would pass for the wrong
    # reason and every build would miss.
    let root = createTempDir("repro-argv-key-stable-", "")
    defer: removeDir(root)
    let argFile = root / "token.txt"
    writeFile(argFile, "same-value\n")
    resetBuildActionRegistry()
    let declared = buildAction("argv-key.stable",
      inlineExecCall(@["/bin/echo", "@FILE:" & argFile]),
      cacheable = true)
    check lowerOne(declared, root).weakFingerprint ==
      lowerOne(declared, root).weakFingerprint
