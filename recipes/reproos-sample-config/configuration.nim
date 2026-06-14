## B1: sample ReproOS system-scope configuration. Demonstrates every
## DSL surface — kernel + cmdline + Tier 1 + Tier 3 + users +
## services + mounts + imports — and is the fixture for the B1
## integration tests under
## `libs/repro_system_apply/tests/t_b1_dsl_*.nim`.

system reproosSampleConfig:
  imports:
    "./modules/users.nim"
    "./modules/git.nim"

  kernel = reproosKernel

  kernel_cmdline = [
    "console=ttyS0,115200n8",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    package(apt, "vim", snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "ada":
      # Overrides the imported module's `ada` entry: same name keeps
      # the existing slot; the merge-rule documented in
      # `docs/reproos-config-dsl.md` says last-write-wins on
      # collisions, so the parent's `groups` field replaces the
      # imported module's value.
      shell = bash
      groups = ["wheel", "video", "audio"]
      home_dir = "/home/ada"

  services:
    enable "systemd-networkd.service"
    enable "serial-getty@ttyS0.service"
    disable "systemd-resolved.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "ro,relatime"
    mount "/boot", source = "LABEL=reproos-boot", fstype = "vfat", options = "umask=0077"
