## Schema v3 envelope round-trip + v2 backward-compat tests for
## ``trycompile.rbsz``.
##
## v3 extends v2 with cross-config descriptors so the direct provider can
## consume multi-config CMake builds (CMAKE_CROSS_CONFIGS /
## CMAKE_DEFAULT_CONFIGS) without falling back to ``reprobuild.nim``. v2
## readers must reject v3 (and the decoder under test accepts v2 → v3
## envelopes, treating the new fields as empty when absent).

import std/[unittest]

import repro_cmake_trycompile
import repro_core

suite "trycompile.rbsz v3 envelope":
  test "test_trycompile_v3_envelope_roundtrip":
    var meta = TryCompileMetadata(
      usedTools: @["gcc", "ld"],
      pools: @[TryCompilePoolDef(name: "link", capacity: 2'u32)],
      actions: @[
        TryCompileActionDef(
          id: "compile-debug",
          inline: true,
          inlineArgv: @["gcc", "-c", "src.c", "-o", "src.debug.o"],
          inlineCwd: "",
          args: @[],
          deps: @[],
          inputs: @["src.c"],
          outputs: @["src.debug.o"],
          pool: "compile",
          poolUnits: 1'u32,
          depfile: "",
          dynamicDepsFile: "",
          cacheable: true,
          commandStatsId: "compile.debug"),
        TryCompileActionDef(
          id: "compile-release",
          inline: true,
          inlineArgv: @["gcc", "-c", "src.c", "-o", "src.release.o"],
          inlineCwd: "",
          args: @[],
          deps: @[],
          inputs: @["src.c"],
          outputs: @["src.release.o"],
          pool: "compile",
          poolUnits: 1'u32,
          depfile: "",
          dynamicDepsFile: "",
          cacheable: true,
          commandStatsId: "compile.release"),
      ],
      targets: @[
        TryCompileTargetDef(
          name: "myTarget:Debug",
          actionIds: @["compile-debug"],
          childTargets: @[],
          isAggregate: false),
        TryCompileTargetDef(
          name: "myTarget:Release",
          actionIds: @["compile-release"],
          childTargets: @[],
          isAggregate: false),
      ],
      defaultTargetName: "all",
      crossConfigs: @["Debug", "Release"],
      crossConfigTargets: @[
        CrossConfigTargetDef(
          name: "all:Debug",
          configName: "Debug",
          baseName: "",
          childTargets: @["myTarget:Debug"]),
        CrossConfigTargetDef(
          name: "all:Release",
          configName: "Release",
          baseName: "",
          childTargets: @["myTarget:Release"]),
        CrossConfigTargetDef(
          name: "myTarget",
          configName: "",
          baseName: "myTarget",
          childTargets: @["myTarget:Debug", "myTarget:Release"]),
        CrossConfigTargetDef(
          name: "all",
          configName: "",
          baseName: "",
          childTargets: @["all:Debug", "all:Release"]),
      ],
      defaultConfigs: @["Debug", "Release"])

    let encoded = encodeTryCompileMetadata(meta)
    # Envelope must declare v3 explicitly — that's the contract a v2
    # reader keys off of when refusing to parse a v3 file.
    check encoded[4] == byte(3)
    check encoded[5] == byte(0)

    let decoded = decodeTryCompileMetadata(encoded)
    check decoded.usedTools == @["gcc", "ld"]
    check decoded.pools.len == 1
    check decoded.pools[0].name == "link"
    check decoded.pools[0].capacity == 2'u32
    check decoded.actions.len == 2
    check decoded.actions[0].id == "compile-debug"
    check decoded.actions[1].id == "compile-release"
    check decoded.targets.len == 2
    check decoded.targets[0].name == "myTarget:Debug"
    check decoded.targets[0].actionIds == @["compile-debug"]
    check decoded.targets[1].name == "myTarget:Release"
    check decoded.defaultTargetName == "all"
    check decoded.crossConfigs == @["Debug", "Release"]
    check decoded.crossConfigTargets.len == 4
    check decoded.crossConfigTargets[0].name == "all:Debug"
    check decoded.crossConfigTargets[0].configName == "Debug"
    check decoded.crossConfigTargets[0].baseName == ""
    check decoded.crossConfigTargets[0].childTargets == @["myTarget:Debug"]
    check decoded.crossConfigTargets[2].name == "myTarget"
    check decoded.crossConfigTargets[2].baseName == "myTarget"
    check decoded.crossConfigTargets[2].childTargets ==
      @["myTarget:Debug", "myTarget:Release"]
    check decoded.crossConfigTargets[3].name == "all"
    check decoded.crossConfigTargets[3].childTargets ==
      @["all:Debug", "all:Release"]
    check decoded.defaultConfigs == @["Debug", "Release"]
    # v1 compat view exposes the first target through the legacy fields.
    check decoded.targetName == "myTarget:Debug"
    check decoded.targetActionIds == @["compile-debug"]

  test "v3 reader accepts v2 envelope and zeroes new fields":
    # Hand-craft a v2 envelope. The v2 trailer ends right after
    # ``defaultTargetName`` — there is no crossConfigs / crossConfigTargets
    # / defaultConfigs section.
    var meta = TryCompileMetadata(
      usedTools: @["gcc"],
      pools: @[],
      actions: @[
        TryCompileActionDef(
          id: "compile",
          inline: true,
          inlineArgv: @["gcc", "-c", "src.c", "-o", "src.o"],
          inlineCwd: "",
          args: @[],
          deps: @[],
          inputs: @["src.c"],
          outputs: @["src.o"],
          pool: "compile",
          poolUnits: 1'u32,
          depfile: "",
          dynamicDepsFile: "",
          cacheable: true,
          commandStatsId: "compile"),
      ],
      targets: @[
        TryCompileTargetDef(
          name: "myTarget",
          actionIds: @["compile"],
          childTargets: @[],
          isAggregate: false),
      ],
      defaultTargetName: "myTarget")

    # The encoder emits v3 unconditionally, so we build a v2 envelope
    # by re-encoding the v3 output with version flipped to 2 and the
    # v3 trailer trimmed off the payload. We compute the trailer length
    # by encoding once with empty cross-config fields and once with the
    # populated fields — the difference is the trailer size.
    #
    # Easier: build the payload manually using the same primitives the
    # encoder uses. This keeps the test independent of internal layout.
    var payload: seq[byte] = @[]
    payload.add(byte(meta.usedTools.len and 0xff))
    payload.add(byte((meta.usedTools.len shr 8) and 0xff))
    payload.add(byte((meta.usedTools.len shr 16) and 0xff))
    payload.add(byte((meta.usedTools.len shr 24) and 0xff))
    for tool in meta.usedTools:
      payload.writeString(tool)
    payload.writeU32Le(uint32(meta.pools.len))
    payload.writeU32Le(uint32(meta.actions.len))
    for action in meta.actions:
      payload.writeString(action.id)
      payload.add(if action.inline: 1'u8 else: 0'u8)
      payload.writeU32Le(uint32(action.inlineArgv.len))
      for arg in action.inlineArgv:
        payload.writeString(arg)
      payload.writeString(action.inlineCwd)
      payload.writeString(action.toolId)
      payload.writeU32Le(uint32(action.args.len))
      for arg in action.args:
        payload.writeString(arg)
      payload.writeU32Le(uint32(action.deps.len))
      for dep in action.deps:
        payload.writeString(dep)
      payload.writeU32Le(uint32(action.inputs.len))
      for inp in action.inputs:
        payload.writeString(inp)
      payload.writeU32Le(uint32(action.outputs.len))
      for outp in action.outputs:
        payload.writeString(outp)
      payload.writeString(action.pool)
      payload.writeU32Le(action.poolUnits)
      payload.writeString(action.depfile)
      payload.writeString(action.dynamicDepsFile)
      payload.add(if action.cacheable: 1'u8 else: 0'u8)
      payload.writeString(action.commandStatsId)
    payload.writeU32Le(uint32(meta.targets.len))
    for target in meta.targets:
      payload.writeString(target.name)
      payload.writeU32Le(uint32(target.actionIds.len))
      for actionId in target.actionIds:
        payload.writeString(actionId)
      payload.writeU32Le(uint32(target.childTargets.len))
      for childName in target.childTargets:
        payload.writeString(childName)
      payload.add(if target.isAggregate: 1'u8 else: 0'u8)
    payload.writeString(meta.defaultTargetName)

    var envelope: seq[byte] = @[]
    for ch in TryCompileMetadataMagic:
      envelope.add(byte(ord(ch)))
    envelope.writeU16Le(2'u16)
    envelope.writeU32Le(uint32(payload.len))
    envelope.add(payload)

    let decoded = decodeTryCompileMetadata(envelope)
    check decoded.usedTools == @["gcc"]
    check decoded.actions.len == 1
    check decoded.targets.len == 1
    check decoded.targets[0].name == "myTarget"
    check decoded.defaultTargetName == "myTarget"
    # The v3-only fields default to empty seqs when reading a v2
    # envelope — that's the backward-compat contract for new readers.
    check decoded.crossConfigs.len == 0
    check decoded.crossConfigTargets.len == 0
    check decoded.defaultConfigs.len == 0
