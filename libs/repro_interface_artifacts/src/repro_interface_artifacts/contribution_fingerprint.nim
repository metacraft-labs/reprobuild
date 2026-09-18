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
## ## What "unresolved" means, and why it is visible
##
## A dependency the resolver does not bind is NOT an error: its leaf
## identity is complete in declaration space, so composition continues
## and a usable hex comes out. But that hex binds the dependency's
## declared COORDINATE and nothing else, so two catalogs differing only
## in that dependency's realization metadata land on the same value.
##
## That is a property of declaration space and this module does not
## pretend to fix it. What it does is refuse to let the difference be
## invisible, and it does so in the two places where invisibility was
## measured:
##
##   1. ``contributionFingerprint`` has NO default resolver. The obvious
##      call used to be the aliasing one -- ``noContributionResolver``
##      was the default argument, so a caller reached the
##      coordinate-only path without naming it or knowing it existed.
##      The resolver is now a required parameter: composing in
##      declaration space only is a legitimate choice that has to be
##      spelled at the call site, where review can see it. A compile
##      error is a better gate than a runtime refusal here precisely
##      because there is no third behaviour to fall back on.
##   2. The result carries ``unresolvedDependencies`` -- every
##      coordinate in the closure that folded in as a leaf, sorted,
##      de-duplicated and accumulated TRANSITIVELY, because a
##      leaf-padded child makes its parent leaf-padded too.
##      ``isResolved`` answers "is there a usable hex" and was true
##      either way; ``dependenciesFullyResolved`` is the predicate a
##      lock writer must gate on.
##
## A contribution that declares NO dependencies is fully bound and is
## not penalised: an empty dependency set is complete evidence -- the
## same distinction ``source_cache_identity`` draws with
## ``optionsSolved`` / ``dependenciesResolved`` / ``searchRootsKnown``,
## whose precedent this follows.
##
## ## Cycles
##
## ``visited`` is a stack of ``<target package>\0<contributor>`` keys.
## A dependency already on the stack is a cycle and is folded in as the
## LEAF identity instead of being recursed into, exactly as
## ``foreignPackageIdentityRec`` does; the stack is popped after each
## contribution's dependency loop so sibling branches see a clean trail.
## A cycle-broken edge is reported in ``unresolvedDependencies`` for the
## same reason an unbindable one is: at that edge the payload carries a
## coordinate and nothing else.
## A ``MaxContributionDepth`` guard additionally bounds a resolver that
## manufactures unboundedly many distinct coordinates (which ``visited``
## alone cannot catch), and it REFUSES rather than truncating.
##
## ## Memoisation, and what makes it sound
##
## ``MaxContributionDepth`` bounds DEPTH, not WORK. Without a memo a
## two-edge-per-level diamond re-composed every shared sub-graph once
## per path: measured on this tree, 428 ms at depth 12, 6.9 s at 16,
## 27.7 s at 18 and 112.7 s at 20 -- doubling per level, so a legal
## 40-level graph did not terminate in practice and the depth bound was
## a promise the composer could not keep. The same graphs now compose in
## about a millisecond, on the same hexes to the byte.
##
## The memo is per CALL and is keyed on the full dependency coordinate
## (package, contributor, normalised target interface fingerprint) --
## the thing the resolver is a function of, and deliberately not the
## 2-part ``visited`` key, which two dependencies pinned to different
## interface revisions share.
##
## Two conditions make reuse sound, and dropping either one is a false
## accept rather than a slowdown:
##
##   * a sub-graph whose value depended on the TRAVERSAL CONTEXT rather
##     than on the graph -- some edge inside it folded a leaf because
##     the coordinate was already on ``visited``, or refused on the
##     depth bound -- is never stored. See
##     ``ComposeOutcome.contextDependent`` for why propagating that one
##     flag upward covers every sub-graph that could disagree. Dropping
##     it makes the fingerprint depend on the order the root declared
##     its dependencies in, which the canonical encoding exists to
##     prevent;
##   * a stored sub-graph records the deepest RELATIVE OFFSET at which
##     some node inside it still OWNS a surviving dependency edge, and
##     is reused only where that node would still be allowed to own one
##     at the new position: ``depth + 1 + edgeDepth <
##     MaxContributionDepth``. Dropping the condition serves a sub-graph
##     memoised near the root to a call site near the bound and silently
##     skips the refusal it owes there.
##
##     The quantity is edge OWNERSHIP and not recursion HEIGHT, and the
##     difference was a measured false accept rather than a refinement.
##     The depth check runs per EDGE and BEFORE the resolver is
##     consulted, so a node whose dependency the resolver answers
##     ``none`` for still owes the check — while recursing through
##     nothing, and so adding nothing to a height. A height-keyed guard
##     therefore admitted, at exactly ``depth + 1 + height ==
##     MaxContributionDepth``, a sub-graph a fresh composition REFUSES,
##     and the verdict flipped with the order the root declared its two
##     dependencies in. Conversely a sub-graph whose deepest node
##     declares no dependencies at all owes no check there and is legal
##     one level below any height bound, so keying on the height would
##     also have stopped reusing it. ``edgeDepth`` is exact in both
##     directions: it is ``-1`` for a sub-graph with no surviving edge
##     anywhere, which is then always reusable.
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
##   * contributor id and target package name;
##   * a provider identity that is 64 hex characters after
##     normalisation. It is a CONTENT identity of the provider
##     implementation -- the same class of value as the target interface
##     fingerprint, and held to the same contract, which it was not
##     before: a placeholder satisfied "required, non-empty" and still
##     produced a hex. A value carrying ``repro.identity.pending`` is
##     refused under that name, because "not computed yet" is a
##     different diagnosis from "malformed";
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
## An UNRESOLVED dependency is not on that list and is not a refusal --
## see "What 'unresolved' means" above. It is a marked, usable identity,
## and marking it is what keeps the two states apart.
##
## ## What this module does NOT do
##
## It does not serialize anything into a lock (M7 deliverable 2, which
## needs M6's catalog coordinates and revision), and it does not select a
## contribution (deliverable 3). It computes an identity; storing and
## choosing are other deliverables.

import std/[algorithm, options, sequtils, strutils, tables]

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

  PendingContributionIdentityMarker* = "repro.identity.pending"
    ## The marker this codebase stamps on an identity that has NOT been
    ## computed yet — ``cache_key.PendingCacheIdentityOptionKey``, spelled
    ## here as a literal because ``repro_interface_artifacts`` does not
    ## depend on ``repro_binary_cache_client`` and must not grow the
    ## dependency for one string. A ``providerIdentity`` carrying it is
    ## refused BY NAME rather than merely as a malformed digest: "not
    ## computed yet" and "malformed" are different diagnoses, and a lock
    ## writer needs to tell them apart.

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
    ##
    ## ``unresolvedDependencies`` is the SECOND axis, and it is not a
    ## refusal: a leaf-folded dependency yields a perfectly well-formed
    ## identity in declaration space. It is the record of which
    ## dependencies that identity binds only by COORDINATE, so a consumer
    ## can tell a fully-bound fingerprint from a leaf-padded one — see
    ## ``dependenciesFullyResolved``.
    hex*: string
    refusals*: seq[string]
    unresolvedDependencies*: seq[ContributionDependencyRef]
      ## Every dependency coordinate in this fingerprint's closure that
      ## folded in as a coordinate-only LEAF rather than as a composed
      ## sub-fingerprint — because the resolver returned ``none``, or
      ## because the edge closed a cycle. Sorted by coordinate and
      ## de-duplicated, and accumulated transitively: a leaf-padded
      ## dependency two levels down makes the root leaf-padded too,
      ## because the root's payload contains that child's hex.
      ##
      ## Empty on a contribution that declares no dependencies at all:
      ## an empty dependency set is complete evidence, not missing
      ## evidence. Same distinction ``source_cache_identity`` draws with
      ## ``dependenciesResolved``.

  ContributionResolver* = proc (dep: ContributionDependencyRef):
    Option[ContributionIdentity] {.gcsafe.}
    ## Caller-supplied map from a declared dependency coordinate to that
    ## dependency's own contribution identity. Returning ``none`` is not
    ## an error: the composer then folds in the dependency's LEAF
    ## identity, which is complete in declaration space, and records the
    ## coordinate in ``unresolvedDependencies``. Mirrors
    ## ``foreign_common.ForeignDepResolver``.
    ##
    ## Assumed to be a FUNCTION of the coordinate for the duration of one
    ## ``contributionFingerprint`` call: the composer memoises on the
    ## coordinate, so a resolver that answers differently for the same
    ## coordinate within one call gets whichever answer was asked for
    ## first. (Between calls it may answer differently; the memo is
    ## per-call.)

proc noContributionResolver*(dep: ContributionDependencyRef):
    Option[ContributionIdentity] {.gcsafe.} =
  ## The EXPLICIT leaf-only resolver: every dependency folds in as its
  ## declared coordinate.
  ##
  ## This is no longer a default argument of ``contributionFingerprint``,
  ## and that is deliberate. As a default it made the obvious call —
  ## ``contributionFingerprint(identity)`` — the aliasing path: two
  ## catalogs differing only in a dependency's realization metadata
  ## fingerprinted identically, and nothing in the call said so. A
  ## caller that genuinely wants declaration-space-only composition names
  ## this proc, and the name is then visible at the call site and in
  ## review.
  none(ContributionIdentity)

proc isResolved*(fp: ContributionFingerprint): bool =
  ## True iff a usable 64-hex fingerprint was produced.
  ##
  ## It says NOTHING about whether the dependency closure was bound: a
  ## fingerprint every one of whose dependencies folded in as a leaf is
  ## still a resolved fingerprint. ``dependenciesFullyResolved`` is the
  ## question a lock writer has to ask.
  fp.refusals.len == 0 and fp.hex.len == 64

proc dependenciesFullyResolved*(fp: ContributionFingerprint): bool =
  ## True iff a usable fingerprint was produced AND every dependency in
  ## its closure was bound through the resolver rather than folded in as
  ## a coordinate-only leaf.
  ##
  ## This is the predicate M7 deliverable 2 must gate lock serialization
  ## on. ``isResolved`` alone is not it: an unresolved dependency binds
  ## only its declared coordinate, so two catalogs differing only in that
  ## dependency's realization metadata still land on the same hex.
  fp.isResolved and fp.unresolvedDependencies.len == 0

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

proc contributionCoordinate*(dep: ContributionDependencyRef): string =
  ## The stable spelling of a declared dependency coordinate — the tuple
  ## the leaf identity binds — for diagnostics, de-duplication and
  ## ordering. Not a digest, and not an input of any payload.
  dep.targetPackage & "@" & dep.contributor & "#" &
    normalizedFingerprint(dep.targetInterfaceFingerprint)

proc isHex(value: string; width: int): bool =
  if value.len != width:
    return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  true

proc isPendingIdentity*(value: string): bool =
  ## True when ``value`` carries the codebase's "identity not computed
  ## yet" stamp. Matched case-insensitively and as a SUBSTRING, because
  ## the marker is used both bare and as ``<marker>:<detail>``, and
  ## because a value that merely mentions it is not a content identity
  ## either. Over-matching here costs a false refusal, which is the safe
  ## direction.
  value.toLowerAscii().contains(PendingContributionIdentityMarker)

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
  ## ``ContributionResolver`` binds that difference; every coordinate
  ## that folds in here instead is reported in
  ## ``ContributionFingerprint.unresolvedDependencies``, so the alias is
  ## detectable rather than silent.
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

type
  ComposeOutcome = object
    ## What one ``composeContribution`` call produced, plus the two facts
    ## the MEMO needs and the public result does not carry.
    fp: ContributionFingerprint
    edgeDepth: int
      ## The deepest offset, RELATIVE to this sub-graph's own node, at
      ## which some node still owns a surviving dependency edge — an
      ## edge that passed coordinate validation and therefore reached
      ## the depth check. ``0`` when this node itself owns one and
      ## nothing below it is deeper; ``-1`` when no node in the
      ## sub-graph owns one at all.
      ##
      ## This, and not the recursion height, is what the depth bound is
      ## about. A node at depth ``d`` may own an edge iff
      ## ``d < MaxContributionDepth``; nothing else about a node is
      ## depth-checked. So a sub-graph computed at depth ``d`` composes
      ## identically at depth ``d2`` iff
      ## ``d2 + edgeDepth < MaxContributionDepth``, which makes the memo
      ## guard exact in both directions:
      ##
      ##   * an edge the resolver answers ``none`` for recurses through
      ##     nothing, so it raises no height — but it is still an edge
      ##     its owner is checked for. Keying on the height admitted
      ##     such a sub-graph one level past the bound, which is a hex
      ##     where a fresh composition refuses. That is a false accept,
      ##     the one failure this module may not have, and it was
      ##     observable as the fingerprint depending on the order the
      ##     root declared its dependencies in;
      ##   * a node that declares NO dependencies owes no check, so a
      ##     sub-graph ending in one is legal a level deeper than its
      ##     height suggests. Keying on the height would have stopped
      ##     reusing it for nothing.
    contextDependent: bool
      ## True when this sub-graph's VALUE depended on the traversal
      ## context rather than on the graph alone: some edge inside it
      ## folded a leaf because the coordinate was already on the
      ## ``visited`` stack, or refused because the depth bound was
      ## reached. Such a value is correct where it was computed and
      ## WRONG anywhere else, so it is never memoised.
      ##
      ## Why propagating this one flag upward is sufficient. Suppose a
      ## memoised sub-graph ``S`` were reused on a path ``P2`` and
      ## disagreed with a fresh composition there. The disagreement must
      ## come from an edge ``u -> v`` inside ``S`` where ``v`` is an
      ## ancestor on ``P2`` but was not on the stack when ``S`` was
      ## computed on ``P1``. Then ``v`` reaches ``u`` (through ``P2``:
      ## ``v`` -> ... -> ``S`` -> ... -> ``u``) and ``u`` reaches ``v``,
      ## so the graph has a cycle through ``u`` and ``v``. On ``P1`` that
      ## same cycle was walked from ``u`` into ``v`` and onward, and
      ## whatever it closed on was already on ``P1``'s stack — a
      ## ``visited`` hit, which sets this flag and stops ``S`` being
      ## memoised at all. So every sub-graph that could disagree is
      ## exactly a sub-graph this flag excludes.

  ContributionMemo = Table[string, ComposeOutcome]
    ## Per-CALL memo, keyed on the full dependency coordinate the
    ## resolver is a function of (package, contributor, normalised target
    ## interface fingerprint) — never on the 2-part ``visited`` key,
    ## which two dependencies pinned to different interface revisions
    ## share.
    ##
    ## Per-call and not global: a resolver may legitimately answer
    ## differently between calls (a catalog is edited, a different
    ## snapshot is selected), and a process-lifetime cache would serve
    ## the first call's graph forever.

proc composeContribution(identity: ContributionIdentity;
                         resolver: ContributionResolver;
                         visited: var seq[string];
                         memo: var ContributionMemo;
                         depth: int): ComposeOutcome =
  let c = identity.contribution
  var refusals: seq[string] = @[]
  var edgeDepth = -1
  var contextDependent = false

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
  # The provider identity is a CONTENT identity of the provider
  # implementation — the same class of value as the target interface
  # fingerprint directly above, and held to the same shape contract. A
  # required input with no shape check is a required input a placeholder
  # satisfies.
  let providerIdentity = normalizedFingerprint(identity.providerIdentity)
  if identity.providerIdentity.strip().len == 0:
    refusals.add("provider identity")
  elif isPendingIdentity(identity.providerIdentity):
    refusals.add("provider identity (stamped " &
      PendingContributionIdentityMarker & ": the provider's content " &
      "identity has not been computed yet)")
  elif not isHex(providerIdentity, 64):
    refusals.add("provider identity (not a 64-hex content identity)")

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
  var unresolved: seq[ContributionDependencyRef] = @[]
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
      #
      # Recorded as UNBOUND for the same reason an unresolvable
      # dependency is: at this edge the payload carries the coordinate
      # and nothing else. The cycle member's own realization metadata is
      # bound at the level that is composing it, but a caller holding
      # only this fingerprint cannot know that, and deliverable 2 must
      # treat both shapes alike.
      depHexes.add(leafContributionIdentityHex(dep))
      unresolved.add(dep)
      contextDependent = true
      continue
    # From here the edge SURVIVES: it is a real dependency edge this node
    # owns, and owning one is precisely what the depth bound checks. It
    # counts towards ``edgeDepth`` whether or not the resolver goes on to
    # bind it — the check below runs first, and a leaf-folded edge is
    # checked exactly like a recursed one.
    edgeDepth = max(edgeDepth, 0)
    if depth >= MaxContributionDepth:
      refusals.add("dependency " & dep.targetPackage &
        ": contribution dependency depth exceeds " & $MaxContributionDepth)
      contextDependent = true
      continue

    # Fold one composed dependency into this contribution.
    template absorb(subFp: ContributionFingerprint) =
      if subFp.isResolved:
        depHexes.add(subFp.hex)
        # Transitive: the root's payload contains this child's hex, so a
        # coordinate the CHILD bound only as a leaf is one the root binds
        # only as a leaf too.
        for u in subFp.unresolvedDependencies:
          unresolved.add(u)
      else:
        # Fail closed: a resolved dependency that cannot be fingerprinted
        # is missing evidence, not an invitation to fall back to its leaf.
        for r in subFp.refusals:
          refusals.add("dependency " & dep.targetPackage & ": " & r)

    let memoKey = contributionCoordinate(dep)
    var served = false
    if memoKey in memo:
      let cached = memo[memoKey]
      # Reuse only where the bound still holds AT THIS DEPTH: the
      # deepest edge-owning node inside the cached sub-graph sits
      # ``cached.edgeDepth`` levels below the child node, which is at
      # ``depth + 1``, and a node may own an edge only strictly inside
      # ``MaxContributionDepth``. ``cached.edgeDepth == -1`` (no
      # surviving edge anywhere in the sub-graph) makes this the
      # tautology ``depth < MaxContributionDepth``, already guaranteed
      # above — such a sub-graph is depth-independent and always
      # reusable.
      if depth + 1 + cached.edgeDepth < MaxContributionDepth:
        edgeDepth = max(edgeDepth, 1 + cached.edgeDepth)
        absorb(cached.fp)
        served = true
    if not served:
      let resolved =
        if resolver.isNil: none(ContributionIdentity) else: resolver(dep)
      if resolved.isNone:
        # Declaration space is complete here, so this is not a refusal —
        # but the payload now binds this dependency's COORDINATE only,
        # and that fact travels with the result.
        depHexes.add(leafContributionIdentityHex(dep))
        unresolved.add(dep)
        continue
      let sub = composeContribution(resolved.get, resolver, visited, memo,
        depth + 1)
      edgeDepth = max(edgeDepth, 1 + sub.edgeDepth)
      if sub.contextDependent:
        contextDependent = true
      else:
        memo[memoKey] = sub
      absorb(sub.fp)
  if visited.len > 0:
    visited.setLen(visited.len - 1)

  # Canonical order for the unbound set: sorted by coordinate and
  # de-duplicated, so the report is a function of the graph rather than
  # of the traversal order that discovered it.
  var unboundKeyed: seq[(string, ContributionDependencyRef)] = @[]
  for dep in unresolved:
    unboundKeyed.add((contributionCoordinate(dep), dep))
  unboundKeyed.sort(proc (a, b: (string, ContributionDependencyRef)): int =
    cmp(a[0], b[0]))
  var unbound: seq[ContributionDependencyRef] = @[]
  var lastKey = ""
  for i, entry in unboundKeyed:
    if i > 0 and entry[0] == lastKey:
      continue
    lastKey = entry[0]
    unbound.add(entry[1])
  result.edgeDepth = edgeDepth
  result.contextDependent = contextDependent
  result.fp.unresolvedDependencies = unbound

  if refusals.len > 0:
    refusals.sort(cmp)
    result.fp.refusals = refusals.deduplicate(isSorted = true)
    result.fp.hex = ""
    return

  var payload = ContributionFingerprintMagic
  payload.putStr(c.contributor)
  payload.putStr(c.targetPackage)
  payload.putStr(targetFingerprint)
  payload.putStr(providerIdentity)
  realizations.sort(cmp)
  payload.putU32Le(uint32(realizations.len))
  for blob in realizations:
    payload.putStr(blob)
  depHexes.sort(cmp)
  depHexes = depHexes.deduplicate(isSorted = true)
  payload.putU32Le(uint32(depHexes.len))
  for hex in depHexes:
    payload.putStr(hex)

  result.fp.hex = hexOfDigest(payload)
  result.fp.refusals = @[]

proc contributionFingerprint*(identity: ContributionIdentity;
                              resolver: ContributionResolver):
    ContributionFingerprint =
  ## THE contribution fingerprint. See the module docstring for the
  ## inputs, the canonicalisation, the base case and the refusal rules.
  ##
  ## ``resolver`` is REQUIRED and has no default. Pass
  ## ``noContributionResolver`` to compose in declaration space only,
  ## which is a legitimate choice with a documented consequence —
  ## see that proc, and ``dependenciesFullyResolved``.
  ##
  ## Never raises: an incomplete contribution comes back with an empty
  ## ``hex`` and a sorted, de-duplicated ``refusals`` list naming exactly
  ## what was missing.
  var visited: seq[string] = @[]
  var memo: ContributionMemo = initTable[string, ComposeOutcome]()
  composeContribution(identity, resolver, visited, memo, 0).fp
