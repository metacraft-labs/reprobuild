## The stdlib ``python3`` and ``python-dev`` tarball arms realize on this host.
##
## Both recipes pin the same python-build-standalone ``install_only`` archives
## on Linux x86_64 and macOS aarch64. In those archives ``python/bin/python3``
## is a relative SYMLINK to ``python3.12``, and tarball realization refuses a
## declared executable reached through a symlink. The recipes used to declare
## ``python/bin/python3``, so tarball provisioning downloaded and verified the
## archive, then failed with "extracted tarball lacks executable
## python/bin/python3" and left ``python3`` to the ambient PATH.
##
## Nothing caught that because every existing catalog check reads the recipe
## TEXT (the M29 audit, the per-catalog smoke tests). A declared layout is a
## claim about bytes nobody had extracted. This test extracts them.
##
## What is asserted, per package, for the arm this host selects:
##
##   * the real recipe declaration (not a copy of it) realizes through the
##     same ``resolveTarballTool`` path ``repro`` uses, into a fresh store;
##   * the resolved executable is inside the sealed prefix and is a regular
##     file, matching the realizer's no-symlink rule;
##   * on POSIX, ``python3`` — the name consumers invoke — is present in the
##     directory the profile puts on PATH;
##   * running that ``python3`` reports 3.12 and can import from its own
##     standard library, so the prefix is a working interpreter and not
##     merely a file with the right name.
##
## A profile is a claim that the tool RUNS on this host, so the interpreter is
## run directly, as a consumer would, with no loader substituted. On a host
## whose dynamic loader cannot start a generic-Linux executable -- NixOS,
## whose FHS loader path holds a stub that refuses with exit 127 -- realization
## must instead refuse with ``TarballHostLoaderMissing``
## (reprobuild-pm/issues/
## 2026-09-28-tarball-realized-linux-executables-cannot-start-on-nixos.md:
## it used to return a profile whose ``python3`` could only exit 127). That
## refusal is checked for truth both ways: the realized interpreter really
## cannot be started directly, and the archive bytes it points at are still a
## working 3.12 when run through the glibc loader this test binary was linked
## against -- so the bytes are verified on that host too.
##
## No mocks. This is a network test: it downloads the upstream archive the
## recipe pins (once — both packages share it, and the store's download cache
## is keyed by digest). On a host with no matching arm (e.g. Linux aarch64)
## the test says so and checks nothing, rather than passing vacuously on a
## different code path.
##
## Falsifiable: restore ``executablePath = "python/bin/python3"`` on either
## recipe and ``resolveTarballTool`` refuses on Linux x86_64 and macOS
## aarch64 with "extracted tarball declares executable python/bin/python3,
## which is present but reached through a symlink (python/bin/python3 ->
## python3.12)". That refusal used to read "extracted tarball lacks
## executable python/bin/python3", which is what sent a reader looking for a
## file the archive contains; the two cases are distinguished now.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support/reasoned_skip

import repro_project_dsl
import repro_interface_artifacts
import repro_tool_profiles
import repro_test_support
import repro_dsl_stdlib/packages/python3
import repro_dsl_stdlib/packages/python_dev

const HostHasPinnedArm =
  (defined(linux) and defined(amd64)) or
  (defined(macosx) and defined(arm64)) or
  (defined(windows) and defined(amd64))

proc pythonToolUse(packageName: string): InterfaceToolUse =
  ## The tool use a consumer declaring ``uses: "<packageName>"`` gets, built
  ## from the registered stdlib package so the tarball arms under test are
  ## the recipe's own.
  let iface = toProjectInterface(PackageDef(
    packageName: "pythonTarballConsumer",
    nativeBuildDeps: @[PackageUseDef(
      rawConstraint: packageName, packageSelector: packageName,
      executableName: "python3", depKind: "native")]), registeredPackages())
  doAssert iface.toolUses.len == 1,
    "expected one tool use for " & packageName
  iface.toolUses[0]

proc selfElfInterpreter(): string =
  ## The PT_INTERP of this test binary (little-endian ELF64 only, which is
  ## every host with a pinned Linux arm), or "" when it cannot be read.
  try:
    let data = readFile("/proc/self/exe")
    if data.len < 64 or data[0 .. 3] != "\x7FELF" or data[4] != '\x02' or
        data[5] != '\x01':
      return ""
    proc u16(at: int): int = ord(data[at]) or (ord(data[at + 1]) shl 8)
    proc u64(at: int): int =
      for i in countdown(7, 0):
        result = (result shl 8) or ord(data[at + i])
    let phoff = u64(0x20)
    let phentsize = u16(0x36)
    let phnum = u16(0x38)
    for i in 0 ..< phnum:
      let ph = phoff + i * phentsize
      if ph + 56 > data.len:
        return ""
      if u16(ph) == 3 and u16(ph + 2) == 0:  # p_type == PT_INTERP
        let off = u64(ph + 8)
        let size = u64(ph + 32)
        if off + size > data.len or size == 0:
          return ""
        return data[off ..< off + size].strip(leading = false,
          chars = {'\0'})
  except CatchableError:
    discard
  ""

proc isRegularFile(path: string): bool =
  getFileInfo(path, followSymlink = false).kind == pcFile

suite "stdlib python tarball arms realize":
  # Publishing is irrelevant here and would need credentials plus a reachable
  # endpoint; disable the shared cache so the realize is local and the bytes
  # come from upstream.
  putEnv("REPRO_CACHE_DISABLE", "1")

  let tempRoot = createTempDir("repro-python-arms-", "")
  let storeRoot = tempRoot / "store"

  for packageName in ["python3", "python-dev"]:
    test packageName & ": the host arm's declared executable is realizable":
      when not HostHasPinnedArm:
        skip("no " & packageName & " tarball arm is pinned for this host " &
          "(" & hostOs & "/" & hostCpu & "); there are no bytes to realize")
      else:
        let useDef = pythonToolUse(packageName)
        require useDef.tarballProvisioning.len > 0

        let probe = "import sys, json; " &
          "print('%d.%d' % sys.version_info[:2]); " &
          "print(json.dumps({'ok': True}))"

        var profile: PathOnlyToolProfile
        var refused = false
        try:
          profile = resolveTarballTool(useDef, storeRoot)
        except TarballHostLoaderMissing as e:
          when defined(linux):
            # This host's loader cannot start the generic-Linux interpreter
            # (NixOS's stub-ld). The refusal is the contract there; check
            # that it is TRUE, then still verify the realized bytes.
            refused = true
            checkpoint("realization refused on this host: " & e.msg)
            check e.loader.len > 0
            check e.prefix.len > 0
            check e.executable.startsWith(e.prefix)
            check isRegularFile(e.executable)
            # Truthful: started directly, the realized interpreter cannot
            # start -- 127, stub-ld's answer and the shell's when the kernel
            # finds no loader -- rather than failing in some other way.
            let direct = runShell(shellCommand([e.executable, "-c", probe]))
            checkpoint("started directly: " & direct.output)
            check direct.code == 127
            # The bytes are a working interpreter all the same, through the
            # glibc loader this test binary itself was linked against.
            let loader = selfElfInterpreter()
            require loader.len > 0 and fileExists(loader)
            let viaLoader = runShell(shellCommand(
              [loader, e.executable, "-c", probe]))
            check viaLoader.code == 0
            check viaLoader.output.contains("3.12")
            check viaLoader.output.contains("{\"ok\": true}")
            if viaLoader.code != 0:
              echo viaLoader.output
          else:
            raise

        if not refused:
          let prefix = profile.selectedStorePath
          let exe = profile.resolvedExecutablePath

          check profile.installMethod == "tarball"
          check exe.startsWith(prefix)
          check fileExists(exe)
          check isRegularFile(exe)
          require profile.pathSearchList.len > 0

          let invoked =
            when defined(windows): exe
            else: profile.pathSearchList[0] / "python3"
          check fileExists(invoked)

          # A returned profile claims the tool runs HERE: run it directly,
          # with no loader substituted.
          let run = runShell(shellCommand([invoked, "-c", probe]))
          check run.code == 0
          check run.output.contains("3.12")
          check run.output.contains("{\"ok\": true}")
          if run.code != 0:
            echo run.output

  try: removeDir(tempRoot) except CatchableError: discard
