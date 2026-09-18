## The provisioning **contribution fingerprint** — M7 deliverable 1 of
## ``ReproOS-Campaign-Completion.milestones.org``, normatively specified by
## ``reprobuild-specs/Provisioning-Contributions.md`` § Identities,
## § Interface Artifacts and § Locks And Snapshots.
##
## ## What this module binds
##
## A provisioning contribution has **two independent identities**. The
## target interface identity — package name plus the canonical
## ``InterfaceFingerprint`` — is already computed by
## ``repro_interface_artifacts.interfaceFingerprint`` and is a projection
## over the SEMANTIC public contract only. This module computes the
## *other* one: the contribution identity, over
##
##   * the **contributor id** (the stable catalog identity);
##   * the **target package name**;
##   * the **target interface fingerprint** the contribution binds to;
##   * the **realization metadata** — every Nix, tarball, Scoop and
##     from-source realization the contribution declares;
##   * the **provider identity** — the content identity of the provider
##     implementation that realizes this contribution;
##   * the **integrity fields** — ``nixpkgsRev`` / ``nixpkgsNarHash``,
##     archive ``sha256`` and mirror set, Scoop ``manifestChecksum`` /
##     ``manifestUrl``, the from-source recipe digest;
##   * the **declared dependency coordinates**, folded in through the
##     recursive composer below.
##
## The invariant this exists to serve is the spec's central one:
##
##   Provisioning metadata is realization policy, not package API.
##   Changing a Nix attribute, Scoop manifest, archive URL, source recipe
##   or default provisioning mode MUST NOT change the canonical package
##   interface fingerprint. It MUST change the contribution fingerprint
##   and any lock selecting that contribution.
##
## The two directions are structurally separated rather than merely
## tested: a contribution record lives in the CATALOG project's interface
## and never in the target package's, so nothing this module reads is an
## input of ``interfaceFingerprint(targetPackage)``. Conversely the target
## interface fingerprint IS an input here, so refreshing the package
## interface moves every contribution identity bound to it — which is what
## makes an incompatible contribution lock detectably stale.
##
## ## What is deliberately NOT an input
##
##   * ``SourceLocation``. The spec calls the contribution's source
##     location a diagnostic. Folding it in would make moving a
##     declaration down a file a realization change, which is the same
##     defect ``writeLocation``'s ``forFingerprint`` sentinel exists to
##     avoid for the interface fingerprint.
##   * ``developInterface``. A develop-bound contribution has no published
##     interface identity at all and is forbidden in a committed lock or
##     catalog snapshot, so it does not get a fingerprint — it REFUSES.
##
## ## Canonical, order-independent encoding
##
## Two equivalent contributions must fingerprint identically regardless of
## the order fields were emitted in or a map was iterated in. Three
## normalisations achieve that, and each is a *sort*, never a dedupe of
## meaning:
##
##   1. every realization is encoded as a **sorted (name, value) field
##      map** — so field emission order cannot be observed;
##   2. the realization blobs of one contribution are **sorted by their
##      encoded bytes** — so declaration order of two ``nixPackage``
##      entries cannot be observed;
##   3. the dependency identity hexes are **sorted and de-duplicated** —
##      the same normalisation ``CacheEntryIdentity.depClosure`` already
##      applies.
##
## Set-valued fields inside a realization (archive ``mirrors``,
## ``prunePaths``, from-source ``recipeInputs``) are sorted for the same
## reason: a mirror list in a different order is the same mirror set, and
## a lock that flipped identity on it would invalidate every downstream
## build for nothing.
##
## Everything is length-prefixed before it is concatenated, so no value
## can be confused with an adjacent one, and the whole payload goes
## through ``blake3DomainDigest(_, hdMetadataEnvelope)`` under its own
## magic — the same domain-framed construction the interface fingerprint
## uses.
##
## ## The base case, and why it is not circular
##
## This is the reason M7 is being worked ahead of its own dependency
## (see the milestone file's M7 implementation notes). M13's source
## identity is blocked because **resolved dependency-instance keys do not
## exist for source packages**: the only 64-hex value available at
## recipe-evaluation time is a ``repro_local_store`` realization hash,
## which is a different key space and is written only AFTER the dependency
## is built. A naive source analogue is circular — every source
## dependency's own identity carries the pending marker, so deriving its
## key refuses, so the parent refuses.
##
## The contribution fingerprint is a **declaration-space** identity, and
## that is what breaks the circle. Its base case,
## ``leafContributionIdentityHex``, is computed from the DECLARED
## coordinate alone:
##
##     (target package, contributor id, target interface fingerprint)
##
## All three are literals present in the catalog source at evaluation
## time. None of them requires the dependency to be built, realized,
## solved or even present on disk. So a dependency instance always has a
## well-defined 64-hex identity, and no path through this module can reach
## a pending realization hash.
##
## This is the same shape ``foreign_common.foreignPackageIdentityRec``
## uses, and the base case plays the same role ``leafDepIdentityHex``
## does there.
##
## ## Cycles
##
## ``visited`` is a stack of ``<target package>\0<contributor>`` keys.
## A dependency already on the stack is a cycle and is folded in as the
## LEAF identity instead of being recursed into, exactly as
## ``foreignPackageIdentityRec`` does; the stack is popped after each
## contribution's dependency loop so sibling branches see a clean trail.
## A ``MaxContributionDepth`` guard additionally bounds a resolver that
## manufactures unboundedly many distinct coordinates (which ``visited``
## alone cannot catch), and it REFUSES rather than truncating.
##
## ## Fail closed
##
## Per this codebase's standing rule — *a false refusal is safe, a false
## accept is not; where undecidable, refuse* — a contribution missing any
## required identity input produces NO fingerprint at all rather than one
## computed over partial data. ``ContributionFingerprint.hex`` is empty
## exactly when ``refusals`` is non-empty, so there is no shape in which a
## caller can obtain a hex that was derived from an incomplete tuple.
##
## Required, and refused when absent or malformed:
##
##   * contributor id, target package name, provider identity;
##   * a target interface fingerprint that is 64 hex characters after
##     normalisation (an unpinned or develop-bound contribution refuses);
##   * at least one realization;
##   * per realization, its selector/coordinate AND its integrity
##     evidence: Nix needs ``nixpkgsRev`` and ``nixpkgsNarHash``, a
##     tarball needs a ``url`` and a well-formed ``sha256``, Scoop needs
##     ``bucket``/``app`` and a well-formed ``manifestChecksum``,
##     from-source needs a recipe path and a 64-hex recipe digest;
##   * every dependency coordinate complete, with a 64-hex target
##     interface fingerprint;
##   * a resolved dependency that itself refuses propagates its refusal
##     upward rather than being silently downgraded to its leaf.
##
## ## What this module does NOT do
##
## It does not serialize anything into a lock (M7 deliverable 2, which
## needs M6's catalog coordinates and revision), and it does not select a
## contribution (deliverable 3). It computes an identity; storing and
## choosing are other deliverables.

import std/[algorithm, options, sequtils, strutils]

import repro_hash

import ../repro_interface_artifacts

const
  ContributionFingerprintMagic* = "reprobuild.contribution-fingerprint.v1"
    ## Domain magic of the contribution-identity payload. Bumping it
    ## re-keys every contribution fingerprint, so it is versioned
    ## explicitly rather than left implicit in the field order.

  ContributionLeafMagic* = "reprobuild.contribution-dependency-leaf.v1"
    ## Domain magic of the dependency BASE CASE. Deliberately distinct
    ## from the composite magic so a leaf identity can never collide with
    ## the full identity of a contribution that happens to declare the
    ## same coordinate.

  MaxContributionDepth* = 64
    ## Recursion bound. ``visited`` already terminates every cycle; this
    ## bounds a resolver that manufactures unboundedly many distinct
    ## coordinates. Exceeding it REFUSES.

type
  ContributionDependencyRef* = object
    ## A declared dependency of a contribution's realization, named by
    ## the coordinate a lock pins — never by a realization hash. See the
    ## module docstring's "base case" section for why this is the shape
    ## that avoids the pending-marker circularity.
    targetPackage*: string
    contributor*: string
    targetInterfaceFingerprint*: string

  FromSourceRealization* = object
    ## From-source realization metadata. ``recipeDigest`` is the 64-hex
    ## source-closure digest of the recipe tree — in practice
    ## ``source_cache_identity.solvedSourceClosure(...).digestHex``, which
    ## is a function of the recipe's complete local source closure rather
    ## than of the entry file's bytes (Reprobuild #171).
    packageName*: string
    contributor*: string
    recipePath*: string
    recipeDigest*: string
    recipeInputs*: seq[(string, string)]
      ## Declared recipe inputs. Order-insensitive: sorted by name, then
      ## value, before it is encoded.
    packageId*: string
    lockIdentity*: string

  ContributionIdentity* = object
    ## The complete identity input of one provisioning contribution.
    ##
    ## ``contribution`` is the record the interface artifact already
    ## carries (``InterfaceProvisioningContribution``), readable without
    ## running the provider. ``providerIdentity``,
    ## ``fromSourceProvisioning`` and ``dependencies`` are the inputs the
    ## v17 artifact codec does not carry yet; the caller supplies them,
    ## and every one of them is REQUIRED-when-applicable rather than
    ## optional — a missing provider identity refuses.
    contribution*: InterfaceProvisioningContribution
    providerIdentity*: string
    fromSourceProvisioning*: seq[FromSourceRealization]
    dependencies*: seq[ContributionDependencyRef]

  ContributionFingerprint* = object
    ## ``hex`` is non-empty exactly when ``refusals`` is empty. There is
    ## no third state and no partial fingerprint.
    hex*: string
    refusals*: seq[string]

  ContributionResolver* = proc (dep: ContributionDependencyRef):
    Option[ContributionIdentity] {.gcsafe.}
    ## Caller-supplied map from a declared dependency coordinate to that
    ## dependency's own contribution identity. Returning ``none`` is not
    ## an error: the composer then folds in the dependency's LEAF
    ## identity, which is complete in declaration space. Mirrors
    ## ``foreign_common.ForeignDepResolver``.

proc noContributionResolver*(dep: ContributionDependencyRef):
    Option[ContributionIdentity] {.gcsafe.} =
  ## Default resolver: every dependency folds in as its leaf coordinate.
  none(ContributionIdentity)

proc isResolved*(fp: ContributionFingerprint): bool =
  ## True iff a usable 64-hex fingerprint was produced.
  fp.refusals.len == 0 and fp.hex.len == 64

proc refusalReason*(fp: ContributionFingerprint): string =
  ## The refusals joined for a diagnostic. Empty on a resolved value.
  fp.refusals.join("; ")

# ---------------------------------------------------------------------------
# Canonical encoding primitives
# ---------------------------------------------------------------------------

proc putU32Le(buf: var string; value: uint32) =
  for shift in [0, 8, 16, 24]:
    buf.add(chr(int((value shr shift) and 0xff'u32)))

proc putStr(buf: var string; value: string) =
  ## Length-prefixed, so no value can be confused with its neighbour.
  buf.putU32Le(uint32(value.len))
  buf.add(value)

proc putStrSet(buf: var string; values: seq[string]) =
  ## A set-valued field: sorted before encoding, so declaration order is
  ## not observable. Duplicates are KEPT — a repeated mirror is a
  ## different declaration from a single one, and dropping it would be a
  ## semantic edit rather than a normalisation.
  var sorted = values
  sorted.sort(cmp)
  buf.putU32Le(uint32(sorted.len))
  for v in sorted:
    buf.putStr(v)

proc cmpFields(a, b: (string, string)): int =
  result = cmp(a[0], b[0])
  if result == 0:
    result = cmp(a[1], b[1])

proc encodeFields(fields: seq[(string, string)]): string =
  ## A realization's field map, sorted by (name, value). This is what
  ## makes the fingerprint invariant to field emission order and to map
  ## iteration order.
  var sorted = fields
  sorted.sort(cmpFields)
  result.putU32Le(uint32(sorted.len))
  for (name, value) in sorted:
    result.putStr(name)
    result.putStr(value)

proc hexOfDigest(payload: string): string =
  toHex(blake3DomainDigest(
    toOpenArrayByte(payload, 0, payload.high), hdMetadataEnvelope).bytes)

# ---------------------------------------------------------------------------
# Normalisation and integrity-field shape
# ---------------------------------------------------------------------------

proc normalizedFingerprint*(value: string): string =
  ## Accepts the spellings the DSL and the artifact codec both allow —
  ## a bare hex digest, or one prefixed with its algorithm. Mirrors
  ## ``repro_interface_artifacts``' own private normalisation so a
  ## contribution that spells its pin ``blake3-256:<hex>`` is the same
  ## contribution as one that spells it ``<hex>``.
  result = value.strip().toLowerAscii()
  for prefix in ["blake3-256:", "blake3:", "b3:"]:
    if result.startsWith(prefix):
      return result[prefix.len .. ^1]

proc isHex(value: string; width: int): bool =
  if value.len != width:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc isDigestField(value: string): bool =
  ## A well-formed integrity digest: 64 hex characters, or the SRI
  ## spelling Nix and Scoop both emit (``sha256-<base64>``). Anything
  ## else — a truncated hex string, a placeholder, a URL — is not
  ## integrity evidence and refuses.
  if isHex(value, 64):
    return true
  for algo in ["sha256-", "sha512-", "sha1-", "md5-"]:
    if value.startsWith(algo):
      let body = value[algo.len .. ^1]
      if body.len < 20:
        return false
      for ch in body:
        if ch notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '='}:
          return false
      return true
  false

# ---------------------------------------------------------------------------
# Realization encoding
# ---------------------------------------------------------------------------

proc encodeNix(p: InterfaceNixProvisioning): string =
  result.putStr("nix")
  result.add(encodeFields(@[
    ("packageName", p.packageName),
    ("contributor", p.contributor),
    ("selector", p.selector),
    ("executablePath", p.executablePath),
    ("expressionFile", p.expressionFile),
    ("nixpkgsRef", p.nixpkgsRef),
    ("nixpkgsRev", p.nixpkgsRev),
    ("nixpkgsNarHash", p.nixpkgsNarHash),
    ("packageId", p.packageId),
    ("lockIdentity", p.lockIdentity)]))

proc encodeTarball(p: InterfaceTarballProvisioning): string =
  result.putStr("tarball")
  result.add(encodeFields(@[
    ("packageName", p.packageName),
    ("contributor", p.contributor),
    ("url", p.url),
    ("sha256", p.sha256),
    ("archiveType", p.archiveType),
    ("executablePath", p.executablePath),
    ("executableAlias", p.executableAlias),
    ("stripComponents", $p.stripComponents),
    ("packageId", p.packageId),
    ("lockIdentity", p.lockIdentity),
    ("cpu", p.cpu),
    ("os", p.os)]))
  result.putStrSet(p.mirrors)
  result.putStrSet(p.prunePaths)

proc encodeScoop(p: InterfaceScoopProvisioning): string =
  result.putStr("scoop")
  result.add(encodeFields(@[
    ("packageName", p.packageName),
    ("contributor", p.contributor),
    ("bucket", p.bucket),
    ("app", p.app),
    ("version", p.version),
    ("preferredVersion", p.preferredVersion),
    ("manifestChecksum", p.manifestChecksum),
    ("manifestUrl", p.manifestUrl),
    ("executablePath", p.executablePath),
    ("requiresExecutionProfileChecksum",
      if p.requiresExecutionProfileChecksum: "1" else: "0"),
    ("packageId", p.packageId),
    ("lockIdentity", p.lockIdentity)]))

proc encodeFromSource(p: FromSourceRealization): string =
  result.putStr("from-source")
  result.add(encodeFields(@[
    ("packageName", p.packageName),
    ("contributor", p.contributor),
    ("recipePath", p.recipePath.replace('\\', '/')),
    ("recipeDigest", p.recipeDigest.toLowerAscii()),
    ("packageId", p.packageId),
    ("lockIdentity", p.lockIdentity)]))
  result.add(encodeFields(p.recipeInputs))

# ---------------------------------------------------------------------------
# The base case
# ---------------------------------------------------------------------------

proc leafContributionIdentityHex*(dep: ContributionDependencyRef): string =
  ## The dependency BASE CASE: a real 64-hex BLAKE3 identity over the
  ## declared coordinate alone. See the module docstring — this is what
  ## lets a dependency instance be identified WITHOUT building it, and
  ## therefore what keeps the composer out of the pending-marker circle.
  ##
  ## It binds the declared coordinate, NOT the dependency's realized
  ## output: two catalogs differing only in an unresolved dependency's
  ## realization metadata land on the same leaf. Supplying a
  ## ``ContributionResolver`` binds that difference.
  var payload = ContributionLeafMagic
  payload.putStr(dep.targetPackage)
  payload.putStr(dep.contributor)
  payload.putStr(normalizedFingerprint(dep.targetInterfaceFingerprint))
  hexOfDigest(payload)

proc dependencyKey(targetPackage, contributor: string): string =
  targetPackage & "\0" & contributor

# ---------------------------------------------------------------------------
# The composer
# ---------------------------------------------------------------------------

proc composeContribution(identity: ContributionIdentity;
                         resolver: ContributionResolver;
                         visited: var seq[string];
                         depth: int): ContributionFingerprint =
  let c = identity.contribution
  var refusals: seq[string] = @[]

  if c.contributor.strip().len == 0:
    refusals.add("contributor id")
  if c.targetPackage.strip().len == 0:
    refusals.add("target package name")
  if c.developInterface:
    # A develop-bound contribution resolves against whatever interface the
    # active checkout happens to have. The spec forbids it in a committed
    # lock or a published catalog snapshot, so it has no stable identity
    # to fingerprint.
    refusals.add("published target interface fingerprint " &
      "(contribution binds developInterface)")
  let targetFingerprint = normalizedFingerprint(c.targetInterfaceFingerprint)
  if not isHex(targetFingerprint, 64):
    refusals.add("target interface fingerprint")
  if identity.providerIdentity.strip().len == 0:
    refusals.add("provider identity")

  var realizations: seq[string] = @[]

  for p in c.nixProvisioning:
    if p.selector.strip().len == 0 and p.expressionFile.strip().len == 0:
      refusals.add("nix realization: selector")
    if p.nixpkgsRev.strip().len == 0:
      refusals.add("nix realization " & p.selector & ": nixpkgsRev")
    if not isDigestField(p.nixpkgsNarHash.strip()):
      refusals.add("nix realization " & p.selector & ": nixpkgsNarHash")
    realizations.add(encodeNix(p))

  for p in c.tarballProvisioning:
    if p.url.strip().len == 0:
      refusals.add("tarball realization: url")
    if not isDigestField(p.sha256.strip()):
      refusals.add("tarball realization " & p.url & ": sha256")
    realizations.add(encodeTarball(p))

  for p in c.scoopProvisioning:
    if p.bucket.strip().len == 0:
      refusals.add("scoop realization: bucket")
    if p.app.strip().len == 0:
      refusals.add("scoop realization: app")
    if not isDigestField(p.manifestChecksum.strip()):
      refusals.add("scoop realization " & p.bucket & "/" & p.app &
        ": manifestChecksum")
    realizations.add(encodeScoop(p))

  for p in identity.fromSourceProvisioning:
    if p.recipePath.strip().len == 0:
      refusals.add("from-source realization: recipePath")
    if not isHex(p.recipeDigest.strip(), 64):
      refusals.add("from-source realization " & p.recipePath &
        ": recipeDigest")
    realizations.add(encodeFromSource(p))

  if realizations.len == 0:
    refusals.add("realization metadata (no nix, tarball, scoop or " &
      "from-source realization is declared)")

  # Dependencies. ``visited`` carries THIS contribution's coordinate for
  # the duration of the loop, so a dependency that points back at it is a
  # cycle and folds in as its leaf.
  var depHexes: seq[string] = @[]
  let myKey = dependencyKey(c.targetPackage, c.contributor)
  visited.add(myKey)
  for dep in identity.dependencies:
    if dep.targetPackage.strip().len == 0:
      refusals.add("dependency coordinate: target package name")
      continue
    if dep.contributor.strip().len == 0:
      refusals.add("dependency " & dep.targetPackage & ": contributor id")
      continue
    if not isHex(normalizedFingerprint(dep.targetInterfaceFingerprint), 64):
      refusals.add("dependency " & dep.targetPackage &
        ": target interface fingerprint")
      continue
    let depKey = dependencyKey(dep.targetPackage, dep.contributor)
    if depKey in visited:
      # Cycle: fold the leaf in and do NOT recurse. Mirrors
      # ``foreignPackageIdentityRec``'s visited handling.
      depHexes.add(leafContributionIdentityHex(dep))
      continue
    if depth >= MaxContributionDepth:
      refusals.add("dependency " & dep.targetPackage &
        ": contribution dependency depth exceeds " & $MaxContributionDepth)
      continue
    let resolved =
      if resolver.isNil: none(ContributionIdentity) else: resolver(dep)
    if resolved.isNone:
      depHexes.add(leafContributionIdentityHex(dep))
      continue
    let sub = composeContribution(resolved.get, resolver, visited, depth + 1)
    if sub.isResolved:
      depHexes.add(sub.hex)
    else:
      # Fail closed: a resolved dependency that cannot be fingerprinted is
      # missing evidence, not an invitation to fall back to its leaf.
      for r in sub.refusals:
        refusals.add("dependency " & dep.targetPackage & ": " & r)
  if visited.len > 0:
    visited.setLen(visited.len - 1)

  if refusals.len > 0:
    refusals.sort(cmp)
    result.refusals = refusals.deduplicate(isSorted = true)
    result.hex = ""
    return

  var payload = ContributionFingerprintMagic
  payload.putStr(c.contributor)
  payload.putStr(c.targetPackage)
  payload.putStr(targetFingerprint)
  payload.putStr(identity.providerIdentity)
  realizations.sort(cmp)
  payload.putU32Le(uint32(realizations.len))
  for blob in realizations:
    payload.putStr(blob)
  depHexes.sort(cmp)
  depHexes = depHexes.deduplicate(isSorted = true)
  payload.putU32Le(uint32(depHexes.len))
  for hex in depHexes:
    payload.putStr(hex)

  result.hex = hexOfDigest(payload)
  result.refusals = @[]

proc contributionFingerprint*(identity: ContributionIdentity;
                              resolver: ContributionResolver =
                                noContributionResolver):
    ContributionFingerprint =
  ## THE contribution fingerprint. See the module docstring for the
  ## inputs, the canonicalisation, the base case and the refusal rules.
  ##
  ## Never raises: an incomplete contribution comes back with an empty
  ## ``hex`` and a sorted, de-duplicated ``refusals`` list naming exactly
  ## what was missing.
  var visited: seq[string] = @[]
  composeContribution(identity, resolver, visited, 0)
