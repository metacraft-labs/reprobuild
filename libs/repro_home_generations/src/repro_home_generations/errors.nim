## Typed exception hierarchy raised by the home generation registry
## library (M62 — Home-Profile-Generations-And-State.md).
##
## Every diagnostic carries enough structured context to render a
## meaningful CLI message and to drive the spec's "fail closed"
## contract: corrupt or out-of-schema pointers are rejected rather than
## silently used.

type
  EHomeGenerations* = object of CatchableError
    ## Common base for every diagnostic this library raises.

  EPointerCorrupt* = object of EHomeGenerations
    ## A `pointer.bin` envelope failed structural validation: the
    ## magic bytes, schema version, declared field set, or trailing
    ## BLAKE3-256 checksum did not match. The pointer is quarantined
    ## (not silently used).
    pointerPath*: string
    field*: string

  EManifestCorrupt* = object of EHomeGenerations
    ## An activation manifest blob in the CAS failed structural
    ## validation: the magic, version, record framing, or trailing
    ## checksum did not match its declared shape.
    manifestPath*: string
    field*: string

  EIntentSnapshotCorrupt* = object of EHomeGenerations
    ## A packed intent-snapshot tree failed structural validation.
    snapshotPath*: string
    field*: string

  EActivationBundleCorrupt* = object of EHomeGenerations
    ## An activation bundle failed structural validation, or the writer
    ## could not assemble a complete closure for a generation.
    bundlePath*: string
    field*: string

  EApplyBusy* = object of EHomeGenerations
    ## `<state-dir>/locks/apply.lock` is already held by another
    ## process. The 30-second poll window elapsed without the holder
    ## releasing the lock.
    lockPath*: string
    waitedSeconds*: int

  EStateDirInvalid* = object of EHomeGenerations
    ## The state directory could not be resolved (e.g. neither
    ## `$LOCALAPPDATA` nor `$USERPROFILE` is set on Windows).

  EGenerationDirInvalid* = object of EHomeGenerations
    ## A directory under `<state-dir>/generations/` does not satisfy
    ## the spec's expected shape (e.g. missing `pointer.bin`).
    generationPath*: string

proc raisePointerCorrupt*(pointerPath, field, msg: string) {.noreturn.} =
  var e = newException(EPointerCorrupt,
    "pointer envelope at '" & pointerPath & "' is corrupt: " & msg &
    " (field: " & field & ")")
  e.pointerPath = pointerPath
  e.field = field
  raise e

proc raiseManifestCorrupt*(manifestPath, field, msg: string) {.noreturn.} =
  var e = newException(EManifestCorrupt,
    "activation manifest at '" & manifestPath & "' is corrupt: " & msg &
    " (field: " & field & ")")
  e.manifestPath = manifestPath
  e.field = field
  raise e

proc raiseIntentSnapshotCorrupt*(snapshotPath, field, msg: string) {.noreturn.} =
  var e = newException(EIntentSnapshotCorrupt,
    "intent snapshot at '" & snapshotPath & "' is corrupt: " & msg &
    " (field: " & field & ")")
  e.snapshotPath = snapshotPath
  e.field = field
  raise e

proc raiseActivationBundleCorrupt*(bundlePath, field, msg: string) {.noreturn.} =
  var e = newException(EActivationBundleCorrupt,
    "activation bundle at '" & bundlePath & "' is corrupt: " & msg &
    " (field: " & field & ")")
  e.bundlePath = bundlePath
  e.field = field
  raise e

proc raiseApplyBusy*(lockPath: string; waitedSeconds: int) {.noreturn.} =
  var e = newException(EApplyBusy,
    "another `repro home apply` is in progress (holding " & lockPath &
    "); waited " & $waitedSeconds & "s before giving up")
  e.lockPath = lockPath
  e.waitedSeconds = waitedSeconds
  raise e

proc raiseStateDirInvalid*(msg: string) {.noreturn.} =
  raise newException(EStateDirInvalid, msg)

proc raiseGenerationDirInvalid*(generationPath, msg: string) {.noreturn.} =
  var e = newException(EGenerationDirInvalid,
    "generation directory '" & generationPath & "' is invalid: " & msg)
  e.generationPath = generationPath
  raise e
