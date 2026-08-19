## Named-Lock-Files NLF-M2 — develop-mode source identity, READ rather than
## fabricated.
##
## `Named-Lock-Files.md` §10.1 settles that a develop-mode dependency's SOURCE
## identity is observed, not solved, and §10.3 records that the implementation
## did the opposite: `smallestSatisfyingVersion` manufactured a version out of
## the declared range text (`">=0"` -> `"0.0.0"`) and handed it to clingo as a
## candidate to search for, while the answer sat on disk. This module is the
## observation half.
##
## WHY IT LIVES HERE, and not in a module that already knows about develop
## mode. The solve path is `configurables/variants.nim`, which deliberately
## does not import `repro_project_dsl` — its own comment says doing so "would
## create a layering loop". `developOverridePath`
## (`repro_project_dsl/runtime_core.nim`) is therefore unreachable from the
## solver's side, and reaching for it is what would make this a layering
## change rather than a defect fix. What this module shares with that accessor
## is the CONTRACT, not the code: the same `REPRO_DEVELOP_OVERRIDES_FILE`
## environment variable naming the same JSON document the engine writes.
##
## WHAT COUNTS AS THE VERSION, in order, and why the order stops where it does:
##
##   1. an explicit `version` on the override entry — the engine knows the
##      upstream solved identity the override replaced, and when it records
##      that, nothing else needs consulting;
##   2. a `VERSION` file at the checkout root.
##
## And then it STOPS, loudly. There is deliberately no fallback to a zero
## version, a timestamp, or the declared range. A develop checkout with no
## version-shaped identity is not a package whose version is "unknown but
## probably fine" — it is a question the caller has to answer, and answering
## it with a synthesized value is exactly the defect this module exists to
## remove, re-introduced one layer down. `EDevelopVersionUnknown` names the
## checkout and every source that was tried.
##
## WHY NOT THE VCS REVISION, which the corpus offers as an alternative
## ("the lock records 2.3.1 **or the checkout's VCS identity**"): reading it
## means running `git` — and `git` here would be an ambient host binary
## resolved off `PATH`, which `Package-Model.md` §"Executables, Libraries, And
## Package Collections" forbids and `scripts/check_ambient_execution.sh`
## ratchets against by file. Doing it properly needs a declared execution
## profile for git, which is real work and is not this defect's. Both sources
## above are plain file reads, so this module adds no execution surface at
## all. The corpus alternative is therefore NOT implemented, deliberately.
##
## KNOWN GAP, recorded rather than papered over: most working develop
## checkouts today satisfy neither source. They are untagged branches with no
## `VERSION` file, because nothing has ever asked them for a version. The
## durable fix is for the engine to record `version` on the override entry
## when it writes it (source 1), since it already knows the identity the
## override replaced. Until it does, a develop sibling must carry one of the
## two, and the diagnostic says exactly that.

import std/[json, options, os, strutils, tables]

type
  EDevelopVersionUnknown* = object of CatchableError
    ## A develop-mode checkout was found, but its version could not be read
    ## from it. Raised rather than defaulted — see the module doc.

  DevelopSource* = object
    ## One resolved develop-mode override: which package, which checkout,
    ## and the version observed there.
    package*: string
    path*: string
    version*: string

var developSourceCache {.threadvar.}: Table[string, DevelopSource]
var developSourcesLoaded {.threadvar.}: bool

proc resetDevelopSourceCache*() =
  ## Drop the memoized overrides. Called from `resetVariantState` so a test
  ## that points `REPRO_DEVELOP_OVERRIDES_FILE` somewhere new is not served a
  ## previous scenario's answer.
  developSourceCache = initTable[string, DevelopSource]()
  developSourcesLoaded = false

proc versionFromVersionFile(checkout: string): string =
  let candidate = checkout / "VERSION"
  if not fileExists(candidate):
    return ""
  readFile(candidate).strip()

proc observedVersion(package, checkout, recorded: string): string =
  if recorded.len > 0:
    return recorded
  result = versionFromVersionFile(checkout)
  if result.len > 0:
    return
  raise newException(EDevelopVersionUnknown,
    "develop-mode dependency '" & package & "' has a checkout at '" &
    checkout & "' but no readable version. Tried, in order: a 'version' " &
    "field on the develop-override entry, and a VERSION file at the " &
    "checkout root. Record one of these; a develop dependency's version is " &
    "read from its checkout and is never synthesized from the declared " &
    "range.")

proc loadDevelopSources() =
  if developSourcesLoaded:
    return
  developSourcesLoaded = true
  developSourceCache = initTable[string, DevelopSource]()
  let metadataPath = getEnv("REPRO_DEVELOP_OVERRIDES_FILE")
  if metadataPath.len == 0 or not fileExists(metadataPath):
    return
  var metadata: JsonNode
  try:
    metadata = parseFile(metadataPath)
  except CatchableError:
    # A malformed overrides file means "we do not know what is in develop
    # mode". Treating that as "nothing is" would silently restore the
    # fabricated-version path for every sibling, so it is not swallowed here;
    # it is left to surface from the reader.
    raise
  if metadata.kind != JObject or not metadata.hasKey("overrides"):
    return
  for item in metadata["overrides"]:
    if item.kind != JObject:
      continue
    let package =
      if item.hasKey("node"): item["node"].getStr()
      elif item.hasKey("dependency"): item["dependency"].getStr()
      elif item.hasKey("package"): item["package"].getStr()
      else: ""
    if package.len == 0:
      continue
    let path =
      if item.hasKey("path"): item["path"].getStr()
      elif item.hasKey("local_path"): item["local_path"].getStr()
      else: ""
    if path.len == 0:
      continue
    developSourceCache[package] = DevelopSource(
      package: package,
      path: path,
      version: item{"version"}.getStr())

proc developSourceFor*(package: string): Option[DevelopSource] =
  ## The develop-mode override governing `package`, if there is one, with its
  ## version resolved from the checkout. Returns `none` when the package is
  ## not in develop mode — the ordinary case, and the one that must keep
  ## reaching the normal candidate-derivation path.
  loadDevelopSources()
  if not developSourceCache.hasKey(package):
    return none(DevelopSource)
  var entry = developSourceCache[package]
  if entry.version.len == 0:
    entry.version = observedVersion(entry.package, entry.path, "")
    developSourceCache[package] = entry
  some(entry)
