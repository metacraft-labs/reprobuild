import std/[options, tables, unittest]

import repro_hcr_agent

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
  FunctionName = "repro_hcr_process_target_entry"

when defined(macosx) and defined(arm64):
  {.emit: """
__attribute__((noinline, used, visibility("default"),
               section("__HCR,__text")))
int repro_hcr_process_target_entry(void) {
  extern volatile int repro_hcr_process_target_seed;
  return repro_hcr_process_target_seed;
}

volatile int repro_hcr_process_target_seed = 11;

void *repro_hcr_process_target_entry_addr(void) {
  return (void *)&repro_hcr_process_target_entry;
}
""".}

  proc repro_hcr_process_target_entry(): cint {.cdecl, importc.}
  proc repro_hcr_process_target_entry_addr(): pointer {.cdecl, importc.}

  suite "HCR process target runtime":
    test "agent runtime patches a linked function in the current process":
      var target = initProcessTargetRuntime()
      target.addProcessTargetSymbol(
        FunctionName,
        addressFromPointer(repro_hcr_process_target_entry_addr()))
      defer: target.close()

      check repro_hcr_process_target_entry() == 11

      let request = directPatchRequest(
        patchId = "patch-process-0001",
        supportProfile = SupportProfile,
        changedFunctions = [FunctionName],
        targetSymbols = [FunctionName],
        directPatchBytes = aarch64ReturnImmediateBytes(77),
        debugObjectBytes = [byte 0x7f, 0x45, 0x4c, 0x46],
        unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
        sourceGenerationMap = [
          HcrSourceGenerationEntry(
            sourcePath: "tests/unit/t_hcr_agent_process_target.nim",
            generation: 1,
            snapshotDigest: "blake3-256:process-target-generation-1",
            lineTableDigest: "blake3-256:process-target-line-table-1")
        ])
      let applied = applyDirectPatchRequest(
        processRuntimeOps(target),
        request,
        registerDebugUnwind = false)

      check repro_hcr_process_target_entry() == 77
      check applied.patchApplied.patchId == "patch-process-0001"
      check applied.patchApplied.changedFunctions == @[FunctionName]
      check applied.patchApplied.symbolGeneration == 1'u64
      check applied.patchApplied.oldCodeRetained
      check not applied.patchApplied.sharedLibraryPositivePath
      check applied.jitRegistration.isNone
      check applied.unwindRegistration.isNone
      check target.flushes.len == 2
      check target.retainedRegions.len == 1
      check target.symbolGenerations[FunctionName] == 1'u64

else:
  suite "HCR process target runtime":
    test "process target runtime is macOS arm64-only":
      skip()
