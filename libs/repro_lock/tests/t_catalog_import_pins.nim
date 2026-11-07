## The committed lock's catalog import pins -- ReproOS-Campaign-Completion M6
## deliverable 1 (``reprobuild-specs/Federated-Catalog-Imports.md``
## § Pinning).
##
## A consumer may name a catalog by a moving ``ref``; the lock pins ONE exact
## revision and the interface-artifact identity read at it, in a
## ``catalog_imports`` array under ``[lock]``. These cases pin the codec's
## contract:
##
##   * the canonical bytes round-trip, independent of the order pins are
##     supplied in, and the key is absent when there is no pin -- so every
##     lock written before it keeps its bytes and its identity;
##   * the pins are NOT part of the lock identity;
##   * the strict reader refuses -- never skips -- an unknown, missing or
##     duplicated field, another record version, a branch name or an
##     abbreviated id where a revision is required, an upper-case revision, a
##     local path, ``file:`` URL or host-ambiguous URL as a remote, two pins
##     for one repo or one remote, an empty array, a truncated line, the key
##     twice, and any non-canonical spelling of the array;
##   * a lock that names the key in a spelling the reader skips is detected,
##     in any letter case, with every separator folded (``-``, ``_``, ``.``,
##     whitespace, zero-width), escaped, or nested in an inline table -- and
##     ``provisioning`` ``\x``-escaped likewise;
##   * a refresh's carry-forward keeps the pins byte for byte, and refuses an
##     incumbent whose pins it cannot read.
##
## Test-double policy: NO mocks, doubles or fakes -- the product's own writer
## and strict reader over real documents.

import std/[sequtils, strutils, unittest]

import repro_lock

const
  RevA = "0123456789abcdef0123456789abcdef01234567"
  RevB = "89abcdef0123456789abcdef0123456789abcdef"
  ArtA = "1111111111111111111111111111111111111111111111111111111111111111"
  ArtB = "2222222222222222222222222222222222222222222222222222222222222222"

proc pinA(): LockedCatalogImport =
  LockedCatalogImport(repo: "catalog-a", remote: "https://example.invalid/a",
    gitRef: "main", revision: RevA, interfaceArtifact: ArtA)

proc pinB(): LockedCatalogImport =
  LockedCatalogImport(repo: "catalog-b", remote: "https://example.invalid/b",
    gitRef: "", revision: RevB, interfaceArtifact: ArtB)

proc baseLock(): LockedDependencies =
  parseLockedDependencies(serializeLockedDependencies(LockedDependencies(
    schema: SolvedGraphLockSchemaV2, platform: "amd64-linux", optimal: true,
    inputsDigest: inputsDigestOf("catalog-import-pins"),
    packages: @[LockedPackage(name: "nim", version: "2.2.8", source: "nim",
      selection: ssSelected)])))

proc pinnedText(pins: seq[LockedCatalogImport]): string =
  serializeLockedDependencies(baseLock().withCatalogImportPins(pins))

proc pinsLine(text: string): string =
  for line in text.splitLines():
    if line.startsWith(CatalogImportsLockKey & " = "):
      return line
  ""

proc refusal(text: string): string =
  try:
    discard parseLockedDependencies(text)
    ""
  except CatchableError as err:
    err.msg

suite "catalog import pins in the committed lock":

  test "the pins round-trip canonically and the key is absent without them":
    let plain = serializeLockedDependencies(baseLock())
    check CatalogImportsLockKey notin plain
    check pinnedText(@[]) == plain
    let text = pinnedText(@[pinB(), pinA()])
    check pinnedText(@[pinA(), pinB()]) == text
    let line = pinsLine(text)
    check line == "catalog_imports = [{ record = \"" &
      LockedCatalogImportRecordV1 & "\", repo = \"catalog-a\", remote = " &
      "\"https://example.invalid/a\", ref = \"main\", revision = \"" & RevA &
      "\", interface_artifact = \"" & ArtA & "\" }, { record = \"" &
      LockedCatalogImportRecordV1 & "\", repo = \"catalog-b\", remote = " &
      "\"https://example.invalid/b\", ref = \"\", revision = \"" & RevB &
      "\", interface_artifact = \"" & ArtB & "\" }]"
    let parsed = parseLockedDependencies(text)
    check parsed.lockedCatalogImportPins() == @[pinA(), pinB()]
    check parsed.catalogImportPinCount == 2
    check serializeLockedDependencies(parsed) == text
    # The plain lock is unchanged by the reader, and the pins are not part
    # of the lock identity.
    check parseLockedDependencies(plain).catalogImportPinCount == 0
    check lockIdentityOf(parsed) == lockIdentityOf(parseLockedDependencies(plain))

  test "the writer refuses malformed, duplicated and empty pins":
    var bad: seq[seq[LockedCatalogImport]] = @[]
    var p = pinA(); p.revision = "main"; bad.add(@[p])
    p = pinA(); p.revision = RevA[0 ..< 12]; bad.add(@[p])
    p = pinA(); p.revision = RevA.toUpperAscii(); bad.add(@[p])
    p = pinA(); p.interfaceArtifact = ArtA[0 ..< 40]; bad.add(@[p])
    p = pinA(); p.remote = "file:///srv/catalog-a"; bad.add(@[p])
    p = pinA(); p.remote = "/srv/catalog-a"; bad.add(@[p])
    p = pinA(); p.remote = "C:/catalogs/a"; bad.add(@[p])
    p = pinA(); p.repo = ""; bad.add(@[p])
    p = pinA(); p.repo = " catalog-a"; bad.add(@[p])
    p = pinA(); p.gitRef = "main..dev"; bad.add(@[p])
    p = pinA(); p.gitRef = RevB; bad.add(@[p])
    p = pinA(); p.repo = "../catalog-a"; bad.add(@[p])
    for badRef in ["ma in", "HEAD~1", "main@{1}", "-main", "a//b", ".hidden",
                   "main.lock", "main:x", "ma\tin"]:
      p = pinA(); p.gitRef = badRef; bad.add(@[p])
    var twin = pinB(); twin.repo = pinA().repo
    bad.add(@[pinA(), twin])
    twin = pinB(); twin.remote = pinA().remote
    bad.add(@[pinA(), twin])
    for pins in bad:
      var raised = false
      try:
        discard pinnedText(pins)
      except LockedCatalogImportError:
        raised = true
      check raised
    var empty = false
    try:
      discard serializeCatalogImports(@[])
    except LockedCatalogImportError:
      empty = true
    check empty
    # The control: well-formed pins, including a slash-separated ref and an
    # empty ref (a commit was declared), are written.
    var good = pinA()
    good.gitRef = "release/1.0"
    check pinnedText(@[good, pinB()]).len > 0

  test "the strict reader refuses every pin it did not write":
    let text = pinnedText(@[pinA()])
    let line = pinsLine(text)
    let rhs = line[line.find('=') + 1 .. ^1].strip()
    let damaged = @[
      (line.replace("revision = \"" & RevA & "\"", "revision = \"main\""),
        "catalog_imports entry 0: field revision: not a full-width revision"),
      (line.replace("revision = \"" & RevA & "\"",
        "revision = \"" & RevA[0 ..< 12] & "\""),
        "catalog_imports entry 0: field revision"),
      (line.replace(RevA, RevA.toUpperAscii()),
        "catalog_imports entry 0: field revision"),
      (line.replace("\"https://example.invalid/a\"", "\"file:///srv/a\""),
        "catalog_imports entry 0: field remote: is a file: URL"),
      (line.replace("\"https://example.invalid/a\"", "\"C:\\\\catalogs\\\\a\""),
        "catalog_imports entry 0: field remote"),
      # A remote whose host depends on who parses it (verification round).
      (line.replace("\"https://example.invalid/a\"",
        "\"https://evil.invalid?@example.invalid/a\""),
        "catalog_imports entry 0: field remote: contains whitespace"),
      (line.replace("\"https://example.invalid/a\"",
        "\"https://a@b@example.invalid/a\""),
        "catalog_imports entry 0: field remote: contains more than one '@'"),
      (line.replace(LockedCatalogImportRecordV1,
        "reprobuild.locked-catalog-import.v2"), "unsupported record version"),
      (line.replace(", ref = \"main\"", ""), "missing field ref"),
      (line.replace(" }]", ", ref = \"main\" }]"), "duplicate field ref"),
      (line.replace(" }]", ", note = \"x\" }]"), "unknown field note"),
      (line.replace("{ record", "{  record"), "not the canonical encoding"),
      (line.replace(" }]", " }, " & rhs[1 .. ^2] & "]"),
        "two catalog imports are pinned for repo"),
      (CatalogImportsLockKey & " = []", "an empty array is never written"),
      (line[0 ..< line.len - 2], "catalog_imports: truncated"),
      (CatalogImportsLockKey, "has a truncated `catalog_imports` line"),
      (line & "\n" & line, "carries the `catalog_imports` key twice")]
    for (d, expected) in damaged:
      let r = refusal(text.replace(line, d))
      check expected in r
      if expected notin r:
        echo "    expected ", expected.escape(), " in ", r.escape()
    # The reader refuses the CANONICAL bytes of a record whose fields are
    # well formed but out of order.
    let reordered = line.replace("repo = \"catalog-a\", remote = " &
      "\"https://example.invalid/a\"", "remote = \"https://example.invalid/a\"" &
      ", repo = \"catalog-a\"")
    check "not the canonical encoding" in refusal(text.replace(line, reordered))

  test "a key spelling the reader skips is detected, in any case and form":
    let text = pinnedText(@[pinA()])
    let line = pinsLine(text)
    let rhs = line[line.find('=') + 1 .. ^1].strip()
    check not lockHasUnreadCatalogImportsSpelling(text)
    check lockDeclaresCatalogImports(text)
    check not lockDeclaresCatalogImports(pinnedText(@[]))
    for spelled in ["\"catalog_imports\" = " & rhs,
                    "\"\\u0063atalog_imports\" = " & rhs,
                    "CATALOG_IMPORTS = " & rhs,
                    "Catalog-Imports = " & rhs,
                    "catalogImports = " & rhs,
                    "lock.catalog_imports = " & rhs,
                    "[catalog_imports]",
                    "[[lock.catalog_imports]]",
                    # Verification round (2026-10-03): the separator and
                    # nesting spellings a TOML reader keys as the pins but
                    # a key-part check folding only '-' / '_' skipped.
                    "\"\\x63atalog_imports\" = " & rhs,
                    "catalog.imports = " & rhs,
                    "catalog . imports = " & rhs,
                    "\"catalog\".\"imports\" = " & rhs,
                    "\"catalog imports\" = " & rhs,
                    "catalog\timports = " & rhs,
                    "\"catalog=imports\" = " & rhs,
                    "catalog\xE2\x80\x8Bimports = " & rhs,
                    "\"catalog\\u200Bimports\" = " & rhs,
                    "[catalog.imports]",
                    "[[catalog.imports]]",
                    "catalog = { imports = " & rhs & " }",
                    "x = { catalog_imports = " & rhs & " }",
                    "x = { y = \"a,b\", catalog_imports = " & rhs & " }"]:
      let other = text.replace(line, spelled)
      check lockHasUnreadCatalogImportsSpelling(other)
      check lockDeclaresCatalogImports(other)
      # Beside the writer's own line too.
      check lockHasUnreadCatalogImportsSpelling(text & spelled & "\n")
    # A value that merely mentions the word is not a key.
    check not lockHasUnreadCatalogImportsSpelling(text.replace(
      "\"https://example.invalid/a\"", "\"https://example.invalid/catalog_imports\""))
    check not lockHasUnreadCatalogImportsSpelling(text &
      "x = { y = \"catalog_imports\", z = \"catalog = imports\" }\n")
    # TOML 1.1's ``\x`` escape is decoded for ``provisioning`` too. (A
    # member of another key's inline table is NOT the provisioning key --
    # M7's e2e pins that -- so only the catalog-imports guard looks inside.)
    check lockHasUnreadProvisioningSpelling(text & "\"\\x70rovisioning\" = []\n")
    check not lockHasUnreadProvisioningSpelling(text &
      "x = { provisioning = 1 }\n")

  test "a refresh carries the pins forward and refuses pins it cannot read":
    let incumbent = pinnedText(@[pinB(), pinA()])
    let fresh = serializeLockedDependencies(baseLock())
    let carried = withProvisioningCarriedForward(parseLockedDependencies(fresh),
      incumbent)
    check carried.lockedCatalogImportPins() == @[pinA(), pinB()]
    check serializeLockedDependencies(carried) == incumbent
    # A plain incumbent contributes nothing.
    check withProvisioningCarriedForward(parseLockedDependencies(fresh),
      fresh).catalogImportPinCount == 0
    let line = pinsLine(incumbent)
    let rhs = line[line.find('=') + 1 .. ^1].strip()
    for damaged in [line[0 ..< line.len - 3],
                    CatalogImportsLockKey,
                    line.replace(RevA, "main"),
                    "\"catalog_imports\" = " & rhs,
                    "CATALOG_IMPORTS = " & rhs]:
      var raised = ""
      try:
        discard withProvisioningCarriedForward(parseLockedDependencies(fresh),
          incumbent.replace(line, damaged))
      except SolvedGraphLockParseError as err:
        raised = err.msg
      check "refusing to replace the committed lock" in raised
      check CatalogImportsLockKey in raised
