## D1 P1: ReproOS MVP system configuration.
##
## The D1 acceptance gate from
## ``ReproOS-Generations-And-Foreign-Packages.milestones.org``: a
## reprobuild-managed system that boots into systemd PID 1 and runs
## **five foreign packages from a pinned Debian bookworm snapshot**
## under the C3 bind-mount sandbox launcher.
##
## The five packages exercise the breadth of the catalog adapter:
##
## * ``git``     — classic VCS; pulls libcurl + libpcre2 + perl, the
##                 fattest closure of the five.
## * ``vim``     — terminal editor; depends on libtinfo6 (shared with
##                 htop's ncurses chain).
## * ``python3`` — language runtime; minimal closure plus its own
##                 stdlib bind. Exercises ``python3 -c 'print(...)'``.
## * ``curl``    — CLI HTTP client; brings libcurl4 + libnghttp2-14.
## * ``htop``    — top-replacement; libncursesw6 + libtinfo6.
##
## Each binary is invoked through ``$prefix/bin/<name>`` which ``exec``s
## the C3 ``reprobuild-sandbox-launcher`` against the per-package
## ``launcher.manifest`` produced by ``materializeSandboxManifest``
## (``libs/repro_local_store/.../sandbox_manifest.nim``).
##
## Snapshot pin: ``debian/bookworm/20260601T000000Z`` — the same pin the
## C2 fixture + C3 launcher dep-resolution integration tests use, so
## the catalog harvest + sandbox bind set are exercised end-to-end
## against bytes the regression suite already covers.
##
## The integration build driver is
## ``recipes/reproos-mvp-config/build-mvp-iso.sh`` (POSIX) and
## ``recipes/reproos-mvp-config/build-mvp-iso.ps1`` (Windows
## orchestration wrapper that delegates to the POSIX driver inside a
## WSL2 distro).
##
## The vm-harness boot-and-assert e2e is
## ``vm-harness/tests/e2e/t_vm_harness_hyperv_reproos_mvp_foreign.nim``.

system reproosMvp:
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
    package(apt, "git",     snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "vim",     snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "python3", snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "curl",    snapshot = "debian/bookworm/20260601T000000Z"),
    package(apt, "htop",    snapshot = "debian/bookworm/20260601T000000Z"),
  ]

  users:
    user "root":
      # Plain-text password "reproos" hashed via mkpasswd -m sha512crypt
      # (yescrypt is unavailable in the Path A pragmatic shadow build;
      #  see ReproOS-MVP campaign R9 reproducibility hazard #11).
      shell = bash
      password_hash = "$6$reproosMvpD1$rrZAqlA3J4u9SLnxnaWWMcQAgVTXMplGNjmnt7yfZP3SyxEv.kE8Va8VbPVD0WBmlLhRrPYz3wO/U5O7Q1mvJ/"
      groups = ["wheel"]
      home_dir = "/root"

  services:
    enable "serial-getty@ttyS0.service"

  mounts:
    mount "/", source = "LABEL=reproos-root", fstype = "ext4", options = "rw,relatime"
