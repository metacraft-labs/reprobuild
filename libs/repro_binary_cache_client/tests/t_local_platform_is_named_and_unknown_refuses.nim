## The platform half of the binary-cache compatibility gate.
##
## Two properties, each with a control:
##
##   1. The host this binary runs on has a NAME. ``detectLocalPlatform``
##      once knew only x86_64 and aarch64 and reported every other host as
##      ``"unknown"`` -- so a 32-bit ARM consumer (the rpi2 add-on host,
##      ``--cpu:arm``) folded ``unknown`` into its entry keys, and an entry
##      published by any other unnamed architecture (i686, riscv64, a
##      different ARM variant) carried the same platform and would have
##      passed ``checkCompat``'s equality gate and run, or faulted, there.
##      On the host running this test the name must be a real one, and the
##      32-bit ARM name (`armv7`, the catalog's `PlatformCpu` spelling that
##      `repro infra cache-keys` publishes under) must differ from every
##      other name this module can produce.
##   2. ``unknown`` never compares EQUAL. A manifest whose platform is
##      ``unknown`` is refused by a local platform that is also ``unknown``
##      (the pre-fix code accepted it: `unknown == unknown`), and by a named
##      one; a named manifest is refused by an unknown local. Control: the
##      same manifest with the local's own named platform passes the
##      platform gates (and is then refused only by the trust gate, which
##      proves the walk got past the platform).
##
## No server, no mocks: ``checkCompat`` is a pure function of the manifest
## and the local platform.

import std/[strutils, unittest]

import ../src/repro_binary_cache_client
import ../../repro_binary_cache_server/src/repro_binary_cache_server/types as bcsTypes

proc manifestFor(cpu, os, abi: string): BinaryCacheManifest =
  result.formatVersion = bcsTypes.BinaryCacheFormatVersion
  result.entryKey.platform = PlatformTriple(cpu: cpu, os: os, abi: abi)
  # Relocation is checked before trust; a bare manifest would otherwise be
  # refused on relocation and never reach the gate this test is about.
  result.relocationPolicy = rpOptional

proc platformReason(m: BinaryCacheManifest; local: LocalPlatform): string =
  ## The reason ``checkCompat`` gives, or "" when it passed the platform
  ## gates. Trust is enforced with no signers, so a manifest that clears the
  ## platform gates is refused on trust: that refusal is the positive signal
  ## that the platform gates were passed.
  let r = checkCompat(m, local, @[], enforceTrust = true)
  if r.ok: return ""
  r.reason

suite "the local platform is named, and an unnamed one substitutes nothing":

  test "this host is named, and the names are distinct":
    let local = detectLocalPlatform("")
    check local.cpu != UnknownPlatformCpu
    check local.cpu.len > 0
    check local.os != UnknownPlatformOs
    when defined(arm):
      check local.cpu == "armv7"
    elif defined(amd64) or defined(x86_64):
      check local.cpu == "x86_64"
    elif defined(arm64) or defined(aarch64):
      check local.cpu == "aarch64"
    # The 32-bit ARM identity shares no name with any other this module
    # produces, so an entry from any of them cannot pass the equality gate.
    for other in ["x86_64", "aarch64", "i686", "riscv64", UnknownPlatformCpu]:
      check other != "armv7"
    let armhf = manifestFor("armv7", "linux", "gnu")
    let armhfLocal = LocalPlatform(cpu: "armv7", os: "linux", abi: "gnu")
    # An entry for any OTHER named family is a CPU mismatch on an armv7 host.
    for other in ["x86_64", "aarch64", "i686", "riscv64"]:
      check "CPU mismatch" in platformReason(manifestFor(other, "linux", "gnu"),
                                             armhfLocal)
    # Refused, and ONLY on trust: the platform gates all passed and the
    # default-untrusted trust gate (no signers configured) is what spoke.
    # Any other wording means a platform gate refused the host's own identity.
    let armhfReason = platformReason(armhf, armhfLocal)
    checkpoint("armhf-on-armhf reason: " & armhfReason)
    check "default-untrusted" in armhfReason
    check "mismatch" notin armhfReason

  test "an unknown platform is refused on either side, never equal":
    let unknownLocal = LocalPlatform(cpu: UnknownPlatformCpu, os: "linux",
                                     abi: "gnu")
    let namedLocal = LocalPlatform(cpu: "x86_64", os: "linux", abi: "gnu")
    let unknownManifest = manifestFor(UnknownPlatformCpu, "linux", "gnu")
    let namedManifest = manifestFor("x86_64", "linux", "gnu")
    # The pre-fix behaviour: unknown == unknown passed the CPU gate.
    check "unknown" in platformReason(unknownManifest, unknownLocal)
    check "unknown" in platformReason(unknownManifest, namedLocal)
    check "unknown" in platformReason(namedManifest, unknownLocal)
    # An unknown OS is refused the same way.
    check "unknown" in platformReason(manifestFor("x86_64", UnknownPlatformOs,
                                                  "gnu"), namedLocal)
    # Control: named on both sides clears the platform gates.
    let r = platformReason(namedManifest, namedLocal)
    check "unknown" notin r
    check "mismatch" notin r
