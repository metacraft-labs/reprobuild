# `tools/sandbox-bench/` — measured per-test overhead, three test paths

> **Note 2026-06-08**: the Hyper-V hot-revert and portability primitives
> measured by the scripts in this directory are now first-class API
> calls in `vm-harness`:
>
> - `snapshotRunning` / `restoreSnapshot` / `removeSnapshot`
> - `exportBaseline` / `importBaseline`
> - CLI: `vm-harness snapshot create --running ...`,
>   `vm-harness baseline export|import ...`
>
> A backend-agnostic Nim benchmark that drives the same measurement
> through the library API ships at
> `metacraft-labs/vm-harness:tools/bench/snapshot_revert_bench.nim`
> (build: `nimble buildBench`). The PowerShell scripts in this
> directory remain the canonical reproducer for the original
> measurements documented here, but new measurement work should
> prefer the vm-harness bench so future backends (Tart `suspend`,
> libvirt native snapshots) can re-measure under the same harness.
> See `docs/per-backend-notes/hyperv-snapshot-benchmarks.md` in
> vm-harness for the project-agnostic version of the numbers below.

Concrete wall-time measurements for the three options reprobuild has
to run a destructive-class e2e test:

| Path        | Per-test overhead | Per-test isolation? | Batching unit | Isolation surface |
|-------------|-------------------|---------------------|---------------|-------------------|
| Bare host   | 0                 | n/a (with REPRO_REGISTRY_ROOT seam: yes for HKCU writes) | n/a | none — uses real HKCU/FS/PATH |
| Windows Sandbox per-test | ~12 s | **yes** | one .wsb per test | fresh HKCU + FS, no Windows Update, no reboot |
| Windows Sandbox batched in one session | ~0 amortized | **no** (no in-session reset; cleanup discipline required) | one .wsb session, many tests | same as above, but tests share state |
| Hyper-V VM cold-boot per test | ~27–46 s | **yes** | one snapshot revert per test (VM stop+start) | fresh HKCU + FS + Windows Update + reboot |
| Hyper-V VM **hot-snapshot revert** per test | **~5.4 s** | **yes** | one Restore-VMCheckpoint per test (no host stop) | same as cold-boot, but VM stays alive between tests |
| Hyper-V Save-VM/Start-VM (hibernate) | ~4.6 s | **no** (resume preserves state — no reset) | warm-restart only | same as cold-boot |

The Sandbox and Hyper-V numbers below were collected on this dev host
(2026-06-06) with the harnesses in this dir. They are reproducible:
`run-sandbox-bench.ps1` and `run-hyperv-bench.ps1` write their raw
timestamps to `D:\metacraft\sandbox-bench-out\TIMINGS*.txt`.

## Measurement methodology

Both harnesses run a payload inside their isolation environment and
record host-side and in-env timestamps at fixed checkpoints. The
"wall time" is from script start (host) to DONE/Stopped (host).

The payload (the actual test) is **deliberately the same** across
environments so the per-environment overhead is comparable. The test
binary, `t_integration_plan_classifier_bucket_drift_is_cache_hit.exe`,
is pre-built on the host once and copied/mapped into each environment.

Caveat for fair comparison: the m80 test calls `installScoopAppAtVersion`
which needs a real `scoop.ps1` on PATH. The sandbox image doesn't have
scoop installed, so the test fast-fails at the `resolveScoopBinary`
assertion (89 ms). The bare-host run reaches further (1.75–2.9 s) before
failing on a different assertion. **For the apples-to-apples overhead
number, treat the test wall time as a constant and read the difference**
between the environment's total wall time and that constant.

## Windows Sandbox: measured ~12 s overhead floor (2026-06-06)

```
T0_wsb_launch                =  0.000 s
T1_logon_fired_host_observed = +9.086 s   ← Sandbox cold-boot + LogonCommand
T2_script_started            = +11.438 s  ← cmd.exe → powershell.exe handoff
T3_vc_staged                 = +11.747 s  ← VC++ DLL copy to System32 (~0.3 s)
T4_test_started              = +11.790 s  ← stage test exe + sqlite + repro
T5_test_finished             = +11.900 s  ← test ran (89 ms — fast-fail on missing scoop)
T6_done                      = +11.928 s
TOTAL host wall              =  12.072 s
```

Cost breakdown:

| Phase | Cost | Comment |
|---|---|---|
| Sandbox cold-boot | ~9 s | Win11 Sandbox is faster than reputation; on older hosts expect 30–60 s |
| Cmd→PowerShell hop | ~2 s | LogonCommand is `cmd.exe /c` for diagnostic reasons (see `migration.wsb` header) |
| VC++ stage | <1 s | Copying 7 DLLs from the mapped folder to System32 |
| Test wall | = bare-host wall | Sandbox's CPU is host-equivalent; the test runs at host speed |

**Implication.** Per-test sandbox cost is ~12 s + test wall time. So:
- 1-second test → 12 s overhead → **13x**
- 10-second test → 12 s overhead → **2.2x**
- 60-second test → 12 s overhead → **1.2x**
- 100 tests batched into ONE sandbox session → 12 s amortized across 100 → **+0.12 s per test**

The cost is the cold-boot, not the per-test work. Batching is the
right answer if Sandbox isolation suffices.

## Hyper-V VM: measured ~29 s overhead floor (2026-06-06)

Reusing the M69 harness VM `repro-m69-hyperv` reverted to its `base-clean`
snapshot:

```
T0_start          =  0.000 s
T1_revert_done    = +0.189 s   ← Restore-VMCheckpoint (diff-layer drop)
T2_psdirect_ready = +26.592 s  ← Start-VM + Windows boot + PSDirect handshake
T3_stage_done     = +26.760 s  ← Copy-VMFile a tiny payload (host → guest)
T4_invoke_done    = +28.315 s  ← Invoke-Command -VMName ran Get-Date + Get-Content
T5_stopped        = +28.582 s  ← Stop-VM -TurnOff
TOTAL host wall   =  28.586 s
```

Cost breakdown:

| Phase | Cost | Comment |
|---|---|---|
| Restore-VMCheckpoint | ~0.2 s | The differencing-disk revert is a metadata flip |
| Start-VM + boot to PSDirect | ~26 s | Full Windows guest boot to where `Invoke-Command -VMName { hostname }` succeeds |
| Copy-VMFile stage | <0.2 s | tiny file; scales with payload size |
| Invoke-Command round-trip | ~1.5 s | PSDirect channel overhead per RPC, not the command itself |
| Stop-VM -TurnOff | ~0.3 s | Hard power-off; no clean shutdown |

**Implication.** Per-test Hyper-V cost is ~29 s + test wall time + ~1.5 s
per Invoke-Command round-trip (so if the per-test runner stages, runs,
collects logs as three separate Invoke-Commands, that's ~4.5 s of RPC
overhead on top of the 29 s boot).

Comparison (cold-boot path):
- 1-second test → Hyper-V = +29 s → **30x**
- 10-second test → Hyper-V = +29 s → **3.9x**
- 60-second test → Hyper-V = +29 s → **1.5x**
- 100 tests batched into ONE Hyper-V session → 29 s amortized → **+0.29 s per test**

Hyper-V is ~2.4x slower per session than Sandbox (29 s vs 12 s) but
provides full Windows isolation including Windows Update access,
persistent disk, and reboot capability — the three things Sandbox
cannot provide.

## Hyper-V VM with HOT-snapshot revert: measured ~5.4 s per test (2026-06-08)

Standard Checkpoints in Hyper-V capture the memory + CPU + device state
of a RUNNING VM. `Restore-VMCheckpoint` to such a snapshot returns the
VM to that exact running state — no Windows boot, no re-OOBE,
no rebuilding of the Win32 subsystem. The existing `base-clean`
snapshot is a cold snapshot (taken with the VM Off) so it has no memory
state; `run-hyperv-bench-hot.ps1` takes a fresh `base-hot` snapshot
once with the VM running, then measures the revert cycle.

```
Phase A — one-time setup:
  A0_start                       =  0.000 s
  A1_first_boot_done             = +46.468 s   ← cold boot, only paid ONCE
  A2_hot_snapshot_taken          = +2.220 s    ← captures RAM + CPU + devices

Phase B — revert-from-hot × 3 iterations:
  iter1: restore 4.16 s + PSDirect 0.94 s = 5.10 s
  iter2: restore 4.72 s + PSDirect 0.93 s = 5.65 s
  iter3: restore 4.51 s + PSDirect 0.97 s = 5.48 s
  AVERAGE                                = 5.41 s

Phase C — Save-VM / Start-VM (hibernate, NOT a reset):
  C1_save_returned               = +1.673 s   ← writes RAM to disk
  C2_start_returned              = +2.003 s   ← reads RAM back
  C3_psdirect_ready              = +0.943 s
  TOTAL                          = 4.62 s
```

**This changes the routine-CI picture.** With hot-snapshot revert:

| Test wall | Bare host | Sandbox (per-test) | Hyper-V (hot revert) |
|---|---|---|---|
| 1 s   | 1 s   | 13 s (13×)   | **6.4 s (6.4×)** |
| 10 s  | 10 s  | 22 s (2.2×)  | **15.4 s (1.5×)** |
| 60 s  | 60 s  | 72 s (1.2×)  | **65.4 s (1.1×)** |
| 100 batched | 100 t | +0.12 s/test | **46 s setup + 100 × (5.4 + test_wall)** |

Hyper-V with hot revert is **competitive with per-test Sandbox** for
sub-minute tests, AND it gives every test full pristine state without
needing in-test cleanup discipline. For tests requiring DISM / Windows
Update / reboot it's the only option — and the cost is no longer
prohibitive.

**Save-VM / Start-VM is a different tool.** It's hibernate: state is
preserved across the cycle, so it doesn't give you a reset. Useful only
for "warm restart this same state" workflows (e.g., resume after a
host-side power blip during a long test session). Don't confuse it
with hot-snapshot revert.

**Sandbox has no equivalent.** Windows Sandbox is a Hyper-V-isolated
container, but its lifecycle is wrapped by the Sandbox Manager which
exposes no save/checkpoint API. There is no `Save-Sandbox` cmdlet, no
in-config checkpoint directive, and no `*-Sandbox` PowerShell command
beyond launching one via `WindowsSandbox.exe <wsb-file>`. Mapped
writable folders are the only state that survives a session. So the
12 s Sandbox cost is per-session, full stop — you can't amortize it
the way you can with Hyper-V hot revert.

## Hyper-V hot checkpoints are portable across hosts (2026-06-08)

`run-hyperv-bench-portable.ps1` exports a VM with a hot Standard
Checkpoint, then imports it back as a new VM with a fresh ID and
times the resume cycle:

```
Phase A (one-time setup, paid once per cached image):
  First boot to PSDirect          43.838 s
  Checkpoint-VM (Standard, hot)    2.111 s
  Stop-VM                          0.313 s

Phase B (Export-VM):
  Export-VM returned               1.737 s     (same-volume reflink)
  export_total_gb                 53.21 GB
  .vhdx files                     52.53 GB    (2 files, base + diff)
  .avhdx files                     1.25 GB    (snapshot diffs)
  .VMRS files (memory state)       0.69 GB    (3 files; the big one is the hot checkpoint's RAM image)
  .vmgs files                      0.01 GB
  .vmcx files                      ~120 KB

Phase C (Import-VM and resume on the IMPORTED VM):
  Import-VM                        3.023 s
  imported_snapshot_names        = base-clean, exp-hot   ← both came through
  Restore-VMCheckpoint exp-hot     0.128 s
  Start-VM (memory resume)         3.740 s
  PSDirect ready                   0.979 s
  TOTAL import+resume              7.870 s
```

**Bottom line:**
- `.VMRS` files are the snapshot's memory + CPU + device state, and they ARE included in `Export-VM`.
- `Import-VM` brings back the full snapshot tree.
- `Restore-VMCheckpoint` to a hot snapshot on the imported VM works the same as on the original.
- Same-volume export uses reflinks/hardlinks for VHDX files; **the real cross-host payload is ~10 GB** (the VHDX content) + 0.7 GB (memory state) + ~13 MB (config) ≈ **10.7 GB uncompressed**. VHDX content is highly compressible (lots of zeros from sparse provisioning).

**CI artifact-caching model:**
- ONE CI runner (the "warmer") pays the 44 s boot cost ONCE, takes the hot checkpoint, exports the VM, compresses the export folder, and uploads it as a CI artifact.
- Every other runner pulls the artifact, decompresses, `Import-VM`s, `Restore-VMCheckpoint`s to the hot snapshot, `Start-VM`s. Total runner-side cost on a warm machine: **~8 s**.
- Per-test cost on the imported VM: ~5.4 s (the same hot-revert cycle).

**Cross-host caveats:**
- **CPU compatibility.** Memory-state snapshots capture CPU registers and feature flags. Importing on a CPU that lacks features the snapshot expects (e.g. older AVX support) may fail or produce subtle errors. Hyper-V has a "Migrate to a physical computer with a different processor version" option on VM CPU config that masks features down to a baseline — set this on the warmer VM if the CI fleet is heterogeneous.
- **Hyper-V version skew.** A newer Hyper-V's export should import on the same or newer version; downgrade is not supported.
- **Generation 1 vs 2.** Same generation in both ends. The harness VM here is Gen 2.

## When portability is worth the bother

It's worth it when:
- The CI fleet has many runners and the per-runner boot cost (44 s) sums to a real wall-clock loss.
- The test suite needs Hyper-V isolation (DISM, reboots, VS Installer — see `tools/hyperv-m69-system/README.md`) and so can't fall back to Sandbox.
- The runners can store ~10 GB of cached image.

It's NOT worth it when:
- The whole suite is bare-host eligible (REPRO_REGISTRY_ROOT + per-test tempdirs cover it).
- There are <10 runners in the fleet — the warmer-runner cost amortizes badly.
- The test wall time per runner is dominated by per-test work, not by the one-time boot.

The first-time provisioning cost (downloading the 20-50 GB Windows 11
dev VHDX, running OOBE, uninstalling VS, installing Nim/gcc, snapshotting)
is **NOT** in the per-test overhead; it's a one-time bootstrap. See
`tools/hyperv-m69-system/README.md`.

## Which path to pick

The four paths are complementary, not interchangeable. Use this
decision table:

| Test class | Use |
|---|---|
| Touches process-local state only (no HKCU/PATH/services) | bare host |
| Writes to HKCU (env.userPath, registry resources) | bare host with REPRO_REGISTRY_ROOT (see project memory) — the leak fix supersedes the need to sandbox these |
| Touches files in stable system paths (Program Files, ProgramData), needs per-test pristine | Hyper-V hot-revert — runs at 5.4 s/test with full reset |
| Touches files BUT tests can be ordered/grouped so they don't collide | Sandbox per-test (12 s) OR Sandbox batched (if cleanup discipline is real) |
| Needs DISM / OptionalFeature / Capability / WSL / VS Installer / reboot | Hyper-V VM (`tools/hyperv-m69-system/`) — Sandbox cannot provide Windows Update, persistent disk, or reboot capability |
| Needs full Linux destructive scope | throwaway WSL (separate harness; see destructive-gate environments memo) |

The combination of REPRO_REGISTRY_ROOT (driver-level seam, 0 overhead)
+ Hyper-V hot-revert (5.4 s/test, full pristine state) covers the
vast majority of the destructive-test surface without per-test cleanup
discipline. Use Sandbox where its lower memory footprint (~4 GB vs
Hyper-V's whole guest OS) matters more than the per-test isolation
gap.

Sandbox and Hyper-V both isolate from the host, but Sandbox can't run
Windows Update / reboot / install VS. That's the dividing line
documented in `tools/hyperv-m69-system/README.md` § "Why Hyper-V (and
not Sandbox)" — quoting the empirical record (DISM payload fetch fails;
VS Build Tools >1 hour; no reboots).

## Files

| File | Runs on | Purpose |
|---|---|---|
| `bench.wsb` | host | Windows Sandbox config; mapped folders + LogonCommand |
| `provision-and-bench.ps1` | inside Sandbox | Stages VC++ DLLs and runs the bench payload; writes TIMINGS.txt |
| `run-sandbox-bench.ps1` | host | Launches the sandbox, polls for DONE, reports timing |
| `run-hyperv-bench.ps1` | host | Reverts the M69 harness VM (cold path), runs a trivial payload, reports timing |
| `run-hyperv-bench-hot.ps1` | host | Takes a hot Standard Checkpoint, measures revert-to-running and Save-VM/Start-VM cycles |
| `run-hyperv-bench-portable.ps1` | host | Round-trips a hot checkpoint through Export-VM / Import-VM; proves portability and reports import+resume cost |
| `README.md` | — | This file |
