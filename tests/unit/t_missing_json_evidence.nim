## No mocks: exercise the report readers in repro_cli_support against JSON
## nodes and persisted reports, including the missing-key nil sentinel.
## Candidate extraction only inspects paths and file existence; the empty .c
## and .o files below are real filesystem inputs, never loaded as objects.
import std/[json, os, strutils, unittest]
import repro_cli_support

suite "optional report evidence":
  test "missing and malformed evidence produce zero counts":
    for action in [parseJson("{}"), parseJson("{\"evidence\":null}"),
        parseJson("{\"evidence\":7}"), parseJson("{\"evidence\":[]}"),
        parseJson("{\"evidence\":{}}")]:
      let counts = evidenceCountsJsonFromReportForTest(action)
      check counts.len == 7
      for key, count in counts:
        check count.getInt == 0

  test "array counts preserve populated evidence and reject other types":
    let counts = evidenceCountsJsonFromReportForTest(parseJson("""
      {"evidence":{"declaredInputs":["a","b"],"declaredOutputs":null,
        "depfileInputs":{},"monitorReads":"bad","monitorWrites":[],
        "monitorProbes":["x"],"diagnostics":[1,2,3]}}
      """))
    check counts == parseJson("""{"declaredInputs":2,"declaredOutputs":0,
      "depfileInputs":0,"monitorReads":0,"monitorWrites":0,
      "monitorProbes":1,"diagnostics":3}""")

  test "path arrays tolerate missing fields and retain nonempty strings":
    for node in [JsonNode(nil), newJNull(), %7, newJArray(), newJObject()]:
      check jsonStringSeqFieldForTest(node, "declaredInputs").len == 0
    for value in [newJNull(), %7, %"bad", newJObject()]:
      check jsonStringSeqFieldForTest(%*{"declaredInputs": value},
        "declaredInputs").len == 0
    check jsonStringSeqFieldForTest(parseJson("""
      {"declaredInputs":["a","",null,7,{},"b"]}"""),
      "declaredInputs") == @["a", "b"]

  test "watch reader tolerates absent evidence and categories":
    let root = getTempDir() / ("missing-evidence-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    let reportPath = root / "report.json"
    let modulePath = root / "repro.nim"
    writeFile(modulePath, "")
    for report in ["{}", "null", "[]", "{\"actions\":null}",
        "{\"actions\":7}", "{\"actions\":{}}",
        "{\"actions\":[null,7,[],{}]}",
        "{\"actions\":[{}]}",
        "{\"actions\":[{\"evidence\":null}]}",
        "{\"actions\":[{\"evidence\":7}]}",
        "{\"actions\":[{\"evidence\":[]}]}",
        "{\"actions\":[{\"evidence\":{}}]}",
        "{\"actions\":[{\"evidence\":{\"declaredInputs\":[\"input.txt\"]}}]}"]:
      writeFile(reportPath, report)
      let paths = watchPathsFromReportForTest(root, modulePath, reportPath)
      check modulePath in paths
      if report.contains("input.txt"):
        check (root / "input.txt") in paths

  test "HCR reader tolerates absent evidence and categories":
    let root = getTempDir() / ("missing-evidence-hcr-empty-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    let reportPath = root / "report.json"
    for report in ["{}", "null", "[]", "{\"actions\":null}",
        "{\"actions\":7}", "{\"actions\":{}}", "{\"actions\":[{}]}",
        "{\"actions\":[null,7,[],{}]}",
        "{\"actions\":[{\"evidence\":null}]}",
        "{\"actions\":[{\"evidence\":7}]}",
        "{\"actions\":[{\"evidence\":[]}]}",
        "{\"actions\":[{\"evidence\":{}}]}"]:
      writeFile(reportPath, report)
      check hcrWatchObjectCandidatesFromReport(root, reportPath).len == 0

  test "HCR candidates preserve source and post-processed object paths":
    let root = getTempDir() / ("missing-evidence-hcr-" & $getCurrentProcessId())
    createDir(root)
    defer: removeDir(root)
    let reportPath = root / "report.json"
    let sourcePath = root / "input.c"
    let objectPath = root / "input.o"
    let preparedPath = root / "prepared.o"
    for path in [sourcePath, objectPath, preparedPath]:
      writeFile(path, "")
    writeFile(reportPath, $(%*{"actions": [
      {"evidence": {"declaredInputs": [sourcePath],
        "declaredOutputs": [objectPath]}},
      {},
      {"evidence": {"declaredInputs": [objectPath],
        "declaredOutputs": [preparedPath]}}
    ]}))
    let candidates = hcrWatchObjectCandidatesFromReport(root, reportPath)
    check candidates.len == 1
    check candidates[0].sourcePath == sourcePath
    check candidates[0].objectPath == preparedPath
