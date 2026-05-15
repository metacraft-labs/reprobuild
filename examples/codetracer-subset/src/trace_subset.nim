import std/[os, sequtils, strutils]

if paramCount() != 1:
  quit "usage: trace_subset <trace-file>", 2

let events = readFile(paramStr(1)).splitLines().filterIt(it.len > 0)
echo "trace events: ", events.len
