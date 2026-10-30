## The typed diagnostics of ReproOS add-on mode, defined in ONE place.
##
## Add-on mode lets Reprobuild manage a declared set of systemd units, `/etc`
## files, system accounts, tmpfiles/sysctl fragments and secrets on top of a
## distribution-managed host (Debian, Ubuntu, ...). Every refusal it makes is
## typed, so a script, a test and the operator see the same name for the
## same reason. The full set is listed here even where the code that raises a
## code lives in another module, so a second definition of a name cannot
## appear: modules that refuse something in add-on mode import this one and
## raise through `newAddOnError` (or one of the subtypes below).
##
## Each message starts with the diagnostic's name (`EAddOnModeMismatch: ...`)
## so it survives every layer that flattens an exception into text.

type
  AddOnDiagnostic* = enum
    ## The add-on diagnostics. The string value is the name every message
    ## starts with.
    adOutOfScope = "EAddOnOutOfScope"
      ## A resource kind, field or path outside what the add-on may manage,
      ## or a machine-only field (kernel, bootloader, disks, base
      ## networking).
    adPackageOwned = "EAddOnPackageOwned"
      ## A target path is owned by an installed distribution package.
    adUnitShadows = "EAddOnUnitShadows"
      ## A unit name is already provided by a distribution package.
    adUnsupportedBase = "EAddOnUnsupportedBase"
      ## The host's base is outside the supported matrix.
    adModeMismatch = "EAddOnModeMismatch"
      ## The host registry says `addOn` and the host is not a distribution
      ## host, or the host is a distribution host the registry declares
      ## without saying how its system is managed.
    adExclusiveOverlap = "EAddOnExclusiveOverlap"
      ## An `exclusive` unit could not be confirmed stopped before its
      ## successor starts.
    adBaseLayerOwned = "EAddOnBaseLayerOwned"
      ## A path, prefix or unit intersects what a configuration layer above
      ## the distribution writes.
    adNetworkGuard = "EAddOnNetworkGuard"
      ## A `network` generation failed one of the guard's invariants and was
      ## reverted.

  EAddOn* = object of CatchableError
    ## Base of every add-on refusal.
    diagnostic*: AddOnDiagnostic

  EAddOnOutOfScope* = object of EAddOn
    ## `adOutOfScope`: names what was refused and who declared it.
    field*: string
      ## The refused configuration field: a resource kind
      ## (`linux.nixosSystemModule`), a resource field
      ## (`linux.firewallRule.chain`), or a machine-configuration field
      ## (`bootloader`).
    activity*: string
      ## The activity that set it; "" when it is profile-wide.
    subject*: string
      ## The resource or entry that carries the field, as diagnostics name
      ## it (`linux.firewallRule `ssh``), or "".

  EAddOnModeMismatch* = object of EAddOn
    ## `adModeMismatch`.
    host*: string
      ## The host the registry was asked about.
    declaredMode*: string
      ## What the registry says (`addOn`, or `full` for an entry without a
      ## `system:` key).
    observedBase*: string
      ## The base the host was observed to run (`os-release` `ID`, or a
      ## description when there is none).

  EAddOnUnsupportedBase* = object of EAddOn
    ## `adUnsupportedBase`.
    observedBase*: string

proc diagnosticMessage*(diagnostic: AddOnDiagnostic; detail: string): string =
  ## `"<name>: <detail>"`, the shape every add-on message has.
  $diagnostic & ": " & detail

proc newAddOnError*(diagnostic: AddOnDiagnostic; detail: string):
    ref EAddOn =
  ## A plain `EAddOn` for a diagnostic that carries no structured fields.
  result = newException(EAddOn, diagnosticMessage(diagnostic, detail))
  result.diagnostic = diagnostic

proc newAddOnOutOfScope*(field, activity, subject, detail: string):
    ref EAddOnOutOfScope =
  ## `EAddOnOutOfScope` naming `field` and the activity that set it (spec
  ## ReproOS-Add-On-Mode §8.3); `detail` says why it is out of scope.
  let who =
    if activity.len > 0: "activity `" & activity & "`"
    else: "the profile (no activity)"
  result = newException(EAddOnOutOfScope, diagnosticMessage(adOutOfScope,
    "field `" & field & "`" &
    (if subject.len > 0: " of " & subject else: "") &
    ", set by " & who & ", is out of scope in add-on mode: " & detail))
  result.diagnostic = adOutOfScope
  result.field = field
  result.activity = activity
  result.subject = subject

proc newAddOnModeMismatch*(host, declaredMode, observedBase, detail: string):
    ref EAddOnModeMismatch =
  ## `EAddOnModeMismatch` for `host`.
  result = newException(EAddOnModeMismatch, diagnosticMessage(adModeMismatch,
    detail))
  result.diagnostic = adModeMismatch
  result.host = host
  result.declaredMode = declaredMode
  result.observedBase = observedBase

proc newAddOnUnsupportedBase*(observedBase, detail: string):
    ref EAddOnUnsupportedBase =
  ## `EAddOnUnsupportedBase` for a base no add-on realisation covers.
  result = newException(EAddOnUnsupportedBase,
    diagnosticMessage(adUnsupportedBase, detail))
  result.diagnostic = adUnsupportedBase
  result.observedBase = observedBase
