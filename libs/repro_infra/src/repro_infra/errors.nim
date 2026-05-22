## Typed exception hierarchy for the M69 system-scope / infra-apply
## layer.
##
## Mirrors the M62/M68 error conventions: each error carries enough
## structured context for the CLI to render a useful diagnostic and
## for the M69 gates to assert against named fields.

type
  EInfra* = object of CatchableError
    ## Root of the system-scope / infra exception hierarchy.

  ESystemStateDirInvalid* = object of EInfra
    ## The per-host system state directory could not be resolved
    ## (e.g. `PROGRAMDATA` unset on Windows).

  ESystemProfileInvalid* = object of EInfra
    ## The `system.nim` profile could not be parsed, or named an
    ## unknown resource / value kind.
    detail*: string

  EPlanStale* = object of EInfra
    ## `repro infra apply <plan-id>` was given a plan whose recorded
    ## observations no longer match the live world — the user must
    ## re-plan. Raised BEFORE any mutation.
    planId*: string
    drifted*: seq[string]

  EPlanCorrupt* = object of EInfra
    ## An `RBIP` plan envelope failed magic / version / length /
    ## checksum validation.
    field*: string

  EAuditLogCorrupt* = object of EInfra
    ## An `RBSL` audit-log envelope failed validation.
    field*: string

  EFeatureDestroy* = object of EInfra
    ## A rollback would disable a Windows Optional Feature or
    ## uninstall a Capability and `--accept-feature-destroy` was not
    ## passed. Symmetric with `--accept-passwd-destroy`.
    operationAddress*: string

  EPasswdDestroy* = object of EInfra
    ## An apply / rollback would REMOVE a user account
    ## (`passwd.user` destroy) and `--accept-passwd-destroy` was not
    ## passed. The symmetric counterpart of `EFeatureDestroy` — a
    ## `passwd.user` destroy deletes a real account, so it is gated
    ## even when the account was created by a prior apply.
    operationAddress*: string

  EElevationRefused* = object of EInfra
    ## A privileged operation could not be applied because the apply
    ## was run `--no-elevate`, the OS prompt was declined, or the
    ## broker launch failed. A partial-success condition, not a crash.

proc raiseSystemStateDirInvalid*(msg: string) {.noreturn.} =
  raise newException(ESystemStateDirInvalid,
    "repro infra: " & msg)

proc raiseSystemProfileInvalid*(detail: string) {.noreturn.} =
  var e = newException(ESystemProfileInvalid,
    "repro infra: invalid system profile: " & detail)
  e.detail = detail
  raise e

proc raisePlanStale*(planId: string; drifted: seq[string]) {.noreturn.} =
  var e = newException(EPlanStale,
    "repro infra: plan '" & planId & "' is stale — " & $drifted.len &
    " resource(s) drifted since the plan was produced; re-run " &
    "`repro infra plan`.")
  e.planId = planId
  e.drifted = drifted
  raise e

proc raisePlanCorrupt*(field: string; msg: string) {.noreturn.} =
  var e = newException(EPlanCorrupt,
    "repro infra: corrupt RBIP plan envelope (" & field & "): " & msg)
  e.field = field
  raise e

proc raiseAuditLogCorrupt*(field: string; msg: string) {.noreturn.} =
  var e = newException(EAuditLogCorrupt,
    "repro infra: corrupt RBSL audit log (" & field & "): " & msg)
  e.field = field
  raise e

proc raiseFeatureDestroy*(address: string) {.noreturn.} =
  var e = newException(EFeatureDestroy,
    "repro infra: operation '" & address & "' would disable an " &
    "Optional Feature / uninstall a Capability; pass " &
    "--accept-feature-destroy to allow it.")
  e.operationAddress = address
  raise e

proc raisePasswdDestroy*(address: string) {.noreturn.} =
  var e = newException(EPasswdDestroy,
    "repro infra: operation '" & address & "' would REMOVE a user " &
    "account; pass --accept-passwd-destroy to allow it.")
  e.operationAddress = address
  raise e

proc raiseElevationRefused*(msg: string) {.noreturn.} =
  raise newException(EElevationRefused, "repro infra: " & msg)
