## Offline verifier for a Windows direct-patch bundle. This exercises the same
## PE/PDB, COFF relocation, unwind, and CFG preparation path as the production
## coordinator without requiring a running target process.

import std/[json, os, strutils]
import repro_hcr_linkgraph

proc main() =
  if paramCount() != 7:
    raise newException(ValueError,
      "usage: hcr_windows_bundle_probe IMAGE PDB TARGET_SYMBOL " &
      "PATCH_OBJECT PATCH_SYMBOL FIRST_INSTRUCTION_LENGTH OUT")
  let bundle =
    try:
      buildWindowsDirectPatchBundle(
        paramStr(1), paramStr(2), paramStr(3), paramStr(4), paramStr(5),
        uint32(parseInt(paramStr(6))))
    except CatchableError as failure:
      stderr.writeLine("hcr_windows_bundle_probe: REFUSED: " & failure.msg)
      quit(2)
  let encoded = encodeWindowsDirectPatchBundle(bundle)
  writeFile(paramStr(7), cast[string](encoded))
  echo $(%*{
    "schemaId": "reprobuild.hcr.windows-bundle-probe.v1",
    "targetRva": bundle.targetRva,
    "firstInstructionLength": bundle.firstInstructionLength,
    "regionBytes": bundle.regionBytes.len,
    "functionTableCount": bundle.functionTableCount,
    "replacementEntryOffset": bundle.replacementEntryOffset,
    "bundleBytes": encoded.len
  })

when isMainModule:
  main()
