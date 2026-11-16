## The add-on diagnostics are defined once, in
## ``repro_infra/addon_diagnostics`` (``AddOnDiagnostic``), and every
## add-on refusal's message starts with its diagnostic's name.
##
## A script, a test and the operator match a refusal by that name, so a
## name spelled as a string literal in some other module can drift from the
## set (a typo, a rename on one side only) without anything noticing, and a
## refusal whose message starts with free text ("refusing ...") cannot be
## matched by name at all. Both had happened: ``agent_checks`` and
## ``nft_tables`` defined ``EAddOnManagementPath``,
## ``EAddOnCompiledProfile`` and ``EAddOnEgressObserverUnavailable`` as
## their own string constants, ``addon_apply`` spelled ``EAddOnContained``
## and ``EAddOnUnitShadows`` inline, and the collision refusals that have no
## more specific diagnostic (a symbolic link on the target path, a foreign
## diversion, a kept pre-bootstrap input) were raised with no name.
##
## What this holds:
##
## 1. Every ``EAddOn<Name>`` mentioned in the library and app sources and in
##    the public docs is a value of ``AddOnDiagnostic``.
## 2. No source file other than ``addon_diagnostics.nim`` spells a name in a
##    string literal: everything else renders it from the enum.
## 3. A collision refusal with no more specific diagnostic is
##    ``EAddOnCollision``: its message starts with the name. Driven through
##    the real dpkg collision driver over a fixture database. (It stays an
##    ``AddonCollisionError``, not an ``EAddOn``: the switch handles the two
##    differently, see ``collision.nim``.)
## 4. The constants other modules export for their refusals' prefixes are
##    rendered from the enum.
##
## *Mocking.* Case 3 reads a fixture dpkg database (a real ``diversions``
## file in dpkg's format under a temporary root) rather than the build
## host's: the host's own database would make the result depend on what is
## installed. No unit is queried, so ``unitProvision`` answers "not found".
##
## Regression test for reprobuild-pm
## ``issues/2026-11-12-diagnostic-names-and-exit-codes-are-not-defined-once.md``.

import std/[os, re, sets, strutils, unittest]

import repro_infra/addon_diagnostics
import repro_addon/[agent_checks, collision, nft_tables]

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
const DefiningModule = "libs/repro_infra/src/repro_infra/addon_diagnostics.nim"

proc diagnosticNames(): HashSet[string] =
  for d in AddOnDiagnostic: result.incl($d)

proc isDiagnostic(name: string): bool = name in diagnosticNames()

iterator scannedFiles(): string =
  ## The production sources (``libs/*/src``, ``apps``) and the public docs.
  for dir in [RepoRoot / "libs", RepoRoot / "apps", RepoRoot / "docs"]:
    for path in walkDirRec(dir, relative = true):
      let full = dir / path
      let rel = relativePath(full, RepoRoot)
      if rel.startsWith("libs/") and "/src/" notin rel: continue
      if full.endsWith(".nim") or full.endsWith(".md"):
        yield rel

let nameRe = re"EAddOn[A-Z][A-Za-z]*"
let literalRe = re"""("[^"\n]*)(EAddOn[A-Z][A-Za-z]*)"""

suite "the add-on diagnostics are defined once":
  test "every EAddOn name the sources and docs mention is in AddOnDiagnostic":
    var unknown: seq[string]
    for rel in scannedFiles():
      var n = 0
      for line in lines(RepoRoot / rel):
        inc n
        for name in line.findAll(nameRe):
          if not isDiagnostic(name):
            unknown.add(rel & ":" & $n & ": " & name)
    if unknown.len > 0:
      checkpoint("names that AddOnDiagnostic does not define:\n  " &
        unknown.join("\n  "))
    check unknown.len == 0

  test "no module but addon_diagnostics spells a name in a string literal":
    var spelled: seq[string]
    for rel in scannedFiles():
      if rel == DefiningModule or not rel.endsWith(".nim"): continue
      var n = 0
      for line in lines(RepoRoot / rel):
        inc n
        let code = line.strip()
        if code.startsWith("#"): continue   # a comment or doc comment
        if line.find(literalRe) >= 0:
          spelled.add(rel & ":" & $n & ": " & code)
    if spelled.len > 0:
      checkpoint("names spelled outside " & DefiningModule & ":\n  " &
        spelled.join("\n  "))
    check spelled.len == 0

  test "a collision refusal is EAddOnCollision and its message starts with the name":
    let root = getTempDir() / ("repro-addon-diag-names-" &
      $getCurrentProcessId())
    removeDir(root)
    createDir(root / "var/lib/dpkg/info")
    createDir(root / "etc")
    writeFile(root / "var/lib/dpkg/status", "Package: x\n")
    # A diversion of /etc/foreign by another package: §4.3 "Existing
    # diversion by someone else", refused with no opt-in.
    writeFile(root / "var/lib/dpkg/diversions",
      root / "etc/foreign" & "\n" & root / "etc/foreign.other" &
      "\nsomepkg\n")
    defer: removeDir(root)
    proc noUnits(unit: string): UnitProvision {.gcsafe.} =
      UnitProvision(loadState: "not-found")
    let d = newDpkgDriver(root, noUnits)
    var refusal: ref CatchableError
    try:
      discard d.decide(DecisionInputs(address: "dv", kind: tkDiversion),
                       root / "etc/foreign")
    except CatchableError as e:
      refusal = e
    check refusal != nil
    if refusal != nil:
      checkpoint("refusal: " & $refusal.name & ": " & refusal.msg)
      check isDiagnostic("EAddOnCollision")
      check refusal.msg.startsWith("EAddOnCollision: ")
      check "already diverted" in refusal.msg

  test "the refusal prefixes other modules export are rendered from the enum":
    for prefix in [ManagementPathRefusal, CompiledProfileRefusal,
                   EgressObserverUnavailable]:
      checkpoint(prefix)
      check isDiagnostic(prefix)
