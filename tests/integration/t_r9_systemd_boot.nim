## R9 boot integration test.
##
## Boots the R9 ISO (R8 kernel 6.6.142 + R9 initramfs containing
## from-source systemd 257.9) under Hyper-V Gen-2 UEFI via
## vm-harness's ``bootFromMedia`` primitive, captures the COM1
## serial stream, and asserts that systemd starts as PID 1 and
## reaches a login prompt.
##
## Override ISO via $VMH_REPROOS_R9_ISO; default is
## D:/metacraft/reprobuild/build/r9-build/reproos-r9.iso.

import std/[os, osproc, strutils, tables, times]

import ct_test_unittest_parallel

const HostRunsGate = defined(windows)
  ## The Hyper-V backend needs a Windows host. This used to be enforced
  ## by an ``echo`` + ``quit(0)`` at module init, before the ``suite``
  ## template expanded: the binary emitted no catalog, stayed an opaque
  ## whole-binary exit-0 PASS, and its declared case was invisible to
  ## every gate. The guard is now inside the case, so the run counts it
  ## and the skip census says why.

const PlatformSkipReason =
  "t_r9_systemd_boot: Windows host required (Hyper-V backend)"

const SiblingSkipReason =
  "t_r9_systemd_boot: vm-harness sibling unavailable"

when defined(vmHarnessAvailable):
  import vm_harness

  proc isElevated(): bool =
    let cmd = @["powershell.exe", "-NoLogo", "-NoProfile",
                "-ExecutionPolicy", "Bypass", "-Command",
                "try { $null = Get-VMHost -ErrorAction Stop; exit 0 } " &
                "catch { exit 1 }"]
    try:
      let p = startProcess(cmd[0], args = cmd[1 .. ^1],
                           options = {poUsePath, poStdErrToStdOut})
      let code = p.waitForExit(timeout = 30 * 1000)
      p.close()
      return code == 0
    except CatchableError:
      return false

  proc findR9Iso(): string =
    let envOverride = getEnv("VMH_REPROOS_R9_ISO")
    if envOverride.len > 0 and fileExists(envOverride):
      return envOverride
    let cand = "D:" & DirSep & "metacraft" & DirSep & "reprobuild" &
               DirSep & "build" & DirSep & "r9-build" & DirSep &
               "reproos-r9.iso"
    if fileExists(cand):
      return cand
    return ""

  proc runR9BootScenario(backend: HyperVBackend, iso, perVmDir: string,
                         vmName: string) =
    createDir(perVmDir)
    var extra = initTable[string, string]()
    let spec = BootMediaSpec(
      name: vmName,
      kind: bmkIso,
      mediaPath: iso,
      secondaryIsoPath: "",
      cpus: 2,
      memoryMB: 1024,
      generation: 2,
      secureBootEnabled: false,
      serialPipeName: vmName & "-com1",
      serialLogPath: perVmDir / (vmName & ".serial.log"),
      extra: extra)

    let preservedSerialLog = "D:" & DirSep & "metacraft" & DirSep &
      "reprobuild" & DirSep & "build" & DirSep & "r9-build" & DirSep &
      "run-evidence" & DirSep & vmName & ".serial.log"
    createDir(parentDir(preservedSerialLog))

    let vm = backend.bootFromMedia(spec)
    defer:
      let serialLog = perVmDir / (vmName & ".serial.log")
      if fileExists(serialLog):
        try: copyFile(serialLog, preservedSerialLog)
        except CatchableError: discard
      backend.stopAndCleanup(vm, deleteVm = true)
      if dirExists(perVmDir):
        try: removeDir(perVmDir)
        except CatchableError: discard
      echo "[info] preserved serial log -> ", preservedSerialLog

    let serial = backend.captureSerial(vm)
    defer: backend.closeSerial(serial)

    # Phase 1: confirm kernel boots
    echo "[info] expecting kernel banner on COM1..."
    let kernelBanner = backend.expectLine(serial,
      r"Linux version 6\.6\.142",
      timeoutSec = 120)
    check kernelBanner.matched
    if kernelBanner.matched:
      echo "[diag] kernel banner: ", kernelBanner.matchedText.strip()

    # Phase 2: systemd starts as PID 1
    echo "[info] expecting systemd PID 1 banner..."
    let sysdBanner = backend.expectLine(serial,
      r"(systemd\[1\]:|systemd 257|Welcome to ReproOS|" &
      r"Reached target|Started.*[Gg]etty)",
      timeoutSec = 120)
    check sysdBanner.matched
    if sysdBanner.matched:
      echo "[diag] systemd banner matched in ",
           sysdBanner.elapsedMs, " ms: ",
           sysdBanner.matchedText.strip()

    # Phase 3: login prompt
    echo "[info] expecting login prompt..."
    let loginBanner = backend.expectLine(serial,
      r"(login:|reproos-r9 login|root@reproos)",
      timeoutSec = 120)
    if loginBanner.matched:
      echo "[diag] LOGIN PROMPT REACHED in ",
           loginBanner.elapsedMs, " ms: ",
           loginBanner.matchedText.strip()
    else:
      echo "[diag] login prompt not seen; serial log: ",
           perVmDir / (vmName & ".serial.log")
      let p = perVmDir / (vmName & ".serial.log")
      if fileExists(p):
        let logContent = readFile(p)
        let tailStart = max(0, logContent.len - 6000)
        echo "[diag] serial log tail (last 6KiB):"
        echo logContent[tailStart .. ^1]
    check loginBanner.matched

  suite "t_r9_systemd_boot":
    test "R9 ISO boots; systemd 257.9 reaches login prompt":
      if not HostRunsGate:
        skip(PlatformSkipReason)
      else:
        let backend = newHyperVBackend(
          vmName = "repro-test-boot-r9-placeholder")
        if not backend.probeAvailability():
          skip("Hyper-V not available on this host")
        elif not isElevated():
          skip("Hyper-V cmdlets require admin elevation")
        else:
          let iso = findR9Iso()
          if iso.len == 0:
            skip("R9 reproos-r9.iso not found at default path " &
                 "(D:/metacraft/reprobuild/build/r9-build/reproos-r9.iso); " &
                 "set VMH_REPROOS_R9_ISO=<path>")
          else:
            let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
            let vmName = "repro-test-boot-r9-" & suffix[suffix.len - 8 .. ^1]
            let perVmDir =
              getTempDir() / "vm-harness-e2e-r9-systemd-boot" / vmName
            echo "[info] booting R9 ISO: ", iso
            runR9BootScenario(backend, iso, perVmDir, vmName)
else:
  # vm-harness (../vm-harness) is an optional Windows-only sibling. When it
  # is absent the boot scenario cannot be compiled, so the case is declared
  # as a skip rather than left undeclared — the previous ``echo`` +
  # ``quit(0)`` here made the binary an opaque exit-0 PASS
  # (missing optional sibling -> skip, not fatal; RA-23).
  suite "t_r9_systemd_boot":
    test "R9 ISO boots; systemd 257.9 reaches login prompt":
      skip(SiblingSkipReason)
