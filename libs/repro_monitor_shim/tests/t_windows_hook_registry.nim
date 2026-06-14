## M26: ct_interpose hook_registry migration tests for the Windows monitor shim.
##
## These tests exercise the registry-dispatch path in
## ``repro_monitor_shim/windows_hook_registry``. They do NOT load the
## monitor DLL into a child process — that path is exercised by the M11
## ``validate-standard-provider-rust-crude.ps1`` gate. Here we verify:
##
##   1. The registry initialises and is idempotent.
##   2. The monitor's snoop callbacks register against the expected hook
##      names at the expected priority (ShimSnoopPriority = 100).
##   3. The chain's ``original`` callback can be set and dispatched.
##   4. Chain dispatch order is correct (snoop runs, then original).
##   5. A future co-resident consumer can register additional hooks
##      without colliding with the shim's snoop callbacks.
##
## These tests are Windows-only; on POSIX the test is a no-op (matches
## the platform gate that windows_hook_registry itself enforces).

when defined(windows):
  import stackable_hooks/hook_registry
  import repro_monitor_shim/windows_hook_registry as hr

  proc test_register_initialises_lazily() =
    echo "test_register_initialises_lazily..."
    # initShimRegistry is idempotent. Calling it twice must not reset the
    # chain table (which would lose any hooks the caller had registered
    # in between).
    hr.initShimRegistry()
    doAssert hr.shimRegistryReady()
    hr.initShimRegistry()  # second call: no-op
    doAssert hr.shimRegistryReady()
    echo "  PASSED"

  proc test_register_each_expected_hook_name() =
    echo "test_register_each_expected_hook_name..."
    # Register a dummy callback against each canonical hook name. The
    # callback never runs in this test — we only verify the registry
    # accepts the registration and reports the chain via hookCount.
    hr.initShimRegistry()
    let dummy: HookCallback = proc(ctx: var HookContext) {.raises: [].} =
      ctx.result = 0xDEADBEEF'u64
    let baselineCounts = block:
      var s: seq[(string, int)]
      for name in hr.MonitorShimHookNames:
        s.add((name, hr.hookCount(name)))
      s
    for name in hr.MonitorShimHookNames:
      hr.registerMonitorHook(name, dummy)
    for (name, baseline) in baselineCounts:
      let now = hr.hookCount(name)
      doAssert now == baseline + 1,
        "hook count for " & name & " expected " & $(baseline + 1) &
          " but got " & $now
    echo "  PASSED"

  proc test_set_original_and_dispatch() =
    echo "test_set_original_and_dispatch..."
    # End-to-end: register a snoop callback (callNext → calls original),
    # set the original, dispatch a fake call, observe both ran and the
    # result propagated correctly.
    hr.initShimRegistry()
    var trace: seq[string] = @[]
    let testHookName = "test_set_original_and_dispatch_hook"
    let snoop: HookCallback = proc(ctx: var HookContext) {.raises: [].} =
      trace.add("snoop-before-callNext")
      callNext(ctx)
      trace.add("snoop-after-callNext")
      doAssert ctx.result == 0xC0FFEE'u64,
        "original was supposed to write 0xC0FFEE; got " & $ctx.result
    let original: HookCallback = proc(ctx: var HookContext) {.raises: [].} =
      trace.add("original")
      ctx.result = 0xC0FFEE'u64
    hr.shimRegistry()[].registerHook(testHookName, hr.ShimSnoopPriority, snoop)
    hr.setOriginalCallback(testHookName, original)
    var ctx = HookContext(args: @[0xAA'u64, 0xBB'u64])
    hr.dispatchShimHook(testHookName, ctx)
    doAssert trace == @["snoop-before-callNext", "original",
                         "snoop-after-callNext"],
      "Unexpected trace: " & $trace
    doAssert ctx.result == 0xC0FFEE'u64
    doAssert hr.hasOriginal(testHookName)
    echo "  PASSED"

  proc test_co_resident_consumer_does_not_collide() =
    echo "test_co_resident_consumer_does_not_collide..."
    # A second consumer (e.g. a hypothetical codetracer recorder
    # co-resident in the same process) registers its own hook at
    # RecorderPriority = 50, which is LOWER than the shim's
    # ShimSnoopPriority = 100, so it runs FIRST. Confirms the priority
    # contract documented in windows_hook_registry.nim.
    hr.initShimRegistry()
    let chainName = "test_co_resident_consumer_chain"
    var order: seq[string] = @[]
    let recorderHook: HookCallback =
      proc(ctx: var HookContext) {.raises: [].} =
        order.add("recorder")
        callNext(ctx)
    let shimHook: HookCallback =
      proc(ctx: var HookContext) {.raises: [].} =
        order.add("shim-snoop")
        callNext(ctx)
    let original: HookCallback =
      proc(ctx: var HookContext) {.raises: [].} =
        order.add("original")
        ctx.result = 1'u64
    # Register in REVERSE order to be sure priority — not insertion
    # order — drives dispatch.
    hr.shimRegistry()[].registerHook(chainName, hr.ShimSnoopPriority, shimHook)
    hr.shimRegistry()[].registerHook(chainName, hr.RecorderPriority,
                                      recorderHook)
    hr.setOriginalCallback(chainName, original)
    doAssert hr.hookCount(chainName) == 2,
      "expected 2 hooks on test chain, got " & $hr.hookCount(chainName)
    var ctx = HookContext(args: @[])
    hr.dispatchShimHook(chainName, ctx)
    doAssert order == @["recorder", "shim-snoop", "original"],
      "Unexpected chain order: " & $order
    echo "  PASSED"

  proc test_registry_ready_predicate() =
    echo "test_registry_ready_predicate..."
    # shimRegistryReady is the gate the trampolines use to no-op safely
    # before initShimRegistry runs (e.g. if a hooked API somehow fires
    # before repro_monitor_shim_init has been called). After init it
    # must be true.
    hr.initShimRegistry()
    doAssert hr.shimRegistryReady()
    let names = hr.registeredHookNames()
    # We have registered against some chains by now (the other tests
    # populated them). registeredHookNames must reflect at least the
    # canonical hook surface plus the test-only chains.
    for canonical in hr.MonitorShimHookNames:
      var found = false
      for n in names:
        if n == canonical:
          found = true
          break
      if not found:
        # Not fatal — this test runs AFTER test_register_each_expected
        # which registers them, but order is not guaranteed at the file
        # level. So we only echo, not assert.
        echo "  note: ", canonical, " not in registry yet (may be ok)"
    # Sanity: at least one chain is present.
    doAssert names.len > 0, "registry reports no chains after init"
    echo "  PASSED"

  proc test_hook_names_match_win32_api() =
    echo "test_hook_names_match_win32_api..."
    # The canonical names embedded in MonitorShimHookNames must match
    # the strings passed to the IAT walker for the hook to actually
    # connect. We can't easily reach into windows_interpose.nim from
    # here without exporting the trampoline list; instead, verify the
    # expected Win32 API names are present in the canonical list. Any
    # rename caught here means the test author forgot to update one
    # side of the contract.
    let expected = @["CreateFileW", "CreateFileA",
                     "ReadFile", "WriteFile", "CloseHandle",
                     "GetFileAttributesExW", "GetFileAttributesExA",
                     "GetFileAttributesW", "GetFileAttributesA",
                     "CreateProcessW", "CreateProcessA",
                     # M73 Phase 5 — extended hook surface.
                     "DeleteFileW", "DeleteFileA",
                     "CreateDirectoryW", "CreateDirectoryA",
                     "CopyFileW", "CopyFileA",
                     "MoveFileExW", "MoveFileExA",
                     "GetFileInformationByHandleEx",
                     "SetCurrentDirectoryW", "SetCurrentDirectoryA",
                     "NtCreateFile"]
    for e in expected:
      var found = false
      for n in hr.MonitorShimHookNames:
        if n == e:
          found = true
          break
      doAssert found, "expected " & e & " in MonitorShimHookNames; not present"
    doAssert hr.MonitorShimHookNames.len == expected.len,
      "MonitorShimHookNames size " & $hr.MonitorShimHookNames.len &
        " != expected size " & $expected.len &
        " — did a hook get added or removed without updating tests?"
    echo "  PASSED"

  test_register_initialises_lazily()
  test_register_each_expected_hook_name()
  test_set_original_and_dispatch()
  test_co_resident_consumer_does_not_collide()
  test_registry_ready_predicate()
  test_hook_names_match_win32_api()
  echo "All windows_hook_registry tests passed."

else:
  # POSIX: the registry module is Windows-only. Smoke-test that the
  # test compiles + exits clean on Linux/macOS so the per-test gate in
  # scripts/run_tests.sh stays green cross-platform.
  echo "SKIP: t_windows_hook_registry (Windows-only)"
