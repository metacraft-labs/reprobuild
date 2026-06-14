## C1: dnf-specific foreign-package DSL (stub).
##
## C1 ships the DSL constructor + schema validation; the C2 milestone
## delivers the dnf harvester (Fedora kojipkgs / Vault snapshots). The
## constructor is FULLY FUNCTIONAL today — it returns a B1-shape
## ``PackageRef`` (``ptForeignBundle`` variant) that composes byte-for-
## byte with B1's ``parsePackageCall`` output. The "stub" qualifier
## refers to the upstream harvester pipeline, not this entry point.
##
## Surface (campaign spec § C1 Fix scope):
##
## .. code-block:: nim
##
##   import repro_dsl_stdlib/packages/foreign_dnf
##
##   let nvim = dnfPackage("neovim",
##     snapshot = "fedora/39/20260601")
##
## See ``./foreign_apt.nim`` for the full surface description; this
## module is the dnf-specific entry point.

import repro_system_apply/types
import repro_system_apply/errors
import ./foreign_common

export foreign_common
export PackageRef, PackageTier
export ESystemConfig, EUnknownForeignDistro, EMalformedSnapshot,
       EMissingRequiredField

proc dnfPackage*(name: string; snapshot: string;
                 sourceFile = ""; sourceLine = 0): PackageRef =
  ## Construct a ``ptForeignBundle`` PackageRef for a dnf-resolved
  ## package pinned to ``snapshot``. Raises ``EMissingRequiredField``
  ## (empty name) or ``EMalformedSnapshot`` (bad pin).
  mkForeignPackageRef("dnf", name, snapshot, sourceFile, sourceLine)
