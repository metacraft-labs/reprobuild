import std/[os, tempfiles, unittest]
import repro_tool_profiles
import repro_interface_artifacts
import repro_dsl_stdlib/nixpkgs_pin

suite "bootstrap Nim monitoring":
  test "Linux uses the pinned compiler channel instead of the static archive":
    when defined(linux):
      let tool = bootstrapNimToolUse()
      check tool.executableName == "nim"
      check tool.tarballProvisioning.len == 0
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
      skip()

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
      skip()

  test "an explicit bootstrap compiler is preserved without provisioning":
    when defined(linux):
      let root = createTempDir("repro-bootstrap-nim-", "")
      defer: removeDir(root)
      let compiler = root / "compiler"
      writeFile(compiler, "#!/bin/sh\nexit 0\n")
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
      check not dirExists(store)
    else:
      skip()
