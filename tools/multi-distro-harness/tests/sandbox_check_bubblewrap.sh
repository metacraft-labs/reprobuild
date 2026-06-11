#!/bin/sh
# sandbox_check_bubblewrap.sh - probe bubblewrap availability + unprivileged
# user-namespace support on the current distro.
#
# Linux-Third-Party-Sandbox-MVP M0 acceptance probe (read-only). For the
# pinned M0 mechanism (bubblewrap as the per-process FHS-view wrapper) we
# need three facts per distro:
#
#   1. Is `bubblewrap` (or its CLI `bwrap`) present? If yes, which version?
#      If no, what is the install command the M1 driver will need to use?
#   2. Is unprivileged-user-namespace creation enabled in this kernel?
#      (Most modern distros: yes. Some older RHEL-derived kernels gate it
#      behind `sysctl kernel.unprivileged_userns_clone=1`.)
#   3. A single-line summary so the multi-distro runner can grep across
#      distros without re-parsing per-distro output.
#
# This test does NOT install bubblewrap (the M1 driver will own that
# decision). It only PROBES. Exit code:
#
#   0 - bwrap available AND unprivileged user-ns works (M1 will be smooth).
#   0 - bwrap missing but install command available AND user-ns works
#       (M1 needs to install bwrap; documented). We treat this as a soft
#       pass because M1 is the driver that owns install.
#   1 - unprivileged user-ns is DISABLED (hard problem: needs admin sysctl
#       drop-in `kernel.unprivileged_userns_clone=1` or setuid bwrap).
#   1 - distro ID unknown / package manager not in the closed set.
#
# Stays POSIX-sh-compatible (Alpine has no bash by default).

set -eu

# ----------------------------------------------------------------------
# Distro identification.
# ----------------------------------------------------------------------

if [ ! -r /etc/os-release ]; then
  echo "sandbox_check_bubblewrap: FAIL - /etc/os-release missing" >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
distro_id="${ID:-unknown}"

# ----------------------------------------------------------------------
# Resolve per-distro package-manager probe + install command.
# ----------------------------------------------------------------------
# Closed-set switch on /etc/os-release ID. Aliases:
#   debian + ubuntu  -> apt
#   fedora           -> dnf
#   arch             -> pacman
#   alpine           -> apk
#   opensuse-*       -> zypper
#
# install_cmd is REPORTED, not run. M1's driver will own actual install.

case "$distro_id" in
  debian|ubuntu)
    pkgmgr=apt
    pkg_query_cmd='dpkg -s bubblewrap >/dev/null 2>&1'
    install_cmd='apt-get install -y bubblewrap'
    ;;
  fedora)
    pkgmgr=dnf
    pkg_query_cmd='rpm -q bubblewrap >/dev/null 2>&1'
    install_cmd='dnf install -y bubblewrap'
    ;;
  arch)
    pkgmgr=pacman
    pkg_query_cmd='pacman -Qi bubblewrap >/dev/null 2>&1'
    install_cmd='pacman -S --noconfirm bubblewrap'
    ;;
  alpine)
    pkgmgr=apk
    pkg_query_cmd='apk info -e bubblewrap >/dev/null 2>&1'
    install_cmd='apk add bubblewrap'
    ;;
  opensuse|opensuse-tumbleweed|opensuse-leap)
    pkgmgr=zypper
    pkg_query_cmd='rpm -q bubblewrap >/dev/null 2>&1'
    install_cmd='zypper install -y bubblewrap'
    ;;
  *)
    echo "sandbox_check_bubblewrap: FAIL - unknown distro ID='${distro_id}'" >&2
    exit 1
    ;;
esac

# ----------------------------------------------------------------------
# 1. bubblewrap presence + version.
# ----------------------------------------------------------------------

bwrap_status='missing'
bwrap_version=''

# Prefer the package-manager query (truthful even if PATH excludes
# /usr/bin); fall back to a bare `bwrap` lookup.
if eval "$pkg_query_cmd"; then
  bwrap_status='installed'
elif command -v bwrap >/dev/null 2>&1; then
  bwrap_status='installed'
fi

if [ "$bwrap_status" = 'installed' ]; then
  if command -v bwrap >/dev/null 2>&1; then
    # bwrap --version prints e.g. "bubblewrap 0.10.0"
    bwrap_version=$(bwrap --version 2>/dev/null | head -n1 || echo '')
  fi
  if [ -z "$bwrap_version" ]; then
    bwrap_version='version-unknown'
  fi
fi

# ----------------------------------------------------------------------
# 2. Unprivileged user-namespace probe.
# ----------------------------------------------------------------------
# Strategy (in order):
#   a. `sysctl kernel.unprivileged_userns_clone` if the sysctl exists
#      (Debian-derived kernels expose it; vanilla mainline does not).
#   b. Failing that, attempt `unshare --user true`. If it exits 0, the
#      kernel allows unprivileged user-ns creation regardless of any
#      sysctl knob. If it errors out, user-ns is disabled or restricted.
#
# We report the OUTCOME (enabled/disabled), not the mechanism.

userns_state='unknown'
userns_detail=''

if command -v sysctl >/dev/null 2>&1; then
  userns_sysctl=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo '')
  if [ -n "$userns_sysctl" ]; then
    if [ "$userns_sysctl" = '1' ]; then
      userns_detail='sysctl kernel.unprivileged_userns_clone=1'
    else
      userns_detail="sysctl kernel.unprivileged_userns_clone=${userns_sysctl}"
    fi
  fi
fi

# Probe via `unshare --user true`. If util-linux is missing (extremely
# unlikely on a provisioned repro-* WSL instance), fall back to "unknown".
if command -v unshare >/dev/null 2>&1; then
  if unshare --user true >/dev/null 2>&1; then
    userns_state='enabled'
    if [ -z "$userns_detail" ]; then
      userns_detail='unshare --user OK'
    fi
  else
    userns_state='disabled'
    if [ -z "$userns_detail" ]; then
      userns_detail='unshare --user failed'
    fi
  fi
else
  userns_state='unknown'
  userns_detail='unshare(1) missing'
fi

# ----------------------------------------------------------------------
# 3. One-line summary.
# ----------------------------------------------------------------------

if [ "$bwrap_status" = 'installed' ]; then
  bwrap_field="bwrap=${bwrap_version}"
else
  bwrap_field="bwrap=missing (install: ${install_cmd})"
fi

echo "sandbox_check_bubblewrap: distro=${distro_id} pkgmgr=${pkgmgr} ${bwrap_field} userns=${userns_state} (${userns_detail})"

# ----------------------------------------------------------------------
# Exit policy.
# ----------------------------------------------------------------------
# bwrap absence is a soft signal (M1 driver installs it).
# user-ns disabled is a hard signal (M0 spec calls out a needed admin
# sysctl drop-in for distros where it is gated).

if [ "$userns_state" = 'disabled' ]; then
  echo "sandbox_check_bubblewrap: FAIL - unprivileged user-ns disabled on ${distro_id}" >&2
  echo "  remediation: sysctl -w kernel.unprivileged_userns_clone=1" >&2
  echo "  or install a /etc/sysctl.d/00-userns.conf drop-in" >&2
  exit 1
fi
exit 0
