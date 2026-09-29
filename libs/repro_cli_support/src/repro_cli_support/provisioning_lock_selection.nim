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
## strict reader skips (``lockHasUnreadProvisioningSpelling``), even beside
## a line it does read.
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
##     installed. THIS IS THE PRODUCTION STATE TODAY: explicit
##     cross-repository catalog imports with their coordinates, and the
##     provider identity of each offered contribution (ReproOS M6
##     deliverables 1 and 2), have no production supplier, so a real
##     ``repro build`` whose lock carries provisioning records refuses with
##     a message saying so. That is the safe side: before this module the
##     CLI ignored those records and provisioned whatever the catalogs
##     offered;
##   * the lock's ``provisioning`` records cannot be read, or some line
##     names the key in a spelling the strict reader skips (even beside a
##     line it does read);
##   * a lock NAMED for the build is missing or not a file, or the lock file
##     exists and cannot be opened.
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
import repro_lock

export catalog_composition.CatalogImport, catalog_composition.CatalogSelectionPolicy
export contribution_fingerprint.ContributionIdentity,
  contribution_fingerprint.ContributionResolver

type
  ProvisioningSelectionRefused* = object of ValueError
    ## The build's provisioning selection could not be made from the
    ## committed lock. The message is the resolver's (or names the missing
    ## input); the build must fail with it.

  ProvisioningCatalogRequest* = object
    ## What a ``ProvisioningCatalogSource`` is asked for.
    projectRoot*: string
    lockPath*: string
    artifact*: ProjectInterfaceArtifact
    hostPlatform*: string
    targetPlatform*: string

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

  ProvisioningCatalogSource* = proc (request: ProvisioningCatalogRequest):
    ProvisioningCatalogInputs {.closure.}
    ## Supplies the catalog imports for a lock-governed build. ReproOS M6
    ## deliverables 1 and 2 are its production implementation and do not
    ## exist yet; until one is installed, a lock with provisioning records
    ## refuses.

var catalogSource: ProvisioningCatalogSource = nil

proc setProvisioningCatalogSource*(source: ProvisioningCatalogSource) =
  ## Install (or, with ``nil``, remove) the catalog source every
  ## lock-governed build consults.
  catalogSource = source

proc provisioningCatalogSourceInstalled*(): bool =
  not catalogSource.isNil

proc decodedKeyText(keyPart: string): string =
  ## ``keyPart`` with TOML's ``\uXXXX`` / ``\UXXXXXXXX`` escapes of ASCII
  ## code points decoded, so ``"\u0070rovisioning"`` reads as the key it
  ## spells. Everything else is kept byte for byte.
  var i = 0
  while i < keyPart.len:
    if keyPart[i] == '\\' and i + 1 < keyPart.len and
        keyPart[i + 1] in {'u', 'U'}:
      let digits = if keyPart[i + 1] == 'u': 4 else: 8
      if i + 2 + digits <= keyPart.len:
        try:
          let code = parseHexInt(keyPart[i + 2 ..< i + 2 + digits])
          if code >= 0 and code < 128:
            result.add(char(code))
            i += 2 + digits
            continue
        except ValueError:
          discard
    result.add(keyPart[i])
    inc i

proc readsProvisioningLine(line: string): bool =
  ## The ONE form ``repro_lock.parseLockedDependencies`` reads records from:
  ## a (stripped) non-header line whose key, before its first ``=``, is
  ## exactly ``provisioning``.
  if line.startsWith("[") or line.startsWith("#"):
    return false
  let eq = line.find('=')
  eq > 0 and line[0 ..< eq].strip() == ProvisioningLockKey

proc namesProvisioningKey(line: string): bool =
  ## Whether the KEY part of a (stripped, non-comment) line -- the whole of a
  ## header line, else the text before its first ``=`` -- names
  ## ``provisioning`` in any spelling: bare, quoted, escaped, dotted, as a
  ## table or array-of-tables header, or behind bytes TOML does not treat as
  ## whitespace (a BOM, a no-break space). Values are not inspected, so a
  ## dependency that merely mentions the word is not a match.
  let eq = line.find('=')
  let keyPart =
    if line.startsWith("[") or eq < 0: line
    else: line[0 ..< eq]
  ProvisioningLockKey in decodedKeyText(keyPart)

proc lockDeclaresProvisioning*(text: string): bool =
  ## True when ``text`` has a line that names the ``provisioning`` key in ANY
  ## spelling (see ``namesProvisioningKey``), including the writer's own.
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if namesProvisioningKey(line):
      return true
  false

proc lockHasUnreadProvisioningSpelling*(text: string): bool =
  ## True when ``text`` names the ``provisioning`` key on some line OTHER
  ## than the one form the strict reader reads (``readsProvisioningLine``).
  ## The strict reader silently skips every other spelling -- quoted,
  ## escaped, dotted, table headers -- (measured), so records written that
  ## way would be dropped: alone they read as "no record", and beside a
  ## read line (say, one holding only another platform's records) the
  ## host's records vanish while the lock still parses. Either way the CLI
  ## refuses instead of building unpinned.
  for rawLine in text.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    if readsProvisioningLine(line):
      continue
    if namesProvisioningKey(line):
      return true
  false

proc refuse(message: string) {.noreturn.} =
  raise newException(ProvisioningSelectionRefused,
    "provisioning selection refused: " & message)

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
      "); they are not ignored. Repair or regenerate the lock.")
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
      "records are not ignored. Regenerate the lock.")
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
      hostPlatform: host, targetPlatform: target))
  except CatchableError as err:
    refuse("the catalogs the committed lock " & lockPath &
      " is verified against could not be obtained: " & err.msg)
  var resolver: ContributionResolver = noContributionResolver
  if not inputs.resolver.isNil:
    resolver = inputs.resolver
  let resolution = resolveProvisioningSelections(ProvisioningResolutionRequest(
    imports: inputs.imports, lockClaims: claims, policy: inputs.policy,
    offered: inputs.offered, hostPlatform: host, targetPlatform: target),
    resolver)
  if not resolution.resolved:
    refuse("the committed lock " & lockPath & " does not resolve against " &
      "the composed catalogs; the lock is not relaxed to an unpinned " &
      "selection:\n  " & resolution.refusals.join("\n  "))
  resolution.pinsOf()
