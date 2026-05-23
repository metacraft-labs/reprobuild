# M69 POSIX destructive-gate WSL harness

A **throwaway WSL distro** test harness that runs the **real-mutation half**
of the M69 Linux `passwd.user` destructive gate inside a disposable
Ubuntu 22.04 WSL distribution - so the gate exercises real `useradd` /
`usermod` / `userdel` mutations with **zero risk to the host**.

This is *test instrumentation*, not a shipped feature. It exists to
close out M69 by turning the `pending` Linux gate into `passed`:

  * `tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim`
    (`REPRO_M69_PASSWD_VM=1`)

The non-destructive half of the gate already passes on every host (the
pure parsers + diff logic + typed-operation wiring + the
`--accept-passwd-destroy` safety gate); this harness only adds the
host-altering scenario.

## Why a throwaway WSL distro

`useradd` / `usermod` / `userdel` are real `/etc/passwd` mutations that
need root. The gate's `REPRO_M69_PASSWD_VM` guard makes the gate refuse
to mutate a real host. The author's host is Windows; Linux is reached
via WSL.

A **throwaway** distro - created from an Ubuntu cloud-image rootfs,
used once, unregistered with `wsl --unregister` - is the safety
boundary: every `useradd`/`userdel`/`/etc/passwd` write happens inside
the disposable distro and disappears when the distro is unregistered.
The harness uses `try { ... } finally { wsl --unregister }` so a gate
failure does **not** leak a stale distro.

The user's existing primary WSL distribution (`eli-wsl`) is **never
touched**: the harness imports a new distro with a unique, namespaced
name (`repro-m69-posix-<pid>`) into a separate install location on
`D:\metacraft\wsl-m69-posix-state\`.

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
exactly what the gate's real-mutation half expects.

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `run-wsl-m69-posix.ps1` | host | Downloads rootfs (cached), imports a throwaway distro, runs the in-distro provisioner, polls for `DONE`, surfaces results, **unregisters the distro in `finally`** |
| `provision-and-run-m69-posix.sh` | **in distro** | apt-installs gcc + libsqlite3-dev + curl, downloads Nim 2.2.8 binary tarball, copies the repo source out of the read-only mount into a writable workdir, builds the gate binary, sets `REPRO_M69_PASSWD_VM=1`, runs it, captures output |
| `README.md` | -- | This file |

## Rootfs source

  * URL: `https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz`
  * Distribution: Ubuntu 22.04 LTS ("Jammy Jellyfish")
  * Size: ~325 MB
  * Why Jammy and not Noble (24.04)? At the time the harness was written
    the Noble WSL rootfs tarball was not published in the
    `cloud-images.ubuntu.com/wsl/noble/current/` directory (only the
    manifest was). Jammy's `passwd` package (1.5.0+) provides `useradd`
    / `usermod` / `userdel` exactly as the gate requires.
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

## C toolchain + libsqlite3

`gcc` and `libsqlite3-dev` are apt-installed inside the distro. The
project's `config.nims` (Linux branch) links `libsqlite3` from
`/usr/lib/x86_64-linux-gnu/libsqlite3.so` for `repro_local_store`.

## How the build runs inside the distro

The host repo is reachable from inside the distro at
`/mnt/d/metacraft/reprobuild` (the standard WSL `/mnt/<drive>/` view of
Windows drives), and the sibling runquota repo at
`/mnt/d/metacraft/runquota`. The provision script does NOT build
in-place on `/mnt/`: Windows filesystem IO via the 9P bridge is roughly
10x slower than ext4 inside the distro, and case sensitivity of NTFS
files differs from ext4 in ways that occasionally trip Nim's path
handling. Instead, the script:

  1. `cp -a /mnt/d/metacraft/reprobuild /work/reprobuild` (full repo
     copy - ~few hundred MB; fits in tmpfs / VHD without issue).
  2. `cp -a /mnt/d/metacraft/runquota /work/runquota` (sibling repo,
     same reason - `config.nims` looks for it at `..` of reprobuild).
  3. `cd /work/reprobuild && /opt/nim-2.2.8/bin/nim c -r ... tests/e2e/m69/t_e2e_repro_infra_passwd_user_safe_destroy.nim`
     with `REPRO_M69_PASSWD_VM=1` set in the environment.

The gate binary is built and run in one `nim c -r` invocation; output
goes to `/work/out/02-gate-run.txt`, which the script then copies to
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
| `01-gate-build.log` | gate compile log (nim c output) |
| `02-gate-run.txt` | gate stdout/stderr + exit code (the real test output) |
| `RESULT.txt` | per-stage status + one-line verdict |
| `DONE` | sentinel - written **last** |

## How cleanup runs

`run-wsl-m69-posix.ps1` wraps the run in a `try { ... } finally { ... }`.
The `finally` block:

  1. Terminates the distro (`wsl --terminate <name>`).
  2. Unregisters the distro (`wsl --unregister <name>`).
  3. Removes the install directory (`D:\metacraft\wsl-m69-posix-state\<name>\`).

This runs regardless of whether the gate passed, failed, or threw - so
a gate failure does NOT leak a stale distro. The runner verifies
post-run that `wsl --list --quiet` no longer lists the throwaway
distro.

## Idempotence

A re-run cleans up any stale distro from a prior aborted run *before*
creating a new one. Specifically, `Start` matches `repro-m69-posix-*`
in `wsl --list --quiet` and unregisters every match before importing
the new distro. Any stale install directories under
`D:\metacraft\wsl-m69-posix-state\` not corresponding to a live distro
are also removed.

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
   ~30 sec; gate build ~60 sec; gate run ~5 sec; total per run after
   first ~3-5 min.

3. Read the artifacts in `D:\metacraft\wsl-m69-posix-out\`.

## Host-safety guarantees

  * Every `useradd` / `usermod` / `userdel` runs inside the throwaway
    distro - the host's `/etc/passwd` is never touched.
  * The Windows host's filesystem is only ever modified inside two
    scoped directories: `D:\metacraft\wsl-m69-posix-cache\` (rootfs +
    Nim tarball cache) and `D:\metacraft\wsl-m69-posix-out\` (results).
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
