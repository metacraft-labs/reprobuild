## Typed exception hierarchy for the M83 Phase B `RBPI` profile-intent
## binary envelope. Mirrors the M69 `EPlanCorrupt` / `EAuditLogCorrupt`
## convention: every corruption raise tags the offending FIELD so that
## the CLI / tests can assert against it programmatically.

type
  ERbpiCorrupt* = object of CatchableError
    ## An `RBPI` envelope or body failed validation. `field` names the
    ## structural component that tripped the check ("magic",
    ## "schemaVersion", "bodyLength", "checksum", "body", "envelope"),
    ## and `detail` carries the human-readable diagnostic.
    field*: string
    detail*: string

proc raiseRbpiCorrupt*(field, detail: string) {.noreturn.} =
  var e = newException(ERbpiCorrupt,
    "repro profile intent: corrupt RBPI envelope (" & field & "): " & detail)
  e.field = field
  e.detail = detail
  raise e
