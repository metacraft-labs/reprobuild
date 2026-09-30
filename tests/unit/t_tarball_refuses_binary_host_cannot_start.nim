## A tarball-provisioned executable whose dynamic loader the host lacks is
## refused at resolution, by name, instead of failing later with exit 127.
##
## THE DEFECT. Path-mode provisioning falls back to a package's tarball when
## the tool is not on PATH. The stdlib `cargo` package's Linux tarball is
## the generic `x86_64-unknown-linux-gnu` Rust distribution, whose binaries
## ask the kernel for `/lib64/ld-linux-x86-64.so.2`. NixOS has no such
## file, so on a NixOS runner the tarball realized "successfully" and the
## cargo edge then died with exit 127 — "Could not start dynamically linked
## executable ... NixOS cannot run dynamically linked executables intended
## for generic Linux environments" — far from the provisioning decision
## that caused it.
##
## THE CONTRACT.
##   * `elfProgramInterpreter` reads an ELF's PT_INTERP (and "" for a
##     non-ELF payload);
##   * `resolveTarballTool` raises `TarballHostLoaderMissing` when the
##     realized executable's loader does not exist on this host, naming the
##     tool, the loader and the remedies (the tool on PATH, or Nix
##     provisioning);
##   * a binary whose loader exists resolves exactly as before.
##
## THE FIXTURE is a real host ELF (`true`) copied and edited in exactly one
## place: its PT_INTERP string is overwritten with a path that does not
## exist (NUL-padded, never longer than the original). That is precisely the
## condition a generic-Linux binary meets on NixOS, reproduced on any Linux
## host. No mocks: the real realize path over `file://`, archiveType "raw".
##
## Linux only (PT_INTERP is an ELF notion; the guard is Linux-gated).

import std/[os, strutils, tempfiles, unittest]

import repro_attest/measurement
import repro_interface_artifacts
import repro_tool_profiles

proc fileUrl(path: string): string =
  "file:///" & path.replace('\\', '/').strip(leading = true, chars = {'/'})

proc rawUse(url, sha256, name: string): InterfaceToolUse =
  result = InterfaceToolUse(
    rawConstraint: name,
    packageSelector: name,
    executableName: name,
    location: SourceLocation(file: "fixture", line: 1))
  result.tarballProvisioning = @[InterfaceTarballProvisioning(
    packageName: name,
    url: url,
    sha256: "sha256:" & sha256,
    archiveType: "raw",
    executablePath: name,
    stripComponents: 0,
    packageId: name & "@1",
    lockIdentity: "tarball:" & name & "@1:sha256:" & sha256,
    location: SourceLocation(file: "fixture", line: 2))]

proc hostElf(): string =
  ## A dynamically linked host executable, followed through symlinks.
  for name in ["true", "env", "ls"]:
    let exe = findExe(name)
    if exe.len > 0:
      let path = expandFilename(exe)
      if elfProgramInterpreter(path).len > 0:
        return path
  ""

suite "tarball executables the host cannot start":
  putEnv("REPRO_CACHE_DISABLE", "1")

  when defined(linux):
    test "the refusal is a distinct, inspectable error":
      let elf = hostElf()
      require elf.len > 0
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      var bytes = readFile(elf)
      let interp = elfProgramInterpreter(elf)
      let at = bytes.find(interp & "\0")
      require at > 0
      const Missing = "/nonexistent-loader/ld.so"
      for i in 0 ..< interp.len:
        bytes[at + i] = (if i < Missing.len: Missing[i] else: '\0')
      let payload = root / "generic-tool"
      writeFile(payload, bytes)
      check elfProgramInterpreter(payload) == Missing
      var loader = ""
      try:
        discard resolveTarballTool(
          rawUse(fileUrl(payload), sha256Hex(bytes), "generic-tool"),
          root / "store")
      except TarballHostLoaderMissing as e:
        loader = e.loader
      check loader == Missing

    test "PT_INTERP of a host binary is read, and a script has none":
      let elf = hostElf()
      require elf.len > 0
      let interp = elfProgramInterpreter(elf)
      check interp.startsWith("/")
      check fileExists(interp)
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      writeFile(root / "script", "#!/bin/sh\necho hi\n")
      check elfProgramInterpreter(root / "script") == ""

    test "a binary whose loader is missing is refused by name":
      let elf = hostElf()
      require elf.len > 0
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      var bytes = readFile(elf)
      # Located independently of the code under test: the loader path is
      # the run of path characters holding "/ld-linux" (the bytes before
      # PT_INTERP are header data, not a NUL, so walk back over path
      # characters rather than to a terminator).
      let marker = bytes.find("/ld-linux")
      require marker > 0
      var at = marker
      while at > 0 and bytes[at - 1] in {'a'..'z', 'A'..'Z', '0'..'9',
          '.', '_', '/', '+', '-'}:
        dec at
      while at < marker and bytes[at] != '/':
        inc at
      let interp = bytes[at ..< bytes.find('\0', marker)]
      require interp.startsWith("/")
      const Missing = "/nonexistent-loader/ld.so"
      require Missing.len <= interp.len
      for i in 0 ..< interp.len:
        bytes[at + i] = (if i < Missing.len: Missing[i] else: '\0')
      let payload = root / "generic-tool"
      writeFile(payload, bytes)
      var raised = false
      var message = ""
      try:
        discard resolveTarballTool(
          rawUse(fileUrl(payload), sha256Hex(bytes), "generic-tool"),
          root / "store")
      except OSError as e:
        raised = true
        message = e.msg
      check raised
      check Missing in message
      check "generic-tool" in message
      check "--tool-provisioning=nix" in message

    test "a binary whose loader exists resolves as before":
      let elf = hostElf()
      require elf.len > 0
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      let bytes = readFile(elf)
      let payload = root / "host-tool"
      writeFile(payload, bytes)
      let profile = resolveTarballTool(
        rawUse(fileUrl(payload), sha256Hex(bytes), "host-tool"),
        root / "store")
      check fileExists(profile.resolvedExecutablePath)
