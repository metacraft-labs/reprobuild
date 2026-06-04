## M73 Phase 4 — Install-audit acceptance test.
##
## Builds the Windows monitor shim DLL via ``prepareMonitorTools``,
## loads it with ``LoadLibraryW``, calls
## ``repro_monitor_shim_init(nil)``, and asserts
## ``repro_monitor_shim_audit_failures() == 0``. The audit walks every
## hookTable entry (11 entries as of Phase 1) and verifies the first 5
## bytes at each ``kernel32!<name>`` target are an inline-hook
## signature (5-byte JMP rel32 overwrite-mode or the EB F9 + upstream
## E9 hot-patch sequence).
##
## A non-zero audit count means at least one hookTable entry's
## kernel32 body was NOT patched by the inline backend — i.e. an IAT-
## fallback install — and dynlib-resolved callers
## (``{.importc, dynlib: "kernel32".}``, ``LoadLibrary + GetProcAddress``,
## etc.) would silently bypass the monitor for that hook. Loss
## tolerance: zero. The test reports per-failing-hook names via
## ``repro_monitor_shim_audit_failing_names`` so the debug surface
## immediately points at which kernel32 API regressed.
##
## On Linux/macOS this test is a no-op skip: the audit, the hookTable,
## and the inline-hook backend itself are Windows-only.
##
## This test is a load-bearing acceptance gate for the
## ``install_audit.nim`` module added in Phase 4 — a failure here means
## the shim's install backend is degraded for at least one kernel32
## function on the test host's Windows version. The fix is to either
## (a) update ct_inline_hook's length decoder to handle that prologue,
## or (b) document the version as unsupported.

import std/[os, strutils, tempfiles, unittest]
import repro_test_support

suite "M73 Phase 4 install-audit acceptance":
  when not defined(windows):
    test "skip non-windows":
      # The install-audit + inline-hook backend are Windows-only (the
      # hookTable, the ct_inline_hook primitive, and the audit pattern
      # decoder all live under ``when defined(windows)``). The whole
      # Phase 4 gate is therefore Windows-only; on Linux/macOS the suite
      # is a documented no-op so the per-OS test runner stays green.
      skip()
  else:
    # ------------------------------------------------------------------
    # Win32 imports — just enough to load the shim DLL and resolve its
    # control-ABI exports. We deliberately avoid ``{.dynlib: "...".}``
    # for the audit symbols because they live in the shim DLL we're
    # loading at runtime (not a fixed-name system DLL); GetProcAddress
    # is the standard pattern for that.
    # ------------------------------------------------------------------
    type
      HMODULE = pointer
      DWORD = uint32

    proc LoadLibraryW(lpLibFileName: ptr uint16): HMODULE
      {.importc, stdcall, dynlib: "kernel32".}
    proc FreeLibrary(hLibModule: HMODULE): int32
      {.importc, stdcall, dynlib: "kernel32".}
    proc GetProcAddress(hModule: HMODULE, lpProcName: cstring): pointer
      {.importc, stdcall, dynlib: "kernel32".}
    proc GetLastError(): DWORD
      {.importc, stdcall, dynlib: "kernel32".}

    type
      ReproShimInitFn = proc (configPath: cstring): cint
        {.cdecl, raises: [].}
      ReproShimAuditFailuresFn = proc (): cint
        {.cdecl, raises: [].}
      ReproShimAuditFailingNamesFn = proc (buf: ptr char;
                                           bufLen: cint): cint
        {.cdecl, raises: [].}

    proc utf8ToUtf16Z(s: string): seq[uint16] =
      ## Convert a UTF-8 string (Nim's native encoding) to a NUL-
      ## terminated UTF-16 LE buffer for ``LoadLibraryW``. ASCII-safe
      ## roundtrip is sufficient here — the shim DLL path lives under
      ## the per-test tempfile root which Nim's ``createTempDir`` keeps
      ## inside ``%TEMP%`` (ASCII on any sane CI host).
      result = newSeq[uint16](s.len + 1)
      for i in 0 ..< s.len:
        result[i] = uint16(ord(s[i]))
      result[s.len] = 0

    test "audit returns zero failures after init":
      # Build the shim DLL on demand. Reuse the same cache key used by
      # the dispatch-mechanism coverage test so the two suites can share
      # the compiled artifact across a single ``run_tests_windows.ps1``
      # sweep — they exercise the same DLL with different probes.
      let repoRoot = getCurrentDir()
      let tempRoot = createTempDir("repro-m73-phase4", "")
      let monitor = prepareMonitorTools(repoRoot, tempRoot / "monitor",
                                        "m73-phase4-audit")
      let shimLib = monitor.shim
      doAssert fileExists(shimLib),
        "shim DLL build did not produce a file at " & shimLib

      # Load the shim DLL.
      var libPath = utf8ToUtf16Z(shimLib)
      let hShim = LoadLibraryW(addr libPath[0])
      if hShim == nil:
        let err = GetLastError()
        checkpoint("LoadLibraryW failed for " & shimLib &
          " (GetLastError=" & $err & ")")
      check hShim != nil

      if hShim != nil:
        # Resolve the control-ABI exports.
        let initAddr = GetProcAddress(hShim, "repro_monitor_shim_init")
        let auditFailuresAddr = GetProcAddress(hShim,
          "repro_monitor_shim_audit_failures")
        let auditFailingNamesAddr = GetProcAddress(hShim,
          "repro_monitor_shim_audit_failing_names")

        if initAddr == nil:
          checkpoint("GetProcAddress(repro_monitor_shim_init) returned NULL")
        check initAddr != nil
        if auditFailuresAddr == nil:
          checkpoint("GetProcAddress(repro_monitor_shim_audit_failures) " &
            "returned NULL — Phase 4 export not present")
        check auditFailuresAddr != nil
        if auditFailingNamesAddr == nil:
          checkpoint("GetProcAddress(repro_monitor_shim_audit_failing_names)" &
            " returned NULL — Phase 4 export not present")
        check auditFailingNamesAddr != nil

        if initAddr != nil and auditFailuresAddr != nil and
           auditFailingNamesAddr != nil:
          let initFn = cast[ReproShimInitFn](initAddr)
          let auditFailuresFn = cast[ReproShimAuditFailuresFn](
            auditFailuresAddr)
          let auditFailingNamesFn = cast[ReproShimAuditFailingNamesFn](
            auditFailingNamesAddr)

          # Call init. The audit runs synchronously inside init so by
          # the time it returns,
          # ``repro_monitor_shim_audit_failures`` reflects the
          # post-install state.
          let initRc = initFn(nil)
          check initRc == 0

          let failures = auditFailuresFn()

          # If the audit reports failures, pull the list of failing
          # hook names so the test output points directly at the
          # regressed entries. Two-pass query: first call with bufLen=0
          # to learn the needed capacity, second call with the
          # allocated buffer.
          if failures != 0:
            let needed = auditFailingNamesFn(nil, 0)
            var failingNames = "(audit failing-names accessor unavailable)"
            if needed > 0:
              var buf = newString(int(needed))
              discard auditFailingNamesFn(
                cast[ptr char](addr buf[0]), cint(buf.len))
              # The buffer holds a NUL-separated list with a final NUL
              # terminator (REG_MULTI_SZ shape). Parse it into a
              # comma-separated string for the failure message.
              var parts: seq[string] = @[]
              var i = 0
              while i < buf.len:
                let startIdx = i
                while i < buf.len and buf[i] != '\0':
                  inc i
                if i == startIdx:
                  break  # final NUL list terminator
                parts.add(buf[startIdx ..< i])
                inc i    # skip the NUL after this name
              failingNames = parts.join(", ")
            checkpoint("repro_monitor_shim_audit_failures() = " &
              $failures &
              " (expected 0) — failing hookTable entries: " &
              failingNames &
              ". An audit failure means at least one kernel32 " &
              "function's first 5 bytes are NOT an inline-hook " &
              "signature, i.e. the install fell through to the IAT " &
              "fallback (or the hook was uninstalled by another " &
              "party). Dynlib-resolved callers bypass the monitor " &
              "for the listed hook(s) — Monitor-Hook-Shim.md " &
              "§\"Install Backend Requirement\" mandates strict " &
              "equality with zero.")

          check failures == 0

        discard FreeLibrary(hShim)
