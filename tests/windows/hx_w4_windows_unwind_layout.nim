## HX-W-4 coordinator-side real COFF unwind-layout gate helper.
##
## `allowed_mocks: none`. The input is a real MSVC object. This helper invokes
## the production COFF parser and Windows unwind layout builder, writes the exact
## retained region consumed by the real-process C gate, and reports its offsets.

import std/[json, os]

import repro_hcr_linkgraph

proc require(condition: bool; message: string) =
  if not condition:
    raise newException(ValueError, message)

proc main() =
  let arguments = commandLineParams()
  require(arguments.len == 2, "usage: layout OBJECT OUTPUT")
  var facts: CoffObjectFacts
  let graph = parseCoffAmd64Object(arguments[0], facts)
  let layout = buildCoffAmd64WindowsUnwindLayout(graph)
  require(layout.functions.len >= 2,
          "fixture must contain at least two runtime functions")
  require(layout.functionEntryOffsets.len == layout.functions.len,
          "each runtime function needs one CFG entry offset")
  require(layout.functionEntryOffsets[0] mod 16 == 0,
          "patch entry is not at CFG's 16-byte granularity")
  require(layout.functions[0].beginAddress < layout.functions[1].beginAddress,
          "runtime function table is not sorted")
  let patchSymbol = graph.findSymbol("hx_w4_patch")
  require(patchSymbol.address == 0,
          "fixture's selected patch function must open its code section")
  var raw = newString(layout.bytes.len)
  for index, value in layout.bytes:
    raw[index] = char(value)
  writeFile(arguments[1], raw)
  echo $(%*{
    "ok": true,
    "schema_id": layout.schemaId,
    "region_bytes": layout.bytes.len,
    "function_table_offset": layout.functionTableOffset,
    "function_table_count": layout.functionTableCount,
    "function_entries": layout.functionEntryOffsets,
    "selected_entry": layout.functions[0].beginAddress,
    "selected_end": layout.functions[0].endAddress,
    "selected_unwind": layout.functions[0].unwindData,
    "coff_relocations": facts.relocationCount
  })

when isMainModule:
  main()
