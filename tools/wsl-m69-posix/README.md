# M69 POSIX destructive-gate WSL harness

A **throwaway WSL distro** test harness that runs the **real-mutation halves**
of the M69 Linux destructive gates inside a disposable Ubuntu 22.04 WSL
distribution - so the gates exercise real `useradd` / `usermod` / `userdel`
mutations, real `/etc/` file writes, real `/etc/profile.d/` fragment writes,
and real `/etc/systemd/system/` unit-file writes + `systemctl daemon-reload`
with **zero risk to the host**.

This is *test instrumentation*, not a shipped feature. It exists to close
out M69 by turning the `pending` Linux gates into `passed`:

  * `tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim`
    (`REPRO_M69_PASSWD_VM=1`)
  * `tests/e2e/m69/t_e2e_repro_infra_fs_system_file.nim`
    (`REPRO_M69_FS_VM=1`)
  * `tests/e2e/m69/t_e2e_repro_infra_env_system_variable.nim`
    (`REPRO_M69_ENV_VM=1`)
  * `tests/e2e/m69/t_e2e_repro_infra_systemd_system_unit.nim`
    (`REPRO_M69_SYSTEMD_VM=1`)

The non-destructive halves of every gate already pass on every host (the
pure parsers + diff logic + typed-operation wiring + the safety gates);
this harness only adds the host-altering scenarios.

## Why a throwaway WSL distro

`useradd` / `usermod` / `userdel`, writes under `/etc/`, and `systemctl
daemon-reload` are all real system mutations that need root. Each gate's
`REPRO_M69_*_VM` guard makes the gate refuse to mutate a real host. The
author's host is Windows; Linux is reached via WSL.

A **throwaway** distro - created from an Ubuntu cloud-image rootfs, used
once, unregistered with `wsl --unregister` - is the safety boundary: every
real mutation happens inside the disposable distro and disappears when the
distro is unregistered. The harness uses `try { ... } finally { wsl
--unregister }` so a gate failure does **not** leak a stale distro.

The user's existing primary WSL distribution (`eli-wsl`) is **never
touched**: the harness imports a new distro with a unique, namespaced name
(`repro-m69-posix-<pid>`) into a separate install location on
`D:\metacraft\wsl-m69-posix-state\`.

## Multi-gate, one distro session

All four M69 Linux destructive gates run **in a single distro session**:
the harness provisions the rootfs / Nim / shims **once**, then builds and
runs each gate sequentially. Each gate is invoked under `env -i ...
REPRO_M69_<X>_VM=1 <gate-bin>` so only that gate's env var is set for its
run - cross-pollination (one gate accidentally triggering another's
destructive branch) is impossible. Per-gate stdout/stderr/exit lands in
its own `02-<gate>-run.txt`; `RESULT.txt` summarizes per-gate exits + the
overall verdict; `DONE` is written last.

## systemd-in-WSL: scope of the systemd.systemUnit gate

Ubuntu 22.04 WSL supports systemd-as-PID-1 via `/etc/wsl.conf` (`[boot]
systemd=true`) and a `wsl --terminate` + re-enter cycle. We do **not**
activate systemd-as-PID-1 in this harness; instead, the
`systemd.systemUnit` gate is scoped to:

  * write a `.service` unit under `/etc/systemd/system/`;
  * call `systemctl daemon-reload` (which works without systemd-as-PID-1
    - it parses the unit file from disk and validates it);
  * call `systemctl show` (parses from the unit file on disk);
  * exercise the drift-detection + rollback path on the unit file.

The fixture sets `enabled = false` in its `systemd.systemUnit { ... }`
resource, so the driver does **not** call `systemctl enable --now`. The
real `enable --now` + active-state runtime path is **deferred to a
Hyper-V / real-Linux VM**, consistent with M69's existing deferrals for
runtime paths that cannot run inside the M69 Phase C sandbox. This
trade-off keeps the harness simple and reliable while still genuinely
exercising the file-on-disk + daemon-reload + drift + rollback contract
the M69 spec asserts.

## Why `wsl --import` from a rootfs tarball

Two alternatives were considered and rejected:

  * `wsl --install -d Ubuntu` - depends on the Microsoft Store / WSL
    distribution catalog; not scriptable (a fresh distro asks for a
    user/password on first run); leaves a registered distro behind.

  * `wsl --export` / `wsl --import` of the user's primary distro -
    contaminates the harness with the user's apt cache and home
    directory; large; not reproducible.

`wsl --import <name> <install-dir> <tarball>` from the official Ubuntu
cloud-image WSL rootfs is fully scriptable, leaves no Microsoft Store
state, is reproducible, and gives a pristine root environment that is
exactly what the gate's real-mutation halves expect.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `run-wsl-m69-posix.ps1` | host | Downloads rootfs (cached), imports a throwaway distro, runs the in-distro provisioner, polls for `DONE`, surfaces per-gate results, **unregisters the distro in `finally`** |
| `provision-and-run-m69-posix.sh` | **in distro** | apt-installs gcc + libsqlite3-dev + curl + systemd, downloads Nim 2.2.8, copies the repo source out of the read-only mount into a writable workdir, installs verification shims for useradd/usermod/userdel/systemctl, then for each gate: builds + runs with its REPRO_M69_*_VM=1 env var set, captures output |
| `README.md` | -- | This file |

## Rootfs source

  * URL: `https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz`
  * Distribution: Ubuntu 22.04 LTS ("Jammy Jellyfish")
  * Size: ~325 MB
  * Why Jammy and not Noble (24.04)? At the time the harness was written
    the Noble WSL rootfs tarball was not published in the
    `cloud-images.ubuntu.com/wsl/noble/current/` directory (only the
    manifest was). Jammy's `passwd` package + `systemd` package give us
    `useradd` / `usermod` / `userdel` and `systemctl` exactly as the
    gates require.
  * Cached under `D:\metacraft\wsl-m69-posix-cache\` so re-runs do not
    re-download. The cache is content-checked by name; delete the file
    to force a re-download.

## Nim toolchain inside the distro

Ubuntu 22.04 ships Nim 1.6.x; the project's `reprobuild.nimble` requires
`nim >= 2.2.0`. The provision script downloads the official Nim 2.2.8
prebuilt Linux x64 binary tarball:

  * URL: `https://nim-lang.org/download/nim-2.2.8-linux_x64.tar.xz`
  * Size: ~16 MB

This matches the host's Nim version (`D:\metacraft-dev-deps\nim\2.2.8`).

## C toolchain + libsqlite3 + systemd

`gcc`, `libsqlite3-dev`, and `systemd` are apt-installed inside the distro.
The `systemd` package supplies the `systemctl` binary the
`systemd.systemUnit` gate exercises (file-on-disk + daemon-reload path
only; see "systemd-in-WSL" above).

## Verification shims

The destructive shell-outs each gate may invoke are SHIMMED inside the
distro so the gate's destructive code path is provably exercised:

  * `useradd`, `usermod`, `userdel`  ->  log argv to
    `03-passwd-cmd-trace.log`, forward to `<name>.real`
  * `systemctl`  ->  log argv to `04-systemd-cmd-trace.log`, forward to
    `systemctl.real`

After each gate runs the harness greps the trace logs for the
expected destructive pattern (e.g. the passwd gate must have called
`useradd`; the systemd gate must have called `systemctl daemon-reload`)
and records the result in `RESULT.txt`. The shims FORWARD to the real
binary - they never swallow the call. This is observability, not gating.

## How the build runs inside the distro

The host repo is reachable from inside the distro at
`/mnt/d/metacraft/reprobuild`, and the sibling runquota repo at
`/mnt/d/metacraft/runquota`. The provision script does NOT build in
place on `/mnt/`: Windows filesystem IO via the 9P bridge is roughly
10x slower than ext4 inside the distro. Instead it copies both repos
into `/work/` first, then `cd /work/reprobuild && nim c -r ...` for
each gate.

Each gate binary is built and run in one `nim c -r` invocation; output
goes to `/work/out/02-<gate>-run.txt`, which the script then copies to
the host-visible OUTPUT directory.

## How output is captured

The host directory `D:\metacraft\wsl-m69-posix-out\` is the OUTPUT
folder. From inside the distro it is reachable at
`/mnt/d/metacraft/wsl-m69-posix-out/`. The bash script copies its
artifacts to that path as its last steps, with the `DONE` sentinel
written **last** so the host runner knows everything else flushed.

| File | Content |
|------|---------|
| `00-provision.log` | full stage-by-stage provisioning log |
| `01-<gate>-build.log` | per-gate compile log (e.g. `01-passwd-user-build.log`) |
| `02-<gate>-run.txt` | per-gate stdout/stderr + exit code (e.g. `02-fs-system-file-run.txt`) |
| `03-passwd-cmd-trace.log` | useradd/usermod/userdel argv trace |
| `04-systemd-cmd-trace.log` | systemctl argv trace |
| `RESULT.txt` | per-stage + per-gate status, one-line verdict |
| `DONE` | sentinel - written **last** |

## How cleanup runs

`run-wsl-m69-posix.ps1` wraps the run in a `try { ... } finally { ... }`.
The `finally` block:

  1. Terminates the distro (`wsl --terminate <name>`).
  2. Unregisters the distro (`wsl --unregister <name>`).
  3. Removes the install directory (`D:\metacraft\wsl-m69-posix-state\<name>\`).

This runs regardless of whether the gates passed, failed, or threw - so
a gate failure does NOT leak a stale distro. The runner verifies post-run
that `wsl --list --quiet` no longer lists the throwaway distro.

## Idempotence

A re-run cleans up any stale distro from a prior aborted run *before*
creating a new one. Specifically, `Start` matches `repro-m69-posix-*` in
`wsl --list --quiet` and unregisters every match before importing the new
distro. Any stale install directories under
`D:\metacraft\wsl-m69-posix-state\` not corresponding to a live distro are
also removed.

## How to run

1. Source the dev shell (the host-side runner needs no Nim toolchain;
   the dev shell is sourced only for parity with the other harnesses):

   ```pwsh
   . D:\metacraft\env.ps1
   ```

2. Run the host-side runner:

   ```pwsh
   pwsh -File D:\metacraft\reprobuild\tools\wsl-m69-posix\run-wsl-m69-posix.ps1
   ```

   Wall-clock budget: rootfs download ~325 MB (one-time, cached
   thereafter); Nim tarball ~16 MB (one-time per distro); apt-get
   ~30-60 sec; per-gate build ~60 sec * 4; per-gate run ~5 sec * 4;
   total per run after first ~5-8 min.

3. Read the artifacts in `D:\metacraft\wsl-m69-posix-out\`.

## Host-safety guarantees

  * Every `useradd` / `usermod` / `userdel`, every `/etc/` write, every
    `systemctl daemon-reload` runs inside the throwaway distro - the
    host's filesystem and account database are never touched.
  * The Windows host's filesystem is only ever modified inside three
    scoped directories: `D:\metacraft\wsl-m69-posix-cache\` (rootfs +
    Nim tarball cache), `D:\metacraft\wsl-m69-posix-out\` (results),
    and `D:\metacraft\wsl-m69-posix-state\` (the throwaway distro's VHD).
  * The user's primary WSL distribution (`eli-wsl`) is **never**
    referenced or modified.
  * The distro is unregistered in a `finally` block, so a gate failure
    leaves no trace.

## Known limitations

  * Networking inside the distro is required for the apt-get install
    and the Nim tarball download. The cloud-images rootfs ships
    networking enabled by default for WSL2.
  * The rootfs download is ~325 MB; the first run pays that one-time
    cost. Subsequent runs reuse the cached file.
  * The harness assumes WSL 2 is the default WSL version on the host
    (it is, per `wsl --status`). `wsl --import` defaults to the
    default WSL version, so no explicit `--version 2` is needed.
  * The `systemd.systemUnit` gate's `enable --now` + active-state
    runtime path is **deferred** to a real-Linux / Hyper-V VM (see the
    "systemd-in-WSL" section above). The harness exercises the
    file-on-disk + daemon-reload + drift + rollback path, which is the
    real M69 driver contract; the runtime-state path is consistent with
    M69's other sandbox-deferred paths.
