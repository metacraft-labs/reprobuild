## Inspect one exact private Windows function through the production PE/PDB
## identity reader and serialized DbgHelp resolver.

import std/[json, os]
import repro_hcr_linkgraph

proc main() =
  if paramCount() != 3:
    raise newException(ValueError,
      "usage: hcr_windows_symbol_probe IMAGE PDB SYMBOL")
  let image = paramStr(1)
  let pdb = paramStr(2)
  let symbol = paramStr(3)
  let resolution = resolveWindowsPdbFunction(image, pdb, symbol)
  var report = %*{
    "schemaId": "reprobuild.hcr.windows-symbol-probe.v1",
    "symbol": symbol,
    "status": $resolution.status,
    "reason": resolution.reason,
    "matchCount": resolution.matchCount,
    "rva": resolution.rva,
    "size": resolution.size
  }
  if resolution.status == wprsOk and resolution.matchCount == 1:
    let bytes = readPeImageBytesAtRva(image, resolution.rva, 32)
    report["entryBytes"] = %bytes
  echo $report
  if resolution.status != wprsOk or resolution.matchCount != 1:
    quit(2)

when isMainModule:
  main()
