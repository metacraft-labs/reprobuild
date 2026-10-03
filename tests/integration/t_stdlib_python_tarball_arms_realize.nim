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
## On a NixOS host the last step needs one accommodation: NixOS cannot start
## a generic-Linux dynamically linked executable directly (its FHS loader path
## holds a stub that refuses, exit 127), so there -- and only on that exact
## refusal -- the interpreter is run through the glibc loader this test binary
## was linked against. The prefix is still what is being tested.
##
## No mocks. This is a network test: it downloads the upstream archive the
## recipe pins (once — both packages share it, and the store's download cache
## is keyed by digest). On a host with no matching arm (e.g. Linux aarch64)
## the test says so and checks nothing, rather than passing vacuously on a
## different code path.
##
## Falsifiable: restore ``executablePath = "python/bin/python3"`` on either
## recipe and ``resolveTarballTool`` raises "extracted tarball lacks
## executable python/bin/python3" on Linux x86_64 and macOS aarch64.

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

const NixosStubLdSignature =
  "NixOS cannot run dynamically linked executables intended for generic"

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

        let profile = resolveTarballTool(useDef, storeRoot)
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

        let probe = "import sys, json; " &
          "print('%d.%d' % sys.version_info[:2]); " &
          "print(json.dumps({'ok': True}))"
        var run = runShell(shellCommand([invoked, "-c", probe]))
        when defined(linux):
          if run.code == 127 and NixosStubLdSignature in run.output:
            # This host cannot start ANY generic-Linux dynamically linked
            # executable directly: NixOS installs a stub at the FHS loader
            # path that prints the signature above and exits 127. That is a
            # property of the host, not of the prefix under test, so the
            # prefix is run through the glibc loader this test binary was
            # itself linked against -- which still exercises everything this
            # case is about (the interpreter starts, reports 3.12, imports
            # from its own stdlib). Nothing else is excused: any other 127,
            # or a loader that cannot be found, fails below.
            let loader = selfElfInterpreter()
            checkpoint("NixOS stub loader refused " & invoked &
              "; re-running through " & loader)
            require loader.len > 0 and fileExists(loader)
            run = runShell(shellCommand([loader, invoked, "-c", probe]))
        check run.code == 0
        check run.output.contains("3.12")
        check run.output.contains("{\"ok\": true}")
        if run.code != 0:
          echo run.output

  try: removeDir(tempRoot) except CatchableError: discard
