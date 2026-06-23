# /etc/repro/system.nim ─ the user-editable ReproOS system configuration
# entry point for the canonical reproos-desktop generation.
# ---------------------------------------------------------------------
#
# This is the M9.R.20.4 port: the existing `package reproosDesktop:`
# recipe at `./repro.nim` is the build-graph anchor (it still owns the
# multi-contributor merged `/etc/ld.so.conf.d/00-reproos-linux.conf`,
# the displayManagerSymlink artifact, the variant: arm dispatch, the
# validate: predicate, and the bootloader: menu entry). This sibling
# `./system.nim` is the user-facing surface the installer writes + the
# user edits per ReproOS-Configuration-Architecture.md §2.2.
#
# The two files are sibling-coupled by design (per the spec §2.5):
#   * `system.nim` says WHAT this machine should look like — hostname,
#     timezone, default DE, default user, which activities to enable.
#   * `repro.nim` (the build-graph anchor) says HOW the system-level
#     reproos-desktop intent compiles to fs.* artifacts.
#
# M9.R.20.4 demonstrates that the system.nim a user can edit IS
# parseable by the new `system "<hostname>":` macro and round-trips
# through the SystemIntent → JSON → SystemIntent loop. The end-to-end
# composition that consumes this SystemIntent + drives the existing
# `materializeReproosDesktop()` impl module is a follow-up milestone
# (M9.R.21+ for the apply-layer integration).

import repro_profile

system "reproos-default":

  imports:
    "./hardware.nim"
    "modules/activities/development.nim"
    "modules/activities/desktop-core.nim"
    "modules/activities/communication.nim"
    "modules/de/plasma.nim"
    "modules/de/sway.nim"
    "modules/de/gnome.nim"
    "modules/networking/networkmanager.nim"

  config:
    ## Hostname for this machine. Drives /etc/hostname + DHCP-client identity.
    hostname: string = "reproos-default"

    ## IANA timezone. The os.timezone driver maps to platform-native form.
    timezone: string = "UTC"

    ## System locale.
    locale: string = "en_US.UTF-8"

    ## Default account name; matches the legacy `repro.nim` defaultUser.
    defaultUser: string = "repro"

    ## GRUB menu timeout in seconds. Mirrors the bootloader: block below.
    bootloaderTimeout: int = 5

    ## apt-jammy snapshot pin propagated to every sub-package's
    ## sub-config; bumping this invalidates the right thing transitively.
    aptSnapshot: string = "ubuntu/jammy/20260615T000000Z"

    ## Default DE the generation boots into. The closure-affecting set
    ## of installable DEs (the variant) lives in the imported
    ## modules/de/*.nim — this configurable just picks which installed
    ## DE the display-manager autoboots.
    activeAtBoot: string = "plasma"

  users:
    "repro":
      groups: @["wheel", "audio", "video", "networkmanager"]
      homeIntent: import "./home.nim"

  services:
    enable: @["NetworkManager", "sshd", "sddm"]
    disable: @[]

  bootloader:
    `type`: grub
    device: "/dev/sda"
