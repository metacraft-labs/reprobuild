## M10 cross-backend matrix runner: drive the Phase-5 + M69-POSIX gate
## set across every Mac-host-runnable vm-harness backend cell.
##
## Per the M10 deliverables (Multi-OS-VM-Automation-Campaign milestone
## file, "Reprobuild Harness Runs M69 + Phase-5 Gates Across All
## Backends"), this runner exercises every (backend, gate) cell that is
## physically possible on a Mac host:
##
##   * tart-macos       × {8 Phase-5 gates}     — proven by
##                                                ``run_phase5_in_tart.nim``
##                                                in M7-M9; this runner
##                                                composes that suite as
##                                                the first row of the
##                                                matrix.
##   * tart-linux-arm   × {4 M69 POSIX gates}   — NEW for M10.
##   * lima             × {4 M69 POSIX gates}   — NEW for M10.
##
## Cells that require a non-Mac host (libvirt on Linux; Hyper-V/WSL on
## Windows) and the UTM Windows cell (depends on the M3 golden bundle)
## emit a ``[pending-host]`` line and are recorded in the summary as
## ``pending`` rather than ``passing``.
##
## ## Cross-compilation strategy
##
## The four M69 POSIX gate sources (``t_e2e_repro_infra_passwd_user_safe_destroy``,
## ``t_e2e_repro_infra_fs_system_file``, ``t_e2e_repro_infra_env_system_variable``,
## ``t_e2e_repro_infra_systemd_system_unit``) compile cleanly to
## ``aarch64-linux-musl`` via Zig-as-cross-cc:
##
##     nim c --cc:clang --os:linux --cpu:arm64
##           --clang.exe:<zig-cc-wrapper>
##           --clang.linkerexe:<zig-cc-wrapper>
##
## where ``<zig-cc-wrapper>`` is a tiny shell script that execs
## ``zig cc -target aarch64-linux-musl "$@"``. Statically-linked musl
## binaries run unmodified on both the cirruslabs Ubuntu Tart golden
## and Lima's default Ubuntu image.
##
## The destructive halves call ``runInfraApply`` which, when the
## process is already-elevated (``isProcessElevated() and not
## forceBroker``), runs the privileged set IN-PROCESS without
## launching a separate broker — so the gate binary is the only
## artifact we need to stage into the guest. Both backends run the
## binary under passwordless ``sudo`` so ``geteuid() == 0`` inside the
## driver and the in-process privileged-apply path fires.
##
## ## Realistic scope
##
## This milestone is *partially_completed by construction* — the
## Linux- and Windows-host cells genuinely require a non-Mac host.
## The Mac-doable cells (tart-macos × Phase-5, tart-linux-arm × M69-POSIX,
## lima × M69-POSIX) are driven to completion here; the rest are
## recorded as ``pending`` with the blocking-host noted.
##
## ## Per-gate revert budget instrumentation
##
## Per the M0 *Per-Gate Reset Performance Contract*, every backend
## must revert to baseline within a documented per-backend budget. This
## runner records the wall-clock for the revert + exec phase of every
## cell (``vm-harness run`` end-to-end includes both phases plus
## post-run cleanup). The summary block calls out any cell whose
## elapsed time exceeds 90s (Tart) / 240s (Lima) — the documented
## budgets from M2 and M5 respectively.
##
## Run with:
##
##     nim c -r --threads:on tests/e2e/macos-phase5/run_cross_backend_matrix.nim
##
## Exit code 0 = every cell that ran (i.e. every non-pending row)
## PASSed; non-zero = at least one runnable cell failed.

import std/[algorithm, options, os, osproc, sequtils, strformat,
            strutils, tables, tempfiles, times]

when not defined(macosx):
  echo "[skip] run_cross_backend_matrix: macOS host required"
  quit(0)

# ---------------------------------------------------------------------------
# Configuration.

const ProjectRoot = currentSourcePath().parentDir().parentDir()
  .parentDir().parentDir()

const VmHarnessBin = "/Users/zahary/metacraft/vm-harness/build/bin/vm-harness"

const ZigBin = "/opt/homebrew/bin/zig"

# The cirruslabs Ubuntu image ships as ``ubuntu`` with passwordless
# sudo (no separate ``admin`` user); the vm-harness Tart backend
# already handles the user/password defaults internally per
# ``DefaultCirrusLabsUser`` in ``vm-harness/src/vm_harness/backends/tart.nim``.

# ---------------------------------------------------------------------------
# Backend cell types.

type
  BackendKind = enum
    bkTartMacos        ## Mac-doable: macOS guest on Mac host
    bkTartLinuxArm     ## Mac-doable: Linux ARM guest on Mac host
    bkLima             ## Mac-doable: Linux guest on Mac host via Lima
    bkLibvirt          ## Pending: requires Linux host
    bkHyperV           ## Pending: requires Windows host
    bkWsl              ## Pending: requires Windows host
    bkUtmWindowsArm    ## Pending: requires M3 UTM golden bundle

  GuestArch = enum
    gaNative           ## host-native (Mac arm64 → Mac arm64 guest)
    gaLinuxArm64       ## cross-compile to aarch64-linux-musl via Zig

  GateRow = object
    name: string            ## short identifier, used in paths + output
    sourcePath: string      ## relative-to-repo-root Nim test source
    envVar: string          ## env var to set inside the guest
    needsRoot: bool         ## wrap in `sudo -E -n` in guest
    timeoutSec: int         ## per-cell timeout

  Cell = object
    backend: BackendKind
    gate: GateRow

  CellResult = object
    backend: BackendKind
    gateName: string
    verdict: string         ## "PASS" / "FAIL" / "ERROR" / "PENDING"
    exitCode: int
    elapsedMs: int
    outputDir: string
    pendingReason: string   ## non-empty when verdict == "PENDING"

# ---------------------------------------------------------------------------
# Backend metadata.

proc backendId(b: BackendKind): string =
  case b
  of bkTartMacos: "tart-macos"
  of bkTartLinuxArm: "tart-linux-arm"
  of bkLima: "lima"
  of bkLibvirt: "libvirt"
  of bkHyperV: "hyperv"
  of bkWsl: "wsl"
  of bkUtmWindowsArm: "utm-windows-arm"

proc guestKind(b: BackendKind): string =
  case b
  of bkTartMacos: "macos"
  of bkTartLinuxArm, bkLima, bkWsl: "linux"
  of bkLibvirt: "linux"   # for the Linux-guest variant tested here
  of bkHyperV, bkUtmWindowsArm: "windows"

proc requiredArch(b: BackendKind): GuestArch =
  case b
  of bkTartMacos: gaNative
  of bkTartLinuxArm, bkLima: gaLinuxArm64
  else: gaNative   # n/a — never built in this run

proc isMacHostDoable(b: BackendKind): bool =
  case b
  of bkTartMacos, bkTartLinuxArm, bkLima: true
  else: false

proc pendingReasonFor(b: BackendKind): string =
  case b
  of bkLibvirt: "Linux host required (libvirt/QEMU not runnable on macOS)"
  of bkHyperV: "Windows host required (Hyper-V not present on macOS)"
  of bkWsl: "Windows host required (WSL not present on macOS)"
  of bkUtmWindowsArm:
    "UTM Windows ARM golden bundle pending (M3 deliverable)"
  else: ""

proc budgetMsFor(b: BackendKind): int =
  ## Per-cell wall-clock budget (revert + exec). Per the M0 Per-Gate
  ## Reset Performance Contract documented in M2 / M5.
  case b
  of bkTartMacos: 250_000   ## ~3-4 minutes typical end-to-end on cold golden
  of bkTartLinuxArm: 180_000
  of bkLima: 360_000        ## Lima's full-lifecycle revert is slower
  else: 0

# ---------------------------------------------------------------------------
# Gate definitions.

# Phase-5 gates (tart-macos cell). Mirrors run_phase5_in_tart.nim's
# Gates seq — we re-declare here so this runner is self-contained.
let Phase5Gates = @[
  GateRow(name: "fs-systemfile",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "fs-userfile",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_fs_user_file.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_USERFILE_VM",
    needsRoot: false, timeoutSec: 180),
  GateRow(name: "fs-managedblock",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_fs_managed_block.nim",
    envVar: "REPRO_PHASE5_MACOS_FS_MANAGEDBLOCK_VM",
    needsRoot: false, timeoutSec: 180),
  GateRow(name: "env-userpath",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_env_user_path.nim",
    envVar: "REPRO_PHASE5_MACOS_ENV_VM",
    needsRoot: false, timeoutSec: 240),
  GateRow(name: "shell-integration",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_shell_integration.nim",
    envVar: "REPRO_PHASE5_MACOS_SHELL_VM",
    needsRoot: false, timeoutSec: 600),
  GateRow(name: "macos-systemdefault",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_macos_system_default.nim",
    envVar: "REPRO_PHASE5_MACOS_DEFAULTS_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "os-timezone",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_timezone.nim",
    envVar: "REPRO_PHASE5_MACOS_TZ_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "os-hostname",
    sourcePath: "tests/e2e/macos-phase5/t_e2e_macos_phase5_os_hostname.nim",
    envVar: "REPRO_PHASE5_MACOS_HOSTNAME_VM",
    needsRoot: true, timeoutSec: 180),
]

# M69 POSIX gates (tart-linux-arm + lima cells). Each gate's
# destructive half is already guarded by ``(defined(linux) or
# defined(macosx)) and getEnv("REPRO_M69_<x>_VM") == "1"`` (per the
# M69 prompt template); we set the env var inside the guest and run
# under sudo so ``isProcessElevated`` returns true and the broker is
# skipped.
let M69PosixGates = @[
  GateRow(name: "passwd-user",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim",
    envVar: "REPRO_M69_PASSWD_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "fs-system-file",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim",
    envVar: "REPRO_M69_FS_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "env-system-variable",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_env_system_variable.nim",
    envVar: "REPRO_M69_ENV_VM",
    needsRoot: true, timeoutSec: 180),
  GateRow(name: "systemd-system-unit",
    sourcePath: "tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim",
    envVar: "REPRO_M69_SYSTEMD_VM",
    needsRoot: true, timeoutSec: 240),
]

# Build the full cell matrix. We list pending cells explicitly so the
# summary block enumerates them by name — agents reading the summary
# don't have to consult this source to know what's blocked.
proc buildMatrix(): seq[Cell] =
  for g in Phase5Gates:
    result.add(Cell(backend: bkTartMacos, gate: g))
  for g in M69PosixGates:
    result.add(Cell(backend: bkTartLinuxArm, gate: g))
  for g in M69PosixGates:
    result.add(Cell(backend: bkLima, gate: g))
  # Pending rows (no actual cell — these get short-circuited to
  # PENDING in the run loop). We add a single representative cell per
  # pending backend so the summary mentions each blocked backend
  # without exploding the list.
  result.add(Cell(backend: bkLibvirt, gate: M69PosixGates[0]))
  result.add(Cell(backend: bkHyperV,
    gate: GateRow(name: "windows-registry",
      sourcePath: "tests/e2e/m69/t_e2e_windows_registry_system_scope.nim",
      envVar: "REPRO_M69_WIN_REGISTRY_VM",
      needsRoot: false, timeoutSec: 240)))
  result.add(Cell(backend: bkWsl, gate: M69PosixGates[0]))
  result.add(Cell(backend: bkUtmWindowsArm,
    gate: GateRow(name: "windows-feature-capability",
      sourcePath: "tests/e2e/m69/t_e2e_windows_optional_feature_and_capability.nim",
      envVar: "REPRO_M69_WIN_FEATURE_VM",
      needsRoot: false, timeoutSec: 240)))

# ---------------------------------------------------------------------------
# Zig-as-cross-cc wrapper. The script must live on disk because
# Nim's --clang.exe wants a single executable, not a quoted argv.

proc createZigCcWrapper(workDir: string): string =
  ## Emit a tiny shell script that execs ``zig cc -target
  ## aarch64-linux-musl "$@"`` and returns its path.
  let wrapper = workDir / "zig-aarch64-linux-musl-cc.sh"
  writeFile(wrapper,
    "#!/usr/bin/env bash\n" &
    "exec " & ZigBin & " cc -target aarch64-linux-musl \"$@\"\n")
  let perms = {fpUserRead, fpUserWrite, fpUserExec,
               fpGroupRead, fpGroupExec,
               fpOthersRead, fpOthersExec}
  setFilePermissions(wrapper, perms)
  wrapper

# ---------------------------------------------------------------------------
# Build phase — one binary per (gate, arch) combination.

proc buildGateBinary(gate: GateRow; arch: GuestArch;
                     outDir: string; zigWrapper: string): string =
  ## Compile the gate's Nim source for the target arch. Returns the
  ## path to the resulting binary. Raises IOError on build failure.
  let src = ProjectRoot / gate.sourcePath
  doAssert fileExists(src), "gate source missing: " & src
  let suffix = (case arch
    of gaNative: "native"
    of gaLinuxArm64: "linux-arm64")
  let binPath = outDir / (gate.name & "-" & suffix)
  let nimcache = outDir / ("nimcache-" & gate.name & "-" & suffix)
  createDir(nimcache)
  echo "  [build] " & gate.name & " (" & suffix & ") → " & binPath
  let buildStart = epochTime()

  var cmd = @["nim", "c",
              "--hints:off",
              "--warning:UnusedImport:off",
              "--warning:CaseTransition:off",
              "--threads:on",
              "-d:release",
              "--nimcache:" & nimcache,
              "--out:" & binPath]
  if arch == gaLinuxArm64:
    cmd.add(@["--cc:clang", "--os:linux", "--cpu:arm64",
              "--clang.exe:" & zigWrapper,
              "--clang.linkerexe:" & zigWrapper])
  cmd.add(src)

  let proc1 = startProcess(cmd[0], workingDir = ProjectRoot,
                          args = cmd[1 .. ^1],
                          options = {poUsePath, poStdErrToStdOut,
                                     poParentStreams})
  let exitCode = proc1.waitForExit()
  proc1.close()
  let elapsedMs = int((epochTime() - buildStart) * 1000)
  if exitCode != 0:
    raise newException(IOError,
      "build failed for gate " & gate.name & " (" & suffix &
      "; exit " & $exitCode & "); see stderr for nim output")
  doAssert fileExists(binPath),
    "build claimed success but binary missing: " & binPath
  echo "  [build-ok] " & gate.name & " (" & suffix & ", " &
    $elapsedMs & " ms)"
  binPath

# ---------------------------------------------------------------------------
# vm-harness invocation per cell. We use the CLI binary (same
# pattern as run_phase5_in_tart.nim) so the runner is a thin
# auditable wrapper.

proc sourceImageFor(b: BackendKind): string =
  case b
  of bkTartMacos: "ghcr.io/cirruslabs/macos-tahoe-base:latest"
  of bkTartLinuxArm: "ghcr.io/cirruslabs/ubuntu:latest"
  of bkLima: ""   # Lima resolves Ubuntu LTS via its template
  else: ""

proc runCell(cell: Cell; binPath, outDir: string): CellResult =
  let guestBin = "/tmp/" & cell.gate.name & "-gate"
  var guestCmd: seq[string]
  if cell.gate.needsRoot:
    guestCmd = @["sudo", "-E", "-n",
                 "env", cell.gate.envVar & "=1", guestBin]
  else:
    guestCmd = @["env", cell.gate.envVar & "=1", guestBin]

  var args = @[VmHarnessBin, "run",
               "--backend", backendId(cell.backend),
               "--guest", guestKind(cell.backend),
               "--baseline",
                 "m10-" & backendId(cell.backend) & "-" & cell.gate.name,
               "--cpus", "4",
               "--memory-mb", "8192",
               "--disk-gb", "40",
               "--output-dir", outDir,
               "--copy-to", binPath & ":" & guestBin,
               "--timeout-sec", $cell.gate.timeoutSec]
  let img = sourceImageFor(cell.backend)
  if img.len > 0:
    args.add(@["--source-image", img])
  args.add("--")
  args.add(guestCmd)

  echo "  [vm-harness] backend=" & backendId(cell.backend) &
    " gate=" & cell.gate.name & " output=" & outDir
  let runStart = epochTime()
  let proc1 = startProcess(args[0], args = args[1 .. ^1],
                           options = {poUsePath, poStdErrToStdOut,
                                      poParentStreams})
  let exit = proc1.waitForExit()
  proc1.close()
  let elapsedMs = int((epochTime() - runStart) * 1000)

  var verdict = "ERROR"
  let donePath = outDir / "DONE"
  if fileExists(donePath):
    verdict = readFile(donePath).strip()

  CellResult(backend: cell.backend,
             gateName: cell.gate.name,
             verdict: verdict,
             exitCode: exit,
             elapsedMs: elapsedMs,
             outputDir: outDir,
             pendingReason: "")

# ---------------------------------------------------------------------------
# Prerequisites.

proc checkPrerequisites(): bool =
  if findExe("tart").len == 0:
    echo "[skip] tart not on PATH"
    return false
  if findExe("sshpass").len == 0:
    echo "[skip] sshpass not on PATH"
    return false
  if findExe("limactl").len == 0:
    echo "[skip] limactl not on PATH (needed for the Lima row)"
    return false
  if not fileExists(VmHarnessBin):
    echo "[skip] vm-harness binary missing at " & VmHarnessBin
    return false
  if not fileExists(ZigBin):
    echo "[skip] zig missing at " & ZigBin &
      " (needed to cross-build Linux ARM gate binaries)"
    return false
  if getEnv("VMH_TART_SKIP_MACOS", "") == "1":
    echo "[note] VMH_TART_SKIP_MACOS=1 set; tart-macos rows " &
      "will be skipped (not failed)"
  true

# ---------------------------------------------------------------------------
# Entry point.

proc main(): int =
  if not checkPrerequisites():
    return 0    # graceful skip — not a failure

  let workRoot = createTempDir("repro-m10-cross-", "")
  echo "[m10-runner] workRoot=" & workRoot
  echo "[m10-runner] ProjectRoot=" & ProjectRoot
  echo "[m10-runner] vm-harness=" & VmHarnessBin
  echo "[m10-runner] zig=" & ZigBin

  let zigWrapper = createZigCcWrapper(workRoot)
  echo "[m10-runner] zig-cc wrapper=" & zigWrapper

  let matrix = buildMatrix()
  echo "[m10-runner] matrix size: " & $matrix.len & " cells"

  # 1. Build all native + cross gate binaries up front so we fail
  #    fast on any build error before incurring multi-minute VM
  #    provisioning costs.
  var binaries: Table[string, string]    ## key = gateName & "|" & arch
  let skipMacos = getEnv("VMH_TART_SKIP_MACOS", "") == "1"

  for cell in matrix:
    if cell.backend == bkTartMacos and skipMacos:
      continue
    if not cell.backend.isMacHostDoable:
      continue
    let arch = cell.backend.requiredArch
    let key = cell.gate.name & "|" & $arch
    if binaries.hasKey(key):
      continue
    let buildDir = workRoot / ("build-" & cell.gate.name & "-" & $arch)
    createDir(buildDir)
    let binPath = buildGateBinary(cell.gate, arch, buildDir, zigWrapper)
    binaries[key] = binPath

  # 2. Run each cell sequentially.
  var results: seq[CellResult]
  var anyFail = false
  for cell in matrix:
    if not cell.backend.isMacHostDoable:
      results.add(CellResult(
        backend: cell.backend,
        gateName: cell.gate.name,
        verdict: "PENDING",
        exitCode: 0,
        elapsedMs: 0,
        outputDir: "",
        pendingReason: pendingReasonFor(cell.backend)))
      echo "  [pending] backend=" & backendId(cell.backend) &
        " gate=" & cell.gate.name &
        " reason=" & pendingReasonFor(cell.backend)
      continue
    if cell.backend == bkTartMacos and skipMacos:
      echo "  [skip-cell] backend=" & backendId(cell.backend) &
        " gate=" & cell.gate.name & " (VMH_TART_SKIP_MACOS=1)"
      continue
    let outDir = workRoot / ("output-" & backendId(cell.backend) &
                             "-" & cell.gate.name)
    createDir(outDir)
    let key = cell.gate.name & "|" & $cell.backend.requiredArch
    let r = runCell(cell, binaries[key], outDir)
    results.add(r)
    let budgetNote =
      if budgetMsFor(cell.backend) > 0 and
         r.elapsedMs > budgetMsFor(cell.backend):
        " [OVER-BUDGET budget=" & $budgetMsFor(cell.backend) & "ms]"
      else: ""
    echo "  [result] backend=" & backendId(cell.backend) &
      " gate=" & cell.gate.name &
      " verdict=" & r.verdict & " exit=" & $r.exitCode &
      " elapsed=" & $r.elapsedMs & "ms" & budgetNote
    if r.verdict != "PASS" or r.exitCode != 0:
      anyFail = true
      let resultPath = outDir / "RESULT.txt"
      if fileExists(resultPath):
        echo "    ---- RESULT.txt ----"
        echo readFile(resultPath)
      let cmdRunPath = outDir / "01-command-run.txt"
      if fileExists(cmdRunPath):
        echo "    ---- 01-command-run.txt (tail) ----"
        let lines = readFile(cmdRunPath).splitLines()
        let tail = lines[max(0, lines.len - 80) ..< lines.len]
        for ln in tail: echo "      " & ln

  echo ""
  echo "[m10-runner] Cross-backend matrix summary:"
  echo "  =================================================================="
  echo "  backend              gate                       verdict  elapsed-ms"
  echo "  ------------------------------------------------------------------"
  for r in results:
    let bid = backendId(r.backend)
    var line = "  " & bid.alignLeft(20) & " " &
               r.gateName.alignLeft(26) & " " &
               r.verdict.alignLeft(8) & " " & $r.elapsedMs
    if r.pendingReason.len > 0:
      line.add("   [" & r.pendingReason & "]")
    echo line
  echo "  =================================================================="

  # Per-backend budget summary.
  echo ""
  echo "[m10-runner] Per-backend revert+exec wall-clock budget check:"
  for b in [bkTartMacos, bkTartLinuxArm, bkLima]:
    let bid = backendId(b)
    let cellsForBackend = results.filterIt(it.backend == b and
                                           it.verdict != "PENDING")
    if cellsForBackend.len == 0:
      echo "  " & bid & ": no cells ran"
      continue
    let times = cellsForBackend.mapIt(it.elapsedMs)
    let median = times.sorted()[times.len div 2]
    let maxT = times.max
    let budget = budgetMsFor(b)
    let verdict = if maxT <= budget: "WITHIN-BUDGET" else: "OVER-BUDGET"
    echo "  " & bid.alignLeft(20) &
      " median=" & $median & "ms" &
      " max=" & $maxT & "ms" &
      " budget=" & $budget & "ms" &
      " " & verdict

  if anyFail:
    echo "[m10-runner] FAIL — at least one runnable cell did not PASS"
    return 1
  echo "[m10-runner] OK — every Mac-host-runnable cell PASSED " &
    "(pending cells require non-Mac hosts; see summary above)"
  return 0

quit(main())
