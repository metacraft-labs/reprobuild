## Spec-Implementation M2e — ``repro lock explain <variant>`` CLI
## integration test.
##
## Drives a built ``./build/bin/repro`` binary against a fixture file
## describing variants + packages, asserts the structured output
## (text default + ``--json``) is correct, and verifies the unsat
## path emits the assumption-interface core via the JSON surface.
##
## The test refuses to run unless ``./build/bin/repro`` already
## exists — it does NOT trigger a build itself. The repro suite's
## ``run_tests.sh`` ensures the binary is present before running
## integration tests.

import std/[json, os, osproc, strutils, unittest]

const reproBinary = "./build/bin/repro"

proc writeFixture(path: string; content: string) =
  writeFile(path, content)

suite "Spec-Implementation M2e: repro lock explain":

  test "explain a satisfied variant — text output":
    if not fileExists(reproBinary):
      skip()
    else:
      let fixturePath = getTempDir() / "m2e-cli-basic.txt"
      writeFixture(fixturePath, """
variant compiler
kind: enum
values: gcc, clang
default: gcc
set: clang
""")
      defer: removeFile(fixturePath)
      let (output, exitCode) = execCmdEx(reproBinary &
        " lock explain compiler --fixture " & fixturePath)

      # 1. Exit 0 — satisfied.
      check exitCode == 0
      # 2. The text rendering names the chosen value.
      check "chosen: clang" in output
      # 3. Both contributions surface, set first.
      check "set -> clang" in output
      check "default -> gcc" in output
      # 4. The structural section headers are present.
      check "gating constraints:" in output
      check "parent influences:" in output

  test "explain a satisfied variant — JSON output":
    if not fileExists(reproBinary):
      skip()
    else:
      let fixturePath = getTempDir() / "m2e-cli-json.txt"
      writeFixture(fixturePath, """
variant compiler
kind: enum
values: gcc, clang
default: gcc
set: clang
""")
      defer: removeFile(fixturePath)
      let (output, exitCode) = execCmdEx(reproBinary &
        " lock explain compiler --fixture " & fixturePath &
        " --json 2>/dev/null")

      check exitCode == 0
      # 1. Output is valid JSON.
      var parsed: JsonNode
      var parseOk = true
      try:
        parsed = parseJson(output.strip())
      except JsonParsingError:
        parseOk = false
      check parseOk
      # 2. Top-level shape: variant + chosen + contributions array.
      check parsed["variant"].getStr() == "compiler"
      check parsed["chosen"].getStr() == "clang"
      check parsed["contributions"].len == 2
      # 3. Highest-priority contribution lands at index 0.
      check parsed["contributions"][0]["priority"].getStr() == "set"
      check parsed["contributions"][0]["value"].getStr() == "clang"

  test "explain an unsat fixture — minimal core in JSON":
    if not fileExists(reproBinary):
      skip()
    else:
      let fixturePath = getTempDir() / "m2e-cli-unsat.txt"
      writeFixture(fixturePath, """
variant a
kind: enum
values: on
force: on
requires: on -> b = on

variant b
kind: enum
values: on, off
default: off
conflicts: on -> c = on

variant c
kind: enum
values: on
force: on
""")
      defer: removeFile(fixturePath)
      let (output, exitCode) = execCmdEx(reproBinary &
        " lock explain a --fixture " & fixturePath &
        " --json 2>/dev/null")

      # 1. Exit code 3 — unsat (CLI contract).
      check exitCode == 3
      # 2. JSON parses.
      var parsed: JsonNode
      var parseOk = true
      try:
        parsed = parseJson(output.strip())
      except JsonParsingError:
        parseOk = false
      check parseOk
      # 3. The status field is ``unsat``.
      check parsed["status"].getStr() == "unsat"
      # 4. The core array is non-empty — the assumption-interface
      #    re-solve drove the binding successfully.
      check parsed["core"].len >= 1
      # 5. At least one entry has kind ``constraint`` (variant
      #    requires / conflicts).
      var sawConstraint = false
      for entry in parsed["core"]:
        if entry["kind"].getStr() == "constraint":
          sawConstraint = true
      check sawConstraint

  test "missing variant positional emits exit 2":
    if not fileExists(reproBinary):
      skip()
    else:
      let (_, exitCode) = execCmdEx(reproBinary & " lock explain")
      check exitCode == 2

  test "unknown verb emits exit 2":
    if not fileExists(reproBinary):
      skip()
    else:
      let (_, exitCode) = execCmdEx(reproBinary & " lock bogus")
      check exitCode == 2
