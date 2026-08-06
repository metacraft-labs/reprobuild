# reproos-image — NixOS-style build-artifact ReproOS image recipe

**M9.R.50.2.** Spec: [`reprobuild-specs/ReproOS-Image-Recipe.md`](../../../reprobuild-specs/ReproOS-Image-Recipe.md).

Produces a fully-installed `reproos-installed.qcow2` as a build
artifact, on the host, with no boot-time installer step. The
artifact boots directly into multi-user.target + the configured
DE.

## Usage

```sh
# Minimal smoke fixture
repro build recipes/reproos-image

# Custom config
REPRO_AUTO_CONFIG=/path/to/auto-config.toml repro build recipes/reproos-image
```

## Inputs

- `$REPRO_AUTO_CONFIG` — path to a TOML config conforming to the
  schema in the spec doc. Defaults to
  `tests/fixtures/auto-config-minimal.toml`.

## Outputs

- `recipes/reproos-image/.repro/output/install/<sha256>-reproos-installed.qcow2`

## Host requirements

- `qemu-img`, `qemu-nbd` (from the qemu package)
- `parted`, `sgdisk`, `mkfs.ext4`, `mkfs.vfat`
- `rsync`, `grub-install`, `grub-mkconfig`
- `sudo` + the `nbd` kernel module (modprobe'd by the driver)

## Boot smoke

```sh
_m9r50_boot_smoke.sh
```

Boots the artifact via OVMF UEFI, autologins as the configured user,
runs `--version` checks on every DE binary, and asserts the system
reaches `multi-user.target`.

## Boot a development VM

With the `vm-harness` CLI on `PATH`, the recipe exposes a task that selects
the newest content-addressed QCOW2 output and leaves a transient VM running:

```sh
cd recipes/reproos-image
repro run boot-vm
```

The same task uses Hyper-V on Windows and libvirt/QEMU on Linux. Hyper-V
requires an elevated shell and `qemu-img`; vm-harness converts the QCOW2 to a
temporary VHDX before attaching it. Additional vm-harness arguments can be
forwarded after `--`.
