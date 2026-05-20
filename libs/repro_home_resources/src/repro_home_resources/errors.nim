## Typed exception hierarchy for the M68 home-scope resource lifecycle.
##
## Mirrors the M63 / M64 hierarchies: each error carries enough
## structured context (resource address, kind, observed/recorded
## digests) for the CLI to render a useful diagnostic and for the
## gates to assert against named fields.
##
## See Home-Profile-Resource-Lifecycle.md "Drift Handling" and
## "Validation Criteria" for the surface this hierarchy implements.

type
  EHomeResource* = object of CatchableError
    ## Root of the resource-lifecycle exception hierarchy.

  EDrift* = object of EHomeResource
    ## Default-policy outcome when observed state differs from the
    ## recorded post-write digest. The user can pass
    ## `--reconcile-drift` to overwrite or `repro home adopt` to
    ## accept the user's edits into the managed state.
    resourceAddress*: string
    resourceKind*: string
    expectedDigestHex*: string
    observedDigestHex*: string

  EAdoptFailed* = object of EHomeResource
    ## `repro home adopt <resource>` could not import an existing
    ## resource into management (the resource was not observable,
    ## or the address is not addressable from the current intent).
    resourceAddress*: string
    reason*: string

  EAdoptUndeclared* = object of EHomeResource
    ## `repro home adopt <resource>` was asked to adopt a resource
    ## address that the profile's intent does NOT declare. Adopt
    ## claims an EXISTING out-of-band object into management for a
    ## resource the profile WANTS — adopting an undeclared address
    ## would create a binding with no desired state behind it. The
    ## user must add the resource declaration to `home.nim` first.
    resourceAddress*: string

  EUnknownResource* = object of EHomeResource
    ## `repro home resource move <old> <new>` (or another
    ## resource-scoped command) named an `<old>` resource address
    ## that is not a known binding in the active generation's
    ## manifest. There is nothing to carry forward.
    resourceAddress*: string

  EUnsupportedDomain* = object of EHomeResource
    ## A `macos.userDefault` driver cannot reach the sandboxed-app
    ## container plist from the current process. Phase B raises this
    ## from the macOS driver; Phase A reserves it.
    domain*: string
    reason*: string

  EResourceConflict* = object of EHomeResource
    ## Two resources in the desired set address the same identity
    ## (e.g. two `windows.registryValue` entries for the same
    ## `key + name`). The planner refuses; the spec calls for
    ## explicit-only resolution.
    address1*: string
    address2*: string
    realWorldIdentity*: string

  EPreventDestroy* = object of EHomeResource
    ## `lifecyclePolicy = preventDestroy` is set on a resource that
    ## would otherwise be destroyed. The destroy is refused
    ## regardless of `--reconcile-drift` / `--accept-overwrite`.
    resourceAddress*: string

  EResourceDriver* = object of EHomeResource
    ## A driver-level operation (Win32 API call, file read, etc.)
    ## failed for an unexpected reason. Carries the underlying error
    ## string verbatim.
    resourceAddress*: string
    resourceKind*: string
    operation*: string

  ENotImplementedPlatform* = object of EHomeResource
    ## A driver's apply / destroy / observe entry point was invoked on
    ## a platform that the driver cannot service. Phase B drivers
    ## (=linux.gsettings=, =systemd.userUnit=, =macos.userDefault=,
    ## =launchd.userAgent=) raise this when the host OS does not match
    ## the driver's required platform. The apply pipeline's catch-all
    ## branch re-raises this when it sees a resource kind whose driver
    ## is a Phase B skeleton on the current platform — fail-closed,
    ## not silent no-op.
    resourceKind*: string
    currentPlatform*: string
    requiredPlatform*: string

  EUnknownResourceKind* = object of EHomeResource
    ## The apply pipeline received a resource whose kind tag is not
    ## recognized by any driver. Should not happen post-typecheck
    ## because =ResourceKind= is a closed enum; raised as a hard
    ## invariant breach so unknown kinds surface as fail-closed
    ## errors instead of silent no-ops.
    resourceKind*: string

# ---------------------------------------------------------------------------
# Constructors.
# ---------------------------------------------------------------------------

proc raiseDrift*(address, kind, expectedHex, observedHex: string) {.noreturn.} =
  var e = newException(EDrift,
    "repro home: drift detected at " & address & " (" & kind &
    "): expected " &
    (if expectedHex.len >= 12: expectedHex[0 ..< 12] else: expectedHex) &
    " but observed " &
    (if observedHex.len >= 12: observedHex[0 ..< 12] else: observedHex) &
    ". Pass --reconcile-drift to overwrite, or `repro home adopt " &
    address & "` to accept the user's edits.")
  e.resourceAddress = address
  e.resourceKind = kind
  e.expectedDigestHex = expectedHex
  e.observedDigestHex = observedHex
  raise e

proc raiseAdoptFailed*(address, reason: string) {.noreturn.} =
  var e = newException(EAdoptFailed,
    "repro home adopt: " & address & ": " & reason)
  e.resourceAddress = address
  e.reason = reason
  raise e

proc raiseAdoptUndeclared*(address: string) {.noreturn.} =
  var e = newException(EAdoptUndeclared,
    "repro home adopt: '" & address & "' is not declared in the " &
    "profile's intent. Adopt claims an existing object into " &
    "management for a resource the profile WANTS — declare the " &
    "resource in home.nim first, then re-run `repro home adopt " &
    address & "`.")
  e.resourceAddress = address
  raise e

proc raiseUnknownResource*(address: string) {.noreturn.} =
  var e = newException(EUnknownResource,
    "repro home: '" & address & "' is not a known resource in the " &
    "active generation's manifest.")
  e.resourceAddress = address
  raise e

proc raiseUnsupportedDomain*(domain, reason: string) {.noreturn.} =
  var e = newException(EUnsupportedDomain,
    "repro home: unsupported domain '" & domain & "': " & reason)
  e.domain = domain
  e.reason = reason
  raise e

proc raiseResourceConflict*(addr1, addr2, identity: string) {.noreturn.} =
  var e = newException(EResourceConflict,
    "repro home: resource conflict — '" & addr1 & "' and '" & addr2 &
    "' both target real-world identity '" & identity & "'")
  e.address1 = addr1
  e.address2 = addr2
  e.realWorldIdentity = identity
  raise e

proc raisePreventDestroy*(address: string) {.noreturn.} =
  var e = newException(EPreventDestroy,
    "repro home: lifecyclePolicy=preventDestroy refuses to destroy '" &
    address & "'. Edit the profile or set the policy to `default` first.")
  e.resourceAddress = address
  raise e

proc raiseResourceDriver*(address, kind, operation, msg: string) {.noreturn.} =
  var e = newException(EResourceDriver,
    "repro home: driver error at " & address & " (" & kind & "): " &
    operation & ": " & msg)
  e.resourceAddress = address
  e.resourceKind = kind
  e.operation = operation
  raise e

const
  CurrentPlatformTag* =
    when defined(windows): "windows"
    elif defined(macosx): "macosx"
    elif defined(linux): "linux"
    else: "unknown"

proc raiseNotImplementedPlatform*(resourceKind, requiredPlatform: string)
    {.noreturn.} =
  ## Raised by Phase B driver entry points when invoked on a platform
  ## that does not match =requiredPlatform=. Fail-closed: callers must
  ## NEVER silently succeed on the wrong platform.
  var e = newException(ENotImplementedPlatform,
    "repro home: resource kind '" & resourceKind &
    "' is not implemented on platform '" & CurrentPlatformTag &
    "'; this driver requires '" & requiredPlatform & "'.")
  e.resourceKind = resourceKind
  e.currentPlatform = CurrentPlatformTag
  e.requiredPlatform = requiredPlatform
  raise e

proc raiseUnknownResourceKind*(resourceKind: string) {.noreturn.} =
  ## Apply pipeline invariant: an unrecognized resource-kind tag
  ## reached the dispatcher. The closed =ResourceKind= enum should
  ## prevent this in production; raise to surface bugs rather than
  ## silently no-op.
  var e = newException(EUnknownResourceKind,
    "repro home: unknown resource kind '" & resourceKind &
    "' reached the apply dispatcher (should not happen after " &
    "typechecking).")
  e.resourceKind = resourceKind
  raise e
