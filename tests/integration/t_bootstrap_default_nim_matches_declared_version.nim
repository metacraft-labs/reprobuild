## The SUBJECT is the real bootstrap C/Nim producer boundary, including its
## selected immutable package, not a pure policy unit or a fixture compiler.
## Run this whole integration file only after its declared platform producer
## inputs/cost are admitted: Linux/Nix C+Nim packages; Windows/macOS official
## C/archive inputs; no-Nix POSIX the existing source-bootstrap producer.
## Nothing installs a global SDK/default, changes a project pin or supplies
## REPRO_NIM_COMPILER. A private tool store owns all receipts/links and is
## removed after the synchronous producer and version child have settled.
## No mocks. The predecessor's real Linux/Nix default reports2.2.4 and fails
## the SAME actual-version oracle against declared BootstrapNimVersion2.2.10.

import std/[os, strutils, tempfiles, unittest]
import repro_tool_profiles
import repro_test_support

suite "production bootstrap default Nim":
  test "the unexplicit producer realizes the declared release":
    let scratch = createTempDir("repro-bootstrap-default-", "")
    defer: removeDir(scratch)
    let store = scratch / "tool-store"
    let cc = provisionBootstrapCCompiler(store)
    let nim = provisionBootstrapNim(store, cc = cc.path)
    let reported = runProgramSplit(nim, ["--version"], timeoutMs = 15_000)
    checkpoint reported.stdout & reported.stderr
    if reported.code != 0:
      # Catchable failure preserves the private-store defer on refusal.
      raise newException(IOError, "default Nim --version failed (" &
        $reported.code & "): " & reported.stdout & reported.stderr)
    var actualVersion = ""
    for line in reported.stdout.splitLines():
      if line.startsWith("Nim Compiler Version "):
        let words = line.splitWhitespace()
        if words.len >= 4:
          actualVersion = words[3]
        break
    check actualVersion == BootstrapNimVersion
