## ``rust-std`` -- the Rust standard library for a TARGET platform.
##
## rustc compiles for a target only when that target's standard library is
## in its sysroot (``lib/rustlib/<triple>/lib``). The ``rustc`` package's
## archive (``rust-<ver>-<host>.tar.xz``) carries the host's; upstream
## ships every other target's as a separate rust-installer component,
## ``rust-std-<ver>-<triple>.tar.gz``, meant to be merged into the same
## prefix (what ``rustup target add`` does). This package is the catalog's
## arm for those components (ReproOS-Add-On-Mode A15, second deliverable).
##
## ## Why the arms are keyed by the TARGET, and what that means for ``uses:``
##
## Every other package's ``tarball`` arms are selected by the platform the
## tool RUNS on. A standard library runs nowhere: it is linked into what
## rustc produces, so its platform is the one the build compiles FOR. The
## ``cpu`` / ``os`` of each arm below are therefore the target's, and the
## arm for ``armv7-unknown-linux-musleabihf`` is selected by a build whose
## ``targetTriple`` is that triple -- never by the host the build runs on.
##
## The tool-profile realizer selects arms for the host
## (``tarballAcquisitionPlan(target = hostRealizationTarget())`` at every
## call site), so naming ``rust-std`` in a dependency block realizes nothing
## today. The component reaches a build through the stdlib's cross sysroot
## edge instead: ``adapters/rust_target_sysroot`` reads ``rustStdComponent``
## below for the active cross target, fetches the archive by this table's
## URL and digest, and merges it into a copy of the host ``rustc`` prefix
## that ``cargo_package`` points ``RUSTC`` at. Realizing the arm through the
## tool profile under a per-kind ``RealizationTarget`` (``buildDeps:`` for
## the target, ``nativeBuildDeps:`` for the host) is the deferred engine
## half of A15's first deliverable; this table is what it will select from,
## and the test beside the adapter checks that the two stay one table.
##
## ## The version must equal the host rustc's
##
## A standard library built by one rustc is not loadable by another, so
## ``RustStdVersion`` follows ``rustc.nim``'s pin and the sysroot edge
## refuses a host ``rustc --version`` that differs.

import repro_project_dsl
import repro_dsl_stdlib/packages_schema
export packages_schema

type
  RustStdComponent* = object
    ## One target's component: the row the catalog arm below is written
    ## from, and what the sysroot edge reads.
    version*: string
    triple*: string   ## the Rust target triple
    cpu*: string      ## the cache's CPU family of the target
    os*: string
    sha256*: string

const
  RustStdVersion* = "1.94.0"
    ## Follows ``rustc.nim``'s pin (see the header).

  RustStdComponents* = [
    RustStdComponent(version: RustStdVersion,
                     triple: "armv7-unknown-linux-musleabihf",
                     cpu: "armv7", os: "linux",
                     sha256: "eb6d0f4eb9e7e835a3718096234267b20912d24ca1719df3cbf58321f6c4aa72"),
    RustStdComponent(version: RustStdVersion,
                     triple: "aarch64-unknown-linux-musl",
                     cpu: "aarch64", os: "linux",
                     sha256: "32f7881cfde924a798cb226272f908811aa097da3ff360a12dd8979a13ba4dc3"),
    RustStdComponent(version: RustStdVersion,
                     triple: "x86_64-unknown-linux-musl",
                     cpu: "x86_64", os: "linux",
                     sha256: "74a0e509ada9e9dd8e40a987abfdc677c6aa3487506bd6afaf9ede9466e3b189"),
  ]
    ## The digests are upstream's ``<archive>.sha256`` files, read 2026-10-30.
    ## The ``.tar.gz`` archive rather than the ``.tar.xz`` one: tar execs the
    ## decompressor, and ``gzip`` is a catalog package every from-source
    ## recipe already declares, where ``xz`` is not one at all.

proc rustStdUrl*(c: RustStdComponent): string =
  "https://static.rust-lang.org/dist/rust-std-" & c.version & "-" & c.triple &
    ".tar.gz"

proc rustStdComponent*(triple: string): RustStdComponent =
  ## The component for `triple`, or a `ValueError` naming the triple and
  ## the triples the table has.
  for c in RustStdComponents:
    if c.triple == triple:
      return c
  var known: seq[string] = @[]
  for c in RustStdComponents:
    known.add(c.triple)
  var msg = "rust-std: no standard library component is catalogued for the " &
    "target '" & triple & "'; known: "
  for i, k in known:
    if i > 0: msg.add(", ")
    msg.add(k)
  msg.add(". Add a row to RustStdComponents (packages/rust_std.nim) and " &
    "the matching tarball arm.")
  raise newException(ValueError, msg)

proc hasRustStdComponent*(triple: string): bool =
  for c in RustStdComponents:
    if c.triple == triple:
      return true
  false

const
  RustStdDistBase = "https://static.rust-lang.org/dist/rust-std-" &
    RustStdVersion & "-"
  Armv7Sha256 = RustStdComponents[0].sha256
  Aarch64Sha256 = RustStdComponents[1].sha256
  X86_64Sha256 = RustStdComponents[2].sha256

package `rust-std`:
  ## Linux targets only, so far: the arms are the components the add-on
  ## appliances need. A component for another OS is a row and an arm.
  platforms [linux], msg = "rust-std arms are catalogued for Linux targets only; add an arm for another OS's target component."
  provisioning:
    # ``executablePath``: a standard library has no executable, and the
    # realizer requires a file to resolve the prefix on. ``install.sh`` is
    # the rust-installer script every component archive carries at its root
    # (``stripComponents = 1``); it is never run.
    tarball url = RustStdDistBase & "armv7-unknown-linux-musleabihf.tar.gz",
      sha256 = Armv7Sha256,
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "install.sh",
      packageId = "rust-std@" & RustStdVersion,
      cpu = "armv7",
      os = "linux",
      lockIdentity = "tarball:rust-std@" & RustStdVersion &
        ":linux-armv7:sha256:" & Armv7Sha256,
      version = RustStdVersion
    tarball url = RustStdDistBase & "aarch64-unknown-linux-musl.tar.gz",
      sha256 = Aarch64Sha256,
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "install.sh",
      packageId = "rust-std@" & RustStdVersion,
      cpu = "aarch64",
      os = "linux",
      lockIdentity = "tarball:rust-std@" & RustStdVersion &
        ":linux-aarch64:sha256:" & Aarch64Sha256,
      version = RustStdVersion
    tarball url = RustStdDistBase & "x86_64-unknown-linux-musl.tar.gz",
      sha256 = X86_64Sha256,
      archiveType = "tar.gz",
      stripComponents = 1,
      executablePath = "install.sh",
      packageId = "rust-std@" & RustStdVersion,
      cpu = "x86_64",
      os = "linux",
      lockIdentity = "tarball:rust-std@" & RustStdVersion &
        ":linux-x86_64:sha256:" & X86_64Sha256,
      version = RustStdVersion
