# M73 Phase 2 + Phase 3 — dispatch-mechanism coverage test.
#
# Phase 2 (reprobuild 09f6c66, 2026-06-04): acceptance gate for Phase 1's
# "single dispatch-mechanism-agnostic install backend" claim. Drives the
# shim through the five Windows W-variant dispatch mechanisms and asserts
# the depfile records exactly N matching events per mechanism.
#
# Phase 3 (2026-06-04): adds A-variant parallel cases proving the Phase 1
# install path catches the A-variant kernel32 entry points
# (HookCreateFileA, HookGetFileAttributes(Ex)A, HookCreateProcessA) that
# the hookTable already wired but which had no end-to-end test until now.
# Records observed for both W and A paths; per-mechanism count parity.
#
# Loss tolerance: zero. See the milestone file
# `reprobuild-specs/Monitor-Hook-Shim.milestones.org` § "M73 Phase 2" and
# § "M73 Phase 3" for the full acceptance criteria.
#
# Mechanisms (W variants, Phase 2):
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
# Mechanisms (A variants, Phase 3):
#   1A. C statically-linked CreateFileA via __declspec(dllimport).
#   2A. C runtime-resolved LoadLibraryW + GetProcAddress("CreateFileA").
#   3A. Nim winlean `{.importc, stdcall, dynlib: "kernel32".}` createFileA
#       (winlean.createFileA exists in Nim 2.2.8 with the same dynlib
#       lowering as createFileW — verified at
#       `lib/windows/winlean.nim:659`).
#   4A. SKIPPED with documented reasoning: Nim 2.2.8's `os.*` module
#       reaches ONLY W-variant kernel32 functions on Windows (e.g.
#       `os.fileExists` -> `winlean.getFileAttributesW`,
#       `os.removeFile` -> `winlean.deleteFileW`). There is no os.*
#       proc that lands on an A-variant in Nim 2.2.8; the mechanism's
#       defining property — a real-world idiomatic os.* caller — does
#       not exist for the ANSI surface. We honour the milestone spirit
#       by documenting the gap rather than fabricating a fixture that
#       only duplicates mechanism 3A's dispatch path on a different
#       API. Phase 5 will revisit if a real os.* A-variant caller
#       appears as the hookTable grows.
#   5A. Fresh DLL LoadLibraryW'd post-shim-init that statically imports
#       CreateFileA.
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
                  extraArgs: openArray[string] = [];
                  unicodeMain: bool = true) =
    ## Compile a C fixture with mingw-w64 gcc. Used for mechanisms
    ## 1, 2, and 5 (both the host exe and the DLL).
    ##
    ## The W-variant fixtures use `wmain` which mingw expects to be enabled
    ## via `-municode`. The A-variant fixtures (Phase 3 mechanisms 1A, 2A)
    ## use plain `main(int argc, char **argv)` so they need the default
    ## entry point — pass `unicodeMain = false` for those. The mech5A
    ## host (fixture_mech5_main_a.c) is wmain because the marker travels
    ## as a wchar_t through the host before the DLL narrows it; the late-
    ## loaded DLL itself (fixture_mech5_late_dll_a.c) is compiled as a
    ## shared library and has no `main`, so `-municode` is a no-op there
    ## but harmless.
    ##
    ## They also link against kernel32 by default, which mingw does
    ## automatically.
    var args = @[sourcePath]
    if unicodeMain:
      args.add("-municode")
    args.add("-o")
    args.add(outputPath)
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

suite "dispatch-mechanism coverage M73 Phase 2 + Phase 3":
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

    # ================================================================
    # M73 Phase 3 — A-variant parallel cases.
    #
    # Phase 1 wired HookCreateFileA into the hookTable (windows_interpose.nim
    # line ~1416) with its own trampoline + snoopCreateFileA callback. The
    # snoop emits mrFileOpen records with `detail = "CreateFileA"` and the
    # ANSI path string verbatim. The W-variant test above covers the install
    # mechanics; this Phase 3 block covers the A-variant entry-point
    # surface end-to-end, proving the hookTable's A-variant entries land at
    # kernel32's ANSI function bodies the same way they land at the W ones.
    #
    # All four A-variant cases use mrFileOpen records (CreateFileA-class);
    # mechanism 4A is documented-skipped (see header comment above).
    # ================================================================

    # ----------------------------------------------------------------
    # Mechanism 1A — __declspec(dllimport) IAT-routed CreateFileA.
    # ----------------------------------------------------------------
    test "mechanism 1A: __declspec(dllimport) IAT-routed CreateFileA":
      let fixtureSrc = fixturesDir / "fixture_mech1_iat_a.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech1a.exe"
      # ANSI fixture uses plain `main`, not `wmain`; do NOT pass -municode
      # (which would force mingw's wWinMain-required entry layout).
      compileGcc(fixtureSrc, exePath, unicodeMain = false)
      let workDir = tempRoot / "mech1a-work"
      createDir(workDir)
      let marker = workDir / "mech1a-marker"
      let records = runMechanism("mech1a", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech1a-marker")
      if got != N:
        checkpoint("mech1a records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 3." &
          " Mechanism 1A verifies the HookCreateFileA hookTable entry's" &
          " inline install catches __declspec(dllimport) IAT-routed" &
          " ANSI calls.)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 2A — LoadLibrary + GetProcAddress runtime-resolved
    # CreateFileA.
    # ----------------------------------------------------------------
    test "mechanism 2A: LoadLibraryW+GetProcAddress runtime-resolved CreateFileA":
      let fixtureSrc = fixturesDir / "fixture_mech2_getproc_a.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech2a.exe"
      # ANSI fixture uses plain `main`, not `wmain`; skip -municode.
      compileGcc(fixtureSrc, exePath, unicodeMain = false)
      let workDir = tempRoot / "mech2a-work"
      createDir(workDir)
      let marker = workDir / "mech2a-marker"
      let records = runMechanism("mech2a", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech2a-marker")
      if got != N:
        checkpoint("mech2a records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 3." &
          " Mechanism 2A verifies the HookCreateFileA inline install" &
          " catches the cached-function-pointer dispatch typical of" &
          " runtime-resolved ANSI APIs.)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 3A — Nim winlean.createFileA dynlib-dispatched.
    # ----------------------------------------------------------------
    test "mechanism 3A: Nim winlean.createFileA dynlib-dispatched":
      let fixtureSrc = fixturesDir / "fixture_mech3_winlean_a.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech3a.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase3-mech3a")
      let workDir = tempRoot / "mech3a-work"
      createDir(workDir)
      let marker = workDir / "mech3a-marker"
      let records = runMechanism("mech3a", marker,
                                 @[exePath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech3a-marker")
      if got != N:
        checkpoint("mech3a records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 3." &
          " Mechanism 3A is the load-bearing A-variant winlean dynlib" &
          " dispatch case: HookCreateFileA's inline detour at kernel32's" &
          " ANSI function body MUST catch nimGetProcAddr-cached pointer" &
          " calls the same way HookCreateFileW does for the W form.)")
      check got == N

    # ----------------------------------------------------------------
    # Mechanism 4A — SKIPPED (no os.* lands on A-variant in Nim 2.2.8).
    #
    # See the header comment for the full reasoning: Nim's `os` module
    # uses W-variant kernel32 entry points exclusively on Windows
    # (`os.fileExists` -> `winlean.getFileAttributesW`,
    #  `os.removeFile`  -> `winlean.deleteFileW`,
    #  `os.copyFile`    -> `winlean.copyFileW`, etc.).
    # There is no Nim 2.2.8 `os.*` proc whose underlying call lands on
    # a CreateFileA / GetFileAttributesA / DeleteFileA etc. — the
    # mechanism's defining property (an idiomatic real-world `os.*`
    # caller) does not exist for the ANSI surface. The honest signal
    # is a documented skip, not a fabricated fixture that just
    # duplicates mechanism 3A on a different A-variant API.
    # ----------------------------------------------------------------
    test "mechanism 4A: os.* -> winlean ANSI dispatch (skipped)":
      skip()

    # ----------------------------------------------------------------
    # Mechanism 5A — Fresh DLL LoadLibraryW'd post-shim-init that
    # statically imports CreateFileA.
    # ----------------------------------------------------------------
    test "mechanism 5A: late-loaded DLL with __declspec(dllimport) CreateFileA":
      let dllSrc = fixturesDir / "fixture_mech5_late_dll_a.c"
      let mainSrc = fixturesDir / "fixture_mech5_main_a.c"
      doAssert fileExists(dllSrc), "missing fixture: " & dllSrc
      doAssert fileExists(mainSrc), "missing fixture: " & mainSrc
      let dllPath = tempRoot / "mech5a-late.dll"
      let exePath = tempRoot / "mech5a.exe"
      compileGcc(dllSrc, dllPath, @["-shared"])
      compileGcc(mainSrc, exePath)
      let workDir = tempRoot / "mech5a-work"
      createDir(workDir)
      let marker = workDir / "mech5a-marker"
      # Same shape as mech5: host exe takes <dll-path> <marker> <count>
      # and invokes the DLL's `late_create_file_a_n` export. The DLL
      # narrows the wchar_t marker to ANSI internally before each
      # CreateFileA call so the depfile path is end-to-end ANSI.
      let records = runMechanism("mech5a", marker,
                                 @[exePath, dllPath, marker, $N])
      let got = matchingFileOpenRecords(records, "mech5a-marker")
      if got != N:
        checkpoint("mech5a records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records — loss tolerance zero per M73 Phase 3." &
          " Mechanism 5A exercises the post-init-LoadLibraryW IAT" &
          " surface for the ANSI variant: the loader resolves the late" &
          " DLL's CreateFileA IAT slot at LoadLibraryW time, which the" &
          " Phase 1 inline detour at kernel32!CreateFileA must catch.)")
      check got == N

    # ================================================================
    # M73 Phase 5 — Extended hook surface dispatch-mechanism coverage.
    #
    # Phase 5 added 13 new entry points to the hookTable: DeleteFileW/A,
    # CreateDirectoryW/A, CopyFileW/A, MoveFileExW/A,
    # GetFileInformationByHandleEx, SetCurrentDirectoryW/A, and
    # NtCreateFile. Per the milestone "one fixture per API class is
    # sufficient": one mechanism per new entry, with the
    # winlean-dynlib (mechanism-3 style) form preferred for every W
    # variant since that is the load-bearing nimGetProcAddr-cached
    # function-pointer dispatch the M73 install backend exists to
    # catch. GetFileInformationByHandleEx is not in Nim's winlean so a
    # C fixture (mechanism-1, IAT-routed) covers it. NtCreateFile is
    # in ntdll and not in any Win32 winlean binding; a C fixture with
    # GetProcAddress(ntdll.dll, "NtCreateFile") covers it.
    #
    # All snoop->record mappings follow option (b) from the Phase 5
    # plan — no MonitorRecordKind additions, instead reuse mrFileOpen /
    # mrFileWrite / mrPathProbe with descriptive `detail` strings. See
    # the snoop comments in windows_interpose.nim for the per-API
    # mapping table.
    # ================================================================

    proc matchingRecordsByDetail(records: openArray[MonitorRecord];
                                  marker, detail: string;
                                  kind: MonitorRecordKind): int =
      result = 0
      for r in records:
        if r.kind == kind and r.detail == detail and marker in r.path:
          inc result

    # ----------------------------------------------------------------
    # M73 Phase 5: mechanism-4 retirement — os.removeFile -> winlean.deleteFileW.
    #
    # Phase 2 substituted os.fileExists for os.removeFile because
    # DeleteFileW wasn't in the hookTable. Phase 5 added HookDeleteFileW
    # so the originally-spec'd mechanism-4 surface is now observable.
    # This case runs alongside the os.fileExists mechanism-4 (preserved
    # above) — both should reach the shim via winlean's dynlib dispatch
    # and produce a per-call record. The mech4-os-removefile case asserts
    # mrFileWrite + detail "DeleteFileW".
    # ----------------------------------------------------------------
    test "mechanism 4 (retired): os.removeFile -> winlean.deleteFileW":
      let fixtureSrc = fixturesDir / "fixture_mech4_os_removefile.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "mech4-rm.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase5-mech4-rm")
      let workDir = tempRoot / "mech4-rm-work"
      createDir(workDir)
      let marker = workDir / "mech4-rm-marker"
      let records = runMechanism("mech4-rm", marker,
                                 @[exePath, marker, $N])
      let got = matchingRecordsByDetail(records, "mech4-rm-marker",
                                          "DeleteFileW", mrFileWrite)
      if got != N:
        checkpoint("mech4-rm records: " & $got &
          " (expected exactly " & $N &
          " mrFileWrite records with detail \"DeleteFileW\" — loss" &
          " tolerance zero per M73 Phase 5. This retires the Phase 2" &
          " mechanism-4 substitution: the original spec called for" &
          " os.removeFile -> winlean.deleteFileW, which Phase 5" &
          " unblocked by adding HookDeleteFileW.)")
      check got == N

    # ----------------------------------------------------------------
    # Phase 5: CreateDirectoryW via winlean dynlib.
    # ----------------------------------------------------------------
    test "Phase 5: winlean.createDirectoryW":
      let fixtureSrc = fixturesDir / "fixture_createdir_winlean.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "createdir.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase5-createdir")
      let workDir = tempRoot / "createdir-work"
      createDir(workDir)
      let marker = workDir / "createdir-marker"
      let records = runMechanism("createdir", marker,
                                 @[exePath, marker, $N])
      let got = matchingRecordsByDetail(records, "createdir-marker",
                                          "CreateDirectoryW", mrFileWrite)
      if got != N:
        checkpoint("createdir records: " & $got &
          " (expected exactly " & $N &
          " mrFileWrite records with detail \"CreateDirectoryW\" — loss" &
          " tolerance zero per M73 Phase 5.)")
      check got == N

    # ----------------------------------------------------------------
    # Phase 5: CopyFileW via winlean dynlib.
    # ----------------------------------------------------------------
    test "Phase 5: winlean.copyFileW":
      let fixtureSrc = fixturesDir / "fixture_copyfile_winlean.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "copyfile.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase5-copyfile")
      let workDir = tempRoot / "copyfile-work"
      createDir(workDir)
      let marker = workDir / "copyfile-marker"
      let records = runMechanism("copyfile", marker,
                                 @[exePath, marker, $N])
      # Each CopyFileW call emits TWO records: one src (mrFileOpen +
      # detail "CopyFileW:src") and one dst (mrFileWrite + detail
      # "CopyFileW:dst"). We assert both halves equal N.
      let gotDst = matchingRecordsByDetail(records, "copyfile-marker",
                                            "CopyFileW:dst", mrFileWrite)
      let gotSrc = matchingRecordsByDetail(records, "copyfile-marker",
                                            "CopyFileW:src", mrFileOpen)
      if gotDst != N:
        checkpoint("copyfile dst records: " & $gotDst &
          " (expected exactly " & $N &
          " mrFileWrite records with detail \"CopyFileW:dst\".)")
      if gotSrc != N:
        checkpoint("copyfile src records: " & $gotSrc &
          " (expected exactly " & $N &
          " mrFileOpen records with detail \"CopyFileW:src\".)")
      check gotDst == N
      check gotSrc == N

    # ----------------------------------------------------------------
    # Phase 5: MoveFileExW via winlean dynlib.
    # ----------------------------------------------------------------
    test "Phase 5: winlean.moveFileExW":
      let fixtureSrc = fixturesDir / "fixture_movefileex_winlean.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "movefileex.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase5-movefileex")
      let workDir = tempRoot / "movefileex-work"
      createDir(workDir)
      let marker = workDir / "movefileex-marker"
      let records = runMechanism("movefileex", marker,
                                 @[exePath, marker, $N])
      # Each MoveFileExW call emits TWO records: src (mrFileWrite +
      # detail "MoveFileExW:src") and dst (mrFileWrite + detail
      # "MoveFileExW:dst").
      let gotDst = matchingRecordsByDetail(records, "movefileex-marker",
                                            "MoveFileExW:dst", mrFileWrite)
      let gotSrc = matchingRecordsByDetail(records, "movefileex-marker",
                                            "MoveFileExW:src", mrFileWrite)
      if gotDst != N:
        checkpoint("movefileex dst records: " & $gotDst &
          " (expected exactly " & $N & ".)")
      if gotSrc != N:
        checkpoint("movefileex src records: " & $gotSrc &
          " (expected exactly " & $N & ".)")
      check gotDst == N
      check gotSrc == N

    # ----------------------------------------------------------------
    # Phase 5: SetCurrentDirectoryW via winlean dynlib.
    # ----------------------------------------------------------------
    test "Phase 5: winlean.setCurrentDirectoryW":
      let fixtureSrc = fixturesDir / "fixture_setcurrentdir_winlean.nim"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "setcurdir.exe"
      compileNimExe(repoRoot, fixtureSrc, exePath, "m73-phase5-setcurdir")
      let workDir = tempRoot / "setcurdir-work"
      createDir(workDir)
      let marker = workDir / "setcurdir-marker"
      let records = runMechanism("setcurdir", marker,
                                 @[exePath, marker, $N])
      # The fixture also restores cwd via setCurrentDirectoryW to the
      # original working dir AFTER each iteration — that restore path
      # does NOT contain the marker substring, so it is filtered out by
      # the per-record path-contains check. Only the N marker-bearing
      # calls are counted.
      let got = matchingRecordsByDetail(records, "setcurdir-marker",
                                          "SetCurrentDirectoryW", mrFileOpen)
      if got != N:
        checkpoint("setcurdir records: " & $got &
          " (expected exactly " & $N &
          " mrFileOpen records with detail \"SetCurrentDirectoryW\".)")
      check got == N

    # ----------------------------------------------------------------
    # Phase 5: GetFileInformationByHandleEx via IAT-routed C fixture.
    #
    # winlean has no binding for this API; use the simpler mechanism-1
    # IAT-routed dispatch (still goes through kernel32 -> our inline
    # detour catches it).
    # ----------------------------------------------------------------
    test "Phase 5: IAT-routed GetFileInformationByHandleEx":
      let fixtureSrc = fixturesDir / "fixture_getfileinfobyhandleex_iat.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "getinfobyhex.exe"
      compileGcc(fixtureSrc, exePath)
      let workDir = tempRoot / "getinfobyhex-work"
      createDir(workDir)
      let marker = workDir / "getinfobyhex-marker"
      let records = runMechanism("getinfobyhex", marker,
                                 @[exePath, marker, $N])
      # The fixture opens each file via CreateFileW first (so the shim
      # records the handle->path mapping via rememberHandlePath); the
      # subsequent GetFileInformationByHandleEx call's snoop then
      # resolves the path via pathForHandle. The result is an
      # mrPathProbe record whose path contains the marker.
      let got = matchingRecordsByDetail(records, "getinfobyhex-marker",
                                          "GetFileInformationByHandleEx",
                                          mrPathProbe)
      if got != N:
        checkpoint("getinfobyhex records: " & $got &
          " (expected exactly " & $N &
          " mrPathProbe records with detail" &
          " \"GetFileInformationByHandleEx\".)")
      check got == N

    # ----------------------------------------------------------------
    # Phase 5: NtCreateFile via GetProcAddress(ntdll.dll, ...).
    #
    # NtCreateFile lives in ntdll. The Phase 5 snoop defers path
    # extraction (the path lives inside OBJECT_ATTRIBUTES.ObjectName) so
    # record.path is "". The assertion counts mrFileOpen records with
    # detail "NtCreateFile" — by COUNT, not by marker — because we
    # cannot filter on path when the path is blank.
    #
    # Loss tolerance: >= N rather than strict equality. Rationale: the
    # CRT, the Windows loader, and the shim DLL's own initialization
    # all transitively invoke NtCreateFile during process bootstrap;
    # those incidental fires also produce mrFileOpen+NtCreateFile
    # records. We cannot predict the bootstrap count, so the only
    # available correctness statement is "the snoop fires at least N
    # times for our explicit N NtCreateFile calls". This is the one
    # acceptable Phase 5 deviation from strict equality and is
    # documented in the fixture's header comment.
    # ----------------------------------------------------------------
    test "Phase 5: GetProcAddress-dispatched ntdll!NtCreateFile":
      let fixtureSrc = fixturesDir / "fixture_ntcreatefile_getproc.c"
      doAssert fileExists(fixtureSrc),
        "missing fixture: " & fixtureSrc
      let exePath = tempRoot / "ntcreate.exe"
      compileGcc(fixtureSrc, exePath)
      let workDir = tempRoot / "ntcreate-work"
      createDir(workDir)
      let marker = workDir / "ntcreate-marker"
      let records = runMechanism("ntcreate", marker,
                                 @[exePath, marker, $N])
      var got = 0
      for r in records:
        if r.kind == mrFileOpen and r.detail == "NtCreateFile":
          inc got
      if got < N:
        checkpoint("ntcreate records: " & $got &
          " (expected at least " & $N &
          " mrFileOpen records with detail \"NtCreateFile\" — see" &
          " fixture header for the >=-rather-than-= rationale on" &
          " NtCreateFile's process-bootstrap noise floor.)")
      check got >= N
