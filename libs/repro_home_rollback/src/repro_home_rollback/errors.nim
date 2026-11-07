## Typed exception hierarchy for the M64 `repro home rollback`
## pipeline. The diff/digest layer surfaces structured context for the
## CLI to render and for the gates to assert against.
##
## The contract from `Home-Profile-Generations-And-State.md`
## "Rollback" is: any mismatch between the on-disk state and the
## CURRENT manifest's recorded post-write digest is a user edit and
## must NOT be silently destroyed without `--accept-overwrite`.

type
  EHomeRollback* = object of CatchableError
    ## Root of the rollback pipeline exception hierarchy.

  EUnknownGeneration* = object of EHomeRollback
    ## The user named a generation id that does not exist under
    ## `<state-dir>/generations/`.
    requestedId*: string
    candidates*: seq[string]

  EAmbiguousGeneration* = object of EHomeRollback
    ## A short prefix matched multiple generation directories; we
    ## refuse rather than silently picking one.
    requestedPrefix*: string
    matches*: seq[string]

  ENoPreviousGeneration* = object of EHomeRollback
    ## `repro home rollback` was invoked with no argument, but there
    ## is no second-most-recent generation to fall back to (the only
    ## generation is the active one, or no generation exists).

  ENoActiveGeneration* = object of EHomeRollback
    ## `current` is empty — there is no generation to roll back FROM.

  EUserEditDetected* = object of EHomeRollback
    ## A destructive op (remove or overwrite) was about to fire against
    ## a file/block/launcher whose live bytes do NOT match the digest
    ## the CURRENT manifest recorded. Rollback exits non-zero unless
    ## `--accept-overwrite` is set.
    ##
    ## All three identity fields are populated; the gate asserts the
    ## path and a short prefix of each digest hex.
    path*: string
    recordKind*: string                ## "generated-file" | "managed-block" | "launcher"
    expectedDigestHex*: string         ## 64-char hex of expected (recorded)
    observedDigestHex*: string         ## 64-char hex of observed (on disk)

  ERollbackPartial* = object of EHomeRollback
    ## At least one drift was detected without `--accept-overwrite`;
    ## the safe subset of operations was NOT applied (the rollback is
    ## atomic at the "before any destructive op" boundary in M64) and
    ## the rollback exited non-zero. Carries the list of paths that
    ## drifted for diagnostic rendering.
    driftedPaths*: seq[string]

  ERollbackContentMissing* = object of EHomeRollback
    ## The target generation's manifest references a content blob by
    ## `storeContentHash` but the CAS has no entry for that digest.
    ## This indicates store-side corruption (or a manifest from a
    ## different store); rollback refuses to proceed rather than
    ## restoring garbage.
    digestHex*: string
    absoluteOutputPath*: string

  ERollbackAppBundleFailed* = object of EHomeRollback
    ## Re-placing a macOS application bundle from the target generation's
    ## store copy failed: the staged copy failed a check (``check`` names
    ## it, with the same names as apply's ``EApplyAppBundleFailed``:
    ## "signature", "identity", "info-plist", ...), the copy or rename
    ## failed ("placement"), or the target generation's store copy of the
    ## bundle is gone ("store-copy"). Every bundle the rollback re-places
    ## is staged and verified before any rollback operation runs, so
    ## nothing was changed: no staged copy is left, the bundle the current
    ## generation placed is still at ``targetPath``, the current
    ## generation's other files and resources are untouched, ``current``
    ## did not move, and no disk image is attached (rollback copies from
    ## the store, never from an image). Store-And-Installation-Layout.md
    ## § macOS Application Bundles, "Rollback".
    packageId*: string
    resourceAddress*: string
    bundleName*: string
      ## ``<Name>.app``.
    targetPath*: string
    check*: string
    targetGenerationIdHex*: string
      ## The generation whose bundle could not be re-placed.

# ---------------------------------------------------------------------------
# Constructors.
# ---------------------------------------------------------------------------

proc raiseUnknownGeneration*(requestedId: string;
                             candidates: seq[string]) {.noreturn.} =
  var e = newException(EUnknownGeneration,
    "repro home rollback: no generation matching '" & requestedId &
    "' (state-dir has " & $candidates.len & " generation(s))")
  e.requestedId = requestedId
  e.candidates = candidates
  raise e

proc raiseAmbiguousGeneration*(prefix: string;
                               matches: seq[string]) {.noreturn.} =
  var e = newException(EAmbiguousGeneration,
    "repro home rollback: generation prefix '" & prefix &
    "' is ambiguous (" & $matches.len & " matches)")
  e.requestedPrefix = prefix
  e.matches = matches
  raise e

proc raiseNoPreviousGeneration*() {.noreturn.} =
  raise newException(ENoPreviousGeneration,
    "repro home rollback: there is no previous generation to roll back to " &
    "(only the active generation exists, or no generation exists at all)")

proc raiseNoActiveGeneration*() {.noreturn.} =
  raise newException(ENoActiveGeneration,
    "repro home rollback: no active generation (`current` is empty); " &
    "nothing to roll back from")

proc raiseUserEditDetected*(path, recordKind,
                            expectedDigestHex,
                            observedDigestHex: string) {.noreturn.} =
  var e = newException(EUserEditDetected,
    "repro home rollback: user edit detected at " & path &
    " (" & recordKind & "): expected digest " &
    (if expectedDigestHex.len >= 12: expectedDigestHex[0 ..< 12] else: expectedDigestHex) &
    " but live bytes hash to " &
    (if observedDigestHex.len >= 12: observedDigestHex[0 ..< 12] else: observedDigestHex) &
    ". Pass --accept-overwrite to clobber the edit.")
  e.path = path
  e.recordKind = recordKind
  e.expectedDigestHex = expectedDigestHex
  e.observedDigestHex = observedDigestHex
  raise e

proc raiseRollbackPartial*(driftedPaths: seq[string]) {.noreturn.} =
  var e = newException(ERollbackPartial,
    "repro home rollback: " & $driftedPaths.len &
    " path(s) drifted; rollback refused without --accept-overwrite")
  e.driftedPaths = driftedPaths
  raise e

proc raiseContentMissing*(digestHex, absoluteOutputPath: string) {.noreturn.} =
  var e = newException(ERollbackContentMissing,
    "repro home rollback: CAS blob " & digestHex & " referenced by " &
    absoluteOutputPath & " is missing from the store. " &
    "Refusing to restore unknown content.")
  e.digestHex = digestHex
  e.absoluteOutputPath = absoluteOutputPath
  raise e

proc raiseRollbackAppBundleFailed*(packageId, resourceAddress, bundleName,
                                   targetPath, check, targetGenerationIdHex,
                                   msg: string) {.noreturn.} =
  ## A bundle the target generation placed could not be re-placed
  ## (``ERollbackAppBundleFailed``); nothing was rolled back.
  let what =
    case check
    of "placement": "could not be placed"
    of "store-copy": "has no usable copy in the store"
    else: "was refused: the staged copy failed the " & check & " check"
  let generation =
    if targetGenerationIdHex.len > 12: targetGenerationIdHex[0 ..< 12]
    else: targetGenerationIdHex
  var e = newException(ERollbackAppBundleFailed,
    "repro home rollback: could not re-place " & bundleName &
    " for package " & packageId & " from generation " & generation & ": " &
    bundleName & " " & what & ". Nothing was rolled back: " & targetPath &
    " is as the current generation left it, the staged copy was removed " &
    "and the current generation is still active. " & msg)
  e.packageId = packageId
  e.resourceAddress = resourceAddress
  e.bundleName = bundleName
  e.targetPath = targetPath
  e.check = check
  e.targetGenerationIdHex = targetGenerationIdHex
  raise e
