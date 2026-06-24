## ProfileIntent data types for the M83 Phase A profile compilation
## model. The macros under `./macros.nim`, `./resources.nim`, and
## `./predicates.nim` build values of these types at compile time;
## `./emit.nim` serializes the result to JSON.
##
## See `reprobuild-specs/Profile-Compilation-Model.md` for the design.
## Phase A keeps the data shape JSON-friendly. Phase B replaces JSON
## with the RBPI binary envelope while keeping the same Nim-side
## record types.

import std/[options, strutils, tables]

type
  ProfileIntent* = object
    name*: string
    activities*: seq[ActivityIntent]
    configOverrides*: seq[ConfigOverride]
    hosts*: Table[string, seq[string]]
    resources*: seq[ResourceIntent]
    adapterPreference*: OrderedTable[string, seq[string]]
      ## M2.5: per-OS adapter preference parsed from the macro form
      ## `adapterPreference:` block. Keys are canonical OS tags
      ## (`"windows"`, `"linux"`, `"darwin"`); values are the ordered
      ## adapter chain (each entry drawn from the closed set
      ## `{"builtin", "scoop", "nix", "path"}`). Empty table when the
      ## block is absent. `macos` aliases canonicalize to `"darwin"`.
      ## Mirrors the text-form `Profile.adapterPreference` field so
      ## both parsers produce the same AST shape for the same input.

  ActivityElementKind* = enum
    aekPackageRef
    aekWhenGuard

  ActivityElement* = object
    case kind*: ActivityElementKind
    of aekPackageRef:
      pkgName*: string
      pkgVersion*: string             ## M69: the literal version pin from
                                      ## `package(<id>, "<version>")`; "" for
                                      ## a bare identifier reference or
                                      ## the bare `package(<id>)` call form.
      pkgBinaries*: seq[string]       ## 2026-06-09: the binary names the
                                      ## package installs, when they differ
                                      ## from `pkgName`. Path-based catalog
                                      ## adapters (the Linux fallback) probe
                                      ## EACH of these on PATH so e.g.
                                      ## `package("ripgrep", binaries = @["rg"])`
                                      ## resolves via the `rg` binary. Empty
                                      ## seq preserves pre-2026-06 behavior:
                                      ## the adapter probes the package name
                                      ## itself. Metadata is per-package
                                      ## (NOT a global catalog) so each
                                      ## profile declares only what it
                                      ## actually uses.
    of aekWhenGuard:
      predicate*: PredicateExpr
      guardedBody*: seq[ActivityElement]

  ActivityIntent* = object
    name*: string
    body*: seq[ActivityElement]

  ConfigValueKind* = enum
    cvkString
    cvkInt
    cvkBool
    cvkExpr

  ConfigValue* = object
    case kind*: ConfigValueKind
    of cvkString: s*: string
    of cvkInt: i*: int
    of cvkBool: b*: bool
    of cvkExpr: expr*: string

  ConfigOverride* = object
    pkg*: string
    key*: string
    value*: ConfigValue

  FieldValueKind* = enum
    fvkString
    fvkInt
    fvkBool
    fvkList
    fvkExpr

  FieldValue* = object
    case kind*: FieldValueKind
    of fvkString: s*: string
    of fvkInt: i*: int
    of fvkBool: b*: bool
    of fvkList: items*: seq[string]
    of fvkExpr: expr*: string

  WindowsServiceRecoveryAction* = enum
    ## Windows-System-Resources Phase B: the four `sc.exe failure`
    ## actions a service can declare for its 1st/2nd/3rd-failure slots.
    ## The string values are the LOWER-CASE wire form used in the
    ## profile text, JSON, and codec — `sc.exe failure ... actions= `
    ## emits the same tokens (with `""` for `None`). The enum is
    ## referenced by both the profile-side `windowsService` template
    ## (operator-facing typed parameter) and the apply-side
    ## `SystemResource` / `PrivilegedOperation` variants, so its
    ## canonical string form has to survive every encoding boundary.
    wsraNone = "none"
    wsraRestart = "restart"
    wsraRunCommand = "runcommand"
    wsraReboot = "reboot"

  WindowsServiceRecovery* = tuple[action: WindowsServiceRecoveryAction;
                                   delayMs: int]
    ## One entry of `windows.service`'s `recoveryActions` field: the
    ## action to take on a failure plus the delay (in milliseconds)
    ## the SCM waits before invoking it. The triple slot meaning
    ## (1st-failure / 2nd-failure / subsequent-failure) is positional
    ## inside the sequence — `sc.exe failure` consumes up to three
    ## entries in order.

  ScheduleKind* = enum
    ## Windows-System-Resources Phase C: the closed set of trigger
    ## shapes a `windows.scheduledTask` resource accepts. The string
    ## values are the LOWER-CASE wire form used in the profile text,
    ## the ProfileIntent field list, the codec frame, and the broker
    ## dispatch — every encoding boundary agrees on the same vocabulary
    ## so a round-trip is loss-free. A profile carrying a token outside
    ## this set is rejected at the codec / validator boundary.
    sskOnBoot = "onBoot"
    sskOnLogon = "onLogon"
    sskOnce = "once"
    sskDaily = "daily"
    sskInterval = "interval"

  ScheduleSpec* = object
    ## Windows-System-Resources Phase C: discriminated union describing
    ## ONE Task Scheduler trigger. The driver encodes this to the XML
    ## `Register-ScheduledTask` consumes and decodes
    ## `Get-ScheduledTask`'s observation back into the same shape.
    ##
    ## The intermediate ProfileIntent representation stores each spec
    ## as ONE canonical-text string in a `fvkList` value (the codec
    ## token form below) so the existing string-list machinery covers
    ## the JSON, RBEB and canonical-text surfaces without a new
    ## `FieldValue` variant. Per-kind fields:
    ##
    ##   * `sskOnBoot`    — `delaySeconds`         (default 0)
    ##   * `sskOnLogon`   — `forUser`              ("" => any user)
    ##   * `sskOnce`      — `runAt` ISO-8601 stamp
    ##   * `sskDaily`     — `timeOfDay` `HH:MM`
    ##   * `sskInterval`  — `everyMinutes` (>0), `startAt` ISO-8601 ("" allowed)
    case kind*: ScheduleKind
    of sskOnBoot:
      delaySeconds*: int
    of sskOnLogon:
      forUser*: string
    of sskOnce:
      runAt*: string
    of sskDaily:
      timeOfDay*: string
    of sskInterval:
      everyMinutes*: int
      startAt*: string

  ResourceAddress* = object
    kind*: string
    name*: string

  ResourceIntent* = object
    kind*: string         ## e.g. "fs.userFile", "windows.capability"
    address*: string      ## optional named address; empty if unset
    fields*: Table[string, FieldValue]
    dependsOn*: seq[ResourceAddress]

  PredicateExpr* = object
    expr*: string         ## canonical-stringified predicate; apply-
                          ## time parser handles evaluation

  # -------------------------------------------------------------------
  # M9.R.20: SystemIntent — user-editable ``system "<hostname>":`` form.
  # -------------------------------------------------------------------
  #
  # ReproOS-Configuration-Architecture §2.2 pins the four recognised
  # top-level sections (``imports`` / ``config`` / ``users`` /
  # ``validate``) plus the activity helpers in §4.2 (``systemPackages`` /
  # ``systemServices`` / ``groups``). The SystemIntent record captures
  # the macro-expanded form parallel to ``ProfileIntent`` so the same
  # JSON-friendly encode/decode + golden-file machinery applies. See
  # ``./macros_system.nim`` for the macro that builds it.
  #
  # The macro stays text-only at v0.1 — full Configurable + variant
  # threading (Stage 2/3 of the compile-then-apply pipeline) is
  # delegated to the M83 ``repro_profile_compile`` runtime + the
  # existing ``package``-macro registries; the SystemIntent record is
  # the intermediate form the installer + the `system.nim`-port can
  # round-trip through.

  SystemConfigEntry* = object
    ## A single ``config:`` entry — ``key: type = default``. For v0.1
    ## we capture the field name + the default literal verbatim as a
    ## string; full typed-Configurable wiring lives in M9.R.21+.
    key*: string
    typeRepr*: string        ## e.g. ``"string"``, ``"int"``, ``"DesktopKind"``
    defaultExpr*: string     ## verbatim source representation
    docComment*: string      ## attached doc-comment lines (`## ...`)
    isVariant*: bool         ## ``@variant`` directive present

  SystemUserEntry* = object
    ## A single ``users:`` entry — ``"<name>": { groups: ..., homeIntent: import "..." }``.
    name*: string
    fullName*: string        ## optional; empty when not given
    groups*: seq[string]
    homeIntentImport*: string  ## verbatim import path; empty when absent

  SystemServiceList* = object
    ## ``services:`` block — ``enable: @[...]`` + ``disable: @[...]``.
    enableList*: seq[string]
    disableList*: seq[string]

  SystemBootloaderSpec* = object
    ## ``bootloader:`` sub-block — ``type: <ident>`` + ``device: "..."``.
    kind*: string            ## e.g. ``"grub"``, ``"systemd-boot"``
    device*: string

  SystemHardwareFs* = object
    ## ``filesystems:`` entry inside ``hardware "<id>":``.
    mountPoint*: string
    device*: string
    fsType*: string
    options*: seq[string]

  # -------------------------------------------------------------------
  # M9.R.22: declarative disk-layout DSL — port of nix-community/disko.
  # -------------------------------------------------------------------
  #
  # Spec: ``reprobuild-specs/ReproOS-Disko-Port.md``.
  #
  # The ``disko:`` block inside ``hardware "<id>":`` captures the
  # CREATE-FROM-SCRATCH partition intent that the installer needs to
  # rebuild the system on bare metal. The ``filesystems:`` block (above)
  # captures RUNTIME state of an already-installed system; the two are
  # complementary, and the round-trip property is:
  #
  #   probe(installed system) → SystemHardwareSpec.filesystems
  #   disko(probe live system) → SystemHardwareSpec.disko
  #   apply(SystemHardwareSpec.disko) → recreates filesystems[]
  #
  # The shape mirrors disko's recursive Nix expression (every node has a
  # ``kind`` + a ``content:`` child that is itself recursive). The
  # type-bag below is the Nim transliteration the spec §2.3 fixes.

  ContentKind* = enum
    cfsNone           ## absent / unset (the default zero value)
    cfsFilesystem     ## final filesystem layer (ext4/btrfs/vfat/...)
    cfsEncrypted      ## LUKS-style encryption wrapping an inner content
    cfsLvm            ## LVM volume-group + per-LV breakdown
    cfsZfs            ## ZFS pool + dataset reference
    cfsSwap           ## swap partition

  EncryptionSpec* = object
    ## LUKS/dm-crypt parameters that wrap an inner ContentSpec.
    `type`*: string            ## "luks1" / "luks2" (default "luks2")
    keyFile*: string           ## file path or the literal "interactive"
    cipher*: string            ## "aes-xts-plain64" (default if empty)
    allowDiscards*: bool       ## ``settings.allowDiscards = true``

  BtrfsSubvolSpec* = object
    ## ``btrfs subvolume create`` declaration; ``options:`` flow through
    ## as the mount-time flags for the subvolume's bind-mount.
    path*: string              ## "/home", "/nix", "/var/log"
    options*: seq[string]      ## ["compress=zstd", "noatime"]

  ZfsPoolSpec* = object
    ## Top-level ZFS pool (e.g. ``rpool``, ``userdata``) — mirrors
    ## disko's ``disko.devices.zpool.<name>`` namespace. Datasets are
    ## referenced from a partition's ContentSpec via ``kind=cfsZfs``.
    name*: string              ## "rpool", "userdata"
    devices*: seq[string]      ## by-id forms (preferred for stability)
    layout*: string            ## "stripe" / "mirror" / "raidz" / "raidz2"
    options*: seq[string]      ## passed verbatim to ``zpool create -o ...``

  LvmVolumeSpec* = object
    ## Logical-volume declaration inside an LVM volume group.
    name*: string              ## "root", "swap", "home"
    size*: string              ## "20G" / "100%FREE"
    content*: ref ContentSpec  ## what lives inside the LV (ext4, ...)

  ContentSpec* = object
    ## Recursive disko content node. The default-constructed value has
    ## ``kind == cfsNone`` so ``Option[ContentSpec]`` is not needed —
    ## absence is the zero value.
    case kind*: ContentKind
    of cfsFilesystem:
      format*: string             ## "ext4" / "btrfs" / "vfat" / "xfs"
      mountpoint*: string         ## "/", "/boot", "/home" ...
      mountOptions*: seq[string]
      label*: string
      subvols*: seq[BtrfsSubvolSpec]  ## populated when format=="btrfs"
    of cfsEncrypted:
      encryption*: EncryptionSpec
      inner*: ref ContentSpec     ## recursive: what's inside the LUKS
    of cfsLvm:
      vg*: string                 ## volume-group name
      volumes*: seq[LvmVolumeSpec]
    of cfsZfs:
      pool*: string               ## ZFS pool name (must match a
                                  ## ``DiskLayout.pools`` entry)
      dataset*: string            ## e.g. "rpool/nixos/root"
      zfsMountpoint*: string
      zfsProperties*: OrderedTable[string, string]
    of cfsSwap:
      swapPriority*: int
      swapDiscardPolicy*: string  ## "" / "once" / "pages" / "both"
    of cfsNone:
      discard

  PartitionSpec* = object
    ## A single GPT/MBR partition declaration.
    `type`*: string             ## "esp" / "linux" / "swap" / "lvm" /
                                ## "luks" / "raid" / "" (unset)
    size*: string               ## "512M" / "100%" / "remaining"
    content*: ContentSpec       ## recursive content (filesystem,
                                ## encrypted, lvm, zfs, ...)
    bootable*: bool

  DiskSpec* = object
    ## Top-level disk-device declaration; one per physical / virtual
    ## block device the installer is asked to wipe + repartition.
    device*: string             ## "/dev/disk/by-id/ata-Samsung_SSD_..."
    `type`*: string             ## "gpt" (default) or "mbr"
    partitions*: OrderedTable[string, PartitionSpec]

  DiskLayout* = object
    ## The full disko intent: zero or more disks + zero or more ZFS
    ## pools. ``disks`` is an OrderedTable so canonical-emit preserves
    ## the user-provided ordering; ``pools`` is a seq because pool
    ## ordering is positional (the first listed pool is the rpool).
    disks*: OrderedTable[string, DiskSpec]
    pools*: seq[ZfsPoolSpec]

  SystemHardwareSpec* = object
    ## ``hardware "<id>":`` macro form. Captures the per-host probe
    ## output verbatim so v0.1 of the macro round-trips through JSON.
    id*: string
    cpuArch*: string
    cpuMicrocode*: string
    kernelModules*: seq[string]
    loaderDevice*: string
    filesystems*: seq[SystemHardwareFs]
    graphicsDrivers*: seq[string]
    audioCards*: seq[string]
    disko*: Option[DiskLayout]
      ## M9.R.22: declarative create-from-scratch partition intent.
      ## ``none`` when the user did not include a ``disko:`` block.

  SystemActivitySpec* = object
    ## ``activity "<name>":`` macro form at the system scope.
    name*: string
    displayName*: string
    description*: string
    icon*: string
    systemPackages*: seq[string]
    systemServices*: seq[string]
    groups*: seq[string]
    homeContributions*: seq[string]
      ## verbatim activity-helper call exprs (e.g. ``"devTools()"``).

  SystemIntent* = object
    hostname*: string
    imports*: seq[string]
    configs*: seq[SystemConfigEntry]
    users*: seq[SystemUserEntry]
    services*: SystemServiceList
    extraPackages*: seq[string]      ## ``packages: extra: @[...]``
    bootloader*: SystemBootloaderSpec
    validateExprs*: seq[string]      ## verbatim ``validate:`` body expressions

# Convenience constructors -- intentionally simple so macros can use
# them at compile time without needing to know about variant tagging
# specifics.

proc strValue*(s: string): ConfigValue =
  ConfigValue(kind: cvkString, s: s)

proc intValue*(i: int): ConfigValue =
  ConfigValue(kind: cvkInt, i: i)

proc boolValue*(b: bool): ConfigValue =
  ConfigValue(kind: cvkBool, b: b)

proc exprValue*(expr: string): ConfigValue =
  ConfigValue(kind: cvkExpr, expr: expr)

proc strField*(s: string): FieldValue =
  FieldValue(kind: fvkString, s: s)

proc intField*(i: int): FieldValue =
  FieldValue(kind: fvkInt, i: i)

proc boolField*(b: bool): FieldValue =
  FieldValue(kind: fvkBool, b: b)

proc listField*(items: seq[string]): FieldValue =
  FieldValue(kind: fvkList, items: items)

proc exprField*(expr: string): FieldValue =
  FieldValue(kind: fvkExpr, expr: expr)

# ---------------------------------------------------------------------
# Windows-System-Resources Phase B: recovery-action token codec.
#
# `windows.service`'s `recoveryActions` field is a `seq[(action, delayMs)]`
# tuple. The intermediate ProfileIntent shape stores each entry as one
# `"action:delayMs"` string in a `fvkList` value so the existing JSON
# emitter, codec round-trip, and text renderer can ride the established
# string-list machinery without a new FieldValue variant. The strict
# format is `<lower-case-action-token>:<non-negative-decimal>`; the
# encoder rejects anything else.
#
# The matching apply-side codec lives in `repro_elevation/operations.nim`
# (parallel `WindowsServiceRecoveryActionKind` enum + same lower-case
# string vocabulary); the two namespaces share the wire form so a
# round-trip through the adapter is loss-free.
# ---------------------------------------------------------------------

proc recoveryActionToken*(a: WindowsServiceRecoveryAction): string =
  ## The lower-case wire token for a recovery action. Centralised so
  ## the template, the JSON emitter, and the text renderer all agree.
  $a

proc recoveryActionFromToken*(raw: string): WindowsServiceRecoveryAction =
  ## Strict parse of a recovery-action token. Accepts the canonical
  ## lower-case forms only — mirrors the closed-set posture of every
  ## other profile field. Raises `ValueError` on a mismatch.
  case raw
  of "none": wsraNone
  of "restart": wsraRestart
  of "runcommand": wsraRunCommand
  of "reboot": wsraReboot
  else:
    raise newException(ValueError,
      "unknown windows.service recovery action token '" & raw &
      "' (expected one of restart / runcommand / reboot / none)")

proc isKnownRecoveryActionToken*(raw: string): bool =
  ## Non-raising form. Used by the front-end closed-set validators.
  raw in ["none", "restart", "runcommand", "reboot"]

proc encodeWindowsServiceRecovery*(r: WindowsServiceRecovery): string =
  ## Encode a single `(action, delayMs)` pair as the canonical
  ## `"action:delayMs"` token the FieldValue list carries.
  recoveryActionToken(r.action) & ":" & $r.delayMs

proc decodeWindowsServiceRecovery*(token: string): WindowsServiceRecovery =
  ## Decode a single `"action:delayMs"` token. The action half must be
  ## a known lower-case recovery-action token; the delay half must be a
  ## non-negative decimal integer. Both halves are validated so a
  ## malformed entry fails closed rather than collapsing to defaults.
  let sep = token.find(':')
  if sep <= 0 or sep == token.len - 1:
    raise newException(ValueError,
      "windows.service recovery entry '" & token &
      "' is malformed (expected '<action>:<delayMs>')")
  let actionToken = token[0 ..< sep]
  let delayStr = token[sep + 1 .. ^1]
  if not isKnownRecoveryActionToken(actionToken):
    raise newException(ValueError,
      "windows.service recovery entry '" & token &
      "' names an unknown action '" & actionToken &
      "' (expected restart / runcommand / reboot / none)")
  var delayMs: int
  try:
    delayMs = parseInt(delayStr)
  except ValueError:
    raise newException(ValueError,
      "windows.service recovery entry '" & token &
      "' has a non-integer delay '" & delayStr & "'")
  if delayMs < 0:
    raise newException(ValueError,
      "windows.service recovery entry '" & token &
      "' has a negative delay (must be >= 0)")
  (action: recoveryActionFromToken(actionToken),
   delayMs: delayMs)

proc encodeWindowsServiceRecoveryList*(
    recovery: seq[WindowsServiceRecovery]): seq[string] =
  for r in recovery:
    result.add(encodeWindowsServiceRecovery(r))

proc decodeWindowsServiceRecoveryList*(
    tokens: seq[string]): seq[WindowsServiceRecovery] =
  for t in tokens:
    result.add(decodeWindowsServiceRecovery(t))

# ---------------------------------------------------------------------
# Windows-System-Resources Phase C: ScheduleSpec token codec.
#
# `windows.scheduledTask`'s `schedule` field is a discriminated union.
# The intermediate ProfileIntent shape stores it as a SINGLE-ELEMENT
# string seq under a `fvkList` value so the existing JSON emitter,
# canonical-text renderer and codec machinery flow without a new
# FieldValue variant. The canonical token form mirrors the
# `WindowsServiceRecovery` pattern (Phase B):
#
#   * `onBoot:<delaySeconds>`
#   * `onLogon:<forUser>`               (forUser may be empty)
#   * `once:<runAt>`                    (ISO-8601 timestamp)
#   * `daily:<timeOfDay>`               (`HH:MM`)
#   * `interval:<everyMinutes>:<startAt>`  (startAt may be empty)
#
# The codec is closed-set: an unrecognised tag, an empty required
# field, a non-positive `everyMinutes`, or a malformed `HH:MM` is
# rejected at every encoding boundary (template, parser, adapter,
# RBEB decoder) — defence-in-depth identical to Phase B.
# ---------------------------------------------------------------------

proc scheduleKindToken*(k: ScheduleKind): string =
  ## Lower-case wire token for a schedule kind. Centralised so every
  ## boundary agrees on the same spelling.
  $k

proc scheduleKindFromToken*(raw: string): ScheduleKind =
  ## Strict parse of a schedule-kind token. An unknown spelling raises
  ## `ValueError`. Used by the front-end + adapter validators.
  case raw
  of "onBoot": sskOnBoot
  of "onLogon": sskOnLogon
  of "once": sskOnce
  of "daily": sskDaily
  of "interval": sskInterval
  else:
    raise newException(ValueError,
      "unknown windows.scheduledTask schedule kind token '" & raw &
      "' (expected one of onBoot / onLogon / once / daily / interval)")

proc isKnownScheduleKindToken*(raw: string): bool =
  ## Non-raising form, used by closed-set validators.
  raw in ["onBoot", "onLogon", "once", "daily", "interval"]

proc isValidScheduleTimeOfDay*(raw: string): bool =
  ## True only for an `HH:MM` string with a valid 24-hour time. The
  ## driver interpolates this verbatim into the Task Scheduler XML, so
  ## a closed-set validator on the front-end side is necessary as
  ## defence-in-depth on top of the broker's psQuote.
  if raw.len != 5: return false
  if raw[2] != ':': return false
  for i in [0, 1, 3, 4]:
    if raw[i] notin {'0'..'9'}:
      return false
  let h = parseInt(raw[0 ..< 2])
  let m = parseInt(raw[3 ..< 5])
  h in 0..23 and m in 0..59

proc isValidScheduleIso8601*(raw: string): bool =
  ## Lightweight ISO-8601 shape check. We do NOT parse the full
  ## grammar; we just confirm the string is non-empty and uses only the
  ## conservative charset (digits + `-`, `:`, `T`, `Z`, `+`, `.`) that
  ## Task Scheduler accepts in `StartBoundary`. A malformed value here
  ## fails closed at codec time rather than at apply time.
  if raw.len == 0: return false
  for ch in raw:
    if ch notin {'0'..'9', '-', ':', 'T', 'Z', '+', '.'}:
      return false
  true

proc encodeScheduleSpec*(s: ScheduleSpec): string =
  ## Encode a `ScheduleSpec` to its canonical wire token. The encoder
  ## REJECTS malformed inputs (negative `delaySeconds`, non-positive
  ## `everyMinutes`, empty required-time fields, malformed `HH:MM` /
  ## ISO-8601 shapes) so a bypass through the template surface still
  ## fails closed.
  case s.kind
  of sskOnBoot:
    if s.delaySeconds < 0:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" &
        $s.delaySeconds & "' is negative (must be >= 0)")
    "onBoot:" & $s.delaySeconds
  of sskOnLogon:
    "onLogon:" & s.forUser
  of sskOnce:
    if not isValidScheduleIso8601(s.runAt):
      raise newException(ValueError,
        "windows.scheduledTask once runAt '" & s.runAt &
        "' is not a valid ISO-8601 timestamp")
    "once:" & s.runAt
  of sskDaily:
    if not isValidScheduleTimeOfDay(s.timeOfDay):
      raise newException(ValueError,
        "windows.scheduledTask daily timeOfDay '" & s.timeOfDay &
        "' is not a valid HH:MM 24-hour time")
    "daily:" & s.timeOfDay
  of sskInterval:
    if s.everyMinutes <= 0:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" &
        $s.everyMinutes & "' must be > 0")
    if s.startAt.len > 0 and not isValidScheduleIso8601(s.startAt):
      raise newException(ValueError,
        "windows.scheduledTask interval startAt '" & s.startAt &
        "' is not a valid ISO-8601 timestamp")
    "interval:" & $s.everyMinutes & ":" & s.startAt

proc decodeScheduleSpec*(token: string): ScheduleSpec =
  ## Decode a canonical wire token into a `ScheduleSpec`. Rejects every
  ## malformed shape (unknown tag, missing required field, non-integer
  ## numeric half, negative delay, non-positive interval). Raises
  ## `ValueError` on every refusal — the caller turns the message into
  ## the kind-specific diagnostic.
  let sep = token.find(':')
  if sep <= 0:
    raise newException(ValueError,
      "windows.scheduledTask schedule token '" & token &
      "' is malformed (expected '<kind>:<payload>')")
  let kindTok = token[0 ..< sep]
  let payload = token[sep + 1 .. ^1]
  if not isKnownScheduleKindToken(kindTok):
    raise newException(ValueError,
      "windows.scheduledTask schedule token '" & token &
      "' names an unknown kind '" & kindTok &
      "' (expected one of onBoot / onLogon / once / daily / interval)")
  let kind = scheduleKindFromToken(kindTok)
  case kind
  of sskOnBoot:
    var delaySeconds: int
    try:
      delaySeconds = parseInt(payload)
    except ValueError:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" & payload &
        "' is not an integer")
    if delaySeconds < 0:
      raise newException(ValueError,
        "windows.scheduledTask onBoot delaySeconds '" & payload &
        "' is negative (must be >= 0)")
    ScheduleSpec(kind: sskOnBoot, delaySeconds: delaySeconds)
  of sskOnLogon:
    # `payload` may legitimately be empty (any-user logon trigger).
    ScheduleSpec(kind: sskOnLogon, forUser: payload)
  of sskOnce:
    if not isValidScheduleIso8601(payload):
      raise newException(ValueError,
        "windows.scheduledTask once runAt '" & payload &
        "' is not a valid ISO-8601 timestamp")
    ScheduleSpec(kind: sskOnce, runAt: payload)
  of sskDaily:
    if not isValidScheduleTimeOfDay(payload):
      raise newException(ValueError,
        "windows.scheduledTask daily timeOfDay '" & payload &
        "' is not a valid HH:MM 24-hour time")
    ScheduleSpec(kind: sskDaily, timeOfDay: payload)
  of sskInterval:
    let sep2 = payload.find(':')
    if sep2 < 0:
      raise newException(ValueError,
        "windows.scheduledTask interval payload '" & payload &
        "' is malformed (expected '<everyMinutes>:<startAt>')")
    let everyStr = payload[0 ..< sep2]
    let startAt = payload[sep2 + 1 .. ^1]
    var everyMinutes: int
    try:
      everyMinutes = parseInt(everyStr)
    except ValueError:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" & everyStr &
        "' is not an integer")
    if everyMinutes <= 0:
      raise newException(ValueError,
        "windows.scheduledTask interval everyMinutes '" & everyStr &
        "' must be > 0")
    if startAt.len > 0 and not isValidScheduleIso8601(startAt):
      raise newException(ValueError,
        "windows.scheduledTask interval startAt '" & startAt &
        "' is not a valid ISO-8601 timestamp")
    ScheduleSpec(kind: sskInterval, everyMinutes: everyMinutes,
      startAt: startAt)

proc `==`*(a, b: ScheduleSpec): bool =
  ## Structural equality for `ScheduleSpec`. Used by adapter / driver
  ## drift checks. Two specs of different `kind` are NEVER equal; same-
  ## kind specs compare on the variant's fields.
  if a.kind != b.kind:
    return false
  case a.kind
  of sskOnBoot:
    a.delaySeconds == b.delaySeconds
  of sskOnLogon:
    a.forUser == b.forUser
  of sskOnce:
    a.runAt == b.runAt
  of sskDaily:
    a.timeOfDay == b.timeOfDay
  of sskInterval:
    a.everyMinutes == b.everyMinutes and a.startAt == b.startAt

proc parseResourceAddress*(s: string): ResourceAddress =
  ## Parse a `kind:name` string into a ResourceAddress. The address
  ## form mirrors the apply-time pipeline's existing convention.
  ## Empty string returns an empty address (kind == "" and name == "").
  if s.len == 0:
    return ResourceAddress(kind: "", name: "")
  let colonIdx = s.find(':')
  if colonIdx < 0:
    return ResourceAddress(kind: s, name: "")
  ResourceAddress(kind: s[0 ..< colonIdx], name: s[colonIdx + 1 .. ^1])

proc `$`*(a: ResourceAddress): string =
  if a.name.len == 0:
    a.kind
  else:
    a.kind & ":" & a.name
