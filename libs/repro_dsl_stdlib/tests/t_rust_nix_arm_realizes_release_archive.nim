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
## ranges the ``tarball`` arms pin).
##
## THE RELEASES. The catalog offers more than one release (1.94.0, the
## default, and 1.97.1). Each has a Nix arm of its own that declares its
## ``version``, so a ``uses:`` range selects among them exactly as it
## selects among the ``tarball`` arms; the cases below check that the two
## channels offer the same releases, in the same order, from the same
## archives.
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
import repro_dsl_stdlib/rust_toolchain_pins

proc packageNamed(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(KeyError, "no catalog package " & name)

proc expressionText(arm: NixPackageProvisioningDef): string =
  let file = arm.expressionFile
  check file.isAbsolute
  check fileExists(file)
  readFile(file)

proc builderText(arm: NixPackageProvisioningDef): string =
  ## The shared builder each release's expression calls.
  let file = arm.expressionFile.parentDir.parentDir / "rust-release.nix"
  check fileExists(file)
  readFile(file)

suite "rustc / cargo: the Nix channel is rust-lang's release archive":

  test "one Nix arm per release, default first, each declaring its version":
    for name in ["rustc", "cargo"]:
      checkpoint name
      let arms = packageNamed(name).nixProvisioning
      check arms.len == RustReleases.len
      for i, release in RustReleases:
        check arms[i].version == release.version
        check arms[i].lockIdentity == rustNixLockIdentity(release)
        check arms[i].expressionFile.parentDir.extractFilename ==
          "rust-" & release.version
    check RustReleases[0] == RustDefaultRelease
    check RustDefaultRelease.version == RustStdVersion

  test "rustc and cargo name one expression per release, so they realize " &
      "one prefix":
    let rustc = packageNamed("rustc")
    let cargo = packageNamed("cargo")
    check rustc.nixProvisioning.len == cargo.nixProvisioning.len
    for i in 0 ..< rustc.nixProvisioning.len:
      let r = rustc.nixProvisioning[i]
      let c = cargo.nixProvisioning[i]
      check r.selector == c.selector
      check r.expressionFile == c.expressionFile
      check r.lockIdentity == c.lockIdentity
      check r.version == c.version
      check r.executablePath == "bin/rustc"
      check c.executablePath == "bin/cargo"
      # Not nixpkgs' own rustc: its crates cannot load rust-lang's rust-std.
      check not r.selector.startsWith("nixpkgs#")
      check r.nixpkgsRev.len == 0

  test "each expression pins every rust-installer archive the tarball arms " &
      "pin for its release":
    # Same bytes through either channel: every Linux / macOS tarball arm in
    # the rust-installer layout (``bin/rustc`` after the merge) has its
    # triple and digest in the expression of its release, and every release
    # the tarball arms offer has a Nix arm.
    let rustc = packageNamed("rustc")
    var compared = 0
    for arm in rustc.tarballProvisioning:
      if arm.os notin ["linux", "macos"] or
          arm.executablePath != "bin/rustc":
        continue
      var expression = ""
      for nix in rustc.nixProvisioning:
        if nix.version == arm.detail.version:
          expression = expressionText(nix)
      checkpoint arm.url
      check expression.len > 0
      check ("version = \"" & arm.detail.version & "\"") in expression
      let leaf = arm.url.extractFilename
      check leaf.startsWith("rust-" & arm.detail.version & "-")
      let triple = leaf["rust-".len + arm.detail.version.len + 1 ..
        ^(".tar.xz".len + 1)]
      check ("triple = \"" & triple & "\"") in expression
      check ("sha256 = \"" & arm.sha256 & "\"") in expression
      inc compared
    # x86_64 Linux and aarch64 macOS at least, for each release.
    check compared >= 2 * RustReleases.len

  test "each expression's digests are the pins module's rows":
    for nix in packageNamed("rustc").nixProvisioning:
      let text = expressionText(nix)
      for release in RustReleases:
        if release.version != nix.version: continue
        for sha in [release.sha256X8664Linux, release.sha256Aarch64Linux,
                    release.sha256Aarch64Darwin, release.sha256X8664Darwin]:
          check ("sha256 = \"" & sha & "\"") in text

  test "every release's target rust-std components are catalogued":
    # A cross build merges the target's component into the host rustc's
    # sysroot, and only the component of the same release loads.
    for release in RustReleases:
      for c in RustStdComponents:
        if c.version == RustStdVersion:
          checkpoint release.version & " " & c.triple
          check rustStdComponent(c.triple, release.version).version ==
            release.version

  test "on Linux the binaries are pointed at the pinned glibc, not the FHS loader":
    for nix in packageNamed("rustc").nixProvisioning:
      check "import ../nixpkgs.nix" in expressionText(nix)
      check "import ../rust-release.nix" in expressionText(nix)
      let text = builderText(nix)
      check "patchelf --set-interpreter" in text
      check "nix-support/dynamic-linker" in text
      # ``--add-rpath`` keeps ``$ORIGIN/../lib``, where rustc finds
      # ``librustc_driver``; ``--set-rpath`` would drop it.
      check "patchelf --add-rpath" in text
      check "--set-rpath" notin text
      # Stripping would make it a different compiler from the tarball arm's.
      check "dontStrip = true" in text
