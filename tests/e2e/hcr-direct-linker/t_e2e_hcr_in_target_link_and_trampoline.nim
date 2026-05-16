import std/[json, os, osproc, strutils, unittest]

import repro_hcr_linker
import repro_hcr_linkgraph
import repro_hcr_test

proc q(value: string): string =
  quoteShell(value)

proc shellCommand(args: openArray[string]): string =
  for index, arg in args:
    if index > 0:
      result.add(" ")
    result.add(q(arg))

proc runSuccess(command: string; cwd = getCurrentDir()): string =
  let res = execCmdEx(command, workingDir = cwd)
  if res.exitCode != 0:
    checkpoint(res.output)
  check res.exitCode == 0
  res.output

proc operationNames(evidence: PatchTransactionEvidence): seq[string] =
  for op in evidence.operations:
    result.add op.name

proc commitFlags(evidence: PatchTransactionEvidence): seq[bool] =
  for op in evidence.operations:
    result.add op.commitMutation

when defined(macosx) and defined(arm64):
  suite "e2e_hcr_in_target_link_and_trampoline":
    test "shared direct-HCR transaction applies to fake and real target process":
      let repoRoot = getCurrentDir()
      let functionName = "_hcr_m27_entry"
      let oldBytes = aarch64PatchableReturnBytes(11, sledNops = 4)
      let patchBytes = aarch64ReturnImmediateBytes(77)
      let plan = directPatchPlanFromBytes(functionName, patchBytes)

      var fake = initFakeTarget(functionName, oldBytes)
      let fakeEntry = fake.entryAddress(functionName)
      check fake.callOriginalPointer(functionName) == 11
      check fake.regionProtectionAt(fakeEntry) == tpReadExec

      expect(ValueError):
        fake.debugWriteBytes(fakeEntry, @[0'u8])
      expect(ValueError):
        fake.debugSetProtection(fakeEntry, tpReadWriteExec)

      let fakeTx = patchTransactionFromPlan(plan, functionName, fakeEntry,
        nopSledBytes = 16)
      let fakeEvidence = applyPatchTransaction(fake.targetOps(), fakeTx)

      check fake.callOriginalPointer(functionName) == 77
      check fake.latestAddress(functionName) == fakeEvidence.patchAddress
      check fake.symbolGeneration(functionName) == 1
      check fake.regionProtectionAt(fakeEntry) == tpReadExec
      check fake.regionProtectionAt(fakeEvidence.patchAddress) == tpReadExec
      check fake.retainedRegions.len == 1
      check fake.retainedRegions[0].bytes == fakeEvidence.oldEntryBytes
      check bytesHex(fakeEvidence.oldEntryBytes) == "1f2003d5"
      check fakeEvidence.trampoline.kind == tkAarch64BranchImm26
      check fakeEvidence.trampoline.destinationAddress == fakeEvidence.patchAddress
      check fakeEvidence.operationNames == @[
        "allocate-patch-memory",
        "write-patch-bytes",
        "set-patch-memory-executable",
        "flush-patch-instruction-cache",
        "install-trampoline",
        "flush-trampoline-instruction-cache",
        "publish-symbol-generation",
        "retain-old-patch-region"
      ]
      check fakeEvidence.commitFlags == @[
        false, false, false, false, true, true, true, true
      ]
      check fakeEvidence.preparationComplete
      check fakeEvidence.commitComplete
      check not fakeEvidence.sharedLibraryPositivePath
      check not fakeEvidence.debuggerUnwindRegistered
      check fake.flushes.len == 2
      check fake.trampolineWrites.len == 1

      let targetSource = repoRoot / "tests" / "e2e" / "hcr-direct-linker" /
        "hcr_m27_target.nim"
      let targetBin = repoRoot / "build" / "test-bin" / "hcr_m27_target"
      createDir(repoRoot / "build" / "test-bin")
      createDir(repoRoot / "build" / "nimcache")
      discard runSuccess(shellCommand([
        "nim", "c", "--threads:on",
        "--nimcache:" & repoRoot / "build" / "nimcache" / "hcr_m27_target",
        "--out:" & targetBin,
        targetSource
      ]), repoRoot)

      check not fileExists(targetBin & ".dylib")
      check not fileExists(targetBin & ".so")

      let realOutput = runSuccess(q(targetBin), repoRoot).strip()
      check not realOutput.contains("dlopen")
      check not realOutput.contains("dlsym")
      check not realOutput.contains("LoadLibrary")
      check not realOutput.contains("GetProcAddress")
      let real = parseJson(realOutput)

      check real["schemaId"].getStr() ==
        "reprobuild.hcr.m27.real-target-result.v1"
      check real["before"].getInt() == 11
      check real["after"].getInt() == 77
      check real["targetProtection"].getStr() == "tpReadExec"
      check real["patchProtection"].getStr() == "tpReadExec"
      check real["retainedOldEntryBytesHex"].getStr() == "1f2003d5"
      check real["symbolGeneration"].getInt() == 1
      check real["flushCount"].getInt() == 2
      check real["sharedLibraryPositivePath"].getBool() == false
      check real["debuggerUnwindRegistered"].getBool() == false

      let realEvidence = real["evidence"]
      check realEvidence["sharedLibraryPositivePath"].getBool() == false
      check realEvidence["debuggerUnwindRegistered"].getBool() == false
      check realEvidence["trampoline"]["kind"].getStr() ==
        "tkAarch64BranchImm26"
      check realEvidence["trampoline"]["bytesHex"].getStr().len == 8
      check realEvidence["operations"].len == 8
      check realEvidence["operations"][4]["name"].getStr() == "install-trampoline"
      check realEvidence["operations"][4]["commitMutation"].getBool() == true
      for i in 0 .. 3:
        check realEvidence["operations"][i]["commitMutation"].getBool() == false

      let realPlan = real["patchPlan"]
      check realPlan["schemaId"].getStr() ==
        "reprobuild.hcr.patch-plan-evidence.v1"
      check realPlan["sharedLibraryPositivePath"].getBool() == false
      check realPlan["plannedSectionBytes"][0]["bytesHex"].getStr() ==
        bytesHex(patchBytes)

      var inspection = newJObject()
      inspection["schemaId"] =
        newJString("reprobuild.hcr.m27.combined-inspection.v1")
      inspection["supportProfile"] =
        newJString("m27-macos-arm64-direct-trampoline")
      inspection["fakeBefore"] = newJInt(11)
      inspection["fakeAfter"] = newJInt(fake.callOriginalPointer(functionName))
      inspection["fakeEvidence"] = transactionEvidenceJson(fakeEvidence)
      inspection["realResult"] = real
      inspection["sharedLibraryPositivePath"] = newJBool(false)
      inspection["debuggerUnwindRegistered"] = newJBool(false)
      let logDir = repoRoot / "test-logs"
      createDir(logDir)
      writeFile(logDir / "e2e_hcr_in_target_link_and_trampoline.json",
        pretty(inspection))

when not (defined(macosx) and defined(arm64)):
  suite "e2e_hcr_in_target_link_and_trampoline":
    test "M27 real direct trampoline gate is macOS arm64-only":
      skip()
