## DSL-port M9.R.15d.1 — libegl-headers stdlib stub registration test.
##
## Pins the M9.R.15d.1 widening: the libepoxy ``egl=yes`` meson option
## needs ``EGL/egl.h`` + ``EGL/eglext.h`` + ``EGL/eglplatform.h`` on
## the include search path at compile time. The
## ``libegl-headers`` stdlib stub surfaces those headers through
## ``nixpkgs#libglvnd.dev`` so the from-source resolver lands a usable
## channel on Nix-capable hosts.
##
## Without this stub the resolver short-fails with:
##   tool-resolution failed: --tool-provisioning=from-source requested
##   for "libegl-headers" (package "libegl-headers") but no sibling
##   recipe ... and no stdlib provisioning channel ... declared.

import std/unittest

import repro_project_dsl
# Pull the system-tools aggregator so the M9.R.15d.1 stub registers
# at module-init time and ``registeredPackages()`` can find it.
import repro_dsl_stdlib/packages/system_tools

proc findPackage(name: string): PackageDef =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return pkg
  raise newException(ValueError, "package not registered: " & name)

const CanonicalNixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8"

suite "DSL-port M9.R.15d.1 — libegl-headers stdlib stub":

  test "libegl-headers registers as a package":
    let pkg = findPackage("libegl-headers")
    check pkg.packageName == "libegl-headers"

  test "libegl-headers declares at least one nix provisioning channel":
    let pkg = findPackage("libegl-headers")
    check pkg.nixProvisioning.len >= 1

  test "libegl-headers nix selector points at libglvnd.dev":
    let pkg = findPackage("libegl-headers")
    var seenSelector = false
    for nix in pkg.nixProvisioning:
      if nix.selector == "nixpkgs#libglvnd.dev":
        seenSelector = true
    check seenSelector

  test "libegl-headers nix executablePath points at EGL/egl.h":
    # The "executablePath" field doubles as the canonical sentinel path
    # for header-only packages. Since libglvnd.dev exposes the canonical
    # Khronos EGL header set, ``include/EGL/egl.h`` is the sentinel.
    let pkg = findPackage("libegl-headers")
    var seenSentinel = false
    for nix in pkg.nixProvisioning:
      if nix.executablePath == "include/EGL/egl.h":
        seenSentinel = true
    check seenSentinel

  test "libegl-headers pins the canonical nixpkgs rev":
    let pkg = findPackage("libegl-headers")
    for nix in pkg.nixProvisioning:
      check nix.nixpkgsRev == CanonicalNixpkgsRev
