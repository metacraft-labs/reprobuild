## The darwin release's own non-SIP tools bundle is found beside the image.
##
## Distribution-And-Packaging.md §5.1, "The darwin non-SIP tools bundle": a
## darwin archive carries stackable-hooks-macos-tools at
## `<prefix>/libexec/stackable-hooks-macos-tools`, and the engine sets
## `STACKABLE_HOOKS_TOOLS_DIR` to it when the variable is unset and its
## `bin/sh` is a valid replacement. Without it an unpacked release on a Mac
## without Nix failed every monitored launch with "SIP-safe monitored launch
## requires a non-SIP shell" (reprobuild-pm
## issues/2026-11-12-darwin-release-names-a-nix-store-path-for-its-non-sip-shell-and-fails-on-a-nix-less-mac.md).
##
## Everywhere: the prefix search, driven through its injected shell check. On
## macOS: the real start-up seeding, with the prefix anchored through
## `REPRO_PUBLIC_CLI_PATH` (the same anchor an installed launcher sets) on a
## real temporary tree, a caller's value winning, and the diagnostic naming
## each tools root's state. Nothing is mocked; the shell is a real executable
## script outside the SIP-protected directories.

import std/[os, strutils, tempfiles, unittest]

import repro_build_engine

proc makeShell(path: string) =
  createDir(path.parentDir)
  writeFile(path, "#!/bin/sh\nexit 0\n")
  setFilePermissions(path, {fpUserExec, fpUserRead, fpUserWrite,
    fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

suite "darwin release tools bundle":
  test "the first prefix whose bundle has a valid shell wins":
    let root = createTempDir("t_shipped_macos_tools_", "")
    defer: removeDir(root)
    let empty = root / "empty"
    let good = root / "good"
    createDir(empty / ShippedMacosToolsSubdir)
    makeShell(good / ShippedMacosToolsSubdir / "bin" / "sh")
    let valid = proc(sh: string): bool = fileExists(sh)
    check shippedMacosToolsDirFor(["", empty, good], valid) ==
      good / ShippedMacosToolsSubdir
    check shippedMacosToolsDirFor([empty], valid) == ""
    check shippedMacosToolsDirFor([good],
      proc(sh: string): bool = false) == ""

  when defined(macosx):
    test "start-up points the resolver at the archive's bundle, unless set":
      let root = createTempDir("t_shipped_macos_tools_mac_", "")
      defer: removeDir(root)
      let prefix = root / "reprobuild-x-darwin-aarch64"
      let tools = prefix / ShippedMacosToolsSubdir
      makeShell(tools / "bin" / "sh")
      createDir(prefix / "bin")
      let prevTools = getEnv(ShippedMacosToolsEnvVar)
      let hadTools = existsEnv(ShippedMacosToolsEnvVar)
      let prevCli = getEnv("REPRO_PUBLIC_CLI_PATH")
      defer:
        if hadTools: putEnv(ShippedMacosToolsEnvVar, prevTools)
        else: delEnv(ShippedMacosToolsEnvVar)
        if prevCli.len > 0: putEnv("REPRO_PUBLIC_CLI_PATH", prevCli)
        else: delEnv("REPRO_PUBLIC_CLI_PATH")
      putEnv("REPRO_PUBLIC_CLI_PATH", prefix / "bin" / "reprobuild")

      delEnv(ShippedMacosToolsEnvVar)
      ensureShippedMacosToolsEnvironment()
      check getEnv(ShippedMacosToolsEnvVar) == tools
      check describeMacosToolsRoot(tools).endsWith("(usable)")

      putEnv(ShippedMacosToolsEnvVar, "/caller/choice")
      ensureShippedMacosToolsEnvironment()
      check getEnv(ShippedMacosToolsEnvVar) == "/caller/choice"
      check describeMacosToolsRoot("/caller/choice").endsWith("(does not exist)")

      removeFile(tools / "bin" / "sh")
      check describeMacosToolsRoot(tools).contains("no usable")
      delEnv(ShippedMacosToolsEnvVar)
      ensureShippedMacosToolsEnvironment()
      check not existsEnv(ShippedMacosToolsEnvVar)
