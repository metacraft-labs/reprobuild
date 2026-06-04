# M9 WSL sandbox harness

The canonical disposable env for running the M9 Linux home-profile
validation harness on a Windows dev host (per
``project_reprobuild_destructive_gate_envs`` — "throwaway WSL for Linux
system-scope").

This directory's WSL harness mirrors the shape of
``tools/sandbox-migration/`` (Windows Sandbox harness) but targets a
throwaway WSL distro instead of Windows Sandbox.

## Operator-supplied WSL bootstrap

The WSL base tarball is OUT OF SCOPE for M9 to ship (Ubuntu base is
~50MB compressed; too large to commit to the reprobuild repo). The
operator supplies the tarball and the harness imports it.

### One-time setup on the Windows dev host

```powershell
# 1. Download a minimal Ubuntu base tarball (or use any other distro
#    you trust). Ubuntu 22.04 LTS images are available at
#    https://cloud-images.ubuntu.com/wsl/jammy/current/ as
#    ``ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz``.
$base = "$env:USERPROFILE\Downloads\ubuntu-jammy-wsl-amd64.rootfs.tar.gz"

# 2. Import as a throwaway WSL distro. The instance dir is also
#    throwaway — point it at a scratch dir you can ``Remove-Item`` after
#    the run.
$instanceDir = "$env:LOCALAPPDATA\WSL\m9-throwaway"
New-Item -ItemType Directory -Force -Path $instanceDir | Out-Null
wsl --import m9-throwaway $instanceDir $base

# 3. (Optional) Pre-install ghc + cabal + crystal inside the distro
#    via apt so the LIVE harness picks them up via the cakPath
#    fallback. The M9 catalog half (poLinux slices in
#    packages/<tool>.nim) is awaiting a Linux harvester pass; until
#    that lands the LIVE harness needs SOME path resolution to
#    graduate the fixtures.
wsl -d m9-throwaway -- bash -c "apt-get update && apt-get install -y ghc cabal-install crystal"

# 4. Run the harness from inside the throwaway distro.
wsl -d m9-throwaway --cd /mnt/d/metacraft/reprobuild -- bash -c \
  "REPRO_LIVE=1 ./scripts/verify-m9-linux-home-profile-fixtures.sh"

# 5. Tear down.
wsl --terminate m9-throwaway
wsl --unregister m9-throwaway
Remove-Item -Recurse -Force $instanceDir
```

### Inside the throwaway distro — first-run reprobuild build

The harness expects ``build/bin/repro`` to already exist. Build it
once inside the distro (the artifact lives under the repo's
``build/bin/`` and is reused across runs):

```bash
# Inside the WSL distro (one-time setup):
cd /mnt/d/metacraft/reprobuild
sudo apt-get install -y nim build-essential
bash ./scripts/build_apps.sh
```

The build produces ``build/bin/repro`` (Linux ELF), which is what the
M9 harness invokes.

### Why a separate throwaway distro?

WSL distros share the host filesystem via ``/mnt/`` mounts. A
``wsl --unregister`` only removes the distro's per-instance VHDX; the
host's ``/mnt/d/metacraft/`` is untouched. This pattern is the
canonical "destructive-gate disposable env" for Linux — see
``project_reprobuild_destructive_gate_envs`` in the user's memory.

## Hermetic counterpart

The M9 resolver-level contract is asserted by
``tests/e2e/m9/t_e2e_m9_linux_phase2_partials_resolve.nim``. That gate
runs on Windows under ``scripts/run_tests.sh`` and threads
``hostOs = poLinux`` through ``chainResolvePackage`` to assert the
chain's per-adapter classification matrix without needing a real
Linux host. The WSL harness here is the LIVE-on-Linux gate (gated
behind ``REPRO_LIVE=1`` per the M9 verification table).

## Out of scope for M9

- Shipping the WSL base tarball (~50MB; too large).
- macOS validation (no macOS test runner in M9; M71 closing-table note
  for macOS stands).
- Non-glibc distros (Alpine/musl); M9 covers WSL Ubuntu only.
- CI integration — the harness is operator-runnable from a Windows
  dev host with WSL. A future M wires it as a periodic CI gate.
