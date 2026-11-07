## Publishing a catalog's interface artifacts -- the publisher half of
## ``reprobuild-specs/Federated-Catalog-Imports.md`` § What a catalog
## publishes (ReproOS-Campaign-Completion M6 deliverable 5).
##
## A catalog repository commits, at every revision a consumer may pin, the
## interface artifacts its OWN provider generates, under
## ``published-interfaces/*.rbsz``. Publishing runs the catalog's provider;
## consuming never does. This module is that publishing step:
##
##   1. each provider module of the catalog is extracted by the production
##      interface extraction (``extractInterfaceFromModule``: the module is
##      compiled into an extraction runner and run, exactly as for any
##      project's interface), with the extraction cache bypassed so the
##      bytes come from this run of the provider;
##   2. every source location is rewritten relative to the catalog
##      repository's root (``/``-separated). An extraction records ABSOLUTE
##      paths of the publisher's checkout, which would put the publisher's
##      host path into the published bytes and make two publications of one
##      source differ by where the checkout sat. Locations are excluded from
##      every identity (the interface fingerprint, the record digest, the
##      contribution fingerprint and ``catalogArtifactIdentity``), so this
##      changes no identity (measured by the D5 fixture test: two roots, one
##      identity). A location OUTSIDE the catalog root refuses (it could only
##      be a host path) -- including one that starts with the root's spelling
##      and climbs out of it with ``..``; ``.`` and empty segments are dropped
##      and an inner ``..`` resolved, so a location has one spelling;
##   3. the result is checked exactly as a consumer will check it
##      (``decodePublishedArtifact``: the envelope decodes and carries the
##      semantic fingerprint; ``publishedCatalogContent``: every record the
##      catalog's own, pinned, not ``developInterface``), and its encoded
##      bytes must not contain the catalog root, the reprobuild root or the
##      extraction scratch directory -- in any spelling this host gives them
##      (either separator, doubled separators, letter case on Windows, the
##      8.3 short and the long form, the MSYS ``/c/...`` form, percent-
##      encoded). A publisher never commits what a consumer would refuse, or
##      a host path. (A path a provider deliberately re-encodes -- UTF-16,
##      split across fields -- is not looked for.);
##   4. ``published-interfaces/`` is REPLACED by exactly these artifacts,
##      one per module, named ``<projectName>.rbsz``.
##
## Committing is the publisher's business (``git add``/``git commit``); a
## consumer reads the result only as committed objects of the catalog's
## shared clone (``catalog_discovery``).
##
## There is no CLI verb for this yet: the federated catalog fixtures drive
## it, and the real ``reprobuild-*-packages`` catalogs do not publish yet.

import std/[algorithm, os, sequtils, strutils, tempfiles]

import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/catalog_declaration

type
  CatalogPublicationError* = object of CatchableError
    ## The catalog cannot be published; the message names every cause.

  PublishedArtifactFile* = object
    ## One artifact written to ``published-interfaces/``.
    module*: string        ## the provider module, relative to the catalog root.
    fileName*: string      ## ``<projectName>.rbsz``.
    bytes*: string         ## exactly what was written.
    artifact*: ProjectInterfaceArtifact

proc publicationError(message: string) {.noreturn.} =
  raise newException(CatalogPublicationError, message)

proc slashed(path: string): string =
  path.replace('\\', '/')

proc comparable(path: string): string =
  ## A spelling two paths of one file share on this host.
  result = slashed(path)
  when defined(windows):
    result = result.toLowerAscii()
  while result.len > 1 and result.endsWith("/"):
    result.setLen(result.len - 1)

proc scanForm(text: string): string =
  ## ``comparable`` for the host-path scan, with every run of separators
  ## folded to one: a path written with escaped (``\\``) or doubled
  ## separators is still the path.
  let c = comparable(text)
  result = newStringOfCap(c.len)
  for ch in c:
    if ch == '/' and result.len > 0 and result[^1] == '/':
      continue
    result.add(ch)

proc percentDecoded(text: string): string =
  ## ``%XX`` sequences decoded (a path inside a ``file:`` URL); anything else
  ## kept byte for byte.
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    if text[i] == '%' and i + 2 < text.len and
        text[i + 1] in HexDigits and text[i + 2] in HexDigits:
      result.add(char(parseHexInt(text[i + 1 .. i + 2])))
      i += 3
    else:
      result.add(text[i])
      inc i

when defined(windows):
  proc getLongPathNameW(short, long: WideCString; size: int32): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetLongPathNameW".}
  proc getShortPathNameW(long, short: WideCString; size: int32): int32 {.
    stdcall, dynlib: "kernel32", importc: "GetShortPathNameW".}

  proc windowsSpelling(path: string; long: bool): string =
    var buffer = newWideCString(newString(32768))
    let n =
      if long: getLongPathNameW(newWideCString(path), buffer, 32768)
      else: getShortPathNameW(newWideCString(path), buffer, 32768)
    if n > 0 and n < 32768: $buffer else: ""

proc hostPathSpellings(path: string): seq[string] =
  ## The spellings of one host path a publication could carry: as given and,
  ## on Windows, its long and 8.3 short forms (when it exists) and the MSYS
  ## drive form (``/c/...``) of each. Compared after ``scanForm``.
  var forms = @[path]
  when defined(windows):
    for long in [true, false]:
      let other = windowsSpelling(path, long)
      if other.len > 0 and other notin forms:
        forms.add(other)
    for f in forms[0 .. ^1]:
      if f.len > 2 and f[1] == ':' and f[0] in Letters:
        let msys = "/" & $f[0] & f[2 .. ^1]
        if msys notin forms:
          forms.add(msys)
  for f in forms:
    let s = scanForm(f)
    if s.len > 0 and s notin result:
      result.add(s)

proc withinRoot(rel: string): tuple[ok: bool; rel: string] =
  ## ``rel`` (``/``-separated, relative to the catalog root) with its ``.``
  ## and empty segments dropped and each ``..`` resolved lexically; refused
  ## (``ok = false``) when a ``..`` climbs above the root or nothing is
  ## left. ``<root>/../x`` names a file OUTSIDE the catalog although it
  ## starts with the root's spelling.
  var parts: seq[string] = @[]
  for part in rel.split('/'):
    if part.len == 0 or part == ".":
      continue
    if part == "..":
      if parts.len == 0:
        return (false, "")
      parts.setLen(parts.len - 1)
    else:
      parts.add(part)
  if parts.len == 0:
    return (false, "")
  (true, parts.join("/"))

proc relativeToRoot(file, root: string): tuple[ok: bool; rel: string] =
  ## ``file`` relative to ``root`` (``/``-separated, normalized by
  ## ``withinRoot``) when it lies beneath it; a relative ``file`` is already
  ## host-independent and is kept, normalized the same way.
  if not isAbsolute(file) and not file.startsWith("/") and
      not file.startsWith("\\"):
    return withinRoot(slashed(file))
  let f = comparable(file)
  let r = comparable(root) & "/"
  if f.startsWith(r) and f.len > r.len:
    return withinRoot(slashed(file)[r.len .. ^1])
  (false, "")

proc relocateLocations[T](x: var T; root: string; outside: var seq[string]) =
  ## Rewrite every ``SourceLocation`` reachable from ``x`` relative to
  ## ``root``; collect the ones that are not beneath it.
  when T is SourceLocation:
    if x.file.len > 0:
      let (ok, rel) = relativeToRoot(x.file, root)
      if ok:
        x.file = rel
      else:
        outside.add(x.file & ":" & $x.line)
  elif T is object or T is tuple:
    for field in fields(x):
      relocateLocations(field, root, outside)
  elif T is seq or T is array:
    for item in mitems(x):
      relocateLocations(item, root, outside)
  else:
    discard

proc fileNameDefect(name: string): string =
  if name.len == 0:
    return "is empty"
  for ch in name:
    if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '-'}:
      return "contains " & ($ch).escape() &
        " (a published artifact is named by its project name, and only " &
        "letters, digits, '.', '_' and '-' are accepted)"
  if name.startsWith("."):
    return "starts with '.'"
  ""

proc byteString(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc publishableArtifact*(extracted: ProjectInterfaceArtifact;
                          catalogRoot, module: string;
                          hostPaths: openArray[string] = []):
    PublishedArtifactFile =
  ## The artifact a catalog at ``catalogRoot`` publishes for ``module``,
  ## from what its extraction produced (steps 2 and 3 of the module
  ## docstring). Raises ``CatalogPublicationError`` naming every cause.
  ## ``hostPaths``: further host paths the bytes must not contain (the
  ## catalog root is always checked).
  var pi = extracted.projectInterface
  var outside: seq[string] = @[]
  relocateLocations(pi, catalogRoot, outside)
  var problems: seq[string] = @[]
  if outside.len > 0:
    problems.add("source locations outside the catalog repository " &
      catalogRoot & " would publish a host path: " &
      outside.sorted(cmp).deduplicate(isSorted = true).join(", "))
  # Re-fingerprinted from the rewritten interface (``artifactFor``), so the
  # stored fingerprint is the semantic one by construction -- which
  # ``decodePublishedArtifact`` below checks as a consumer will. Locations
  # are no input of it, so this is the extracted fingerprint; not asserted
  # separately, because no input can make such a check fail.
  let published = artifactFor(pi)
  let fileName = pi.projectName & PublishedArtifactSuffix
  let nameDefect = fileNameDefect(pi.projectName)
  if nameDefect.len > 0:
    problems.add("project name " & pi.projectName.escape() & " " & nameDefect)
  let bytes = byteString(encodeProjectInterfaceArtifact(published))
  let path = PublishedInterfacesDir & "/" & fileName
  var checked: seq[PublishedArtifact] = @[]
  try:
    checked.add(PublishedArtifact(path: path,
      artifact: decodePublishedArtifact(path, bytes)))
  except CatchableError as err:
    problems.add(err.msg)
  if checked.len > 0:
    discard publishedCatalogContent(checked, problems)
  # Compared with separators folded and separator runs collapsed (and, on
  # Windows, letter case), in the bytes as written and percent-decoded, and
  # against every spelling of each path this host has (``hostPathSpellings``),
  # so no spelling a toolchain writes slips through. A path deliberately
  # re-encoded (UTF-16, split across fields) is not looked for: the scan
  # guards against a publisher's own host paths leaking, not against a
  # provider that encodes one on purpose.
  let haystacks = [scanForm(bytes), scanForm(percentDecoded(bytes))]
  for hostPath in @[catalogRoot] & @hostPaths:
    if hostPath.len == 0:
      continue
    block scan:
      for spelling in hostPathSpellings(hostPath):
        for haystack in haystacks:
          if spelling in haystack:
            problems.add("the encoded artifact contains the host path " &
              hostPath)
            break scan
  if problems.len > 0:
    publicationError("catalog " & catalogRoot & " cannot publish " & module &
      ":\n  " & problems.join("\n  "))
  PublishedArtifactFile(module: slashed(module), fileName: fileName,
    bytes: bytes, artifact: published)

proc extractCatalogModule*(catalogRoot, module, reproRoot,
                           scratchDir: string): ProjectInterfaceArtifact =
  ## Step 1: run the production interface extraction over the catalog's
  ## provider module, cache bypassed, writing only under ``scratchDir``.
  let modulePath = catalogRoot / module
  if not fileExists(modulePath):
    publicationError("catalog " & catalogRoot & " has no provider module " &
      module)
  createDir(scratchDir)
  let stem = module.replace('/', '_').replace('\\', '_').changeFileExt("")
  try:
    result = extractInterfaceFromModule(modulePath,
      scratchDir / (stem & ".rbsz"), scratchDir / (stem & "_interface.nim"),
      workDir = reproRoot, scratchDir = scratchDir, requireStub = false,
      consumerRoot = catalogRoot, useExtractionCache = false)
  except CatchableError as err:
    publicationError("catalog " & catalogRoot & ": extracting " & module &
      " failed: " & err.msg)

proc writePublishedInterfaces*(catalogRoot: string;
                               files: seq[PublishedArtifactFile]) =
  ## Step 4: replace ``published-interfaces/`` with exactly ``files``.
  var names: seq[string] = @[]
  for f in files:
    if f.fileName in names:
      publicationError("catalog " & catalogRoot & ": two modules publish " &
        f.fileName & " (one project name is one published artifact)")
    names.add(f.fileName)
  if files.len == 0:
    publicationError("catalog " & catalogRoot & " publishes nothing; a " &
      "publication holds at least one artifact")
  let dir = catalogRoot / PublishedInterfacesDir
  if dirExists(dir):
    removeDir(dir)
  createDir(dir)
  for f in files:
    writeFile(dir / f.fileName, f.bytes)

proc publishCatalogInterfaces*(catalogRoot: string; modules: openArray[string];
                               reproRoot: string; scratchDir = ""):
    seq[PublishedArtifactFile] =
  ## Publish the catalog at ``catalogRoot``: extract each provider module
  ## (paths relative to the root), make each artifact publishable and write
  ## ``published-interfaces/`` (see the module docstring). ``reproRoot`` is
  ## the reprobuild checkout whose libraries the extraction compiles
  ## against. Raises ``CatalogPublicationError``; on a refusal nothing is
  ## written. Returns the files written, in module order.
  if modules.len == 0:
    publicationError("catalog " & catalogRoot & ": no provider module named")
  let owned = scratchDir.len == 0
  let scratch =
    if owned: createTempDir("repro-catalog-publish-" & $getCurrentProcessId() &
                "-", "")
    else: scratchDir
  try:
    for module in modules:
      let extracted = extractCatalogModule(catalogRoot, module, reproRoot,
        scratch / module.replace('/', '_').replace('\\', '_'))
      result.add(publishableArtifact(extracted, catalogRoot, module,
        [reproRoot, scratch]))
  finally:
    if owned:
      try: removeDir(scratch)
      except CatchableError: discard
  writePublishedInterfaces(catalogRoot, result)
