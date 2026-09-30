## The bootstrap Nim is one the build monitor can observe, on every route.
##
## The vendor Linux archive's ``bin/nim`` is a static ELF, which a preload
## monitor cannot enter, so an interface extraction it ran was uncacheable.
## Linux therefore takes the pinned nixpkgs Nim where the host has Nix and,
## where it has not, builds the same release from its official SOURCE archive
## (a dynamically linked compiler) -- never the vendor binary archive.

import std/[os, strutils, tempfiles, unittest]
import repro_tool_profiles
import repro_interface_artifacts
import repro_dsl_stdlib/nixpkgs_pin

suite "bootstrap Nim monitoring":
  test "Linux uses the pinned compiler channel instead of the static archive":
    when defined(linux):
      let tool = bootstrapNimToolUse()
      check tool.executableName == "nim"
      # The only archive is the source one, built by its own build.sh; the
      # vendor binary archive (``nim-2.2.10-linux_x64.tar.xz``) is not there.
      check tool.tarballProvisioning.len == 1
      if tool.tarballProvisioning.len == 1:
        let archive = tool.tarballProvisioning[0]
        check archive.url == BootstrapNimSourceTarballUrl
        check archive.url.endsWith("/nim-2.2.10.tar.xz")
        check "linux_" notin archive.url
        check archive.executablePath == "build.sh"
        check archive.sha256 == BootstrapNimSourceTarballSha256
      check tool.nixProvisioning.len == 1
      if tool.nixProvisioning.len == 1:
        let source = tool.nixProvisioning[0]
        check source.selector == "nixpkgs#nim"
        check source.executablePath == "bin/nim"
        check source.nixpkgsRev == CanonicalNixpkgsRev
        check source.nixpkgsNarHash == CanonicalNixpkgsNarHash
        check source.nixpkgsRef == "github:NixOS/nixpkgs/" & CanonicalNixpkgsRev
        check source.lockIdentity == source.nixpkgsRef & "?narHash=" &
          CanonicalNixpkgsNarHash & "#nim"
    else:
      skip("not Linux — the pinned nixpkgs compiler channel is the Linux bootstrap path")

  test "Windows retains its pinned native archive":
    when defined(windows):
      let tool = bootstrapNimToolUse()
      check tool.nixProvisioning.len == 0
      check tool.tarballProvisioning.len == 1
      if tool.tarballProvisioning.len == 1:
        check tool.tarballProvisioning[0].os == "windows"
        check tool.tarballProvisioning[0].executablePath == "bin/nim.exe"
        check tool.tarballProvisioning[0].sha256.len == 64
    else:
      skip("not Windows — the pinned native tarball is the Windows bootstrap path")

  test "an explicit bootstrap compiler is preserved without provisioning":
    when defined(linux):
      let root = createTempDir("repro-bootstrap-nim-", "")
      defer: removeDir(root)
      let compiler = root / "compiler"
      writeFile(compiler, "#!/bin/sh\nexit 0\n")
      # Executable: an explicit REPRO_BOOTSTRAP_CC is now probed (it must
      # compile a trivial C file), and this stand-in passes by exiting 0.
      setFilePermissions(compiler, {fpUserRead, fpUserWrite, fpUserExec})
      let oldNimSet = existsEnv("REPRO_NIM_COMPILER")
      let oldNim = getEnv("REPRO_NIM_COMPILER")
      let oldCcSet = existsEnv("REPRO_BOOTSTRAP_CC")
      let oldCc = getEnv("REPRO_BOOTSTRAP_CC")
      defer:
        if oldNimSet: putEnv("REPRO_NIM_COMPILER", oldNim)
        else: delEnv("REPRO_NIM_COMPILER")
        if oldCcSet: putEnv("REPRO_BOOTSTRAP_CC", oldCc)
        else: delEnv("REPRO_BOOTSTRAP_CC")
      putEnv("REPRO_NIM_COMPILER", compiler)
      putEnv("REPRO_BOOTSTRAP_CC", compiler)
      let store = root / "unused-store"
      ensureBootstrapToolchainEnv(tpmFromSource, store)
      check getEnv("REPRO_NIM_COMPILER") == compiler
      check getEnv("REPRO_BOOTSTRAP_CC") == compiler
      # Nothing was provisioned. The store holds at most the probe verdict for
      # the caller's compiler, and nothing else.
      if dirExists(store):
        for kind, path in walkDir(store):
          check path.extractFilename == "compiler-probes"
    else:
      skip("not Linux — ensureBootstrapToolchainEnv is exercised on the Linux bootstrap path")
