## C1: apt-specific foreign-package DSL.
##
## Surface (campaign spec § C1 Fix scope):
##
## .. code-block:: nim
##
##   import repro_dsl_stdlib/packages/foreign_apt
##
##   let gitFromBookworm = aptPackage("git",
##     snapshot = "debian/bookworm/20260601T000000Z")
##
## The returned value is a B1-shape ``PackageRef`` (``ptForeignBundle``
## variant) — the SAME type B1's ``configuration.nim`` parser emits when
## the operator writes the equivalent
## ``package(apt, "git", snapshot = "debian/bookworm/...")`` call
## inside a ``packages = [...]`` block. This lets a single seq carry
## values produced by either path:
##
## .. code-block:: nim
##
##   let pkgs = @[
##     aptPackage("git",   snapshot = "debian/bookworm/20260601T000000Z"),
##     aptPackage("curl",  snapshot = "debian/bookworm/20260601T000000Z"),
##   ]
##   # pkgs[i] composes byte-for-byte with `cfg.packages[i]` from B1.
##
## Validation is performed at construction time (snapshot pin shape +
## distro membership), using the SAME B1 exception types so a CLI that
## already catches ``ESystemConfig`` for configuration-file diagnostics
## also catches inline-DSL diagnostics.

import repro_system_apply/types
import repro_system_apply/errors
import ./foreign_common

export foreign_common
export PackageRef, PackageTier
export ESystemConfig, EUnknownForeignDistro, EMalformedSnapshot,
       EMissingRequiredField

proc aptPackage*(name: string; snapshot: string;
                 sourceFile = ""; sourceLine = 0): PackageRef =
  ## Construct a ``ptForeignBundle`` PackageRef for an apt-resolved
  ## package pinned to ``snapshot``. Raises:
  ##
  ##   * ``EMissingRequiredField`` if ``name`` is empty;
  ##   * ``EMalformedSnapshot`` if ``snapshot`` is empty, missing the
  ##     ``<distro>/<release>/<rfc3339-compact>`` shape, or carries an
  ##     empty segment.
  ##
  ## (``EUnknownForeignDistro`` is impossible from this entry point —
  ## the ``distro`` argument is hard-wired to ``"apt"``. The check still
  ## runs inside ``mkForeignPackageRef`` so a future schema bump that
  ## removes ``apt`` from ``KnownForeignDistros`` fails closed.)
  mkForeignPackageRef("apt", name, snapshot, sourceFile, sourceLine)
