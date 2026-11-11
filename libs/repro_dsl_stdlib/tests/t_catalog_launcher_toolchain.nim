## Catalog entries for the codetracer-launcher toolchain: zig 0.14.1,
## llvm-strip, llvm-objdump (Windows arms), ldd, and elixir's nix arm.
##
## codetracer-launcher's `repro build` / `repro test` run through
## setup-dev-env's `dev-exec`, which deliberately does NOT enter the flake dev
## shell, so every tool the launcher's actions name must be provisionable by
## reprobuild itself. These are the entries that were missing.
##
## What is pinned, and why each check exists:
##
## * zig 0.14.1 has an archive for every (cpu, os) upstream publishes, each
##   with upstream's URL and a 64-hex sha256. The selector picks it for the
##   exact version on each slice, so a pinned `uses: "zig >=0.14 <0.15"`
##   cannot fall through to 0.13.0 or 0.16.0. The unpinned default is still
##   0.13.0: adding a version must not move existing unpinned consumers.
## * zig, elixir, llvm-strip, llvm-objdump and ldd each have a nix arm at the
##   canonical nixpkgs pin. A nix arm at an unpinned nixpkgs would be the
##   ambient-version defect this catalog exists to prevent.
## * llvm-strip / llvm-objdump have a Windows arm for x86_64 and aarch64,
##   taken from the llvm-mingw archives `llvm_mingw.nim` already pins. The
##   x86_64 digest must equal that module's, so the two cannot drift.
## * ldd is declared Linux-only, because nixpkgs builds glibc for Linux alone.
##
## No mocks: the real registered package definitions and the real selector.
## Nothing is downloaded. Whether each archive really contains the declared
## executable is the network conformance sweep's job, and these modules are
## enrolled for it in `catalog_tarball_packages`.

import std/[strutils, unittest]

import repro_interface_artifacts
import repro_dsl_stdlib/package_registry
import repro_dsl_stdlib/nixpkgs_pin
import repro_dsl_stdlib/packages/[zig, elixir, llvm_objdump, llvm_strip, ldd,
  llvm_mingw]
import repro_home_apply/package_catalog

proc isHex64(s: string): bool =
  if s.len != 64: return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f'}:
      return false
  true

proc pick(tool, version: string; cpu: PlatformCpu; os: PlatformOs):
    tuple[ok: bool; record: InterfaceTarballProvisioning] =
  let records = profileToolUse(tool).useDef.tarballProvisioning
  let choice = selectTarballRecord(records,
    realizationTargetFor(cpu, os, baselineMicroarchLevel(cpu)), version)
  if choice.status != kcSelected:
    return (false, InterfaceTarballProvisioning())
  (true, records[choice.index])

proc nixArms(tool: string): seq[InterfaceNixProvisioning] =
  profileToolUse(tool).useDef.nixProvisioning

const Zig0141Slices = [
  (cpu: pcX86_64, os: poWindows, file: "zig-x86_64-windows-0.14.1.zip"),
  (cpu: pcAArch64, os: poWindows, file: "zig-aarch64-windows-0.14.1.zip"),
  (cpu: pcX86_64, os: poLinux, file: "zig-x86_64-linux-0.14.1.tar.xz"),
  (cpu: pcAArch64, os: poLinux, file: "zig-aarch64-linux-0.14.1.tar.xz"),
  (cpu: pcX86_64, os: poMacos, file: "zig-x86_64-macos-0.14.1.tar.xz"),
  (cpu: pcAArch64, os: poMacos, file: "zig-aarch64-macos-0.14.1.tar.xz"),
]

suite "launcher toolchain catalog entries":

  test "zig 0.14.1 selects an upstream archive on every published slice":
    for slice in Zig0141Slices:
      checkpoint $slice.cpu & "/" & $slice.os
      let p = pick("zig", "0.14.1", slice.cpu, slice.os)
      check p.ok
      if not p.ok: continue
      check p.record.url == "https://ziglang.org/download/0.14.1/" & slice.file
      check isHex64(p.record.sha256)
      check p.record.detail.version == "0.14.1"
      check p.record.detail.extractPath ==
        slice.file.replace(".tar.xz", "").replace(".zip", "")
      if slice.os == poWindows:
        check p.record.executablePath == "zig.exe"
      else:
        check p.record.executablePath == "zig"

  test "the unpinned zig default is still 0.13.0":
    let p = pick("zig", "", pcX86_64, poLinux)
    check p.ok
    check p.record.detail.version == "0.13.0"

  test "every new nix arm resolves against the canonical nixpkgs pin":
    for (tool, selector, exe) in [
        ("zig", "nixpkgs#zig_0_14", "bin/zig"),
        ("elixir", "nixpkgs#elixir", "bin/elixir"),
        ("llvm-strip", "nixpkgs#llvm", "bin/llvm-strip"),
        ("llvm-objdump", "nixpkgs#llvm", "bin/llvm-objdump"),
        ("ldd", "nixpkgs#glibc^bin", "bin/ldd")]:
      checkpoint tool
      let arms = nixArms(tool)
      check arms.len == 1
      if arms.len != 1: continue
      check arms[0].selector == selector
      check arms[0].executablePath == exe
      check arms[0].nixpkgsRev == CanonicalNixpkgsRev
      check arms[0].nixpkgsNarHash == CanonicalNixpkgsNarHash

  test "llvm-strip and llvm-objdump have llvm-mingw arms on both Windows cpus":
    let mingwX64 = pick("llvm-mingw", "", pcX86_64, poWindows)
    check mingwX64.ok
    for tool in ["llvm-strip", "llvm-objdump"]:
      for cpu in [pcX86_64, pcAArch64]:
        checkpoint tool & " " & $cpu
        let p = pick(tool, "", cpu, poWindows)
        check p.ok
        if not p.ok: continue
        check p.record.executablePath == "bin/" & tool & ".exe"
        check isHex64(p.record.sha256)
        check "github.com/mstorsjo/llvm-mingw/releases/download/20260519/" in
          p.record.url
        if cpu == pcX86_64:
          # Same archive as llvm_mingw.nim: one pin, not two that can drift.
          check p.record.url == mingwX64.record.url
          check p.record.sha256 == mingwX64.record.sha256
      # No POSIX archive: POSIX hosts take the nix arm.
      check not pick(tool, "", pcX86_64, poLinux).ok

  test "ldd is declared Linux-only":
    let avail = packageAvailability("ldd")
    check avail.declared
    for p in avail.platforms:
      check p.os == poLinux
