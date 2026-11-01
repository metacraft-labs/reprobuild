## The ``rustc`` and ``cargo`` packages' Nix channel realizes rust-lang's
## own release archive, the one their ``tarball`` arms download.
##
## THE NEED. A cross build merges rust-lang's prebuilt ``rust-std`` for the
## target into the host compiler's sysroot, and only rust-lang's own rustc
## can load it: a nixpkgs-built rustc of the same version refuses every
## crate with ``E0514`` (compiled by an incompatible version of rustc). On a
## NixOS host without nix-ld the ``tarball`` arm is refused too
## (``TarballHostLoaderMissing``: the generic-Linux binaries name the FHS
## loader), so the Nix channel is the only route left there, and it must
## realize the release archive, adapted to the pinned glibc, rather than
## nixpkgs' own rustc (which is also 1.91 at the canonical pin, outside the
## 1.94 range the ``tarball`` arms pin).
##
## WHAT IS EXERCISED, AND WHAT IS MOCKED. Nothing is mocked. The catalog's
## package records are read as the resolver reads them, and the expression
## file they name is read from disk. Realizing it is not repeated here: it
## downloads a 300 MB archive, and the integration path that realizes Nix
## expressions is covered by the Nix-daemon tests.

import std/[os, strutils, unittest]

import repro_project_dsl
# Imported for their ``package`` blocks, which register the records read
# below; no symbol of either is named.
{.push warning[UnusedImport]: off.}
import repro_dsl_stdlib/packages/rustc
import repro_dsl_stdlib/packages/cargo
{.pop.}
import repro_dsl_stdlib/packages/rust_std

proc packageNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(KeyError, "no catalog package " & name)

proc expressionText(pkg: PackageDef): string =
  check pkg.nixProvisioning.len == 1
  let file = pkg.nixProvisioning[0].expressionFile
  check file.isAbsolute
  check fileExists(file)
  readFile(file)

suite "rustc / cargo: the Nix channel is rust-lang's release archive":

  test "rustc and cargo name one expression, so they realize one prefix":
    let rustc = packageNamed("rustc")
    let cargo = packageNamed("cargo")
    check rustc.nixProvisioning.len == 1
    check cargo.nixProvisioning.len == 1
    let r = rustc.nixProvisioning[0]
    let c = cargo.nixProvisioning[0]
    check r.selector == c.selector
    check r.expressionFile == c.expressionFile
    check r.lockIdentity == c.lockIdentity
    check r.executablePath == "bin/rustc"
    check c.executablePath == "bin/cargo"
    # Not nixpkgs' own rustc: its crates cannot load rust-lang's rust-std.
    check not r.selector.startsWith("nixpkgs#")
    check r.nixpkgsRev.len == 0

  test "the expression pins every rust-installer archive the tarball arms pin":
    # Same bytes through either channel: every Linux / macOS tarball arm in
    # the rust-installer layout (``bin/rustc`` after the merge) has its
    # triple and digest in the expression, and the expression's release is
    # the one the target ``rust-std`` components are built by.
    let rustc = packageNamed("rustc")
    let text = expressionText(rustc)
    check ("version = \"" & RustStdVersion & "\"") in text
    var compared = 0
    for arm in rustc.tarballProvisioning:
      if arm.os notin ["linux", "macos"] or
          arm.executablePath != "bin/rustc":
        continue
      let leaf = arm.url.extractFilename
      check leaf.startsWith("rust-" & RustStdVersion & "-")
      let triple = leaf["rust-".len + RustStdVersion.len + 1 ..
        ^(".tar.xz".len + 1)]
      check ("triple = \"" & triple & "\"") in text
      check ("sha256 = \"" & arm.sha256 & "\"") in text
      inc compared
    # x86_64 Linux and aarch64 macOS at least.
    check compared >= 2

  test "on Linux the binaries are pointed at the pinned glibc, not the FHS loader":
    let text = expressionText(packageNamed("rustc"))
    check "import ../nixpkgs.nix" in text
    check "patchelf --set-interpreter" in text
    check "nix-support/dynamic-linker" in text
    # ``--add-rpath`` keeps ``$ORIGIN/../lib``, where rustc finds
    # ``librustc_driver``; ``--set-rpath`` would drop it.
    check "patchelf --add-rpath" in text
    check "--set-rpath" notin text
    # Stripping would make it a different compiler from the tarball arm's.
    check "dontStrip = true" in text
