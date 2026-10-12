## The attestation surface has a census over its own CODE, and this gate
## is where it is enforced.
##
## ## The hole this closes, which is not hypothetical
##
## A commit removed nine source files from the attestation surface — two
## library modules, a verifier module, a test harness, three gates and
## two committed mutation tools — and *every gate in this repository
## stayed green*. Nothing was weakened and no check was skipped. The
## suite simply had no check whose subject is the existence of a module.
##
## Three things conspired:
##
##   * the structural checks in this repository count *refusal sites*,
##     *test cases* and *pinned fixtures*, and count no modules;
##   * the derived artifacts — the generated test-edge table, the static
##     case-count baseline and the source inventory — are REGENERATED
##     from a directory scan, so a deleted gate does not contradict them,
##     it stops appearing in them. A smaller tree is a consistent tree;
##   * the umbrella's ``import``/``export`` lines were removed in the
##     same edit, so not even a compile failed.
##
## `attestation-corpus-census.tsv` is the sibling of this idea for pinned
## BYTES, and it is why a fixture cannot vanish quietly. This gate is the
## same idea for the attestation libraries' own LOGIC, and for the
## committed tooling that nothing else in the tree references and which
## therefore has no other reason to stay.
##
## ## What it asserts, and why each half is needed
##
## 1. *Every path the census records is present and non-empty.* This is
##    the headline: deleting a module turns this red. On its own it is
##    weak, because deleting the row with the file would defeat it —
##    hence 2.
## 2. *The census matches a directory scan in BOTH directions*, per
##    directory, with the per-directory row COUNTS pinned as literal
##    numbers in this file. A module added without a row is red; a row
##    whose file is gone is red; and deleting a file together with its
##    row is still red, because the count no longer matches. That is
##    three edits to make a module disappear quietly, one of them to a
##    number in a test that says what the number is for.
## 3. *The recorded umbrella wiring is what the umbrella actually does*,
##    in both directions. Nine modules are deliberately not re-exported
##    and the census says which; a module silently unwired from its
##    library is red while the file is still there, which is the other
##    half of what the commit above did.
## 4. *The umbrella imports and exports nothing the census does not
##    record*, so the wiring cannot grow a name this file has never
##    heard of.
##
## ## What it deliberately does NOT assert
##
## Nothing about the CONTENT of any recorded file: not a digest, not a
## line count, not a symbol. A census that pinned content would be a
## second, worse copy of what the gates already check, and every ordinary
## edit would be red. The claim here is narrow on purpose — *this file
## still exists, is still wired the way the record says, and the record
## still enumerates what is on disk* — and it is exactly the claim that
## was missing.
##
## It also says nothing about whether a recorded module is EXERCISED.
## Sixteen of the forty-three are reached only through their umbrella, so
## a per-module "some test names it" rule is not available without a
## token loose enough to match prose; that is recorded here rather than
## approximated.
##
## ## Mocking
##
## None. Real files, real directory scans, the committed record.

import std/[algorithm, os, sequtils, strutils, unittest]

# DELIBERATELY NOT IMPORTING THE ATTESTATION LIBRARIES. A census that
# cannot run while the thing it audits is missing reports nothing on the
# one day it matters: removing a module would make this gate fail to
# COMPILE, which reads like a build break rather than like the finding it
# is. Everything below is a file-system and text question, so it stays a
# file-system and text question.

const
  # The row counts, pinned as numbers. See property 2 in the header:
  # without these, deleting a file and its row together is silent.
  ReproAttestModules = 26
  ReproAttestVerifyModules = 18
  UmbrellaModules = 2
  MutationTools = 4
  AttestationTestSources = 93

  AttestDir = "libs/repro_attest/src/repro_attest"
  VerifyDir = "libs/repro_attest_verify/src/repro_attest_verify"
  AttestUmbrella = "libs/repro_attest/src/repro_attest.nim"
  VerifyUmbrella = "libs/repro_attest_verify/src/repro_attest_verify.nim"
  ToolsDir = "tools/attestation-mutations"
  TestsDir = "tests/integration"

  # The token a test source carries when it is part of this surface.
  # Substring rather than an import-grammar parse, and that is a choice:
  # a parse has corner cases this gate would then own, while a substring
  # can only ever over-include — and over-including costs one census row,
  # which is the failure mode to prefer.
  SurfaceToken = "repro_attest"

type
  CensusRow = object
    path: string
    kind: string
    umbrella: string
    summary: string

proc repoRoot(): string =
  ## Located from this file rather than from the working directory, so
  ## the gate reads the same tree whatever it is run from.
  currentSourcePath().parentDir.parentDir.parentDir

proc censusRows(): seq[CensusRow] =
  let text = readFile(repoRoot() / TestsDir / "attestation-module-census.tsv")
  var lineNo = 0
  for raw in text.splitLines():
    inc lineNo
    let line = raw.strip(leading = false, trailing = true)
    if line.len == 0 or line.startsWith("#"):
      continue
    let f = line.split('\t')
    doAssert f.len == 4,
      "attestation-module-census.tsv:" & $lineNo & ": " & $f.len &
      " fields, expected 4"
    result.add CensusRow(path: f[0], kind: f[1], umbrella: f[2],
                         summary: f[3])

proc pathsOfKind(rows: seq[CensusRow]; kind: string): seq[string] =
  for r in rows:
    if r.kind == kind: result.add r.path
  result.sort()

proc nimFilesIn(dir: string): seq[string] =
  for p in walkFiles(repoRoot() / dir / "*.nim"):
    result.add dir & "/" & p.extractFilename
  result.sort()

proc toolFilesIn(dir: string): seq[string] =
  ## Files only. A directory is not a tool, and a generated cache
  ## (``__pycache__``) is not one either — it is excluded by name rather
  ## than by extension so that a future tool in any language still has to
  ## be recorded.
  for kind, p in walkDir(repoRoot() / dir):
    if kind != pcFile: continue
    let name = p.extractFilename
    if name.startsWith(".") or name.startsWith("__"): continue
    result.add dir & "/" & name
  result.sort()

proc attestationTestSources(): seq[string] =
  ## Every Nim source under the integration test tree whose text names an
  ## attestation library. Recursive: three of them live in a
  ## subdirectory.
  let root = repoRoot()
  for p in walkDirRec(root / TestsDir):
    if not p.endsWith(".nim"): continue
    if SurfaceToken notin readFile(p): continue
    result.add p[root.len + 1 .. ^1].replace('\\', '/')
  result.sort()

proc umbrellaWiring(umbrellaPath, pkg: string):
    tuple[imported, exported: seq[string]] =
  ## What the umbrella's own text says, read as text. ``export`` lists
  ## wrap, and a wrapped line is a continuation of the one above it, so
  ## the scan carries the flag until a line does not end in a comma.
  let text = readFile(repoRoot() / umbrellaPath)
  var inExport = false
  for raw in text.splitLines():
    var line = raw
    let hash = line.find('#')
    if hash >= 0: line = line[0 ..< hash]
    let s = line.strip()
    if s.len == 0:
      inExport = false
      continue
    if s.startsWith("import ./" & pkg & "/"):
      result.imported.add s["import ./".len + pkg.len + 1 .. ^1].strip()
      continue
    var body = ""
    if s.startsWith("export "):
      body = s["export ".len .. ^1]
      inExport = true
    elif inExport:
      body = s
    else:
      continue
    for tok in body.split({',', ' '}):
      let t = tok.strip()
      if t.len > 0: result.exported.add t
    inExport = s.endsWith(",")
  result.imported.sort()
  result.exported.sort()

let rows = censusRows()

suite "every module the record says was delivered is in the tree":

  test "every recorded path names a file that exists and is not empty":
    # The headline. Nine files once left this tree with no gate to say
    # so; this is the gate that says so.
    var missing: seq[string] = @[]
    var empty: seq[string] = @[]
    for r in rows:
      let full = repoRoot() / r.path
      if not fileExists(full):
        missing.add r.path
      elif getFileSize(full) <= 0:
        empty.add r.path
    check missing == newSeq[string]()
    check empty == newSeq[string]()

  test "the record is not empty, and every row carries the four fields":
    # A reader that silently returned nothing would make every other
    # case in this file vacuously true, which is the shape this gate
    # exists to refuse one level down. ``censusRows`` already refuses a
    # row with the wrong field count; this pins that it read any.
    check rows.len ==
      ReproAttestModules + ReproAttestVerifyModules + UmbrellaModules +
      MutationTools + AttestationTestSources
    for r in rows:
      check r.path.len > 0
      check r.kind in ["library", "umbrella", "tool", "gate"]
      check r.summary.len > 0

suite "the record and the tree agree in both directions":

  test "the two library directories are enumerated exactly":
    let recorded = pathsOfKind(rows, "library")
    let onDisk = (nimFilesIn(AttestDir) & nimFilesIn(VerifyDir)).sorted()
    # Named rather than counted, so a failure says WHICH module moved.
    check recorded.filterIt(it notin onDisk) == newSeq[string]()
    check onDisk.filterIt(it notin recorded) == newSeq[string]()
    check recorded == onDisk
    # And pinned as numbers, because the two sets above agree just as
    # well after a file and its row are deleted together.
    check nimFilesIn(AttestDir).len == ReproAttestModules
    check nimFilesIn(VerifyDir).len == ReproAttestVerifyModules

  test "both umbrellas are recorded":
    check pathsOfKind(rows, "umbrella") ==
      @[AttestUmbrella, VerifyUmbrella].sorted()
    check pathsOfKind(rows, "umbrella").len == UmbrellaModules

  test "the committed mutation tooling is enumerated exactly":
    # These have no other reason to stay: nothing in the suite imports
    # them, nothing builds them, and a deletion costs no compile. One of
    # the two that vanished was the driver for the very table that
    # proved the deleted gates were checks.
    let recorded = pathsOfKind(rows, "tool")
    let onDisk = toolFilesIn(ToolsDir)
    check recorded.filterIt(it notin onDisk) == newSeq[string]()
    check onDisk.filterIt(it notin recorded) == newSeq[string]()
    check recorded.len == MutationTools

  test "every attestation test source is recorded, and every recorded one exists":
    # The gates are the other half of what was lost, and the derived
    # artifacts cannot catch their loss: they are regenerated from a
    # directory scan, so three fewer gates is three fewer rows and no
    # disagreement anywhere.
    let recorded = pathsOfKind(rows, "gate")
    let onDisk = attestationTestSources()
    check recorded.filterIt(it notin onDisk) == newSeq[string]()
    check onDisk.filterIt(it notin recorded) == newSeq[string]()
    check recorded.len == AttestationTestSources

suite "the recorded wiring is what the umbrella does":

  test "a module recorded exported is imported AND re-exported":
    for (umb, pkg, dir) in [(AttestUmbrella, "repro_attest", AttestDir),
                            (VerifyUmbrella, "repro_attest_verify", VerifyDir)]:
      let wiring = umbrellaWiring(umb, pkg)
      for r in rows:
        if r.kind != "library" or not r.path.startsWith(dir & "/"): continue
        if r.umbrella != "exported": continue
        let stem = r.path.extractFilename[0 ..< r.path.extractFilename.len - 4]
        check stem in wiring.imported
        check stem in wiring.exported

  test "a module recorded standalone is neither imported nor re-exported":
    # Without this the previous case is satisfied by an umbrella that
    # exports everything, and the distinction the column records would
    # mean nothing.
    var standalone = 0
    for (umb, pkg, dir) in [(AttestUmbrella, "repro_attest", AttestDir),
                            (VerifyUmbrella, "repro_attest_verify", VerifyDir)]:
      let wiring = umbrellaWiring(umb, pkg)
      for r in rows:
        if r.kind != "library" or not r.path.startsWith(dir & "/"): continue
        if r.umbrella != "standalone": continue
        inc standalone
        let stem = r.path.extractFilename[0 ..< r.path.extractFilename.len - 4]
        check stem notin wiring.imported
        check stem notin wiring.exported
    # A reachable input for the case above: if the column ever held only
    # one value, the two cases together would still pass and prove
    # nothing about either.
    check standalone == 9

  test "the umbrellas import and export nothing the record does not name":
    for (umb, pkg, dir) in [(AttestUmbrella, "repro_attest", AttestDir),
                            (VerifyUmbrella, "repro_attest_verify", VerifyDir)]:
      let wiring = umbrellaWiring(umb, pkg)
      var recordedStems: seq[string] = @[]
      for r in rows:
        if r.kind != "library" or not r.path.startsWith(dir & "/"): continue
        recordedStems.add r.path.extractFilename[0 ..<
          r.path.extractFilename.len - 4]
      check wiring.imported.filterIt(it notin recordedStems) == newSeq[string]()
      for name in wiring.exported:
        # The umbrellas also re-export names that are not modules of
        # their own package; those are not this census's subject. What is
        # refused is a MODULE-shaped export naming a file no row records.
        if fileExists(repoRoot() / dir / (name & ".nim")):
          check name in recordedStems
