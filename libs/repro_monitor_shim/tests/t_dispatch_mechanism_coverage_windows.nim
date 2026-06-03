# M73 Phase 2 — dispatch-mechanism coverage test.
#
# Acceptance gate for Phase 1's "single dispatch-mechanism-agnostic
# install backend" claim (reprobuild 2cfa1a7, 2026-06-04).
#
# Drives the shim end-to-end through the five known Windows dispatch
# mechanisms and asserts the depfile records exactly N matching events
# per mechanism. Loss tolerance: zero. See the milestone file
# `reprobuild-specs/Monitor-Hook-Shim.milestones.org` § "M73 Phase 2"
# for the full acceptance criteria.
#
# Mechanisms:
#   1. C statically-linked CreateFileW via __declspec(dllimport).
#   2. C runtime-resolved LoadLibraryW + GetProcAddress("CreateFileW").
#   3. Nim winlean `{.importc, stdcall, dynlib: "kernel32".}` createFileW
#      (the case that motivated M73 — nimGetProcAddr-cached function
#      pointer, IAT entirely bypassed).
#   4. Real-world Nim os.* caller landing on winlean dynlib-dispatch:
#      `os.fileExists` -> `winlean.getFileAttributesW` (load-bearing
#      verification of Nim 2.2.8 source done in
#      `tests/fixtures/fixture_mech4_os_module.nim`).
#   5. Fresh DLL LoadLibraryW'd post-shim-init that statically imports
#      CreateFileW.
#
# Per-mechanism record count must equal N EXACTLY. No tolerance
# bounds. No `check count > 0`. No skipping on any Windows version
# the rest of the dev-env suite runs on.
#
# Build dependencies: gcc (for the C fixtures) and Nim 2.2.8 (for
# the shim, fs-snoop, and Nim fixtures) — both are wired through
# scripts/run_tests.sh / run_tests_windows.ps1 on Windows hosts.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support

when defined(windows):
  import repro_monitor_depfile/types
  import repro_monitor_depfile/reader

  const
    # N=8 per mechanism: small enough that the test runs in seconds,
    # large enough that an off-by-one (e.g. the trampoline accidentally
    # double-records the call, or misses the first one before the
    # registry is ready) would surface as a non-zero delta from N. The
    # exact value isn't load-bearing — the strict-equality check is.
    N = 8

  # Fixture sources live under `libs/repro_monitor_shim/tests/fixtures/`.
  # Anchor on `currentSourcePath` so the test runs correctly regardless
  # of the test driver's working directory (run_tests_windows.ps1 sets
  # cwd to the repo root, but the test binary itself may be invoked
  # from elsewhere during development).
  let testDir = currentSourcePath().parentDir()
  let fixturesDir = testDir / "fixtures"

  proc compileGcc(sourcePath, outputPath: string;
                  extraArgs: openArray[string] = []) =
    ## Compile a C fixture with mingw-w64 gcc. Used for mechanisms
    ## 1, 2, and 5 (both the host exe and the DLL).
    ##
    ## The fixtures use `wmain` which mingw expects to be enabled via
    ## `-municode`. They also link against kernel32 by default, which
    ## mingw does automatically.
    var args = @[sourcePath, "-municode", "-o", outputPath]
    for a in extraArgs:
      args.add(a)
    # mingw's gcc is on PATH per scripts/run_tests_windows.ps1; the per-
    # job PATH inherits it. On standalone `nim c -r` runs from a dev
    # shell the same env applies.
    let res = runShell(shellCommand(@["gcc"] & args))
    if res.code != 0:
      checkpoint("gcc " & args.join(" ") & " failed:\n" & res.output)
    check res.code == 0

  proc compileNimExe(repoRoot, sourcePath, outputPath, cacheName: string) =
    ## Compile a Nim fixture into a standalone exe. Used for mechanisms
    ## 3 and 4. Distinct nimcache per fixture so parallel test runs
    ## don't contend on the same IR directory.
    let args = @[
      "nim", "c", "--threads:on", "--verbosity:0", "--hints:off",
      "--warnings:off",
      "--nimcache:" & repoRoot / "build" / "nimcache" / cacheName,
      "--out:" & outputPath,
      sourcePath
    ]
    discard requireSuccess(shellCommand(args), repoRoot)

  proc matchingFileOpenRecords(records: openArray[MonitorRecord];
                               marker: string): int =
    ## Count mrFileOpen records whose path contains the per-mechanism
    ## unique marker substring. The marker is a random temp-dir name so
    ## it cannot accidentally match a sibling mechanism's depfile entries
    ## (the test runs each mechanism in its own temp dir AND each
    ## mechanism gets a separate fs-snoop invocation that writes its own
    ## depfile, so the cross-talk surface is doubly closed).
    result = 0
    for r in records:
      if r.kind == mrFileOpen and marker in r.path:
        inc result

  proc matchingPathProbeRecords(records: openArray[MonitorRecord];
                                marker: string): int =
    ## Count mrPathProbe records whose path contains the marker. Used by
    ## mechanism 4 (os.fileExists -> winlean.getFileAttributesW emits a
    ## mrPathProbe per call).
    result = 0
    for r in records:
      if r.kind == mrPathProbe and marker in r.path:
        inc result

  proc runUnderFsSnoop(fsSnoop, depFilePath: string;
                       command: openArray[string]): CmdResult =
    ## Invoke repro-fs-snoop with the requested command, writing the
    ## depfile to `depFilePath`. fs-snoop's Windows arm sets
    ## REPRO_MONITOR_FRAGMENT_DIR / REPRO_MONITOR_OUTPUT etc. internally
    ## and merges fragments into the canonical RMDF at exit.
    ##
    ## We thread the shim DLL path via REPRO_MONITOR_SHIM_LIB; that's
    ## the explicit env override fs-snoop's findShimLibrary honours.
    ## Without it fs-snoop would look in `build/lib/` which the test's
    ## per-suite cache doesn't populate.
    let args = @[fsSnoop, "--depfile=" & depFilePath, "--"] & @command
    runShell(shellCommand(args))

suite "dispatch-mechanism coverage M73 Phase 2":
  when not defined(windows):
    test "skip non-windows":
      # The whole acceptance gate is Windows-specific (it tests Windows
      # dispatch mechanisms). On Linux/macOS the suite is a no-op so
      # the per-OS test runner stays green. We do NOT use
      # `when defined(...)` to silence the test on Windows itself —
      # that's the anti-pattern the orchestrator explicitly bans.
      skip()
  else:
    # All five mechanism tests share the same compiled shim DLL +
    # fs-snoop exe. Compile them once (lazily on first use) and stash
    # the paths in module-level vars. `prepareMonitorTools` is the
    # same helper the e2e dev-env tests use; cache key
    # "m73-phase2-dispatch" gives us our own nimcache so concurrent
    # suites don't stomp our IR.
    let repoRoot = getCurrentDir()
    let tempRoot = createTempDir("repro-m73-phase2", "")
    # NB: we do NOT `defer: removeDir(tempRoot)` at module scope — Nim
    # doesn't honour module-scope defer for test binaries the way it
    # does inside proc scopes. The OS reclaims the tree on next reboot
    # or via the user's normal temp-cleanup; we choose to leave it so
    # a failing run leaves the depfile around for post-mortem.
    let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
                                      "m73-phase2-dispatch")
    let fsSnoop = monitor.fsSnoop
    let shimLib = monitor.shim
    # Make the shim discoverable to fs-snoop. fs-snoop's
    # `findShimLibrary` honours REPRO_MONITOR_SHIM_LIB before its
    # build/lib/ fallback; setting it here covers both the in-process
    # CLI helper and any spawn-as-child invocation.
    putEnv("REPRO_MONITOR_SHIM_LIB", shimLib)

    proc runMechanism(mechanismName, marker: string;
                      command: openArray[string]): seq[MonitorRecord] =
      ## Run `command` (the fixture + its args) under fs-snoop with a
      ## per-mechanism depfile path. Returns the recorded events so
      ## the caller can apply the mechanism-specific count assertion.
      let depPath = tempRoot / (mechanismName & ".rdep")
      let res = runUnderFsSnoop(fsSnoop, depPath, command)
      if res.code != 0:
        checkpoint(mechanismName & " fs-snoop run failed (rc=" &
          $res.code & "):\n" & res.output)
      check res.code == 0
      check fileExists(depPath)
      let dep = readMonitorDepFile(depPath)
      dep.records

    # ----------------------------------------------------------------
    # Mechanism 1 — __declspec(dllimport) IAT-routed.
    # ----------------------------------------------------------------
    test "mechanism 1: __declspec(dllimport) IAT-routed CreateFileW":
      let fixtureSrc = fixturesDir / "fixture_mech1_iat.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech1.exe"
      compileGcc(fixtureSrc, exePath)
      let workDir = tempRoot / "mech1-work"
      createDir(workDir)
      # Marker = an absolute path inside the per-mechanism workDir,
      # so the file basename is unique enough that it cannot collide
      # with a sibling mechanism's recorded paths. We use an absolute
      # path so fs-snoop's recorded paths contain the exact substring
      # regardless of how the shim resolves them.
      let marker = workDir / "mech1-marker"
      let records = runMechanism("mech1", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech1-marker")
      if got != N:
        checkpoint("mech1 records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 2)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 2 — LoadLibrary + GetProcAddress runtime-resolved.
    # ----------------------------------------------------------------
    test "mechanism 2: LoadLibraryW+GetProcAddress runtime-resolved CreateFileW":
      let fixtureSrc = fixturesDir / "fixture_mech2_getproc.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech2.exe"
      compileGcc(fixtureSrc, exePath)
      let workDir = tempRoot / "mech2-work"
      createDir(workDir)
      let marker = workDir / "mech2-marker"
      let records = runMechanism("mech2", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech2-marker")
      if got != N:
        checkpoint("mech2 records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 2)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 3 — Nim winlean dynlib-dispatched createFileW.
    # ----------------------------------------------------------------
    test "mechanism 3: Nim winlean.createFileW dynlib-dispatched":
      let fixtureSrc = fixturesDir / "fixture_mech3_winlean.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech3.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase2-mech3")
      let workDir = tempRoot / "mech3-work"
      createDir(workDir)
      let marker = workDir / "mech3-marker"
      let records = runMechanism("mech3", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech3-marker")
      if got != N:
        checkpoint("mech3 records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 2." &
          " Mechanism 3 is the load-bearing winlean dynlib dispatch" &
          " case the milestone exists to catch.)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 4 — Nim os.fileExists -> winlean.getFileAttributesW.
    # ----------------------------------------------------------------
    test "mechanism 4: os.fileExists -> winlean.getFileAttributesW":
      let fixtureSrc = fixturesDir / "fixture_mech4_os_module.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech4.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase2-mech4")
      let workDir = tempRoot / "mech4-work"
      createDir(workDir)
      let marker = workDir / "mech4-marker"
      let records = runMechanism("mech4", marker,
                                 @[exePath, marker, $N])
      let got = matchingPathProbeRecords(records, "mech4-marker")
      if got != N:
        checkpoint("mech4 records: " & $got &
          " (expected exactly " & $N &
          " mrPathProbe records — loss tolerance zero per M73 Phase 2." &
          " Mechanism 4 verifies real-world os.* callers reach the" &
          " shim via the winlean dynlib path.)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 5 — Fresh DLL LoadLibraryW'd post-shim-init.
    # ----------------------------------------------------------------
    test "mechanism 5: late-loaded DLL with __declspec(dllimport) CreateFileW":
      let dllSrc = fixturesDir / "fixture_mech5_late_dll.c"
      let mainSrc = fixturesDir / "fixture_mech5_main.c"
      doAssert fileExists(dllSrc), "missing fixture: " & dllSrc
      doAssert fileExists(mainSrc), "missing fixture: " & mainSrc
      let dllPath = tempRoot / "mech5-late.dll"
      let exePath = tempRoot / "mech5.exe"
      compileGcc(dllSrc, dllPath, @["-shared"])
      compileGcc(mainSrc, exePath)
      let workDir = tempRoot / "mech5-work"
      createDir(workDir)
      let marker = workDir / "mech5-marker"
      # The host exe takes the DLL path as its first arg, then the
      # marker + count for the late-DLL wrapper. fs-snoop sees the
      # marker substring on every CreateFileW the late DLL makes.
      let records = runMechanism("mech5", marker,
                                 @[exePath, dllPath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech5-marker")
      if got != N:
        checkpoint("mech5 records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 2." &
          " Mechanism 5 exercises the post-init-LoadLibraryW IAT" &
          " surface that the inline detour at kernel32 catches via" &
          " loader-resolved IAT slots.)")
      check got == N
