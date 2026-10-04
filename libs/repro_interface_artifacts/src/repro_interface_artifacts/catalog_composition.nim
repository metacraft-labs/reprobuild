## Federated catalog composition — M6 deliverables 1, 3 and (part of) 4 of
## ``ReproOS-Campaign-Completion.milestones.org``, normatively specified by
## ``reprobuild-specs/Provisioning-Contributions.md`` § Interface Artifacts,
## § Resolution and § Repository Composition.
##
## ## What this module is for
##
## A ReproOS-shaped workspace imports several independent repositories —
## ``reprobuild-packages`` owning canonical interfaces, then whichever
## realization catalogs (``reprobuild-nix-packages``,
## ``reprobuild-scoop-packages``, …) its policy permits — and has to turn
## them into ONE resolver input. This module is that step, and only that
## step: it takes explicitly identified catalog imports and produces a
## deterministic, canonically serialised composition, or it refuses with a
## diagnostic naming what is wrong.
##
## ## Why a coordinate, and why these four components
##
## The spec's § Resolution ends with a rule this module exists to enforce:
##
##   Import order is never a selection rule.
##
## The milestone adds the other half — a catalog must not be bound "by
## ambient sibling-directory names" either. So a ``CatalogCoordinate``
## names a catalog by four EXPLICIT components and nothing else:
##
##   * ``workspace`` — the workspace name under which the consumer declares
##     the catalog repository (the ``repo`` of its ``repro-catalogs.toml``
##     import, which is the ``repos/<repo>.toml`` / ``LockedDep`` name; see
##     ``reprobuild-specs/Federated-Catalog-Imports.md``). A composition is a
##     statement made by one consumer, and the name is how that consumer
##     refers to the catalog.
##   * ``remote`` — the catalog repository. Not a local path: a path is
##     where a checkout happens to sit today.
##   * ``revision`` — the exact pinned revision. Without it the same remote
##     at two tips is the same catalog, which is precisely the
##     "branch-tip changes" failure the campaign is trying to close.
##   * ``interfaceArtifact`` — the 64-hex identity of the interface-artifact
##     set that revision publishes (see ``catalogArtifactIdentity``). The
##     revision names the source; this names what was EXTRACTED from it, so
##     a re-extraction that changes the artifact is visible even at a fixed
##     revision.
##
## All four are REQUIRED. A coordinate missing any of them refuses — it is
## not completed from the environment, the directory name, or the position
## of the import in the list. ``CatalogImport.discoveredAt`` records where
## the checkout was found for DIAGNOSTICS and is deliberately not an input
## to any identity or to the composed bytes; composing the same catalog
## from two different on-disk locations therefore produces identical output
## to the byte.
##
## ## How determinism is obtained
##
## ``resolverInput`` is a canonical LF-only text document. Nothing about it
## depends on the order the imports arrived in:
##
##   1. every field is escaped (``\\``, ``\t``, ``\n``, ``\r``) and records
##      are tab-separated, so no value can break the framing;
##   2. imports are grouped by coordinate DIGEST, so re-importing the same
##      catalog — from another directory, or twice — collapses to one entry
##      rather than duplicating it;
##   3. every emitted section is sorted by its own record bytes: catalogs by
##      coordinate key, canonical interfaces by (package, catalog),
##      contributions by (package, interface fingerprint, contributor,
##      record digest, catalog);
##   4. a contribution is reduced to ``interfaceContributionRecordDigest``,
##      which is itself order-independent in its field and realization
##      encoding, so permuting the contributions inside a catalog cannot be
##      observed either;
##   5. diagnostics are sorted by (kind, message) and de-duplicated, and
##      every message lists its candidates in sorted order — so even a
##      REFUSAL is byte-identical under permutation.
##
## What would break it, and is therefore never done here: folding
## ``discoveredAt`` or a contribution's ``SourceLocation`` into any digest;
## iterating a ``Table`` to emit records; relying on the arrival order of
## anything; emitting a platform-width integer or a native path separator.
##
## ## Fail closed
##
## Per this codebase's standing rule — *a false refusal is safe, a false
## accept is not; where undecidable, refuse* — a composition that produced
## ANY diagnostic carries an empty ``resolverInput``, empty digests and an
## empty ``selections`` list. There is no shape in which a caller obtains a
## composed resolver input that was derived from an incomplete, conflicting
## or ambiguous catalog set, and no shape in which one of two eligible
## contributions is picked because it was imported first.
##
## ## What this module does NOT do
##
##   * It does not read, clone, fetch or check out anything. A
##     ``CatalogImport`` is handed in already resolved; ``content`` being
##     ``none`` is how the caller says "declared, not found", and this
##     module turns that into the missing-catalog diagnostic.
##   * It does not execute provider code, and it cannot: every input is a
##     record the interface artifact already carries (M6 deliverable 2).
##     That is also why composition is keyed on
##     ``interfaceContributionRecordDigest`` and not on the full
##     ``contributionFingerprint`` — the latter needs a provider identity,
##     which is not readable from an artifact.
##   * It does not write, read or validate a LOCK. The lock record is M7
##     deliverable 2 (``repro_lock/provisioning``, written by
##     ``contribution_lock``); reading it and checking it against this
##     composition is M7 deliverable 3 (``contribution_selection``), which
##     passes the lock's selections in as ``CatalogLockPin``s -- the
##     highest-precedence selector, checked here only for the pinned
##     CONTRIBUTOR being offered. ``CatalogSelectionPolicy`` is the spec's
##     *curator policy* — an explicit, in-memory selection input — and must
##     not be mistaken for a lock: it is not serialised, carries no
##     contribution fingerprint, revision, platform or capability set, and
##     survives nothing; its choice reaches the lock only through
##     ``contribution_lock``.
##   * It does not accept a CONTRADICTORY curator policy. A policy naming
##     two different contributors for one package is undecidable, and
##     which entry wins must not depend on which was written last — an
##     entry's position in the policy list is no more a selection rule
##     than an import's position in the import list. Such a policy
##     refuses with ``contradictory-curator-policy``. A policy that
##     merely REPEATS one entry is not contradictory and composes.
##   * It does not VERIFY ``CatalogCoordinate.interfaceArtifact``. It
##     receives ``CatalogContent``, not the artifacts themselves, so it
##     cannot recompute ``catalogArtifactIdentity`` to check the claim:
##     a single import declaring any well-formed 64-hex string composes
##     without complaint. Only TWO imports of one coordinate disagreeing
##     on their CONTENT are caught, by ``catalog-identity-conflict``. A
##     consumer that needs the component verified must recompute it
##     where the artifacts are actually read -- which the production
##     catalog source (``repro_cli_support/catalog_discovery``) does: the
##     coordinate it hands in carries the identity it recomputed from the
##     artifacts it read at the pinned revision, checked against the lock.
##   * It does not filter by version, platform, ABI or capability (spec
##     § Resolution step 4). Every contribution whose target interface
##     fingerprint matches is eligible here, so a set this module calls
##     ambiguous may become unambiguous once that filter exists. Refusing
##     is the safe side of that gap.

import std/[algorithm, options, sequtils, strutils, tables]

import repro_hash

import ../repro_interface_artifacts
import ./contribution_fingerprint

const
  CatalogCoordinateMagic* = "reprobuild.catalog-coordinate.v1"
    ## Domain magic of a catalog coordinate digest.

  CatalogArtifactIdentityMagic* = "reprobuild.catalog-artifact-identity.v1"
    ## Domain magic of the interface-artifact-set identity.

  CatalogCompositionMagic* = "reprobuild.catalog-composition.v1"
    ## First line of ``resolverInput``. The document is self-describing, so
    ## the digest covers its own format version.

  CatalogSelectionMagic* = "reprobuild.catalog-selection.v1"
    ## First line of ``selectedGraph``.

type
  CatalogCoordinate* = object
    ## The EXPLICIT identity of an imported catalog. See the module
    ## docstring for why each component is required.
    workspace*: string
    remote*: string
    revision*: string
    interfaceArtifact*: string
      ## 64-hex identity of the interface-artifact set published at
      ## ``revision``. ``catalogArtifactIdentity`` computes it.

  CatalogPackageInterface* = object
    ## A canonical package interface a catalog OWNS. ``packageName`` has
    ## exactly one owner across the whole composition; two owners refuse.
    packageName*: string
    interfaceFingerprint*: string

  CatalogContent* = object
    ## What an imported catalog publishes — read out of its interface
    ## artifacts, never by running its provider.
    canonicalInterfaces*: seq[CatalogPackageInterface]
    contributions*: seq[InterfaceProvisioningContribution]

  CatalogImport* = object
    ## One declared cross-repository catalog import.
    coordinate*: CatalogCoordinate
    discoveredAt*: string
      ## Where the checkout was found. DIAGNOSTIC ONLY — never an input to
      ## a digest, to the composed bytes, or to selection. This field is
      ## the thing the "not by filesystem position" rule is about.
    content*: Option[CatalogContent]
      ## ``none`` means the declared catalog was not found, which is the
      ## missing-catalog diagnostic.

  CatalogSelectionRule* = object
    ## One curator-policy selection. NOT a lock entry — see the module
    ## docstring.
    targetPackage*: string
    contributor*: string

  CatalogSelectionPolicy* = object
    selections*: seq[CatalogSelectionRule]

  CatalogLockPin* = object
    ## One selection pinned by the COMMITTED LOCK (M7 deliverable 3): the
    ## contributor a ``repro.lock`` ``provisioning`` record names for a
    ## package on the platform pair being resolved. Highest precedence --
    ## above curator policy and above a unique eligible contribution -- and
    ## never a fallback: a pin whose contributor offers no eligible
    ## contribution refuses (``locked-contribution-unavailable``); it does
    ## not fall back to policy or to the unique eligible one. Composition
    ## checks only that the pinned CONTRIBUTOR is offered; the record's
    ## interface, contribution fingerprint, catalog coordinate and
    ## realization are checked by ``contribution_selection``, which is the
    ## only caller that builds pins.
    targetPackage*: string
    contributor*: string

  CatalogSelectionReason* = enum
    csUniqueEligible = "unique-eligible"
    csCuratorPolicy = "curator-policy"
    csLock = "lock"
      ## Appended, so the two older reasons keep their ordinals and every
      ## composition made without lock pins keeps its bytes.

  CatalogSelection* = object
    targetPackage*: string
    targetInterfaceFingerprint*: string
    contributor*: string
    contributionRecordDigest*: string
    catalogCoordinate*: CatalogCoordinate
    reason*: CatalogSelectionReason

  CatalogDiagnosticKind* = enum
    cdIncompleteCoordinate = "incomplete-catalog-coordinate"
    cdMissingCatalog = "missing-catalog"
    cdCatalogIdentityConflict = "catalog-identity-conflict"
    cdDuplicateCanonicalInterface = "duplicate-canonical-interface"
    cdUnknownTargetInterface = "unknown-target-interface"
    cdIncompatibleFingerprint = "incompatible-interface-fingerprint"
    cdAmbiguousContribution = "unresolved-contribution-ambiguity"
    cdPolicySelectionUnsatisfied = "policy-selection-unsatisfied"
    cdContradictoryPolicy = "contradictory-curator-policy"
    cdLockedContributionUnavailable = "locked-contribution-unavailable"
      ## Appended after the M6 kinds so their ordinals -- which order the
      ## diagnostics -- do not move.
    cdContradictoryLock = "contradictory-lock-pins"

  CatalogDiagnostic* = object
    kind*: CatalogDiagnosticKind
    message*: string

  CatalogComposition* = object
    ## ``resolverInput`` is non-empty exactly when ``diagnostics`` is
    ## empty. There is no partial composition.
    resolverInput*: string
    resolverInputDigest*: string
    selectedGraph*: string
    selectedGraphDigest*: string
    selections*: seq[CatalogSelection]
    diagnostics*: seq[CatalogDiagnostic]

proc refused*(composition: CatalogComposition): bool =
  ## True iff composition produced any diagnostic, in which case every
  ## composed output is empty.
  composition.diagnostics.len > 0

proc diagnosticReport*(composition: CatalogComposition): string =
  ## Every diagnostic, one per line, in the sorted order they are stored
  ## in — so the report is byte-identical under import permutation too.
  var lines: seq[string] = @[]
  for diagnostic in composition.diagnostics:
    lines.add($diagnostic.kind & ": " & diagnostic.message)
  lines.join("\n")

# ---------------------------------------------------------------------------
# Canonical text encoding
# ---------------------------------------------------------------------------

proc escapeField(value: string): string =
  for ch in value:
    case ch
    of '\\': result.add("\\\\")
    of '\t': result.add("\\t")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    else: result.add(ch)

proc record(fields: varargs[string]): string =
  ## One canonical record: escaped, tab-separated, LF-terminated.
  for i, field in fields:
    if i > 0: result.add('\t')
    result.add(escapeField(field))
  result.add('\n')

proc digestOfText(text: string): string =
  toHex(blake3DomainDigest(
    toOpenArrayByte(text, 0, text.high), hdMetadataEnvelope).bytes).
    toLowerAscii()

proc isHex64(value: string): bool =
  if value.len != 64:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

# ---------------------------------------------------------------------------
# Coordinate identity
# ---------------------------------------------------------------------------

proc catalogCoordinateKey*(coordinate: CatalogCoordinate): string =
  ## The stable human spelling of a coordinate, used in every diagnostic
  ## and as the emission order of the catalog section. Not a digest.
  escapeField(coordinate.workspace) & "|" & escapeField(coordinate.remote) &
    "@" & escapeField(coordinate.revision) & "#" &
    normalizedFingerprint(coordinate.interfaceArtifact)

proc catalogCoordinateDigest*(coordinate: CatalogCoordinate): string =
  ## 64-hex identity of a coordinate. Two imports agreeing on it are the
  ## same catalog and must agree on their content.
  var text = CatalogCoordinateMagic & "\n"
  text.add(record("workspace", coordinate.workspace))
  text.add(record("remote", coordinate.remote))
  text.add(record("revision", coordinate.revision))
  text.add(record("interface-artifact",
    normalizedFingerprint(coordinate.interfaceArtifact)))
  digestOfText(text)

proc catalogArtifactIdentity*(
    artifacts: openArray[ProjectInterfaceArtifact]): string =
  ## The interface-artifact component of a coordinate: a 64-hex digest over
  ## the SEMANTIC identity of this catalog's published artifact set — each
  ## artifact's project name and its ``InterfaceFingerprint`` — sorted so
  ## the set is order-independent.
  ##
  ## It is deliberately NOT a digest of ``encodeProjectInterfaceArtifact``'s
  ## bytes, and that distinction was measured rather than assumed. The
  ## encoded artifact carries every declaration's ``SourceLocation``, which
  ## on a real extraction is an ABSOLUTE path: composing the same catalog on
  ## a Windows checkout and on a Linux checkout produced two different
  ## coordinate identities, and therefore two different composed digests,
  ## for one catalog. A coordinate that cannot survive being computed on a
  ## second machine cannot pin a federated import at all.
  ##
  ## ``interfaceFingerprint`` is the projection that already excludes source
  ## locations (its ``forFingerprint`` sentinel exists for exactly this
  ## reason) while still binding the contribution records — see
  ## ``t_provisioning_contributions.nim`` "contribution metadata changes
  ## catalog interface fingerprint". So this identity moves when the catalog
  ## publishes different realization metadata, and does not move when the
  ## same catalog is extracted from a different directory.
  var entries: seq[string] = @[]
  for artifact in artifacts:
    entries.add(record("artifact", artifact.projectInterface.projectName,
      artifact.projectInterface.packageName,
      toHex(artifact.interfaceFingerprint.bytes).toLowerAscii()))
  entries.sort(cmp)
  var text = CatalogArtifactIdentityMagic & "\n"
  text.add(entries.deduplicate(isSorted = true).join(""))
  digestOfText(text)

proc catalogInterface*(packageName, interfaceFingerprint: string):
    CatalogPackageInterface =
  ## Construct a canonical-interface entry. The fingerprint is expected to
  ## come from ``canonicalPackageInterfaceFingerprint``.
  CatalogPackageInterface(packageName: packageName,
    interfaceFingerprint: interfaceFingerprint)

# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------

type
  ResolvedCatalog = object
    coordinate: CatalogCoordinate
    key: string
    digest: string
    content: CatalogContent
    contentText: string

  EligibleContribution = object
    targetPackage: string
    targetFingerprint: string
    contributor: string
    recordDigest: string
    catalogKey: string
    coordinate: CatalogCoordinate
    location: SourceLocation

proc locationSpelling(location: SourceLocation): string =
  ## A source location for a diagnostic. Slashes are normalised so the same
  ## declaration reads the same on either host; the value never reaches a
  ## digest.
  if location.file.len == 0:
    return "<unknown source>"
  location.file.replace('\\', '/') & ":" & $location.line

proc contentText(content: CatalogContent): string =
  ## The canonical bytes of one catalog's published content. Two imports of
  ## one coordinate must agree on this exactly.
  var lines: seq[string] = @[]
  for entry in content.canonicalInterfaces:
    lines.add(record("interface", entry.packageName,
      normalizedFingerprint(entry.interfaceFingerprint)))
  for contribution in content.contributions:
    lines.add(record("contribution", contribution.targetPackage,
      normalizedFingerprint(contribution.targetInterfaceFingerprint),
      contribution.contributor,
      interfaceContributionRecordDigest(contribution)))
  lines.sort(cmp)
  lines.deduplicate(isSorted = true).join("")

proc coordinateGaps(coordinate: CatalogCoordinate): seq[string] =
  if coordinate.workspace.strip().len == 0:
    result.add("workspace is empty")
  if coordinate.remote.strip().len == 0:
    result.add("remote is empty")
  if coordinate.revision.strip().len == 0:
    result.add("revision is empty")
  let artifact = normalizedFingerprint(coordinate.interfaceArtifact)
  if artifact.len == 0:
    result.add("interface-artifact identity is empty")
  elif not isHex64(artifact):
    result.add("interface-artifact identity is not a 64-hex digest: \"" &
      coordinate.interfaceArtifact & "\"")

proc composeCatalogs*(imports: openArray[CatalogImport];
                      policy: CatalogSelectionPolicy;
                      lockPins: openArray[CatalogLockPin] = []):
    CatalogComposition =
  ## Compose explicitly identified catalog imports into ONE deterministic
  ## resolver input, or refuse.
  ##
  ## Selection precedence per package (Provisioning-Contributions.md,
  ## Resolution): a ``lockPins`` entry, else a ``policy`` rule, else the
  ## unique eligible contribution; anything else refuses. A lock pin is
  ## never relaxed to a lower rung. ``lockPins`` empty keeps every
  ## composed byte exactly as before it existed.
  ##
  ## Never raises. The result is byte-identical under any permutation of
  ## ``imports`` and of the contributions inside each catalog, and does not
  ## depend on ``CatalogImport.discoveredAt`` in any way except through the
  ## text of a diagnostic that names it.
  var diagnostics: seq[CatalogDiagnostic] = @[]

  template refuse(diagnosticKind: CatalogDiagnosticKind; text: string) =
    diagnostics.add(CatalogDiagnostic(kind: diagnosticKind, message: text))

  # --- 1. Per-import identity validation -----------------------------------
  var groupOrder: seq[string] = @[]
  var groupImports = initTable[string, seq[CatalogImport]]()
  for imported in imports:
    let gaps = coordinateGaps(imported.coordinate)
    if gaps.len > 0:
      refuse(cdIncompleteCoordinate,
        "catalog import discovered at \"" & imported.discoveredAt &
        "\" (remote \"" & imported.coordinate.remote &
        "\") has an incomplete coordinate: " & gaps.join(", ") &
        ". A catalog is bound by explicit workspace/remote/revision/" &
        "interface-artifact identity, never by a sibling-directory name " &
        "or its position in the import list.")
      continue
    if imported.content.isNone:
      refuse(cdMissingCatalog,
        "catalog " & catalogCoordinateKey(imported.coordinate) &
        " was declared but not found (discovered at \"" &
        imported.discoveredAt & "\"); no interface artifact is available " &
        "to compose. Pin the catalog in the workspace manifest, or remove " &
        "the import.")
      continue
    let digest = catalogCoordinateDigest(imported.coordinate)
    if digest notin groupImports:
      groupOrder.add(digest)
      groupImports[digest] = @[]
    groupImports[digest].add(imported)

  # --- 2. Group by coordinate; one coordinate is one content ---------------
  var catalogs: seq[ResolvedCatalog] = @[]
  # ``groupOrder`` is deliberately NOT sorted, and that is a COLLAPSE
  # rather than an omission. Sorting it made ``catalogs`` deterministic,
  # which made every ordering guard downstream inert: the catalog
  # section, the ownership diagnostics, the eligible-candidate list and
  # the selection order were all stable whether or not they sorted
  # anything themselves. M6 verification measured the consequence —
  # ``groupOrder.sort`` and ``catalogLines.sort`` EACH survived deletion
  # with a green suite, so a refactor could have deleted either one on
  # the strength of the tests and a later one its partner by the same
  # reasoning. Each emitted section now owns its own order and is
  # falsifiable on its own. The composed bytes are unchanged, because
  # the emitted order was always the sorted-record order and never this
  # grouping order.
  for digest in groupOrder:
    let group = groupImports[digest]
    var texts: seq[string] = @[]
    var locations: seq[string] = @[]
    for imported in group:
      texts.add(contentText(imported.content.get))
      locations.add(imported.discoveredAt)
    let distinctTexts = texts.sorted(cmp).deduplicate(isSorted = true)
    let key = catalogCoordinateKey(group[0].coordinate)
    if distinctTexts.len > 1:
      refuse(cdCatalogIdentityConflict,
        "catalog coordinate " & key & " was imported with " &
        $distinctTexts.len & " different contents; one coordinate names " &
        "exactly one interface-artifact identity. Discovered at: " &
        locations.sorted(cmp).deduplicate(isSorted = true).join("; ") &
        ". Re-extract the catalog's interface artifacts, or give the " &
        "differing checkout its own revision.")
      continue
    catalogs.add(ResolvedCatalog(
      coordinate: group[0].coordinate,
      key: key,
      digest: digest,
      content: group[0].content.get,
      contentText: distinctTexts[0]))

  # --- 3. Canonical interface ownership ------------------------------------
  var ownerOrder: seq[string] = @[]
  var owners = initTable[string, seq[string]]()
  var canonicalOf = initTable[string, string]()
  for catalog in catalogs:
    for entry in catalog.content.canonicalInterfaces:
      if entry.packageName notin owners:
        ownerOrder.add(entry.packageName)
        owners[entry.packageName] = @[]
      owners[entry.packageName].add("catalog " & catalog.key &
        " declares " & normalizedFingerprint(entry.interfaceFingerprint))
      canonicalOf[entry.packageName] =
        normalizedFingerprint(entry.interfaceFingerprint)
  # Not sorted, for the reason above: ``ownerOrder`` only chooses the
  # order in which ``duplicate-canonical-interface`` diagnostics are
  # RAISED, and every diagnostic is sorted by (kind, message) before it
  # is reported. Two guards over one ordering meant neither could be
  # falsified alone.
  var ambiguouslyOwned: seq[string] = @[]
  for packageName in ownerOrder:
    let declarations =
      owners[packageName].sorted(cmp).deduplicate(isSorted = true)
    if declarations.len > 1:
      ambiguouslyOwned.add(packageName)
      refuse(cdDuplicateCanonicalInterface,
        "package \"" & packageName & "\" has more than one canonical " &
        "interface owner: " & declarations.join("; ") &
        ". Exactly one catalog may own a canonical package interface; " &
        "split the declaration or drop one of the imports.")

  # --- 4. Contribution eligibility -----------------------------------------
  var eligible: seq[EligibleContribution] = @[]
  for catalog in catalogs:
    for contribution in catalog.content.contributions:
      let declared =
        normalizedFingerprint(contribution.targetInterfaceFingerprint)
      if contribution.targetPackage notin canonicalOf:
        refuse(cdUnknownTargetInterface,
          "contribution from \"" & contribution.contributor &
          "\" in catalog " & catalog.key & " targets package \"" &
          contribution.targetPackage & "\" (declared at " &
          locationSpelling(contribution.location) &
          "), but no imported catalog declares a canonical interface for " &
          "it. Import the catalog that owns the interface, or remove the " &
          "contribution.")
        continue
      if contribution.targetPackage in ambiguouslyOwned:
        continue
      let canonical = canonicalOf[contribution.targetPackage]
      if declared != canonical:
        refuse(cdIncompatibleFingerprint,
          "contribution from \"" & contribution.contributor &
          "\" in catalog " & catalog.key & " targets package \"" &
          contribution.targetPackage & "\" at interface fingerprint " &
          declared & ", but the composed canonical interface is " &
          canonical & " (contribution declared at " &
          locationSpelling(contribution.location) &
          "). The contribution is pinned to a superseded interface " &
          "revision and must be refreshed against the current interface.")
        continue
      eligible.add(EligibleContribution(
        targetPackage: contribution.targetPackage,
        targetFingerprint: canonical,
        contributor: contribution.contributor,
        recordDigest: interfaceContributionRecordDigest(contribution),
        catalogKey: catalog.key,
        coordinate: catalog.coordinate,
        location: contribution.location))

  # --- 5. Selection --------------------------------------------------------
  var policyOf = initTable[string, string]()
  var policyPackages: seq[string] = @[]
  var policyContributors = initTable[string, seq[string]]()
  for rule in policy.selections:
    if rule.targetPackage notin policyOf:
      policyPackages.add(rule.targetPackage)
      policyContributors[rule.targetPackage] = @[]
    policyOf[rule.targetPackage] = rule.contributor
    policyContributors[rule.targetPackage].add(rule.contributor)
  # Not sorted, for the reason ``ownerOrder`` is not: this order reaches
  # only ``contradictory-curator-policy`` and
  # ``policy-selection-unsatisfied`` diagnostics, which the final
  # diagnostic sort orders.
  var contradictoryPolicy: seq[string] = @[]
  for packageName in policyPackages:
    let named = policyContributors[packageName].sorted(cmp).
      deduplicate(isSorted = true)
    if named.len > 1:
      contradictoryPolicy.add(packageName)
      refuse(cdContradictoryPolicy,
        "curator policy names " & $named.len & " different contributors for " &
        "package \"" & packageName & "\": " &
        named.mapIt("\"" & it & "\"").join(", ") &
        ". A policy entry's position is no more a selection rule than an import's " &
        "(Provisioning-Contributions.md, Resolution): which of two contradictory " &
        "entries wins is undecidable, so composition refuses rather than taking " &
        "the one written last. Keep exactly one entry per package.")

  # Lock pins. Like the policy, a pin's POSITION is never a selection rule:
  # two pins naming different contributors for one package refuse.
  var lockOf = initTable[string, string]()
  var lockPackages: seq[string] = @[]
  var lockContributors = initTable[string, seq[string]]()
  for pin in lockPins:
    if pin.targetPackage notin lockOf:
      lockPackages.add(pin.targetPackage)
      lockContributors[pin.targetPackage] = @[]
    lockOf[pin.targetPackage] = pin.contributor
    lockContributors[pin.targetPackage].add(pin.contributor)
  var contradictoryLock: seq[string] = @[]
  for packageName in lockPackages:
    let named = lockContributors[packageName].sorted(cmp).
      deduplicate(isSorted = true)
    if named.len > 1:
      contradictoryLock.add(packageName)
      refuse(cdContradictoryLock,
        "the lock pins " & $named.len & " different contributors for " &
        "package \"" & packageName & "\": " &
        named.mapIt("\"" & it & "\"").join(", ") &
        ". Which one wins is undecidable; restore the committed lock.")

  var packageOrder: seq[string] = @[]
  for candidate in eligible:
    if candidate.targetPackage notin packageOrder:
      packageOrder.add(candidate.targetPackage)
  packageOrder.sort(cmp)

  var selections: seq[CatalogSelection] = @[]
  var satisfiedPolicy: seq[string] = @[]
  for packageName in packageOrder:
    # ``candidates`` is deliberately NOT sorted -- the last of the seven
    # redundant-by-construction guards M6 verification named, collapsed
    # rather than pinned. Its order reaches no composed byte: a selection is
    # made only when exactly ONE candidate is wanted, so ``wanted[0]`` is
    # order-free, and every candidate shares the canonical fingerprint. It
    # reached only two diagnostic texts, and each of those now orders its
    # own list: the ambiguity message sorts ``described``, the
    # unsatisfied-policy message sorts its contributor ids. The candidate
    # sort and the ``described`` sort were each other's mask -- measured,
    # either could be deleted with the suite green -- so a refactor could
    # delete one on the strength of the tests and a later one the other.
    if packageName in contradictoryLock:
      continue
    if packageName in lockOf:
      # The lock outranks the policy and the unique-eligible rule, and is
      # never relaxed to either of them.
      let candidates = eligible.filterIt(it.targetPackage == packageName)
      let wanted = candidates.filterIt(it.contributor == lockOf[packageName])
      if wanted.len == 0:
        refuse(cdLockedContributionUnavailable,
          "the lock pins contributor \"" & lockOf[packageName] &
          "\" for package \"" & packageName & "\", but no imported " &
          "catalog offers an eligible contribution from it. Eligible " &
          "contributors: " &
          candidates.mapIt("\"" & it.contributor & "\"").sorted(cmp).
            deduplicate(isSorted = true).join(", ") &
          ". The lock is not re-selected by policy or by a unique " &
          "eligible contribution: restore the locked catalog, or refresh " &
          "the lock deliberately.")
        continue
      if wanted.len > 1:
        var described: seq[string] = @[]
        for candidate in wanted:
          described.add("contributor \"" & candidate.contributor &
            "\" from catalog " & candidate.catalogKey & " declared at " &
            locationSpelling(candidate.location))
        refuse(cdAmbiguousContribution,
          "package \"" & packageName & "\" (interface " &
          wanted[0].targetFingerprint & ") has " & $wanted.len &
          " eligible provisioning contributions from the locked " &
          "contributor \"" & lockOf[packageName] & "\"; import order is " &
          "never a selection rule (Provisioning-Contributions.md, " &
          "Resolution). Candidates: " &
          described.sorted(cmp).deduplicate(isSorted = true).join("; ") &
          ".")
        continue
      selections.add(CatalogSelection(
        targetPackage: packageName,
        targetInterfaceFingerprint: wanted[0].targetFingerprint,
        contributor: wanted[0].contributor,
        contributionRecordDigest: wanted[0].recordDigest,
        catalogCoordinate: wanted[0].coordinate,
        reason: csLock))
      continue
    if packageName in contradictoryPolicy:
      # Refused above. Which of its entries "wins" is undecidable, so
      # NOTHING -- no selection and no diagnostic -- is derived from either
      # entry. ``policyOf`` folds the entries last-wins, and consulting it
      # here made the REFUSAL depend on the entry written last (verification
      # of the per-guard pass, 2026-09-23): with one eligible and one absent
      # contributor, only the order that wrote the absent one last added a
      # ``policy-selection-unsatisfied`` diagnostic, and that message named
      # whichever contributor came last.
      continue
    let candidates = eligible.filterIt(it.targetPackage == packageName)
    var wanted = candidates
    var reason = csUniqueEligible
    if packageName in policyOf:
      wanted = candidates.filterIt(it.contributor == policyOf[packageName])
      reason = csCuratorPolicy
      if wanted.len == 0:
        refuse(cdPolicySelectionUnsatisfied,
          "curator policy selects contributor \"" & policyOf[packageName] &
          "\" for package \"" & packageName &
          "\", but no imported catalog offers an eligible contribution " &
          "from it. Eligible contributors: " &
          (if candidates.len == 0: "<none>"
           else: candidates.mapIt(it.contributor).sorted(cmp).
             deduplicate(isSorted = true).mapIt("\"" & it & "\"").
             join(", ")) & ".")
        continue
      satisfiedPolicy.add(packageName)
    if wanted.len > 1:
      var described: seq[string] = @[]
      for candidate in wanted:
        described.add("contributor \"" & candidate.contributor &
          "\" from catalog " & candidate.catalogKey & " declared at " &
          locationSpelling(candidate.location))
      refuse(cdAmbiguousContribution,
        "package \"" & packageName & "\" (interface " &
        wanted[0].targetFingerprint & ") has " & $wanted.len &
        " eligible provisioning contributions and no lock or curator " &
        "policy selects one; import order is never a selection rule " &
        "(Provisioning-Contributions.md, Resolution). Candidates: " &
        described.sorted(cmp).deduplicate(isSorted = true).join("; ") &
        ". Pin one with an explicit selection.")
      continue
    selections.add(CatalogSelection(
      targetPackage: packageName,
      targetInterfaceFingerprint: wanted[0].targetFingerprint,
      contributor: wanted[0].contributor,
      contributionRecordDigest: wanted[0].recordDigest,
      catalogCoordinate: wanted[0].coordinate,
      reason: reason))

  for packageName in policyPackages:
    if packageName in packageOrder or packageName in satisfiedPolicy or
        packageName in contradictoryPolicy:
      # A contradictory package is skipped for the reason given in the
      # selection loop: ``policyOf`` would name its LAST entry.
      continue
    if packageName in lockOf:
      continue
    refuse(cdPolicySelectionUnsatisfied,
      "curator policy selects contributor \"" & policyOf[packageName] &
      "\" for package \"" & packageName &
      "\", but no imported catalog offers an eligible contribution from " &
      "it. Eligible contributors: <none>.")

  for packageName in lockPackages:
    if packageName in packageOrder or packageName in contradictoryLock:
      continue
    refuse(cdLockedContributionUnavailable,
      "the lock pins contributor \"" & lockOf[packageName] &
      "\" for package \"" & packageName & "\", but no imported catalog " &
      "offers an eligible contribution for the package at all. Eligible " &
      "contributors: <none>. The lock is not re-selected: restore the " &
      "locked catalog, or refresh the lock deliberately.")

  # --- 6. Canonical serialisation ------------------------------------------
  var catalogLines: seq[string] = @[]
  var interfaceLines: seq[string] = @[]
  var contributionLines: seq[string] = @[]
  for catalog in catalogs:
    catalogLines.add(record("catalog", catalog.coordinate.workspace,
      catalog.coordinate.remote, catalog.coordinate.revision,
      normalizedFingerprint(catalog.coordinate.interfaceArtifact),
      catalog.digest))
    for entry in catalog.content.canonicalInterfaces:
      interfaceLines.add(record("interface", entry.packageName,
        normalizedFingerprint(entry.interfaceFingerprint), catalog.digest))
    for contribution in catalog.content.contributions:
      contributionLines.add(record("contribution",
        contribution.targetPackage,
        normalizedFingerprint(contribution.targetInterfaceFingerprint),
        contribution.contributor,
        interfaceContributionRecordDigest(contribution),
        catalog.digest))
  catalogLines.sort(cmp)
  interfaceLines.sort(cmp)
  contributionLines.sort(cmp)

  var resolverInput = CatalogCompositionMagic & "\n"
  # The catalog section is NOT de-duplicated: step 2 groups imports BY
  # coordinate digest and emits one ``ResolvedCatalog`` per group, and
  # the digest is a field of the record, so two catalog lines cannot be
  # equal. The grouping is the single guard, and it is falsifiable ("the
  # same catalog imported twice is one catalog"). The interface and
  # contribution sections DO de-duplicate, because one catalog may
  # legitimately declare the same interface or the same contribution
  # twice.
  resolverInput.add(catalogLines.join(""))
  resolverInput.add(interfaceLines.deduplicate(isSorted = true).join(""))
  resolverInput.add(contributionLines.deduplicate(isSorted = true).join(""))

  var selectionLines: seq[string] = @[]
  for selection in selections:
    selectionLines.add(record("select", selection.targetPackage,
      selection.targetInterfaceFingerprint, selection.contributor,
      selection.contributionRecordDigest,
      catalogCoordinateDigest(selection.catalogCoordinate),
      $selection.reason))
  # Neither sorted nor de-duplicated here, and both for one reason:
  # ``selections`` carries exactly one entry per package name and is
  # emitted in ``packageOrder``, which IS sorted and which the public
  # ``CatalogComposition.selections`` list is ordered by as well. Sorting
  # the rendered lines as well produced the same bytes (a ``select``
  # record begins with its package name) while making both guards
  # unfalsifiable on their own.
  var selectedGraph = CatalogSelectionMagic & "\n"
  selectedGraph.add(selectionLines.join(""))

  # --- 7. Fail closed ------------------------------------------------------
  diagnostics.sort(proc (a, b: CatalogDiagnostic): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.message, b.message))
  diagnostics = diagnostics.deduplicate(isSorted = true)
  if diagnostics.len > 0:
    return CatalogComposition(diagnostics: diagnostics)

  CatalogComposition(
    resolverInput: resolverInput,
    resolverInputDigest: digestOfText(resolverInput),
    selectedGraph: selectedGraph,
    selectedGraphDigest: digestOfText(selectedGraph),
    selections: selections,
    diagnostics: @[])
