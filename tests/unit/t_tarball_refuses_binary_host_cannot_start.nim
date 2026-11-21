## A tarball-provisioned executable whose dynamic loader the host lacks is
## refused at resolution, by name, instead of failing later with exit 127.
##
## THE DEFECT. Path-mode provisioning falls back to a package's tarball when
## the tool is not on PATH. The stdlib `cargo` package's Linux tarball is
## the generic `x86_64-unknown-linux-gnu` Rust distribution, whose binaries
## ask the kernel for `/lib64/ld-linux-x86-64.so.2`. NixOS has no such
## file (or, since 24.05, a stub that refuses every program), so on a NixOS
## runner the tarball realized "successfully" and the
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
##   * it raises the same refusal when the loader EXISTS but refuses to
##     start the executable -- `<loader> --verify <exe>` exits 127, which is
##     what NixOS's stub-ld at `/lib64/ld-linux-x86-64.so.2` does
##     (reprobuild-pm/issues/
##     2026-09-28-tarball-realized-linux-executables-cannot-start-on-nixos.md:
##     a file-existence check passed there and realization reported a
##     python3 that could only exit 127). The refusal quotes the loader's
##     answer and carries the realized prefix;
##   * a loader that never answers the probe is killed after the probe
##     timeout and reported as a refusal, so realization cannot hang on it;
##   * a binary whose loader exists and accepts it resolves exactly as
##     before.
##
## THE FIXTURE is a real host ELF (`true`) copied and edited in exactly one
## place: its PT_INTERP string is overwritten with a path that does not
## exist (NUL-padded, never longer than the original). That is precisely the
## condition a generic-Linux binary meets on NixOS, reproduced on any Linux
## host. No mocks: the real realize path over `file://`, archiveType "raw".
##
## The refusing-loader cases use a SYNTHESIZED ELF (header plus one
## PT_INTERP program header) so the loader path may be any length, and a
## shell script as the loader: one that prints the stub-ld text and exits
## 127, and a positive control that exits 0. The script stands in for
## stub-ld because the behaviour under test is the realizer's reading of the
## loader's answer, and a real stub-ld exists only on NixOS hosts.
##
## Linux only (PT_INTERP is an ELF notion; the guard is Linux-gated).

import std/[os, strutils, tempfiles, times, unittest]

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

const StubLdSignature =
  "NixOS cannot run dynamically linked executables intended for generic"

const StubLdText =
  "Could not start dynamically linked executable: $0\n" &
  StubLdSignature & "\nlinux environments out of the box. For more " &
  "information, see:\nhttps://nix.dev/permalink/stub-ld\n"

proc writeLoaderScript(path, message: string; exitCode: int): string =
  ## A stand-in dynamic loader: a shell script that prints ``message`` and
  ## exits ``exitCode`` whatever it is asked. With the NixOS stub-ld text and
  ## 127 it behaves as stub-ld does (https://nix.dev/permalink/stub-ld).
  ## The kernel would not accept a script as PT_INTERP, but nothing here
  ## starts the fixture: the realizer only PROBES the loader, by running it.
  var body = "#!/bin/sh\n"
  if message.len > 0:
    body.add("cat >&2 <<'STUB'\n" & message & "STUB\n")
  body.add("exit " & $exitCode & "\n")
  writeFile(path, body)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  path

proc synthesizedElf(interp: string): string =
  ## A minimal little-endian ELF64 executable carrying one program header,
  ## ``PT_INTERP`` = ``interp``, laid out per the System V gABI
  ## (https://refspecs.linuxbase.org/elf/gabi4+/ch5.pheader.html). It is
  ## never run, so it needs no code; building it rather than editing a
  ## host binary puts no limit on the length of ``interp``.
  proc put(s: var string; at, width: int; value: int) =
    for i in 0 ..< width:
      s[at + i] = char((value shr (8 * i)) and 0xff)
  const HeaderSize = 64
  const PhdrSize = 56
  let interpAt = HeaderSize + PhdrSize
  result = newString(interpAt + interp.len + 1)
  result[0 .. 3] = "\x7FELF"
  result[4] = char(2)          # ELFCLASS64
  result[5] = char(1)          # ELFDATA2LSB
  result[6] = char(1)          # EV_CURRENT
  result.put(16, 2, 2)         # e_type = ET_EXEC
  result.put(18, 2, 0x3e)      # e_machine = EM_X86_64
  result.put(20, 4, 1)         # e_version
  result.put(32, 8, HeaderSize) # e_phoff
  result.put(52, 2, HeaderSize) # e_ehsize
  result.put(54, 2, PhdrSize)  # e_phentsize
  result.put(56, 2, 1)         # e_phnum
  let ph = HeaderSize
  result.put(ph, 4, 3)         # p_type = PT_INTERP
  result.put(ph + 4, 4, 4)     # p_flags = PF_R
  result.put(ph + 8, 8, interpAt) # p_offset
  result.put(ph + 16, 8, interpAt) # p_vaddr
  result.put(ph + 24, 8, interpAt) # p_paddr
  result.put(ph + 32, 8, interp.len + 1) # p_filesz
  result.put(ph + 40, 8, interp.len + 1) # p_memsz
  result.put(ph + 48, 8, 1)    # p_align
  for i, c in interp:
    result[interpAt + i] = c

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

    test "a binary whose loader exists but refuses is refused by name":
      # NixOS's stub-ld: the FHS loader path exists, so a file-existence
      # check passes, and every program it is asked to start fails with
      # exit 127. Before the probe, realization reported this tool usable.
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      let loader = writeLoaderScript(root / "stub-ld", StubLdText, 127)
      let bytes = synthesizedElf(loader)
      let payload = root / "generic-tool"
      writeFile(payload, bytes)
      require elfProgramInterpreter(payload) == loader
      check hostLoaderRefusal(payload).reason.len > 0
      var raised = false
      var err: ref TarballHostLoaderMissing
      try:
        discard resolveTarballTool(
          rawUse(fileUrl(payload), sha256Hex(bytes), "generic-tool"),
          root / "store")
      except TarballHostLoaderMissing as e:
        raised = true
        err = e
      require raised
      check err.loader == loader
      check loader in err.msg
      check "generic-tool" in err.msg
      check "exited 127" in err.msg
      check "Could not start dynamically linked executable" in err.msg
      check "--tool-provisioning=nix" in err.msg
      check StubLdSignature in err.probeOutput
      # The bytes were realized; only the host cannot run them, so the
      # refusal still points at the sealed prefix.
      check err.prefix.len > 0
      check dirExists(err.prefix)
      check err.executable.startsWith(err.prefix)
      check fileExists(err.executable)
      # A loader that exists but cannot be executed at all (here: no execute
      # permission; on a real host, an ELF for another architecture) is a
      # refusal too -- the shell running the probe answers 126.
      let unrunnable = root / "unrunnable"
      createDir(unrunnable)
      let deadLoader = writeLoaderScript(unrunnable / "ld", "", 0)
      setFilePermissions(deadLoader, {fpUserRead, fpUserWrite})
      let deadPayload = unrunnable / "generic-tool"
      writeFile(deadPayload, synthesizedElf(deadLoader))
      check hostLoaderRefusal(deadPayload).reason.len > 0

    test "a binary whose existing loader accepts it resolves":
      # Positive control for the probe above: the same synthesized ELF,
      # with a loader that answers `--verify` with 0, is not refused. So the
      # refusal is decided by the loader's answer, not by the fixture shape.
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      let loader = writeLoaderScript(root / "accepting-ld", "", 0)
      let bytes = synthesizedElf(loader)
      let payload = root / "generic-tool"
      writeFile(payload, bytes)
      require elfProgramInterpreter(payload) == loader
      check hostLoaderRefusal(payload).reason.len == 0
      # A real glibc ld.so answers `--verify` with 1 (static or not
      # loadable) or 2 (a dynamic object with no interpreter), and musl's
      # loader exits 1 on an option it does not know. None of those is a
      # refusal.
      for answer in [1, 2]:
        let other = root / ("answers-" & $answer)
        createDir(other)
        let otherLoader = writeLoaderScript(other / "ld", "usage\n", answer)
        let otherPayload = other / "generic-tool"
        writeFile(otherPayload, synthesizedElf(otherLoader))
        check hostLoaderRefusal(otherPayload).reason.len == 0
      let profile = resolveTarballTool(
        rawUse(fileUrl(payload), sha256Hex(bytes), "generic-tool"),
        root / "store")
      check fileExists(profile.resolvedExecutablePath)

    test "a loader that does not answer is refused, not waited on":
      # PT_INTERP is whatever path the archive names, so the probe is
      # bounded: a loader that never answers `--verify` is killed after
      # `probeTimeoutSeconds` and reported, rather than hanging realization.
      let root = createTempDir("repro-interp-", "")
      defer: removeDir(root)
      let loader = root / "hanging-ld"
      writeFile(loader, "#!/bin/sh\nsleep " & $(probeTimeoutSeconds * 6) &
        "\n")
      setFilePermissions(loader, {fpUserRead, fpUserWrite, fpUserExec})
      let payload = root / "generic-tool"
      writeFile(payload, synthesizedElf(loader))
      let started = epochTime()
      let refusal = hostLoaderRefusal(payload)
      let elapsed = epochTime() - started
      check refusal.loader == loader
      check "does not answer" in refusal.reason
      check elapsed < float(probeTimeoutSeconds * 3)
