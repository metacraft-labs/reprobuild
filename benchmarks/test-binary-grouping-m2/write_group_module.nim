## Writes build/test-groups/<group>.nim for each group named on the command
## line, from repro_tests.nim, with the recipe's own groupModuleText.
import std/[os, strutils, tables]
import ct_test_nim_unittest/grouping
let index = parseCaseSourceIndex(readFile("repro_tests.nim"))
for g in commandLineParams():
  var members: seq[string]
  for m in index.groupMembers.getOrDefault(g): members.add m
  doAssert members.len > 0, g
  writeFile(groupModulePath(g), groupModuleText(g, members))
  echo g, " ", members.len
