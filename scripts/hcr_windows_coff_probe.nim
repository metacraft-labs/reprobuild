## Print the production COFF reader's facts for one replacement symbol.

import std/[json, os]
import repro_hcr_linkgraph

proc main() =
  if paramCount() != 2:
    raise newException(ValueError, "usage: hcr_windows_coff_probe OBJECT SYMBOL")
  var facts: CoffObjectFacts
  let graph = parseCoffAmd64Object(paramStr(1), facts)
  let symbol = graph.findSymbol(paramStr(2))
  if not symbol.isDefined:
    raise newException(ValueError, "symbol is absent")
  var relocations = newJArray()
  for relocation in graph.relocationsForSymbol(symbol):
    relocations.add %*{
      "kind": relocation.kindName,
      "target": relocation.targetName,
      "offset": relocation.offset
    }
  echo $(%*{
    "symbol": symbol.name,
    "sectionId": symbol.sectionId,
    "size": symbol.size,
    "relocations": relocations
  })

when isMainModule:
  main()
