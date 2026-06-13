# R9: systemd-from-source build (Path A pragmatic)

## Status

R9 ACCEPTANCE GATE: PASS (2026-06-13).

Boot evidence:
- `Linux version 6.6.142` (R8 kernel boots through Hyper-V Gen-2 UEFI)
- `systemd[1]: systemd 257.9 running in system mode (+PAM +SECCOMP +KMOD +XZ ...)` (PID 1 confirmed)
- `Reached target Basic System`
- `Reached target Multi-User System`
- `reproos-r9 login: root (automatic login)`

Preserved serial log:
`D:/metacraft/reprobuild/build/r9-build/run-evidence/repro-test-boot-r9-bfab5aa6.serial.log`

## Source pin

- systemd 257.9 (LTS-flavoured; R3 closure document called for v257 line).
- Upstream: `https://github.com/systemd/systemd/archive/refs/tags/v257.9.tar.gz`
- sha256 = `b27dcc100a738b4b5b81f7c5174c1239a6495f5bdf3d3caa94a17b8373e6a1ca`
- Vendored at runtime to `/root/r9-work/systemd-257.9.tar.gz` inside repro-ubuntu
  WSL (gitignored under `build/r9-build/`).

Divergence from nixpkgs (06a4933d0 pin): nixpkgs ships systemd 260.1; R9 spec
called for 257 LTS, so we pin 257.9 (latest 257.x patch release at build time).

## Build strategy: Path A pragmatic

Per R8 precedent, R9 builds systemd against the **host distribution's libc + dev
packages** (Ubuntu 22.04 in `repro-ubuntu` WSL with gcc 11.4 + glibc 2.35), not
against the strict R5/R6/R7 outputs. Rationale: R5/R6/R7 outputs were lost when
`repro-debian` broke; the user's stated goal for the milestone chain is "ReproOS
actually boots in a VM with systemd", and the proof of that is a booting VM.

A strict-bootstrap path (Path B) would require re-running R5/R6/R7 first
(~2 hours wall-clock) and is left for a future Rn milestone.

## Feature-flag set (MVP)

Disabled (per R3 §5.2 recommendation):
- `apparmor`, `audit`, `selinux`, `tpm2`, `acl`
- `gcrypt`, `gnutls`, `openssl`, `libcryptsetup`, `libcurl`, `microhttpd`
- `zstd`, `lz4`, `bzip2`
- `remote`, `repart`, `homed`, `importd`, `machined`, `networkd`,
  `resolve`, `timesyncd`, `polkit`, `portabled`, `oomd`, `vmspawn`, `nspawn`
- `efi`, `bootloader`, `ukify`, `nss-resolve`
- `hwdb`, `xdg-autostart`, `coredump`, `pstore`, `sysext`, `nsresourced`
- `libarchive`, `qrencode`, `libfido2`, `p11kit`, `libiptc`, `smack`
- `passwdqc`, `pwquality`, `blkid`, `fdisk`, `libidn`, `idn`
- `man`, `html`, `translations`
- `binfmt`, `hibernate`, `backlight`, `rfkill`, `environment-d`, `ldconfig`
- `machined`, `nss-mymachines`, `nss-systemd`, `quotacheck`
- `storagetm`, `mountfsd`

Enabled (the minimum for boot-to-login):
- `pam`, `kmod`, `seccomp`, `xz`
- `libidn2`, `pcre2`
- `logind`, `hostnamed`, `localed`, `timedated`, `userdb`
- `utmp`, `vconsole`, `firstboot`, `sysusers`, `tmpfiles`
- `initrd`, `nss-myhostname`
- `gshadow`, `adm-group`, `wheel-group`

Result: `systemd 257 (257.9) +PAM -AUDIT -SELINUX -APPARMOR -IMA -IPE -SMACK
+SECCOMP -GCRYPT -GNUTLS -OPENSSL -ACL -BLKID -CURL +ELFUTILS -FIDO2 +IDN2 -IDN
-IPTC +KMOD ... +PCRE2 ... +XZ +ZLIB ... +UTMP +SYSVINIT -LIBARCHIVE`

## Build pipeline

```
build-systemd.sh         meson configure with MVP flag set (-> build-systemd/)
                         ninja -C build-systemd
                         meson install -C build-systemd  (DESTDIR=systemd-install)

build-initramfs.sh       FHS skeleton + systemd-install copy + closure-walk
                         libc copy from host (libc.so.6 + ld-linux + libcrypt
                         + libcap + libmount + libseccomp + libxslt + libkmod
                         + libdbus + libpcre2 + libidn2 + libpam + libelf
                         + liblzma + libdw + ...) into rootfs/lib + /usr/lib;
                         /init -> /usr/lib/systemd/systemd symlink;
                         /sbin/init -> systemd symlink;
                         busybox-static @ /usr/bin/busybox + applet symlinks
                         (sh, bash, cat, mount, login, getty, switch_root, ...);
                         real /usr/bin/agetty copied from host util-linux
                         (busybox has no `agetty` applet);
                         /etc/passwd, /etc/group, /etc/shadow, /etc/hostname,
                         /etc/hosts, /etc/nsswitch.conf, /etc/os-release;
                         /etc/pam.d/{login,system-auth} stubs using pam_permit.so;
                         systemd-firstboot pre-population: /etc/machine-id,
                         /etc/locale.conf, /etc/vconsole.conf, /etc/timezone,
                         /etc/localtime so firstboot doesn't block on console;
                         /etc/systemd/system/serial-getty@ttyS0.service.d/
                         override.conf with `agetty --autologin root` for
                         serial console autologin;
                         masks for `systemd-firstboot.service`,
                         `systemd-vconsole-setup.service`, `systemd-logind.service`
                         (logind crashes on this minimal rootfs without full
                         /sys/fs/cgroup systemd hierarchy + dbus daemon;
                         not needed for MVP serial getty login);
                         cpio newc + gzip -n + SOURCE_DATE_EPOCH-stamped mtime
                         for reproducibility.

ISO assembly             reused R2 recipe `recipes/reproos-iso/scripts/build-iso.sh`
                         with bzImage = R8 kernel, initramfs = R9 initramfs.
```

## Reproducibility env

All scripts honour:
- `SOURCE_DATE_EPOCH=1735689600` (2025-01-01T00:00:00Z)
- `LC_ALL=C`
- `TZ=UTC`

## Reproducibility hazards (Path A pragmatic)

Because R9 uses host-provided shared libraries:
- The initramfs embeds glibc 2.35 (Ubuntu 22.04 jammy), NOT a from-source
  glibc. A strict Rn would rebuild against R6's glibc 2.42.
- Embedded RPATH on systemd binaries points at `/usr/lib/x86_64-linux-gnu/systemd`
  (NixOS-style nix-store paths absent — this is intentional, but it means the
  layout is FHS, not Reprobuild store).
- libpam pulls in audit-stub from host even though we built with `-Daudit=disabled`.
- The systemd binary itself has zero embedded host paths in /tmp or /home
  (verified by `strings build-systemd/systemd | grep -E '/tmp|/home'` → no leaks).

## Outputs (build/r9-build/)

| File | sha256 | Size |
|---|---|---|
| `reproos-r9.iso` | `f2bb0a0dfac1ac6882cb8aa979214329525454ffd797d22f53f39cde0e3579f0` | 30,464,000 B |
| `initramfs-systemd.cpio.gz` | `7a908297903f91ecc239de790bae88b894b8d06e8932415be61941910ad6766d` | 10,663,830 B |
| `systemd-257.9.tar.gz` (vendored source) | `b27dcc100a738b4b5b81f7c5174c1239a6495f5bdf3d3caa94a17b8373e6a1ca` | 16,401,765 B |
| `systemd-install.tar.gz` (DESTDIR install snapshot) | `015649df1c2a711495e59a681ea38f2c2abbbb1de1805132a7365d9cd88b5e93` | 6,503,846 B |

## Build environment (repro-ubuntu WSL)

- Ubuntu 22.04.5 LTS jammy
- gcc 11.4.0
- glibc 2.35
- meson 1.11.1 (via `pip install --user 'meson>=1.5'`; the apt package is
  0.61.2, too old for some recent meson idioms)
- ninja 1.10.1
- python3 3.10.12
- Direct apt-installed deps (the closure on the WSL host):
  `meson ninja-build python3 python3-jinja2 python3-pyelftools gperf intltool
  libcap-dev libmount-dev libseccomp-dev libxslt1-dev xsltproc kmod libkmod-dev
  libdbus-1-dev libpcre2-dev libgnutls28-dev libidn2-dev libpam0g-dev
  libpam-modules pkg-config gettext wget xz-utils libssl-dev liblzma-dev
  libelf-dev libdw-dev libblkid-dev libfdisk-dev libcrypt-dev libapparmor-dev
  libcap-ng-dev xorriso grub-pc-bin grub-efi-amd64-bin mtools busybox-static`

## Test

The boot-smoke test lives at:
`tests/integration/t_r9_systemd_boot.nim`

Run with:
```powershell
. D:/metacraft/env.ps1
nim c --path:D:/metacraft/vm-harness/src `
  -o:D:/metacraft/reprobuild/build/r9-build/t_r9_systemd_boot.exe `
  D:/metacraft/reprobuild/tests/integration/t_r9_systemd_boot.nim
D:/metacraft/reprobuild/build/r9-build/t_r9_systemd_boot.exe
```

Requires Hyper-V + elevation. Expects:
- Kernel banner `Linux version 6.6.142` within 120 s
- systemd PID 1 banner within 120 s
- Login prompt (`reproos-r9 login:` or `root (automatic login)`) within 120 s

## Open items for follow-up Rn

1. **Strict Path B**: re-run R5/R6/R7 first (gcc 15.2 + binutils 2.46 + glibc 2.42
   + cc-wrapper-glibc + bash 5.3 + coreutils 9.11 + util-linux 2.42 + linux-pam
   1.7.1), then rebuild systemd against THAT toolchain instead of host
   Ubuntu's. Establishes byte-deterministic bootstrap.

2. **systemd-logind**: currently masked. Bringing it up needs (a) dbus-daemon
   in the rootfs (we already include libdbus); (b) /sys/fs/cgroup mounted
   with the systemd hierarchy; (c) PAM config wired through. Required for
   real-user login (today's autologin bypasses logind).

3. **Reproducibility gate**: re-run build-systemd.sh + build-initramfs.sh +
   build-iso.sh twice and assert byte-identical outputs. Not yet done for R9.

4. **Path determinism**: walk the ELF section strings of every binary in
   the initramfs and assert no `/tmp/*` or `/home/*` leak. The
   systemd-install snapshot was verified leak-clean; the host-borrowed
   libc/libpam/libcap/etc. have not been spot-checked.
