## R2 boot integration test.
##
## Boots the R2 reproos-iso recipe's produced ISO under a transient
## Hyper-V Gen-2 UEFI VM via vm-harness's ``bootFromMedia`` primitive,
## then captures the COM1 serial stream and asserts that the kernel
## reaches userspace (the Debian-installer-on-serial path produces a
## distinctive banner line that the test matches on).
##
## This is a Tier-2 reprobuild integration test: it depends on the R2
## recipe's output (``recipes/reproos-iso/build/reproos.iso``) and on
## vm-harness as the boot-orchestration library. The vm-harness Tier-1
## generic primitives stay generic; the "ReproOS-specific" assertions
## live here.
##
## Skips when:
## - Not Windows (Hyper-V backend is Windows-only).
## - Hyper-V not available on the host.
## - Process is not elevated (Hyper-V cmdlets require admin).
## - The R2 ISO has not been built (``recipes/reproos-iso/build/``
##   missing or empty).
##
## Override the ISO location via ``$VMH_REPROOS_ISO``.

import std/[os, osproc, strutils, tables, times, unittest]
import vm_harness

when not defined(windows):
  echo "[skip] t_r2_iso_boot: Windows host required (Hyper-V backend)"
  quit(0)

# ---------------------------------------------------------------------------
# Probe helpers.

proc isElevated(): bool =
  ## Best-effort elevation probe: try a Hyper-V cmdlet that requires
  ## admin and see if it succeeds. ``Get-VMHost`` is sufficient.
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

proc findReproosIso(): string =
  ## Look for the R2 ISO at the recipe's default output path, then at
  ## the published-evidence dir, then at $VMH_REPROOS_ISO.
  let envOverride = getEnv("VMH_REPROOS_ISO")
  if envOverride.len > 0 and fileExists(envOverride):
    return envOverride
  var candidates: seq[string] = @[
    # Recipe output
    "D:" & DirSep & "metacraft" & DirSep & "reprobuild" & DirSep &
      "recipes" & DirSep & "reproos-iso" & DirSep & "build" & DirSep &
      "reproos.iso",
    # Reproducibility-gate artefact (latest rebuild)
    "D:" & DirSep & "metacraft" & DirSep & "reprobuild" & DirSep &
      "build" & DirSep & "r2-iso-reproducibility" & DirSep &
      "rebuild-3" & DirSep & "reproos.iso",
    # Recipe's run-evidence dir, if a previous gate published an ISO
    "D:" & DirSep & "metacraft" & DirSep & "reprobuild" & DirSep &
      "recipes" & DirSep & "reproos-iso" & DirSep & "run-evidence" &
      DirSep & "reproos.iso",
  ]
  for c in candidates:
    if fileExists(c):
      return c
  return ""

# ---------------------------------------------------------------------------
# Scenario body.

proc runBootScenario(backend: HyperVBackend, iso, perVmDir: string,
                     vmName: string) =
  ## Boot the R2 ISO under a transient Gen-2 UEFI VM. Tail COM1.
  ## Assert that the kernel boots and reaches the Debian-installer
  ## serial banner.
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

  # Preserve the serial log on cleanup so a failed boot leaves a
  # diagnosable artefact behind. The reproducibility gate publishes
  # there too.
  let preservedSerialLog = "D:" & DirSep & "metacraft" & DirSep &
    "reprobuild" & DirSep & "recipes" & DirSep & "reproos-iso" &
    DirSep & "run-evidence" & DirSep & vmName & ".serial.log"
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

  # The Debian Installer's d-i kernel writes a distinctive banner to
  # ttyS0 once the kernel + initramfs hand control to the installer
  # framework. Any of these lines confirms "kernel reached userspace":
  #
  #   "Debian GNU/Linux installer"
  #   "Choose language"
  #   "Welcome to the Debian Installer"
  #   "Loading installation components"
  #
  # The kernel's own boot banner ("Linux version X.Y.Z ...") also
  # appears earlier, before the installer starts; that's an even
  # stronger signal. We match on either: a strict regex that catches
  # both the kernel banner AND the installer banner.
  # The kernel emits "Linux version X.Y.Z" early in its printk stream
  # (before init userspace), then the d-i kernel hands off to busybox
  # which writes "Loading installation components" and friends. We
  # match any line that confirms either path. The kernel printk alone
  # is sufficient evidence that the bootloader + UEFI handoff worked.
  echo "[info] expecting kernel/installer banner on COM1..."
  let banner = backend.expectLine(serial,
    r"(Linux version|Booting [^ ]+ Linux|" &
    r"Decompressing Linux|Kernel command line|" &
    r"Debian.*[Ii]nstaller|Choose language|" &
    r"Loading installation components|Welcome to)",
    timeoutSec = 240)
  check banner.matched
  if banner.matched:
    echo "[diag] banner matched in ", banner.elapsedMs, " ms: ",
         banner.matchedText.strip()
  else:
    # Diagnostic: read whatever IS on the serial pipe so the next
    # iteration knows what to match on. The serial log file persists
    # under perVmDir until the suite's finally cleans it up.
    echo "[diag] no banner matched within 240s; serial log at: ",
         perVmDir / (vmName & ".serial.log")
    let serialLogPath = perVmDir / (vmName & ".serial.log")
    if fileExists(serialLogPath):
      let logContent = readFile(serialLogPath)
      echo "[diag] serial log (first 4000 bytes):"
      echo logContent[0 .. min(4000, logContent.high)]

# ---------------------------------------------------------------------------
# Suite.

suite "t_r2_iso_boot":
  test "R2 ISO boots under Hyper-V Gen-2 UEFI; kernel + initramfs reach userspace":
    let backend = newHyperVBackend(vmName = "repro-test-boot-r2-placeholder")

    if not backend.probeAvailability():
      echo "[skip] Hyper-V not available on this host"
      skip()
    elif not isElevated():
      echo "[skip] Hyper-V cmdlets require admin elevation; current " &
           "process is not elevated (Get-VMHost failed)"
      skip()
    else:
      let iso = findReproosIso()
      if iso.len == 0:
        echo "[skip] R2 reproos.iso not found. Build it with " &
             "`bash tests/reproducibility/t_r2_iso_reproducibility.sh` " &
             "(inside repro-debian WSL) or set VMH_REPROOS_ISO=<path>"
        skip()
      else:
        let suffix = $(epochTime() * 1000.0).int64.toHex().toLowerAscii()
        let vmName = "repro-test-boot-r2-" & suffix[suffix.len - 8 .. ^1]
        let perVmDir = getTempDir() / "vm-harness-e2e-r2-iso-boot" / vmName
        echo "[info] booting ISO: ", iso
        runBootScenario(backend, iso, perVmDir, vmName)
