# ReproOS configuration DSL (B1)

This document is the user-facing reference for the system-scope
configuration DSL introduced in the
`ReproOS-Generations-And-Foreign-Packages` campaign, milestone B1.

A ReproOS host is described by a single
`/etc/reproos/configuration.nim` file. The file declares which kernel
boots, what arguments the kernel receives at boot time, which
packages are installed in the running system, which users and groups
exist, which systemd units are enabled, and the static mount layout
of the root filesystem.

> **Status:** B1 delivers the typed DSL + parser + lowering pass.
> The apply pipeline that turns a parsed config into a bootable
> generation lives in B2; rollback semantics live in B3.

## Quick start

```nim
system reproosConfig:
  kernel = reproosKernel
  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,            # Tier 1: built from source by the reprobuild graph
    bash,
    systemd,
    package(apt, "git", snapshot = "debian/bookworm/20260601T000000Z"),  # Tier 3
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$y$j9T$..."
    user "ada":
      shell = bash
      groups = ["wheel"]

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat"
```

The parser is intentionally **not** a general Nim parser. It walks the
file line by line and recognizes exactly the block forms shown above.
Anything else is rejected with a structured diagnostic that points at
the offending line + column.

## Top-level header

Every file declares exactly one `system <name>:` block. The name must
be a valid Nim identifier; it is used as the symbol the lowering pass
emits into the build graph.

A file may carry `import`/`from`/`include` statements above the
`system` header (they are tolerated for compatibility with full Nim
files but the parser does not act on them); everything else above the
header is rejected.

## Sections

The parser recognizes these section keywords inside the `system`
body. Each section is optional, but a section, once opened, must
indent its children one step deeper than the section header. The
parser auto-detects the indent width from the first child line; the
campaign style is two spaces.

### `kernel = <identifier>`

References the build action that produces the kernel image. The
identifier names a reprobuild recipe symbol (e.g. `reproosKernel` for
the R8 from-source kernel). The lowering pass emits one `bekKernel`
edge per declaration.

### `kernel_cmdline = [<string>, ...]`

The kernel boot command line. Stored as a list of strings; the
lowering pass joins them space-separated when materializing the GRUB
menu entry. May span multiple lines:

```nim
kernel_cmdline = [
  "console=ttyS0,115200n8",
  "init=/sbin/init",
  "rw",
]
```

### `packages = [<ref>, ...]`

The package set. Each element is one of:

| Form | Tier | Meaning |
|---|---|---|
| `coreutils` | Tier 1 | A bare identifier references a reprobuild-built recipe. The lowering pass emits a `bekPackageFromSource` edge. |
| `package("blob-name")` | Tier 2 | A vendored standalone-binary blob. Emits a `bekPackageStandalone` edge. |
| `package(apt, "git", snapshot = "...")` | Tier 3 | A foreign-distro package fetched from a pinned upstream index. Emits a `bekPackageForeignBundle` edge. |

For Tier 3, the recognized distros are `apt`, `dnf`, and `pacman`.
The `snapshot = ...` argument is **required** and must match the
`<distro>/<release>/<rfc3339-compact>` shape. The harvester that
turns a snapshot pin into actual `.deb`/`.rpm`/`.pkg.tar.zst` files
arrives in campaign Phase C (C1-C3); B1 only validates the surface.

### `users:`

Each `user "<name>":` sub-block declares one user. The recognized
fields are:

| Field | Type | Required | Notes |
|---|---|---|---|
| `shell` | identifier | yes | References a package in the `packages` list (e.g. `bash`). |
| `password_hash` | string | no | Yescrypt or similar hash; empty = no interactive login. |
| `groups` | `[ "g1", "g2", ... ]` | no | Group membership. |
| `uid` | int | no | Defaults to the next free UID at lowering. |
| `home_dir` | string | no | Defaults to `/home/<name>` (or `/root` for `root`). |

All users + groups roll up into the singleton `bekEtcSkeleton` edge
that B2's apply pipeline materializes into `/etc/passwd`,
`/etc/group`, `/etc/shadow`.

### `services:`

Each line declares one systemd unit's desired state. The recognized
verbs are `enable`, `disable`, and `mask`. The unit name must end in
one of the recognized systemd unit suffixes (`.service`, `.socket`,
`.target`, `.timer`, `.path`, `.mount`, `.automount`, `.swap`,
`.device`, `.slice`, `.scope`). Template-form units (e.g.
`getty@.service` or `serial-getty@ttyS0.service`) are recognized.

```nim
services:
  enable "systemd-networkd.service"
  disable "systemd-resolved.service"
  mask "snapd.service"
```

All services roll up into the singleton `bekUnitGraphSnapshot` edge.

### `mounts:`

Each line declares one `/etc/fstab` entry:

```nim
mount "<mount-point>", source = "...", fstype = "...", options = "...", dump = 0, pass = 0
```

`source` and `fstype` are required; `options`, `dump`, `pass` are
optional. The `fstype` must be one of the recognized values
(`ext4`, `ext3`, `ext2`, `xfs`, `btrfs`, `vfat`, `ntfs`, `iso9660`,
`tmpfs`, `squashfs`, `f2fs`, `swap`, `proc`, `sysfs`, `devtmpfs`,
`cgroup`, `cgroup2`, `overlay`, `bind`). The `source` field is
free-form (`LABEL=...`, `UUID=...`, `/dev/...`, network-mount
syntax).

All mount entries roll up into the singleton `bekEtcSkeleton` edge
along with the user records.

## Composition: the `imports:` block

A configuration can be split into modules. The parent declares its
imports up front:

```nim
system reproosConfig:
  imports:
    "./modules/git.nim"
    "./modules/users.nim"
  ...
```

Each path is resolved at parse time, **relative to the directory
containing the file that declares the import**. The imported module
must itself be a complete `system <name>:` file (its `<name>` is
ignored when merging — the parent's name wins).

### Merge semantics: last-write-wins on collisions

The merge is performed **before** the parent's own body is parsed, so
the parent's own declarations override the imported module's by
section key:

| Section | Collision key | On collision |
|---|---|---|
| `kernel = ...` | (singleton) | Parent overrides if set; otherwise import survives. |
| `kernel_cmdline = ...` | (singleton) | Parent overrides if set. |
| `packages = ...` | package name | Parent's redeclaration replaces the import's entry. |
| `users:` | user name | Parent's redeclaration replaces the import's entry. |
| `services:` | unit name | Parent's redeclaration replaces the import's entry. |
| `mounts:` | mount point | Parent's redeclaration replaces the import's entry. |

Imports that introduce **new** entries (entries the parent does not
mention) are preserved verbatim. The `sourceFile` field on each typed
record records which file the entry actually came from, which lets
diagnostics and the B2 plan/preview pass attribute each output to
its originating module.

### Circular imports are an error

A→B→A or any longer cycle raises `ECircularImport` with the full
import stack. The parser tracks the stack across nested calls.

### Missing imports are an error

A relative path that doesn't resolve to a readable file raises
`EImportNotFound` with both the literal text and the absolute
resolved path.

## Diagnostics

Every error this library raises inherits `ESystemConfig` and carries
the file path. The structured subclasses are:

| Exception | Raised when |
|---|---|
| `ENoConfig` | The expected `configuration.nim` does not exist. |
| `EUnstructured` | The parser saw a line it cannot interpret. Carries 1-based line + column + saw/expected pair. |
| `EMissingRequiredField` | A sub-record (user / mount) is missing a required field. |
| `EUnknownForeignDistro` | A `package(<distro>, ...)` used a distro tag outside `{apt, dnf, pacman}`. |
| `EMalformedSnapshot` | A Tier 3 `snapshot = "..."` string didn't match `<distro>/<release>/<rfc3339-compact>`. |
| `EUnknownService` | A `services:` entry's unit name has an unrecognized suffix. |
| `EUnknownFstype` | A `mount` entry's `fstype` is not one of the recognized filesystems. |
| `ECircularImport` | The transitive imports form a cycle. |
| `EImportNotFound` | An `imports:` path doesn't resolve to a readable file. |

A `try: ... except ESystemConfig as e:` clause catches every
diagnostic the parser + lowering layer raises.

## Lowering: the typed `BuildGraph`

`lower(cfg: SystemConfig): BuildGraph` converts a parsed config into
the build-graph edges B2's apply pipeline consumes. The result is
deterministic: re-lowering the same config produces a byte-identical
graph (verified by the `t_b1_dsl_lowering.nim` "re-lowering produces
a byte-identical graph" test).

The edge kinds are:

| Kind | Cardinality | What it builds |
|---|---|---|
| `bekKernel` | 0 or 1 | The kernel image. |
| `bekKernelCmdline` | 0 or 1 | The boot command line (consumed by the GRUB menu generator). |
| `bekPackageFromSource` | per Tier-1 package | One from-source recipe build. |
| `bekPackageStandalone` | per Tier-2 package | One standalone-binary materialization. |
| `bekPackageForeignBundle` | per Tier-3 package | One foreign-bundle fetch + sandbox-wrap (the C-phase harvester populates the cache). |
| `bekUnitGraphSnapshot` | 0 or 1 | The `/etc/systemd/system/...wants/` symlink farm. |
| `bekEtcSkeleton` | 0 or 1 | `/etc/passwd`, `/etc/group`, `/etc/shadow`, `/etc/fstab`. |

Each edge carries a `payload: Table[string, string]` whose keys are
alphabetically sorted when serialized (see
`serializeForReproCheck`). Tier 3 edges keep the snapshot pin in
their payload so the cache adapter can resolve the upstream index
without re-parsing the source.

## Gotchas

- **Indentation must be consistent.** The parser auto-detects the
  indent width from the first child line of `system <name>:`. Using
  three spaces inside `system` and two inside `users:` is a
  user-visible bug.
- **Single string literal per quoted value.** Multi-line strings and
  `&` concatenation are not recognized; collapse the value onto one
  line.
- **`packages = [...]` is a flat list.** No nested conditionals, no
  `when`-blocks. The campaign roadmap envisions adding a
  conditional shape later (the home-profile intent layer already has
  one); B1 does not.
- **Imports use forward slashes on every platform.** The parser
  accepts `\\` as a Nim path separator but Windows-style backslashes
  are not portable across hosts; prefer `./modules/foo.nim`.
- **Last-write-wins requires intent.** The merge rule is documented
  here and tested in `t_b1_dsl_composition.nim`; reading the rule as
  "the import unconditionally overrides the parent" is incorrect.
- **Tier 2 has no harvester yet.** `package("blob-name")` parses but
  doesn't yet lower into a working acquisition path. Tier 2 sits in
  the standalone-binary catalog; the campaign roadmap doesn't
  promise a Tier-2 ingestor before C-phase.

## References

- Campaign spec: `reprobuild-specs/ReproOS-Generations-And-Foreign-Packages.milestones.org`
  (search for `B1: System-scope configuration DSL`).
- Home-profile analogue: `reprobuild-specs/Home-Profile-Generations-And-State.md`.
- Sample fixture: `recipes/reproos-sample-config/configuration.nim`.
- Implementation: `libs/repro_system_apply/`.
