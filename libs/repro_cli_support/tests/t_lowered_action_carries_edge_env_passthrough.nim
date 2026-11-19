## The environment passthrough an edge declares (`BuildActionDef.
## envPassthrough`) reaches the lowered engine action at every process
## lowering site, beside the `PATH` decision, and does what passthrough means.
##
## `lowerGraphAction` has three process sites that make a `PATH` decision --
## inline exec, the nim-unittest execute site and the general typed-tool
## site -- and each builds the action's passthrough list from it. The
## built-in HCR site makes none and carries the edge's names alone. A site that
## left out the edge's own names would key those reads by value again, and a
## `nim.c` edge would miss on the first build in every new `nix develop`
## shell (reprobuild-pm issue
## `2026-10-18-compile-edges-record-the-shells-temp-so-every-new-nix-develop-shell-misses`).
##
## Each site is checked for the three halves of passthrough
## (`repro_build_engine.actionEnvironmentKeyText`, `cacheEnvInputs`): the
## names are on the action, the NAME moves the weak fingerprint, and an
## observed read of a named variable is left out of the value-keyed
## environment set while every other observed read stays in it.
##
## Nothing is mocked. The snapshot and the tool profile are plain values of
## the production types and lowering is the production
## `lowerProviderSnapshot`, as in `t_lowered_action_key_covers_its_argv.nim`.
## No action is executed: the evidence handed to `cacheEnvInputs` is a plain
## `PathSetEvidence` naming the reads, which is the only part of a monitor
## capture that function consumes.

import std/[os, tempfiles, unittest]

import repro_build_engine
import repro_cli_support
import repro_project_dsl
import repro_provider_runtime
import repro_tool_profiles

const ScratchNames = ["TMPDIR", "TMP", "TEMP", "TEMPDIR"]

proc snapshotOf(declared: BuildActionDef): ProviderGraphSnapshot =
  ProviderGraphSnapshot(fragments: @[StoredGraphFragment(
    namespace: "env-passthrough", nodes: @[GraphNode(id: declared.id,
      kind: gnkAction, stableName: declared.id,
      payload: actionPayload(declared))])])

proc lowerOne(declared: BuildActionDef; projectRoot: string;
              identity = PathOnlyBuildIdentity()): BuildAction =
  let lowered = lowerProviderSnapshot(snapshotOf(declared), identity,
    projectRoot, @[declared.id])
  require lowered.actions.len == 1
  lowered.actions[0]

proc typedIdentity(): PathOnlyBuildIdentity =
  PathOnlyBuildIdentity(profiles: @[PathOnlyToolProfile(
    packageSelector: "passthroughtool", executableName: "passthroughtool",
    resolvedExecutablePath: "/opt/passthroughtool/bin/passthroughtool")])

proc sites(): seq[tuple[name: string; declared: BuildActionDef;
                        identity: PathOnlyBuildIdentity]] =
  ## One declared edge per process lowering site, each built WITHOUT
  ## passthrough; a case adds the names it needs.
  resetBuildActionRegistry()
  result.add(("inline exec",
    buildAction("env-pass.inline", inlineExecCall(@["/bin/true"]),
      cacheable = true),
    PathOnlyBuildIdentity()))
  result.add(("nim-unittest execute",
    buildAction("env-pass.unittest",
      publicCliCall("ct_test_nim_unittest.buildNimUnittest",
        "ct_test_nim_unittest.buildNimUnittest", "run",
        "ct_test_nim_unittest.buildNimUnittest.run",
        @[cliArg("binary", "build/t_unit")]),
      cacheable = true),
    PathOnlyBuildIdentity()))
  result.add(("typed tool",
    buildAction("env-pass.typed",
      publicCliCall("passthroughtool", "passthroughtool", "", "passthroughtool",
        @[cliArg("verbose", true)]),
      cacheable = true),
    typedIdentity()))

suite "an edge's declared env passthrough reaches the lowered action":

  test "every process site carries the names after its PATH decision":
    let root = createTempDir("repro-env-pass-", "")
    defer: removeDir(root)
    for site in sites():
      checkpoint site.name
      let plain = lowerOne(site.declared, root, site.identity)
      var declared = site.declared
      declared.envPassthrough = @ScratchNames
      let named = lowerOne(declared, root, site.identity)
      # The PATH decision's own answer is kept, first, and unchanged.
      check named.envPassthrough.len == plain.envPassthrough.len +
        ScratchNames.len
      check named.envPassthrough[0 ..< plain.envPassthrough.len] ==
        plain.envPassthrough
      for name in ScratchNames:
        check name in named.envPassthrough
      check classifyActionPath(named) == classifyActionPath(plain)
      check named.env == plain.env
      # A passthrough NAME is part of what the action is.
      check named.weakFingerprint != plain.weakFingerprint
      # Lowering is deterministic: the same declaration keeps its key.
      check lowerOne(declared, root, site.identity).weakFingerprint ==
        named.weakFingerprint

  test "an observed read of a named variable is not keyed by value":
    let root = createTempDir("repro-env-pass-reads-", "")
    defer: removeDir(root)
    for site in sites():
      checkpoint site.name
      var declared = site.declared
      declared.envPassthrough = @ScratchNames
      let plain = lowerOne(site.declared, root, site.identity)
      let named = lowerOne(declared, root, site.identity)
      let evidence = PathSetEvidence(
        monitorEnvReads: @["TEMP", "HOME", "TMPDIR", "NIX_BUILD_TOP"])
      var plainNames, namedNames: seq[string]
      for input in plain.cacheEnvInputs(evidence):
        plainNames.add(input.name)
      for input in named.cacheEnvInputs(evidence):
        namedNames.add(input.name)
      # Control: without the declaration every read is keyed.
      check plainNames == @["HOME", "NIX_BUILD_TOP", "TEMP", "TMPDIR"]
      # With it, only the reads the edge did not name.
      check namedNames == @["HOME", "NIX_BUILD_TOP"]

  test "a name the edge also declares keeps its declared launch value":
    let root = createTempDir("repro-env-pass-declared-", "")
    defer: removeDir(root)
    for site in sites():
      checkpoint site.name
      var declared = site.declared
      declared.env = @[("TMPDIR", "/declared/tmp")]
      declared.envPassthrough = @["TMPDIR"]
      let named = lowerOne(declared, root, site.identity)
      check "TMPDIR=/declared/tmp" in named.env
      check "TMPDIR" in named.envPassthrough
      # The engine's environment key renders the name, not the value (the
      # recipe's payload text, which holds the value, is keyed separately).
      var other = declared
      other.env = @[("TMPDIR", "/other/tmp")]
      let otherLowered = lowerOne(other, root, site.identity)
      check "TMPDIR=/other/tmp" in otherLowered.env
      check actionEnvironmentKeyText(named.env, named.envPassthrough) ==
        actionEnvironmentKeyText(otherLowered.env, otherLowered.envPassthrough)

  test "an edge-declared PATH passthrough is refused at every site":
    let root = createTempDir("repro-env-pass-path-", "")
    defer: removeDir(root)
    for site in sites():
      checkpoint site.name
      var declared = site.declared
      declared.envPassthrough = @["TMPDIR", "PATH"]
      expect ValueError:
        discard lowerOne(declared, root, site.identity)

  test "the merge keeps the decision's names and drops duplicates":
    check withEdgeEnvPassthrough(@["PATH"], ["TMPDIR", "TMPDIR", "", "TMP"],
      "a") == @["PATH", "TMPDIR", "TMP"]
    check withEdgeEnvPassthrough(@[], [], "a").len == 0
    expect ValueError:
      discard withEdgeEnvPassthrough(@[], ["path"], "a")

  test "the built-in HCR site, which makes no PATH decision, carries them":
    let root = createTempDir("repro-env-pass-hcr-", "")
    defer: removeDir(root)
    resetBuildActionRegistry()
    let plainDecl = buildAction("env-pass.hcr",
      publicCliCall("reprobuild.builtin", "hcr", "prepareObject",
        "reprobuild.builtin.hcr", @[cliArg("input", "build/a.o"),
          cliArg("output", "build/a.hcr.o"), cliArg("segment", "text")]),
      cacheable = true)
    var namedDecl = plainDecl
    namedDecl.envPassthrough = @ScratchNames
    let plain = lowerOne(plainDecl, root)
    let named = lowerOne(namedDecl, root)
    check plain.envPassthrough.len == 0
    check named.envPassthrough == @ScratchNames
    check named.weakFingerprint != plain.weakFingerprint
    let evidence = PathSetEvidence(monitorEnvReads: @["TEMP", "HOME"])
    var namedNames: seq[string]
    for input in named.cacheEnvInputs(evidence):
      namedNames.add(input.name)
    check namedNames == @["HOME"]
    namedDecl.envPassthrough = @["PATH"]
    expect ValueError:
      discard lowerOne(namedDecl, root)
