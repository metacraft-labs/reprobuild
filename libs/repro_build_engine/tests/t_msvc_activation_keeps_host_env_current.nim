## A host variable that changes after the MSVC activation was captured reaches
## the next launch, and the action-cache key reads the new value.
##
## WHAT BROKE. On Windows the engine layers the host's MSVC developer
## environment (``activateMsvcDevEnv``, captured once per process) under every
## action that inherits the host's PATH (``actionUsesMsvcToolchain``). The
## layer used to be the activation shell's whole ``set`` dump, so every
## variable of the host was re-applied with the value it had at the first
## activation. ``actionEnvResolver`` composes the environment the same way the
## launch does, so the observed-environment key read the stale value too:
## measured on eli-pc at reprobuild ``agents`` ``9e78a755bd``, the profile
## compile edge was a cache hit after ``APPDATA`` changed, and ``nim`` (which
## reads ``%APPDATA%\nim\nim.cfg``) would have been given the old value had it
## run (reprobuild-pm issue
## 2026-11-15-windows-profile-compile-edge-is-not-invalidated-when-appdata-changes).
##
## WHAT IS ASSERTED, after the activation has been captured in this process:
##   1. the resolver the cache key is built from answers the host's CURRENT
##      ``APPDATA``, and a launched action receives it;
##   2. a directory added to the host's PATH after the activation reaches the
##      launched action, and on a host with Build Tools the toolchain's
##      ``bin\HostX64\x64`` is still on it.
## The values set here are fresh per run, so the assertions hold whichever
## earlier test in the same binary captured the activation first.
##
## Where it bites: Windows with Visual Studio Build Tools (eli-pc). Elsewhere
## there is no activation and the same assertions pin the plain inheritance
## the composition must reduce to.
##
## No mocks: the real ``runBuild``, a real ``sh`` subprocess (Git for
## Windows' on Windows), real files in a temporary directory, and the real
## VsDevCmd activation where the host has one.

import std/[os, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_hash
import repro_platform

proc shPath(): string = findExe("sh")

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

suite "MSVC activation keeps the host environment current":
  test "a host value changed after the activation reaches the launch and the key":
    let sh = shPath()
    # Git for Windows' sh on eli-pc, the system sh elsewhere: present on every
    # host this suite runs on. A host without one cannot launch the probe.
    require sh.len > 0
    let root = createTempDir("repro-msvc-host-env-", "")
    defer: removeDir(root)
    let work = root / "work"
    createDir(work / "out")

    # Capture the activation (a no-op off Windows) BEFORE the host changes.
    let devEnv = activateMsvcDevEnv()
    checkpoint("activation available: " & $devEnv.available)

    let savedAppData = (existsEnv("APPDATA"), getEnv("APPDATA"))
    let savedPath = getEnv("PATH")
    defer:
      if savedAppData[0]: putEnv("APPDATA", savedAppData[1])
      else: delEnv("APPDATA")
      putEnv("PATH", savedPath)
    let marker = "repro-msvc-host-" & $getCurrentProcessId() & "-" &
      $epochTime().int64
    let appData = root / marker / "Roaming"
    createDir(appData)
    putEnv("APPDATA", appData)
    let newDir = root / marker / "bin"
    createDir(newDir)
    putEnv("PATH", newDir & $PathSep & savedPath)

    let edge = action("msvc/host-env",
      [sh, "-c",
       "printf '%s\\n%s\\n' \"${APPDATA-<unset>}\" \"${PATH-<unset>}\" " &
         "> out/seen.txt"],
      cwd = work,
      outputs = ["out/seen.txt"],
      cacheable = false,
      weakFingerprint = weakFingerprintFromText("msvc-host-env.probe"),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    # Inherits the host PATH, so the activation is layered under it.
    check actionUsesMsvcToolchain(edge)

    var config = defaultBuildEngineConfig(root / "cache")
    config.bypassRunQuota = true
    # (1) the key's view: the resolver `cacheEnvInputs` reads values from.
    let resolved = actionEnvResolver(edge, addr config)("APPDATA")
    check resolved.present
    check resolved.value == appData

    let res = runBuild(graph([edge]), config)
    check res.byId("msvc/host-env").status == asSucceeded
    let seen = readFile(work / "out" / "seen.txt").splitLines()
    checkpoint("child saw: " & $seen)
    require seen.len >= 2
    # (1) the launch's view. Git-Bash leaves a non-PATH variable in its
    # Windows spelling, so this compares verbatim.
    check seen[0] == appData
    # (2) Git-Bash rewrites PATH entries to `/c/...`; the marker is unique.
    check seen[1].toLowerAscii().contains(marker.toLowerAscii() & "/bin")
    if devEnv.available:
      check seen[1].toLowerAscii().contains("/bin/hostx64/x64")
