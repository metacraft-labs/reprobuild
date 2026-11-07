## Lock-selected provisioning on the CLI build path -- ReproOS-Campaign-
## Completion M7 deliverable 3, wired into ``repro_cli_support``.
##
## Normatively: ``reprobuild-specs/Provisioning-Contributions.md``
## § Resolution and § Locks And Snapshots.
##
## ## What this does
##
## ``lockSelectedProvisioningPins`` is the ONE place the CLI turns a
## committed ``repro.lock``'s ``provisioning`` records into the
## ``ProvisioningPin``s ``repro_tool_profiles.toolBuildIdentity`` provisions
## from:
##
##   1. read the lock the build is governed by (the caller names it: the
##      ``--lock`` binding for ``default``, else ``<project>/repro.lock``)
##      with the STRICT reader (``repro_lock.parseLockedDependencies``);
##   2. take its claims (``lockedProvisioningClaims``);
##   3. obtain the explicitly identified catalog imports, the offered
##      contributions' full identities and the curator policy from the
##      installed ``ProvisioningCatalogSource``;
##   4. run THE resolver, ``contribution_selection
##      .resolveProvisioningSelections``, and hand back ``pinsOf`` its
##      resolution.
##
## ## When nothing changes
##
## No lock file, or a lock with no ``provisioning`` record for the host /
## target platform pair being built: ``@[]`` -- exactly the unpinned
## behaviour the build had before this module existed (a unique eligible
## contributor, or the planners' ambiguity refusal). No catalog source is
## consulted, no resolver runs, and the callers' cache keys are byte-for-byte
## what they were. (A lock whose records all name OTHER platform pairs says
## so on stderr: per-platform records are the lock's semantics, so it is not
## refused, but it is not silently the same as "no lock" either.) "No lock
## file" means the implicit ``<project>/repro.lock``: a lock NAMED for the
## build (``--lock``, or a declared ``path =``) that is missing, or is not a
## file, refuses. A lock the strict reader cannot parse is treated like no
## lock UNLESS it names the ``provisioning`` key: this reader never gated a
## build before, and the build path's own reader
## (``resolveSolvedGraphForBuild``) and ``repro lock validate`` keep
## diagnosing a malformed lock; but records that exist and cannot be read
## are refused, never silently dropped -- and so is a lock file that exists
## and cannot be opened, and a lock that spells the key in any form the
## strict reader skips (``lockHasUnreadProvisioningSpelling``), in any letter
## case, even beside a line it does read.
##
## ## Refusals
##
## Every refusal raises ``ProvisioningSelectionRefused`` carrying the
## resolver's own messages, and nothing falls back to unpinned selection:
##
##   * the resolver refuses (``locked-contribution-unavailable``,
##     ``contribution-changed``, ``interface-changed``, ``catalog-changed``,
##     ``realization-changed``, ``policy-contradicts-lock``, ambiguity, ...);
##   * the lock has records for this platform pair but no catalog source is
##     installed (``setProvisioningCatalogSource(nil)``). Before ReproOS M6
##     deliverables 1 and 2 this was the production state; it still refuses,
##     with the same message;
##   * the PRODUCTION catalog source (``productionProvisioningCatalogSource``,
##     installed by default: ``catalog_discovery``) cannot supply the
##     catalogs -- the project declares none (no ``repro-catalogs.toml``), an
##     import has no lock pin or one that disagrees with the declaration, or
##     a catalog cannot be read at its pinned identity. It never falls back
##     to a sibling checkout, another revision or an unpinned selection;
##   * the lock's ``provisioning`` records cannot be read, or some line
##     names the key in a spelling the strict reader skips, in any letter
##     case (even beside a line it does read);
##   * a lock NAMED for the build is missing or not a file, or the lock file
##     exists and cannot be opened.
##
## ## Why a refusal happened, and re-selection (M7 deliverable 5)
##
## A resolver refusal also carries "what changed since the lock was
## written": ``provisioning_lock_diff.explainLockMismatch`` compares each
## locked record for this platform pair with what the composed catalogs now
## offer for the same contributor -- field by field when the catalog source
## supplies the locked contribution's identity as evidence
## (``ProvisioningCatalogInputs.previous``, used only if it reproduces the
## locked fingerprint), else saying the cause is not determinable from the
## records -- followed by the exact re-select command
## (``provisioningReselectCommand``).
##
## ``repro lock refresh`` never re-selects: it carries the records forward
## (``repro_lock.withProvisioningCarriedForward``). Re-selection is the
## explicit ``repro lock refresh --provisioning``
## (``reselectCommittedProvisioning``): resolve WITHOUT the lock's own
## claims, lock every selection through the lock writer, carry other
## platform pairs, print the diff, and write nothing on any refusal --
## including when no catalog source is installed, or the production one
## finds no declaration (``repro-catalogs.toml``) or cannot read a declared
## catalog. Re-selection also re-pins every declared catalog import
## (``catalog_imports``; ReproOS M6 D1) and reports how the pins moved.
## ``repro lock diff`` (``diffProvisioningLockDocuments``) is the
## same diff over two lock files; an unreadable lock refuses it, never
## reads as "no change".
##
## ## Trust boundary
##
## A ``ProvisioningPin`` is trusted input to the engine (see its doc
## comment). This module keeps that sound: the pins it returns are produced
## HERE, by ``pinOf`` over a resolution made in this call, from the lock
## file as it is on disk now -- every call re-reads the lock and re-runs the
## resolver. Nothing in this module or its callers persists, caches or
## transmits a pin. The CLI's tool-identity cache key binds the pins' fields
## (``repro_cli_support.toolIdentityCacheKey``), but only through a digest:
## a cache entry is looked up with a key recomputed from freshly resolved
## pins, and no cached key, identity or lock identity string is ever turned
## back into a pin.

import std/[algorithm, os, sequtils, strutils]

import repro_core
import repro_interface_artifacts
import repro_interface_artifacts/catalog_composition
import repro_interface_artifacts/contribution_fingerprint
import repro_interface_artifacts/contribution_selection
import repro_interface_artifacts/provisioning_lock_diff
import repro_lock

import ./catalog_diagnostics
import ./catalog_discovery

export catalog_composition.CatalogImport, catalog_composition.CatalogSelectionPolicy
export contribution_fingerprint.ContributionIdentity,
  contribution_fingerprint.ContributionResolver
export provisioning_lock_diff
export catalog_discovery
export catalog_diagnostics

type
  ProvisioningSelectionRefused* = object of ValueError
    ## The build's provisioning selection could not be made from the
    ## committed lock. The message is the resolver's (or names the missing
    ## input); the build must fail with it.

  ProvisioningCatalogPurpose* = enum
    pcpBuild = "build"
      ## A build (or inspection / develop session) verifying the committed
      ## lock; ``artifact`` is the consumer's interface artifact.
    pcpLockReselect = "lock-reselect"
      ## ``repro lock refresh --provisioning`` re-selecting the lock's
      ## provisioning records. A lock refresh builds and extracts nothing,
      ## so ``artifact`` is EMPTY; the source answers for the project at
      ## ``projectRoot``.

  ProvisioningCatalogRequest* = object
    ## What a ``ProvisioningCatalogSource`` is asked for.
    projectRoot*: string
    lockPath*: string
    artifact*: ProjectInterfaceArtifact
    hostPlatform*: string
    targetPlatform*: string
    purpose*: ProvisioningCatalogPurpose
    catalogImportPins*: seq[LockedCatalogImport]
      ## The committed lock's catalog import pins (ReproOS M6 D1), strictly
      ## read. A build reads every catalog at the revision pinned here;
      ## re-selection re-pins and ignores them.
    lockClaims*: seq[LockedRealization]
      ## The committed lock's provisioning records, all platform pairs: the
      ## coordinates a source may read diagnostic evidence at.

  ProvisioningCatalogInputs* = object
    ## The resolver inputs a build cannot read out of its own artifact.
    imports*: seq[CatalogImport]
      ## Explicitly identified catalog imports (coordinates + content).
    offered*: seq[ContributionIdentity]
      ## The full identities (provider identity included) of the offered
      ## contributions.
    policy*: CatalogSelectionPolicy
      ## The explicit curator policy (may be empty).
    resolver*: ContributionResolver
      ## Dependency resolver for contribution fingerprints; ``nil`` means
      ## ``noContributionResolver`` (a contribution with dependencies is
      ## then not fully bound and the resolver refuses it).
    previous*: seq[ContributionIdentity]
      ## OPTIONAL diagnostic evidence: full identities of contributions as
      ## they were at the LOCKED catalog revisions, when the source can
      ## supply them. Used only to explain a changed contribution field by
      ## field (``provisioning_lock_diff``), and only after its fingerprint
      ## is recomputed and found EQUAL to the locked one. Never selects
      ## anything.
    catalogImportPins*: seq[LockedCatalogImport]
      ## The catalog import pins the answer was read at (ReproOS M6 D1).
      ## Re-selection writes them into the lock (and reports how they
      ## moved); a build ignores them. A source that pins nothing leaves the
      ## lock's ``catalog_imports`` key absent, exactly as before it existed.
    declaration*: LocatedCatalogDeclaration
      ## OPTIONAL, diagnostics only (ReproOS M6 D4): the declaration the
      ## catalogs were read for, with the line of every table, so a refusal
      ## can name the table to edit. Empty from a source that reads none.
    evidenceFailures*: seq[CatalogEvidenceFailure]
      ## OPTIONAL, diagnostics only: catalogs that could not be read at a
      ## locked record's own revision for ``previous``, with the cause.

  ProvisioningCatalogSource* = proc (request: ProvisioningCatalogRequest):
    ProvisioningCatalogInputs {.closure.}
    ## Supplies the catalog imports for a lock-governed build. The
    ## production implementation is ``productionProvisioningCatalogSource``
    ## (ReproOS M6 deliverables 1 and 2), installed by default.

const ProvisioningCommittedLockName = "repro.lock"
  ## ``repro_cli_support.CommittedLockFileName``; repeated here because this
  ## module is imported by, and cannot import, that one.

proc provisioningReselectCommand*(projectRoot, lockPath: string): string =
  ## The exact command that re-selects the provisioning records of the lock
  ## at ``lockPath`` for the project at ``projectRoot``: ``repro lock
  ## refresh --provisioning``, naming the project and -- when it is not the
  ## project's own ``repro.lock`` -- the lock.
  result = "repro lock refresh --provisioning"
  if projectRoot.len > 0:
    result.add(" " & quoteShell(projectRoot))
  if lockPath.len > 0 and os.normalizedPath(absolutePath(lockPath)) !=
      os.normalizedPath(absolutePath(projectRoot /
        ProvisioningCommittedLockName)):
    result.add(" --lock " & quoteShell(lockPath))

proc productionProvisioningCatalogSource*(request: ProvisioningCatalogRequest):
    ProvisioningCatalogInputs =
  ## THE production catalog source (``catalog_discovery``): the catalogs the
  ## project declares in ``repro-catalogs.toml``, each read from the
  ## workspace's shared clone of its remote at the revision the committed
  ## lock pins (a build) or at the revision its declared commit or ref names
  ## now (re-selection), every object re-hashed, nothing compiled or run.
  ## Raises ``CatalogDiscoveryError`` naming every cause; the callers turn
  ## that into a refusal.
  let answer =
    case request.purpose
    of pcpBuild:
      catalogsForBuild(request.projectRoot, request.catalogImportPins,
        request.lockClaims, provisioningReselectCommand(request.projectRoot,
          request.lockPath))
    of pcpLockReselect:
      catalogsForReselect(request.projectRoot, request.lockClaims)
  ProvisioningCatalogInputs(imports: answer.imports, offered: answer.offered,
    policy: answer.policy, resolver: answer.resolver,
    previous: answer.previous, catalogImportPins: answer.pins,
    declaration: answer.declaration,
    evidenceFailures: answer.evidenceFailures)

var catalogSource: ProvisioningCatalogSource =
  productionProvisioningCatalogSource

proc setProvisioningCatalogSource*(source: ProvisioningCatalogSource) =
  ## Install (or, with ``nil``, remove) the catalog source every
  ## lock-governed build consults.
  catalogSource = source

proc provisioningCatalogSourceInstalled*(): bool =
  not catalogSource.isNil

proc refuse(message: string) {.noreturn.} =
  raise newException(ProvisioningSelectionRefused,
    "provisioning selection refused: " & message)

proc relevantEvidenceFailures*(changes: seq[ProvisioningRecordChange];
                               records: seq[LockedRealization];
                               failures: seq[CatalogEvidenceFailure]):
    seq[CatalogEvidenceFailure] =
  ## The evidence failures that explain why a change's cause is NOT
  ## determinable (M6 deliverable 4): a failure for the catalog coordinate
  ## (remote, revision) of a record of a change whose cause could not be
  ## determined. A failure for any other record -- another platform pair, an
  ## explained change -- is not printed. Sorted by repo, remote, revision.
  for c in changes:
    if c.causeDeterminable: continue
    for f in failures:
      if f in result: continue
      for r in records:
        if r.packageName == c.packageName and
            r.hostPlatform == c.hostPlatform and
            r.targetPlatform == c.targetPlatform and
            r.catalogRemote == f.remote and r.catalogRevision == f.revision:
          result.add(f)
          break
  result.sort(proc (a, b: CatalogEvidenceFailure): int =
    result = cmp(a.repo, b.repo)
    if result == 0: result = cmp(a.remote, b.remote)
    if result == 0: result = cmp(a.revision, b.revision))

proc lockSelectedProvisioningPins*(artifact: ProjectInterfaceArtifact;
                                   projectRoot, lockPath: string;
                                   lockRequired = false):
    seq[ProvisioningPin] =
  ## The pins for building ``artifact`` under the committed lock at
  ## ``lockPath`` (see the module docstring). ``@[]`` when the lock does not
  ## govern provisioning on this platform pair; raises
  ## ``ProvisioningSelectionRefused`` on every refusal.
  ##
  ## ``lockRequired``: the lock was NAMED (a ``--lock`` binding, or a
  ## declared ``path =``), so a missing file, or a path that is not a file,
  ## is missing evidence and refuses. Unnamed -- the implicit
  ## ``<project>/repro.lock`` -- its absence still means "no lock".
  if not fileExists(extendedPath(lockPath)):
    if lockRequired:
      refuse("the lock named for this build, " & lockPath & ", cannot be " &
        "read: " & (if dirExists(extendedPath(lockPath)): "it is a directory"
                    else: "no such file") & ". A named lock is not treated " &
        "as \"no lock\"; name an existing lock or drop the binding.")
    return @[]
  var text = ""
  try:
    text = readFile(extendedPath(lockPath))
  except CatchableError as err:
    refuse("the committed lock " & lockPath & " exists but cannot be read (" &
      err.msg & "); its `" & ProvisioningLockKey & "` records, if any, are " &
      "not ignored.")
  var lock: LockedDependencies
  try:
    lock = parseLockedDependencies(text)
  except CatchableError as err:
    if not lockDeclaresProvisioning(text):
      return @[]
    refuse("the committed lock " & lockPath & " has `" &
      ProvisioningLockKey & "` records that cannot be read (" & err.msg &
      "); they are not ignored. Restore the `" & ProvisioningLockKey &
      "` line from version control, or delete it and re-select with `" &
      provisioningReselectCommand(projectRoot, lockPath) & "` (a refresh " &
      "does not replace records it cannot read).")
  let host = currentPlatformId()
  let target = host
  let claims = lock.lockedProvisioningClaims()
  if lockHasUnreadProvisioningSpelling(text) or
      (claims.len == 0 and lockDeclaresProvisioning(text)):
    # Some line names the key in a form the strict reader skips. Checked
    # whether or not the reader found records elsewhere: beside a read line
    # the skipped records would otherwise vanish silently. (The writer never
    # emits an empty array and the reader refuses one, so a lock that names
    # the key yet yields no record is the same case.)
    refuse("the committed lock " & lockPath & " names `" &
      ProvisioningLockKey & "` in a form the lock reader does not read (only " &
      "the writer's `" & ProvisioningLockKey & " = [...]` line is read); the " &
      "records are not ignored. Restore the `" & ProvisioningLockKey &
      " = [...]` line from version control, or delete every spelling of " &
      "the key and re-select with `" &
      provisioningReselectCommand(projectRoot, lockPath) & "`.")
  let here = claims.filterIt(it.hostPlatform == host and
    it.targetPlatform == target)
  if here.len == 0:
    if claims.len > 0:
      # Distinguishable from "no lock", and said so: the lock pins
      # provisioning, just not for this platform pair (a lock refreshed on
      # another host, or a record edited to another platform -- which is a
      # lock edit like deleting it). Per-platform records are the lock's
      # semantics, so this is not refused.
      let pairs = claims.mapIt(it.hostPlatform & " -> " & it.targetPlatform).
        sorted(cmp).deduplicate(isSorted = true)
      stderr.writeLine("repro: note: the committed lock " & lockPath &
        " pins provisioning only for " & pairs.join(", ") & "; nothing is " &
        "pinned for " & host & " -> " & target & ", so provisioning on this " &
        "platform is selected unpinned.")
    return @[]
  let packages = here.mapIt("\"" & it.packageName & "\" -> \"" &
    it.contributor & "\"").sorted(cmp).deduplicate(isSorted = true)
  if lockHasUnreadCatalogImportsSpelling(text):
    # M6 D1: catalog import pins under a key spelling the strict reader
    # skips would be invisible, and the catalogs would read as unpinned.
    refuse("the committed lock " & lockPath & " names `" &
      CatalogImportsLockKey & "` in a form the lock reader does not read " &
      "(only the writer's `" & CatalogImportsLockKey & " = [...]` line is " &
      "read); the pins are not ignored. " & CatalogImportsRepairAdvice & ".")
  if catalogSource.isNil:
    refuse("the committed lock " & lockPath & " pins provisioning " &
      "contributions on " & host & " -> " & target & " (" &
      packages.join(", ") & "), and this build has nothing to verify them " &
      "against: explicit cross-repository catalog imports and the offered " &
      "contributions' provider identities (ReproOS M6 deliverables 1 and 2) " &
      "are not supplied to this command. The lock is not ignored, and no " &
      "contribution is selected without verifying it. Remove the lock's `" &
      ProvisioningLockKey & "` records to provision unpinned.")
  var inputs: ProvisioningCatalogInputs
  try:
    inputs = catalogSource(ProvisioningCatalogRequest(
      projectRoot: projectRoot, lockPath: lockPath, artifact: artifact,
      hostPlatform: host, targetPlatform: target,
      catalogImportPins: lock.lockedCatalogImportPins(), lockClaims: claims))
  except CatchableError as err:
    refuse("the catalogs the committed lock " & lockPath &
      " is verified against could not be obtained: " & err.msg)
  var resolver: ContributionResolver = noContributionResolver
  if not inputs.resolver.isNil:
    resolver = inputs.resolver
  let request = ProvisioningResolutionRequest(
    imports: inputs.imports, lockClaims: claims, policy: inputs.policy,
    offered: inputs.offered, hostPlatform: host, targetPlatform: target)
  let resolution = resolveProvisioningSelections(request, resolver)
  if not resolution.resolved:
    # M6 deliverable 4: each refusal the composed catalogs produced is
    # followed by the catalogs and candidates it concerns (repo, remote,
    # revision, published source location, the importing
    # ``repro-catalogs.toml`` line) and the exact edit or command.
    let remedy = CatalogRemedyContext(projectRoot: projectRoot,
      lockPath: lockPath,
      reselectCommand: provisioningReselectCommand(projectRoot, lockPath),
      declaration: inputs.declaration, lockClaims: here)
    var message = "the committed lock " & lockPath & " does not resolve " &
      "against the composed catalogs; the lock is not relaxed to an " &
      "unpinned selection:\n  " & withRemedies(resolution.refusals,
        resolution.diagnostics, remedy, "    ").join("\n  ")
    # M7 deliverable 5: say WHAT changed, with the same diff re-selection
    # prints, and name the one command that re-selects.
    try:
      let explained = explainLockMismatch(request, resolver, inputs.previous)
      if explained.len > 0:
        message.add("\nwhat changed since the lock was written (the locked " &
          "record -> what the composed catalogs offer now):")
        for change in explained:
          for line in renderChange(change):
            message.add("\n  " & line)
        for line in renderEvidenceFailures(relevantEvidenceFailures(
            explained, here, inputs.evidenceFailures)):
          message.add("\n  " & line)
    except CatchableError as err:
      message.add("\n(the change could not be explained: " & err.msg & ")")
    message.add("\nto re-select explicitly (rewrites the lock's " &
      "provisioning records and prints this diff; nothing re-selects " &
      "silently):\n  " & provisioningReselectCommand(projectRoot, lockPath))
    refuse(message)
  resolution.pinsOf()

# ---------------------------------------------------------------------------
# M7 deliverable 5: the diff of two committed locks, and explicit
# re-selection (``repro lock refresh --provisioning``)
# ---------------------------------------------------------------------------

proc provisioningRecordsOf*(text, label: string;
                            records: var seq[LockedRealization]): string =
  ## The ``provisioning`` records of a committed lock document, read for a
  ## DIFF; returns the refusal, or "" when ``records`` holds them all. Every
  ## record must be readable: a document the strict reader cannot parse, or
  ## one that names the key in a spelling the reader skips (in any letter
  ## case), is refused rather than read as having no records.
  records = @[]
  var lock: LockedDependencies
  try:
    lock = parseLockedDependencies(text)
  except CatchableError as err:
    return label & " cannot be read as a committed lock (" & err.msg & ")"
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#") or readsProvisioningLine(line):
      continue
    if namesProvisioningKey(line):
      return label & " names `" & ProvisioningLockKey & "` in a form the " &
        "lock reader does not read (only the writer's `" &
        ProvisioningLockKey & " = [...]` line is read): " & line.escape() &
        "; its records would be invisible, so it is not diffed"
  records = lock.lockedProvisioningClaims()
  ""

proc diffProvisioningLockDocuments*(oldText, newText: string;
                                    evidence = ProvisioningDiffEvidence()):
    ProvisioningLockDiff =
  ## The provisioning-level diff of two committed lock documents. A
  ## document that cannot be read refuses the diff (never "no change"); a
  ## lock written before the ``provisioning`` key existed has no records.
  var oldRecords, newRecords: seq[LockedRealization]
  var refusals: seq[string] = @[]
  let a = provisioningRecordsOf(oldText, "the old lock", oldRecords)
  if a.len > 0: refusals.add(a)
  let b = provisioningRecordsOf(newText, "the new lock", newRecords)
  if b.len > 0: refusals.add(b)
  if refusals.len > 0:
    return ProvisioningLockDiff(refusals: refusals)
  diffProvisioningRecords(oldRecords, newRecords, evidence)

type
  CommittedReselection* = object
    ## The outcome of ``repro lock refresh --provisioning``: the document to
    ## write and the report to print, or the refusals (nothing is written).
    document*: string
    report*: string
    diff*: ProvisioningLockDiff
    refusals*: seq[string]

proc reselected*(r: CommittedReselection): bool = r.refusals.len == 0

proc renderReselectionRefusal*(verb, lockPath: string;
                               refusals: seq[string]): string =
  ## What ``repro lock <verb> --provisioning`` prints on stderr when
  ## re-selection refuses (exit 1, the lock untouched): the header, then
  ## every refusal -- with its remedy lines -- indented by two spaces.
  result = "repro lock " & verb & " --provisioning: re-selection refused; " &
    lockPath & " was not written:"
  for refusal in refusals:
    for line in refusal.splitLines():
      result.add("\n  " & line)

proc reselectCommittedProvisioning*(projectRoot, lockPath: string;
                                    incumbentExists: bool;
                                    incumbentText, freshDocument: string;
                                    hostPlatform, targetPlatform: string):
    CommittedReselection =
  ## Explicit re-selection of the committed lock's provisioning records on
  ## one platform pair, over ``freshDocument`` (the lock the refresh just
  ## solved): every selection the resolver makes WITHOUT the lock's own
  ## pins (curator policy, else the unique eligible contribution) is locked
  ## by the lock writer, the incumbent's records for other platform pairs
  ## are carried unchanged, and the provisioning diff against the incumbent
  ## is reported. All or nothing: any refusal -- an unreadable incumbent, no
  ## catalog source, an ambiguous or unsatisfiable selection, a
  ## contradictory policy, a contribution that is not fully bound, a
  ## realization the writer cannot lock -- leaves ``document`` empty.
  ##
  ## The pins a build provisions from are NOT produced here: they are
  ## re-derived in-process, on every build, from the records written.
  var incumbent: seq[LockedRealization] = @[]
  if incumbentExists and lockDeclaresProvisioning(incumbentText):
    # An incumbent that names the key in no spelling contributes no record
    # (and may be any document, as for a plain refresh); one that names it
    # must be read in full.
    let refusal = provisioningRecordsOf(incumbentText,
      "the committed lock " & lockPath, incumbent)
    if refusal.len > 0:
      return CommittedReselection(refusals: @[refusal])
  # M6 D1: the incumbent's catalog import pins, read only to report how
  # re-selection moves them -- but read strictly: an unreadable array is
  # refused, not silently replaced.
  var incumbentPins: seq[LockedCatalogImport] = @[]
  if incumbentExists and lockDeclaresCatalogImports(incumbentText):
    if lockHasUnreadCatalogImportsSpelling(incumbentText):
      return CommittedReselection(refusals: @["the committed lock " &
        lockPath & " names `" & CatalogImportsLockKey & "` in a form the " &
        "lock reader does not read; " & CatalogImportsRepairAdvice])
    try:
      incumbentPins = parseLockedDependencies(incumbentText).
        lockedCatalogImportPins()
    except CatchableError as err:
      return CommittedReselection(refusals: @["the committed lock " &
        lockPath & " has `" & CatalogImportsLockKey & "` pins that cannot " &
        "be read (" & err.msg & ")"])
  if catalogSource.isNil:
    return CommittedReselection(refusals: @["re-selection needs the " &
      "composed catalogs, and none is supplied to this command: explicit " &
      "cross-repository catalog imports and the offered contributions' " &
      "provider identities (ReproOS M6 deliverables 1 and 2) -- and no " &
      "catalog source is installed in this process. The lock is left " &
      "unchanged."])
  var inputs: ProvisioningCatalogInputs
  try:
    inputs = catalogSource(ProvisioningCatalogRequest(
      projectRoot: projectRoot, lockPath: lockPath,
      artifact: ProjectInterfaceArtifact(), hostPlatform: hostPlatform,
      targetPlatform: targetPlatform, purpose: pcpLockReselect,
      catalogImportPins: incumbentPins, lockClaims: incumbent))
  except CatchableError as err:
    return CommittedReselection(refusals: @["the catalogs to re-select " &
      "from could not be obtained: " & err.msg])
  var resolver: ContributionResolver = noContributionResolver
  if not inputs.resolver.isNil:
    resolver = inputs.resolver
  var outcome: ProvisioningReselection
  try:
    outcome = reselectProvisioning(ProvisioningReselectionRequest(
      imports: inputs.imports, policy: inputs.policy, offered: inputs.offered,
      previous: inputs.previous, incumbent: incumbent,
      hostPlatform: hostPlatform, targetPlatform: targetPlatform), resolver)
  except CatchableError as err:
    return CommittedReselection(refusals: @["re-selection failed: " & err.msg])
  if not outcome.reselected:
    # M6 deliverable 4: each composition refusal followed by what to edit.
    return CommittedReselection(refusals: withRemedies(outcome.refusals,
      outcome.diagnostics, CatalogRemedyContext(projectRoot: projectRoot,
        lockPath: lockPath,
        reselectCommand: provisioningReselectCommand(projectRoot, lockPath),
        declaration: inputs.declaration), "    "))
  var document = freshDocument
  try:
    # With no record and no catalog import pin to write, the fresh document
    # is written exactly as a plain refresh writes it (``landCommittedLock``),
    # byte for byte.
    if outcome.records.len > 0 or inputs.catalogImportPins.len > 0:
      document = serializeLockedDependencies(parseLockedDependencies(
        freshDocument).withProvisioningRealizations(outcome.records).
        withCatalogImportPins(inputs.catalogImportPins))
  except CatchableError as err:
    return CommittedReselection(refusals: @["the re-selected lock cannot " &
      "be written: " & err.msg])
  let selectedHere = outcome.records.len - outcome.carriedForward
  var report = "repro lock refresh --provisioning: re-selected provisioning " &
    "on " & hostPlatform & " -> " & targetPlatform & " (" & $selectedHere &
    " selection(s) locked; " & $outcome.carriedForward & " record(s) for " &
    "other platform pairs carried forward unchanged)"
  if outcome.diff.unchanged:
    report.add("\nno provisioning selection changed")
  else:
    report.add("\n" & renderProvisioningDiff(outcome.diff))
  # M6 D1: how the catalog import pins moved (nothing when unchanged).
  for line in renderCatalogPinChanges(incumbentPins, inputs.catalogImportPins):
    report.add("\n" & line)
  CommittedReselection(document: document, report: report,
    diff: outcome.diff)
