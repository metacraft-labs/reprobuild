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
##
## ---------------------------------------------------------------------------
##
## THE VARIANT HALF (NLF-M2's third deliverable, and owner decision Q-4).
##
## §10.3 records that the implementation had develop mode's two halves exactly
## inverted: the version was fabricated and then solved for, while "the develop
## sibling's own variants reach nothing at all". The version half is above.
## This is the other one, and it travels the same road for the same reason —
## the `variants` array sits on the same override entry that already carries
## `path` and `version`, so the solve path still shares only the CONTRACT with
## `repro_project_dsl` and still imports nothing from it.
##
## WHAT IS RECORDED IS THE DECLARATION, NOT THE ANSWER, and the distinction is
## the whole of Q-4 (2026-08-18: "variants of a develop-mode package are SOLVED,
## not recorded"). A checkout contributes its variants' NAMES, UNIVERSES and
## DECLARED DEFAULTS — the shape of the question. It does not contribute an
## assignment. Q-4's third reason is why: "if a checkout carried its own variant
## values, those values would have to feed back into the solve that configures
## its dependents — the same circularity §5.6 refuses for metadata fetching".
## So a recorded `default` becomes a default-band CONTRIBUTION, which the solve
## may overrule; it never becomes a pin, which the solve could not.
##
## THE NAMES ARE QUALIFIED BY THE PACKAGE (`qualifiedVariantName`), and that is
## a correctness requirement rather than a convention. Variant identity is a
## flat string all the way down to the ASP atom `variant_assigned("name", X)`.
## A sibling's `enableTls` injected under its bare name would MERGE with a
## consumer that declares `enableTls` too: one universe, one assignment, one
## `--variant` flag steering both — or, when the two universes differ, an
## unexplained UNSAT with nothing in it naming the collision.
##
## AN UNREADABLE DECLARATION IS REFUSED, not skipped, on the rule
## `repro_solver/lock_pins` states for its own grammar: "an unknown entry
## dropped in silence is a constraint that was supposed to hold and didn't,
## with nothing in the output to say so". A silently dropped variant
## declaration is a package configured out of a universe nobody declared, which
## is the same failure one level down.
##
## KNOWN GAP, same shape as the version one and recorded for the same reason:
## the engine does not write `variants` yet either (`writeDevelopOverrides` in
## `repro_cli_support.nim` emits `node` and `path`). Until it does, a develop
## sibling contributes no variants and the rendering is byte-unchanged — which
## is exactly what every override on disk today looks like, and why landing
## this moves no fingerprint. The durable fix is for the engine to record the
## sibling's declarations when it registers the override, since introspecting
## the sibling's recipe is work it is already positioned to do.

import std/[json, options, os, strutils, tables]

type
  EDevelopVariantsMalformed* = object of CatchableError
    ## A develop override's recorded variant declarations could not be
    ## understood. Raised rather than skipped — see the variant section of the
    ## module doc.

  EDevelopVersionUnknown* = object of CatchableError
    ## A develop-mode checkout was found, but its version could not be read
    ## from it. Raised rather than defaulted — see the module doc.

  DevelopVariantKind* = enum
    ## The two universe shapes a recorded variant declaration can have. They
    ## mirror the encoder's ``vkBool`` / ``vkEnum`` without importing it: this
    ## module is std-only by design, so that the solve path can consume it
    ## without acquiring a dependency in either direction.
    dvkBool
    dvkEnum

  DevelopVariant* = object
    ## One variant DECLARATION recorded against a develop override: the name,
    ## the universe, and the recipe's declared default. Deliberately not an
    ## assignment — see the variant section of the module doc.
    name*: string
    kind*: DevelopVariantKind
    allowedValues*: seq[string]
      ## The enum universe. Empty for ``dvkBool``, whose universe is closed.
    default*: string
      ## The declared default, or ``""`` when the recipe declares none. It
      ## becomes a default-band CONTRIBUTION, never a pin.

  DevelopSource* = object
    ## One resolved develop-mode override: which package, which checkout,
    ## the version observed there, and the variants the checkout declares.
    package*: string
    path*: string
    version*: string
    variants*: seq[DevelopVariant]

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

proc qualifiedVariantName*(package, variant: string): string =
  ## The name a develop sibling's variant carries into the solve. One home for
  ## the rule so the reader and every consumer cannot disagree about it — see
  ## the variant section of the module doc for why the qualification is a
  ## correctness property and not a convention.
  package & "." & variant

proc refuse(package, variant, detail: string) {.noreturn.} =
  ## One diagnostic shape for every malformed declaration. It names the
  ## sibling and the variant because a refusal that names neither sends the
  ## reader through every override entry by hand. Marked `noreturn` so the
  ## callers below read as guards rather than as branches that fall through.
  raise newException(EDevelopVariantsMalformed,
    "develop-mode dependency '" & package & "' records a variant declaration " &
    "that cannot be read" &
    (if variant.len > 0: " ('" & variant & "')" else: "") &
    ": " & detail & ". A develop sibling's variant declarations are refused " &
    "rather than skipped: a dropped declaration is a package configured out " &
    "of a universe nobody declared.")

proc parseDevelopVariants(package: string; node: JsonNode):
    seq[DevelopVariant] =
  ## Read the `variants` array recorded against one override entry. Every
  ## departure from the shape is an error; see the module doc.
  if node.isNil:
    return @[]
  if node.kind != JArray:
    refuse(package, "", "the 'variants' field is " & $node.kind &
      ", but it must be an array of variant declarations")
  for item in node:
    if item.kind != JObject:
      refuse(package, "", "a 'variants' entry is " & $item.kind &
        ", but every entry must be an object")
    let name = item{"name"}.getStr()
    if name.len == 0:
      refuse(package, "", "it has no non-empty 'name'")
    for existing in result:
      if existing.name == name:
        refuse(package, name, "it is declared twice in the same override " &
          "entry, and the two declarations cannot both be the universe")
    let kindText = item{"kind"}.getStr()
    var decl = DevelopVariant(name: name)
    case kindText
    of "bool":
      decl.kind = dvkBool
    of "enum":
      decl.kind = dvkEnum
      let values = item{"values"}
      if values.isNil or values.kind != JArray or values.len == 0:
        refuse(package, name, "kind 'enum' requires a non-empty 'values' " &
          "array naming the universe; a universe re-derived from the " &
          "contributions alone would silently drop every value nobody " &
          "contributed")
      for value in values:
        if value.kind != JString or value.getStr().len == 0:
          refuse(package, name, "every entry of 'values' must be a non-empty " &
            "string")
        decl.allowedValues.add(value.getStr())
    of "":
      refuse(package, name, "it has no 'kind'; declare 'bool' or 'enum'")
    else:
      refuse(package, name, "'" & kindText & "' is not a variant kind this " &
        "reader understands; declare 'bool' or 'enum'")
    decl.default = item{"default"}.getStr()
    if decl.default.len > 0:
      let universe =
        if decl.kind == dvkBool: @["true", "false"] else: decl.allowedValues
      if decl.default notin universe:
        refuse(package, name, "the recorded default '" & decl.default &
          "' is not in the declared universe (" & universe.join(", ") &
          "), so no model could honour it")
    result.add(decl)

proc readDevelopSources(): Table[string, DevelopSource] =
  result = initTable[string, DevelopSource]()
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
    result[package] = DevelopSource(
      package: package,
      path: path,
      version: item{"version"}.getStr(),
      variants: parseDevelopVariants(package, item{"variants"}))

proc loadDevelopSources() =
  if developSourcesLoaded:
    return
  # The memo flag is set only after a SUCCESSFUL read. Setting it first — as
  # this proc used to — meant a refusal was raised once and then swallowed
  # forever: the second call saw `loaded` and served the half-built empty
  # cache, so every sibling silently fell back to the fabricated-version path
  # the module exists to remove. A diagnostic that fires once and then
  # disappears is worse than one that fires every time.
  developSourceCache = readDevelopSources()
  developSourcesLoaded = true

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
