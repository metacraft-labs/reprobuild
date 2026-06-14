## C1: pacman-specific foreign-package DSL (stub).
##
## C1 ships the DSL constructor + schema validation; the C2 milestone
## delivers the pacman harvester (Arch archive.archlinux.org
## snapshots). The constructor is FULLY FUNCTIONAL today — it returns a
## B1-shape ``PackageRef`` (``ptForeignBundle`` variant) that composes
## byte-for-byte with B1's ``parsePackageCall`` output. The "stub"
## qualifier refers to the upstream harvester pipeline, not this entry
## point.
##
## Surface (campaign spec § C1 Fix scope):
##
## .. code-block:: nim
##
##   import repro_dsl_stdlib/packages/foreign_pacman
##
##   let htop = pacmanPackage("htop",
##     snapshot = "archlinux/20260601")
##
## Note: Arch's snapshot is day-granularity only (no ``THHMMSSZ``
## suffix), so the third segment is the bare ``YYYYMMDD`` date. The
## three-segment-minimum snapshot validator accommodates this.

import repro_system_apply/types
import repro_system_apply/errors
import ./foreign_common

export foreign_common
export PackageRef, PackageTier
export ESystemConfig, EUnknownForeignDistro, EMalformedSnapshot,
       EMissingRequiredField

proc pacmanPackage*(name: string; snapshot: string;
                    sourceFile = ""; sourceLine = 0): PackageRef =
  ## Construct a ``ptForeignBundle`` PackageRef for a pacman-resolved
  ## package pinned to ``snapshot``. Raises ``EMissingRequiredField``
  ## (empty name) or ``EMalformedSnapshot`` (bad pin).
  mkForeignPackageRef("pacman", name, snapshot, sourceFile, sourceLine)
