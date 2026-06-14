## B1: typed surface for a ReproOS system-scope configuration.
##
## A `SystemConfig` is the parsed result of an `etc/reproos/configuration.nim`
## file (see the surface example in the campaign spec
## `ReproOS-Generations-And-Foreign-Packages.milestones.org` -> "B1: System-
## scope configuration DSL"). It mirrors the home-profile typed shape from
## `libs/repro_home_apply` but lifts it from per-user scope to whole-OS
## scope. Where the home-profile types describe one user's intent, the
## system-scope types describe the entire boot image: which kernel boots,
## the kernel command line, which packages are present, which users exist,
## which systemd units are enabled, and the static mount layout.
##
## B1 P1: shapes only. Lowering is in `./lower.nim`; the parse + macro
## surface is in `./dsl.nim`; the plan/apply pipeline lives in B2 (not
## delivered here).
##
## Field-level justification: every field in every record below has a
## documented downstream consumer — either the lowering pass in
## `./lower.nim` that turns this AST into build-graph edges, or the B2
## plan/apply pipeline that materializes the lowered actions. No
## "speculative" fields are kept.

import std/[options, tables]

const
  KnownForeignDistros* = ["apt", "dnf", "pacman"]
    ## Closed set of foreign-package adapters whose harvesters exist or
    ## are scheduled by Phase C (C1 = apt, C2 = dnf + pacman). Any other
    ## distro tag in a `package(<distro>, ...)` call is rejected at parse
    ## time with `EUnknownForeignDistro`.

  KnownServiceVerbs* = ["enable", "disable", "mask"]
    ## Closed set of recognized `services:` block verbs. The corresponding
    ## systemd state is recorded in `ServiceState` (one of
    ## `svsEnabled`/`svsDisabled`/`svsMasked`).

  KnownFstypes* = ["ext4", "ext3", "ext2", "xfs", "btrfs", "vfat",
    "ntfs", "iso9660", "tmpfs", "squashfs", "f2fs", "swap",
    "proc", "sysfs", "devtmpfs", "cgroup", "cgroup2", "overlay",
    "bind"]
    ## Closed set of `fstype` values the parser accepts. Anything else
    ## is rejected at parse time. The list is conservative: filesystems
    ## that aren't on it can be added when a recipe needs them.

type
  PackageTier* = enum
    ## Tier classification for a single package reference in the
    ## `packages` list. The lowering pass uses this discriminator to
    ## decide whether the package is built from source (Tier 1) or
    ## bundled from a snapshot of a foreign distro index (Tier 3).
    ptFromSource = "from-source"        ## Tier 1 — reprobuild-built
                                        ## (e.g. `coreutils`, `bash`).
                                        ## DSL surface: a bare identifier.
    ptStandaloneBinary = "standalone-binary"
                                        ## Tier 2 — a vendored standalone
                                        ## binary blob. DSL surface:
                                        ## `package("blob-name")` with no
                                        ## distro tag. (Phase B records
                                        ## the shape; the Tier 2 ingestor
                                        ## lives elsewhere.)
    ptForeignBundle = "foreign-bundle"   ## Tier 3 — a foreign-distro
                                        ## package fetched from a pinned
                                        ## snapshot URL. DSL surface:
                                        ## `package(<distro>, "<name>",
                                        ## snapshot = "<snapshot-pin>")`.

  PackageRef* = object
    ## One entry in `system.packages`. The fields below cover every
    ## tier; unused fields are empty strings (Phase B documents the
    ## marker; later phases may switch to a Nim object-variant if the
    ## tiers diverge further). Keeping a flat object simplifies
    ## byte-stable serialization for the lowering pass's reproducibility
    ## checks.
    tier*: PackageTier
    name*: string                       ## the identifier surface name
                                        ## (`coreutils`) or the foreign
                                        ## package name (`"git"`).
                                        ## REQUIRED for every tier.
    distro*: string                     ## Tier 3 only; one of
                                        ## `KnownForeignDistros`. Empty
                                        ## for Tier 1 / Tier 2.
    snapshot*: string                   ## Tier 3 only; the pinned
                                        ## snapshot specifier (e.g.
                                        ## `"debian/bookworm/20260601T000000Z"`).
                                        ## Empty for Tier 1 / Tier 2.
                                        ## Validated at parse time:
                                        ## non-empty and slash-separated
                                        ## with at least three segments.
    sourceFile*: string                 ## file path where this reference
                                        ## was declared (for diagnostics
                                        ## and last-write-wins merge
                                        ## auditing). Empty when synthetic.
    sourceLine*: int                    ## 1-based line in `sourceFile`.

  KernelRef* = object
    ## Identifies the kernel build action that produces the running
    ## kernel image for this system. In Phase B the kernel is named by
    ## the symbol of the recipe that builds it (`reproosKernel` is the
    ## R8 from-source kernel recipe). The lowering pass converts this
    ## into a `BuildEdge` of kind `bekKernel`.
    name*: string                       ## the kernel recipe symbol; if
                                        ## empty, no kernel edge is
                                        ## emitted (the config can be
                                        ## merged-into from a module that
                                        ## supplies it).
    sourceFile*: string
    sourceLine*: int

  KernelCmdline* = object
    ## The kernel boot command line. Stored as a `seq[string]` so the
    ## lowering pass emits a deterministic byte-stable join (space-
    ## separated) and the diff pass (B2) can present added/removed
    ## entries one per line.
    parts*: seq[string]
    sourceFile*: string
    sourceLine*: int

  User* = object
    ## One entry inside the `users:` block. Mirrors the
    ## `/etc/passwd` line shape plus group membership.
    ##
    ## Cited consumers:
    ##   * `name` — `/etc/passwd` USER field; the user-skeleton
    ##     snapshot edge keys on this.
    ##   * `uid` — `/etc/passwd` UID; optional (auto-allocated by the
    ##     skeleton synthesizer when `none`).
    ##   * `shell` — `/etc/passwd` SHELL field; references a package
    ##     symbol (`bash`) that the lowering pass cross-checks against
    ##     the configured `packages` list.
    ##   * `passwordHash` — `/etc/shadow` PASSWD field. Empty string =
    ##     no password set (interactive login disabled).
    ##   * `groups` — `/etc/group` membership; the lowering pass emits
    ##     a `/etc/group` skeleton edge that consumes this.
    ##   * `homeDir` — `/etc/passwd` HOME field. Optional; defaults
    ##     `/home/<name>` (or `/root` for `root`) at lowering time.
    name*: string
    uid*: Option[int]
    shell*: string                      ## package-symbol reference
    passwordHash*: string
    groups*: seq[string]
    homeDir*: string
    sourceFile*: string
    sourceLine*: int

  ServiceStateKind* = enum
    svsEnabled = "enabled"
    svsDisabled = "disabled"
    svsMasked = "masked"

  ServiceState* = object
    ## One entry inside the `services:` block. The lowering pass
    ## collects every entry into a single deterministically ordered
    ## "unit-graph snapshot" edge whose output is the symlink farm under
    ## `/etc/systemd/system/<target>.wants/` that systemd reads at boot.
    unit*: string                       ## e.g. "systemd-networkd.service".
                                        ## Validated at parse time:
                                        ## must match the
                                        ## `<name>(@<inst>)?.<type>` shape
                                        ## where `<type>` is one of the
                                        ## recognized systemd unit
                                        ## suffixes.
    state*: ServiceStateKind
    sourceFile*: string
    sourceLine*: int

  MountEntry* = object
    ## One entry inside the `mounts:` block. The lowering pass collects
    ## every entry into a single deterministically ordered
    ## `/etc/fstab` skeleton edge.
    ##
    ## Cited consumers:
    ##   * `mountPoint` — `/etc/fstab` MNTPT field.
    ##   * `source` — `/etc/fstab` DEV field. Free-form (LABEL=, UUID=,
    ##     `/dev/...`, network mount syntax). Required.
    ##   * `fstype` — `/etc/fstab` FSTYPE field. One of
    ##     `KnownFstypes`. Required.
    ##   * `options` — `/etc/fstab` OPTIONS field. Empty seq means
    ##     `defaults`.
    ##   * `dump`, `pass` — `/etc/fstab` DUMP/PASS fields. Defaults
    ##     `0`/`0` for everything except `/` which defaults to `0`/`1`.
    mountPoint*: string
    source*: string
    fstype*: string
    options*: seq[string]
    dump*: int
    pass*: int
    sourceFile*: string
    sourceLine*: int

  SystemConfig* = ref object
    ## Top-level typed AST for one `configuration.nim` file. The fields
    ## below are the ordered output of the parser; the lowering pass
    ## reads them in declaration order so the resulting build graph is
    ## deterministic per the B1 spec's "re-lowering produces byte-
    ## identical graph" requirement.
    name*: string                       ## the symbol after `system`,
                                        ## e.g. "reproosConfig".
    kernel*: KernelRef                  ## empty if unset; lower() emits
                                        ## a `bekKernel` edge only when
                                        ## set.
    kernelCmdline*: KernelCmdline
    packages*: seq[PackageRef]
    users*: seq[User]
    services*: seq[ServiceState]
    mounts*: seq[MountEntry]
    imports*: seq[string]               ## relative paths declared in
                                        ## the `imports:` block. Resolved
                                        ## at parse time; the resolved
                                        ## list is preserved for
                                        ## diagnostics.
    sourceFile*: string                 ## the absolute path of the
                                        ## top-level configuration file.

  SystemConfigDiffEntryKind* = enum
    ## Used by the B2 plan-apply-record pass; B1 only defines the
    ## shape.
    sdAdded = "added"
    sdRemoved = "removed"
    sdChanged = "changed"

  SystemConfigDiffEntry* = object
    ## One per-field diff entry. The `kind` indicates whether the entry
    ## was added, removed, or changed relative to the previous
    ## generation's recorded state. The `category` names which section
    ## of the AST changed (`"kernel"`, `"kernel-cmdline"`, `"packages"`,
    ## `"users"`, `"services"`, `"mounts"`); the `key` is the
    ## section-specific identifier (package name, user name, unit name,
    ## mount point); the `previous`/`current` carry textual previews
    ## for `repro system plan`-style preview output.
    kind*: SystemConfigDiffEntryKind
    category*: string
    key*: string
    previous*: string
    current*: string

  SystemConfigDiff* = object
    ## Used by the B2 plan-apply-record pass; B1 only defines the
    ## shape. The diff is deterministically ordered by (`category`,
    ## `key`) so two identical applies produce byte-identical diffs.
    entries*: seq[SystemConfigDiffEntry]

  BuildEdgeKind* = enum
    ## Discriminator for entries in the lowered `BuildGraph` (see
    ## `./lower.nim`). B2 takes a `BuildGraph` as input and runs the
    ## materialization pipeline.
    bekKernel = "kernel"                 ## one per `system.kernel`
    bekPackageFromSource = "package-from-source"
                                         ## one per Tier 1 package
    bekPackageStandalone = "package-standalone"
                                         ## one per Tier 2 package
    bekPackageForeignBundle = "package-foreign-bundle"
                                         ## one per Tier 3 package
    bekUnitGraphSnapshot = "unit-graph-snapshot"
                                         ## ONE edge total, collected
                                         ## from all `services:` entries
    bekEtcSkeleton = "etc-skeleton"      ## ONE edge total, collected
                                         ## from users, mounts, kernel
                                         ## cmdline
    bekKernelCmdline = "kernel-cmdline"  ## one per `system.kernel_cmdline`

  BuildEdge* = object
    ## One edge in the lowered build graph. The fields below cover
    ## every kind; unused fields are empty.
    kind*: BuildEdgeKind
    ## Stable identity for this edge across re-lowerings of the same
    ## `SystemConfig`. The lowering pass derives this from
    ## `(kind, primaryKey)` with a deterministic stringification so
    ## the same config produces the same id every time.
    edgeId*: string
    primaryKey*: string                 ## kernel name / package name /
                                        ## "" for the singleton edges.
    payload*: Table[string, string]     ## kind-specific attributes;
                                        ## sorted alphabetically by
                                        ## key when serialized for the
                                        ## reproducibility check.

  BuildGraph* = object
    ## The lowered build graph. Ordered by (`kind` enum value, `edgeId`)
    ## so re-lowering produces byte-identical output.
    edges*: seq[BuildEdge]

proc initSystemConfig*(name: string): SystemConfig =
  result = SystemConfig(name: name)

proc isEmpty*(k: KernelRef): bool =
  k.name.len == 0

proc isEmpty*(c: KernelCmdline): bool =
  c.parts.len == 0

iterator pairs*(g: BuildGraph): (int, BuildEdge) =
  for i, e in g.edges:
    yield (i, e)

proc len*(g: BuildGraph): int = g.edges.len
