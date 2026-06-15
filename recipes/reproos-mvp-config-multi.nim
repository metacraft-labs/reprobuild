## D2 P4: ReproOS MVP multi-distro system configuration.
##
## Extends ``reproos-mvp-config.nim`` from 5 apt packages to 9 mixed-distro
## packages, exercising every foreign-distro adapter the campaign delivers:
##
##   apt    : git, vim, python3, curl, htop  (5; same as D1)
##   dnf    : htop, neovim                   (2; Fedora 39 snapshot)
##   pacman : htop, fzf                      (2; Arch rolling snapshot)
##
## ``htop`` is intentionally pinned across all three distros. The D2 gate
## asserts that the three coexist (different prefixes, different shims,
## different launcher manifests) without FHS collisions.
##
## Each distro's binary is invoked through ``$prefix/bin/<name>`` (or
## ``<distro>-<name>`` for the dnf + pacman copies to disambiguate via
## /usr/local/bin). The C3 ``reprobuild-sandbox-launcher`` materialises
## the bind-mount manifest per-prefix; the same launcher works for all
## three distros (the FHS sandbox is distro-agnostic).

system reproosMvpMulti:
  kernel = reproosKernel

  kernel_cmdline = [
    "console=tty1",
    "console=ttyS0,115200n8",
    "earlyprintk=ttyS0,115200",
    "loglevel=7",
    "init=/sbin/init",
    "rw",
  ]

  packages = [
    coreutils,
    bash,
    systemd,
    # 5 apt packages from the D1 snapshot pin.
    package(apt, "git",     snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "vim",     snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "python3", snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "curl",    snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "htop",    snapshot = "debian/bookworm/20260601T000000Z"),
    # 2 dnf packages from the Fedora 39 snapshot.
    package(dnf, "htop",    snapshot = "fedora/39/20260601"),
    package(dnf, "neovim",  snapshot = "fedora/39/20260601"),
    # 2 pacman packages from the Arch rolling snapshot.
    package(pacman, "htop", snapshot = "archlinux/rolling/20260601"),
    package(pacman, "fzf",  snapshot = "archlinux/rolling/20260601"),
  ]

  users:
    user "root":
      shell = bash
      password_hash = "$6$reproosMvpD1$rrZAqlA3J4u9SLnxnaWWMcQAgVTXMplGNjmnt7yfZP3SyxEv.kE8Va8VbPVD0WBmlLhRrPYz3wO/U5O7Q1mvJ/"
      groups = ["wheel"]
      home_dir = "/root"

  services:
    enable "serial-getty@ttyS0.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "rw,relatime"
