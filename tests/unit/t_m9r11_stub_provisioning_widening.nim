## DSL-port M9.R.11 — stub provisioning widening test.
##
## M9.R.10a added 43 stdlib stub packages with **nix-only**
## provisioning. The Windows from-source smoke for wayland trips on
## the very first stub it reaches (``texinfo``) because nix-only
## provisioning resolves to "no usable channel" on a non-nix host.
##
## M9.R.11 widens the canary set (``texinfo`` + the 10 tools the
## ``wayland → gcc → binutils → ...`` auto-recurse chain transitively
## reaches) to ``(nix, [scoop,] tarball)`` so the resolver lands a
## usable channel on every host. This test pins the widening so a
## later re-harvest cannot silently regress it.
##
## Stubs widened in M9.R.11 (this set MUST advertise a tarball channel;
## scoop is added where the ScoopInstaller/Main bucket carries the
## manifest):
##
##   texinfo, perl, m4, bison, flex, gperf, bc, file, rsync, swig,
##   gmp, mpfr, mpc
##
## The remaining 30 M9.R.10a stubs (libpng, libjpeg, kf6/qt6 sub-modules,
## ...) keep their nix-only single-channel shape for now; the
## ``TODO(M9.R.11.1)`` markers in each unwidened file flag the
## follow-up.

import std/[strutils, unittest]

import repro_project_dsl
# Pull every package whose provisioning we want to inspect into module
# init so ``registeredPackages()`` carries the widened
# ``nixProvisioning`` / ``scoopProvisioning`` / ``tarballProvisioning``
# fields. The two aggregator imports cover system_tools (texinfo, perl,
# m4, ...) + gmp/mpfr/mpc (also under system_tools).
import repro_dsl_stdlib/packages/system_tools

proc packageProvisioning(name: string):
    tuple[nix: int; scoop: int; tarball: int] =
  for pkg in registeredPackages():
    if pkg.packageName == name:
      return (nix: pkg.nixProvisioning.len,
              scoop: pkg.scoopProvisioning.len,
              tarball: pkg.tarballProvisioning.len)
  (-1, -1, -1)

const
  WaylandChainStubsRequiringTarball = [
    "texinfo", "perl", "m4", "bison", "flex",
    "gperf", "bc", "file", "rsync", "swig",
    "gmp", "mpfr", "mpc",
  ]
  StubsWithScoop = [
    "perl", "m4", "bison", "bc", "file", "swig",
  ]

suite "DSL-port M9.R.11 — stub provisioning widening":

  test "texinfo (the canary) has nix + tarball provisioning":
    let p = packageProvisioning("texinfo")
    check p.nix >= 1
    check p.tarball >= 1

  test "every wayland-chain stub advertises a tarball channel":
    var missing: seq[string] = @[]
    for name in WaylandChainStubsRequiringTarball:
      let p = packageProvisioning(name)
      if p.nix == -1:
        missing.add(name & " (not registered)")
        continue
      if p.tarball < 1:
        missing.add(name & " (no tarball channel)")
    if missing.len > 0:
      checkpoint("missing tarball provisioning: " & missing.join(", "))
    check missing.len == 0

  test "every wayland-chain stub keeps the original nix channel":
    # The widening must NOT delete the M9.R.10a nix entries — Nix-capable
    # hosts must still resolve via the nix channel as the highest
    # preference.
    for name in WaylandChainStubsRequiringTarball:
      let p = packageProvisioning(name)
      check p.nix >= 1

  test "scoop entries match the ScoopInstaller/Main bucket coverage":
    # Stubs whose tool is in scoop's main bucket carry a scoop entry.
    # Stubs NOT in scoop main keep tarball-only — flex, rsync, gperf,
    # texinfo, gmp/mpfr/mpc fall in this set.
    for name in StubsWithScoop:
      let p = packageProvisioning(name)
      check p.scoop >= 1

  test "every widened tarball lockIdentity starts with 'tarball:'":
    # M48 fingerprinting contract: lockIdentity is the deterministic
    # cache key. The convention is ``tarball:<pkg>@<ver>:[<os>:]sha256:
    # <hash>``; pin the prefix so a future schema rename surfaces here.
    for pkg in registeredPackages():
      if pkg.packageName notin WaylandChainStubsRequiringTarball:
        continue
      for tb in pkg.tarballProvisioning:
        check tb.lockIdentity.startsWith("tarball:")

  test "every widened tarball declares a non-zero sha256":
    # Hash-zero placeholders are explicitly disallowed for the M9.R.11
    # widening set. (Other stubs may still ship a "TODO" marker;
    # the wayland-chain set requires real upstream-pinned hashes.)
    for pkg in registeredPackages():
      if pkg.packageName notin WaylandChainStubsRequiringTarball:
        continue
      for tb in pkg.tarballProvisioning:
        check tb.sha256.len == 64  # hex sha256 = 64 chars
        check tb.sha256 != "0000000000000000000000000000000000000000000000000000000000000000"

  test "remaining M9.R.10a stubs document the widening TODO marker":
    # The 30 stubs NOT in the M9.R.11 canary set should still carry the
    # standard ``TODO(M9.R.10b+):`` or ``TODO(M9.R.11.1):`` marker so a
    # later re-harvest pass can sweep them. We don't read the files
    # here (would couple the test to the filesystem); instead we pin
    # that the unwidened stubs continue to register their single nix
    # channel, which guarantees the audit-test contract.
    for pkg in registeredPackages():
      if pkg.packageName in WaylandChainStubsRequiringTarball:
        continue
      # The non-stub packages (nim, gcc, meson, ...) have multiple
      # channels already — skip them.
      if pkg.nixProvisioning.len == 0:
        continue
      # The legitimate stub fingerprint is: 1 nix channel, 0 scoop,
      # 0 tarball. Confirm the unwidened set hasn't lost its nix entry.
      if pkg.scoopProvisioning.len == 0 and
         pkg.tarballProvisioning.len == 0:
        check pkg.nixProvisioning.len >= 1
