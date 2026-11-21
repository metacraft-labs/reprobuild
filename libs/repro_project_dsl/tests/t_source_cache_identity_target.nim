## A cross build's package identity names the target's consumer platform.
##
## ReproOS-Add-On-Mode A15, fourth deliverable. The binary-cache key of a
## source-built package carries a platform; for a native build it is the
## public-interface triple it always was, and under `repro build
## --target=<triple>` it is the platform the host that will substitute the
## entry derives -- `armv7 / linux / gnu / ""` for a Raspberry Pi running a
## static-musl binary -- so the entry's key and compat-check platform are the
## consumer's, not the x86-64 build box's. Pinned by value both ways: the
## native identity must not move for the recipe corpus.
##
## Nothing is mocked. The identity is composed from a real recipe file in a
## temporary directory, as the conventions compose it.

import std/[os, strutils, unittest]

import repro_binary_cache_client/cache_key
import repro_project_dsl/source_cache_identity
import repro_project_dsl/target_platform

const Triple = "armv7-unknown-linux-musleabihf"

proc withVariants(value: string; body: proc()) =
  let saved = getEnv("REPRO_VARIANTS")
  if value.len > 0: putEnv("REPRO_VARIANTS", value) else: delEnv("REPRO_VARIANTS")
  try: body()
  finally:
    if saved.len > 0: putEnv("REPRO_VARIANTS", saved) else: delEnv("REPRO_VARIANTS")

suite "target platform mapping":
  test "the triple contributes cpu and os; abi and libc are the consumer's":
    let p = consumerPlatformForTarget(Triple)
    check (p.cpu, p.os, p.abi, p.libcVariant) == ("armv7", "linux", "gnu", "")
    check consumerPlatformForTarget("arm-linux-gnueabihf").cpu == "armv7"
    check consumerPlatformForTarget("aarch64-unknown-linux-musl").cpu == "aarch64"
    check consumerPlatformForTarget("x86_64-pc-windows-msvc").abi == "msvc"
    check consumerPlatformForTarget("aarch64-apple-darwin").os == "darwin"
  test "a family or OS the cache does not key by is refused":
    expect ValueError: discard consumerPlatformForTarget("mips-unknown-linux-gnu")
    expect ValueError: discard consumerPlatformForTarget("riscv64-unknown-elf")

suite "source cache identity under --target":
  let dir = getTempDir() / ("t_sci_target_" & $getCurrentProcessId())
  createDir(dir / "probe")
  writeFile(dir / "probe" / "repro.nim", "# a recipe\n")
  defer: removeDir(dir)

  test "a native build keeps the public-interface platform":
    withVariants("", proc() =
      let p = sourceIdentityPlatform()
      check (p.cpu, p.os, p.abi, p.libcVariant) == ("x86_64", "linux", "gnu", "glibc")
      let idy = sourceCacheEntryIdentity(dir / "probe", "probe", "1.0", "cargo")
      check idy.platform.cpu == "x86_64")

  test "a cross build's identity is keyed for the appliance":
    withVariants("targetTriple=" & Triple, proc() =
      let idy = sourceCacheEntryIdentity(dir / "probe", "probe", "1.0", "cargo")
      check (idy.platform.cpu, idy.platform.os, idy.platform.abi,
             idy.platform.libcVariant) == ("armv7", "linux", "gnu", ""))

  test "the two identities differ in the platform and nothing else":
    var native, cross: CacheEntryIdentity
    withVariants("", proc() =
      native = sourceCacheEntryIdentity(dir / "probe", "probe", "1.0", "cargo"))
    withVariants("targetTriple=" & Triple, proc() =
      cross = sourceCacheEntryIdentity(dir / "probe", "probe", "1.0", "cargo"))
    check native.packageName == cross.packageName
    check native.providerRevision == cross.providerRevision
    check native.platform != cross.platform
