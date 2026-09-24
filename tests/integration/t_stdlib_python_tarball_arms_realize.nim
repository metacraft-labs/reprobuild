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

        let run = runShell(shellCommand([invoked, "-c",
          "import sys, json; " &
          "print('%d.%d' % sys.version_info[:2]); " &
          "print(json.dumps({'ok': True}))"]))
        check run.code == 0
        check run.output.contains("3.12")
        check run.output.contains("{\"ok\": true}")
        if run.code != 0:
          echo run.output

  try: removeDir(tempRoot) except CatchableError: discard
