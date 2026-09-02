#!/usr/bin/env bash
# bootstrap_guard.sh — decide whether ``just bootstrap`` must run
# ``scripts/build_apps.sh``, and prove the decision is about THIS
# platform's artefact.
#
# WHY THIS IS A SCRIPT AND NOT THREE LINES IN THE Justfile
# --------------------------------------------------------
# It used to be three lines in the Justfile, and they named the wrong
# file:
#
#     if [ ! -x ./build/bin/repro ]; then needs_bootstrap=1;
#     elif find apps libs config.nims flake.nix repro.nim -type f \
#          -newer ./build/bin/repro -print -quit | grep -q .; then …
#
# ``./build/bin/repro`` is the LINUX artefact name. On Windows the build
# produces ``./build/bin/repro.exe`` and the extension-less name is
# whatever the other platform last left in the shared, gitignored
# ``build/`` tree — this checkout is reached from Windows as
# ``M:\m\dev\reprobuild`` and from WSL as ``/mnt/m/m/dev/reprobuild``, so
# a ``nix develop`` build drops an ELF beside the PE.
#
# Both clauses were therefore wrong on Windows, in two directions:
#
#   * If the extension-less file satisfies ``-x``, the guard concludes the
#     engine is built and ``repro.exe`` is never built or refreshed.
#     Whether it satisfies ``-x`` is a property of the SHELL, not of the
#     file: MSYS2/Git Bash mounts here are ``noacl``, so the mode comes
#     from a DOS-attribute + magic sniff (a ``.exe`` name, an ``MZ``
#     header or a ``#!`` line are executable; an ELF header is not),
#     while WSL mounts the same drive with ``metadata`` and reports the
#     very same file ``-rwxr-xr-x``.
#   * If it does not, the guard rebuilds unconditionally on every
#     invocation — the fast path the recipe's own comment promises is
#     dead, which is the state this checkout is in today.
#
# And the ``elif`` compares source freshness against that same wrong
# file's mtime, so a stale ``repro.exe`` looks fresh whenever the ELF
# beside it is newer than the sources.
#
# WHAT THE GUARD MUST PROVE
# -------------------------
# Presence is not the property. The property is: *the artefact this
# platform builds exists, is of this platform's machine format, and is
# newer than every source the bootstrap build reads.* Anything else must
# rebuild. So this script checks the magic bytes rather than trusting a
# name or a mode bit — a name can be right while the bytes are the other
# platform's, and that is the entire class this guard belongs to.
#
# INTERFACE (stable — tests drive these directly)
# -----------------------------------------------
#   bootstrap_guard.sh decide [root]   -> "bootstrap <reason>" | "skip <reason>"
#   bootstrap_guard.sh format <path>   -> elf | pe | macho | unknown | missing
#   bootstrap_guard.sh host-format     -> the format this host must produce
#   bootstrap_guard.sh host-exe <stem> -> stem with the host executable suffix
#
# ``decide`` always exits 0; the decision is on stdout. That keeps the
# recipe branch-free of exit-status handling and keeps the guard
# testable without a build.

set -eu

# The sources the bootstrap build actually reads.
#
# DECISION, stated rather than left implicit: these are WIDER than the
# pre-fix roots (``apps libs config.nims flake.nix repro.nim``) by the two
# scripts that drive the build, and deliberately NARROWER than the
# postdates-your-edits rule used for review evidence
# (``apps libs tests scripts tools config.nims repro.nim repro_tests.nim
# flake.nix``).
#
# ``tests/``, ``tools/`` and ``repro_tests.nim`` are excluded ON PURPOSE:
# bootstrap builds ``apps/``, not tests, so including them would relink
# the engine on every test edit and make the recipe's fast path useless
# for the workflow it exists to serve. Widening ``scripts/`` wholesale is
# also rejected for the same reason — only the two files that are inputs
# to this build are listed. Anything broader is separate work, and this
# comment is the record that it was considered and declined.
BOOTSTRAP_SOURCE_ROOTS="apps libs config.nims flake.nix repro.nim scripts/build_apps.sh scripts/source_paths.sh"

host_exe_suffix() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf '%s' ".exe" ;;
    *) printf '%s' "" ;;
  esac
}

host_format() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf '%s' "pe" ;;
    Darwin) printf '%s' "macho" ;;
    *) printf '%s' "elf" ;;
  esac
}

# Classify a file by its machine-format magic. Deliberately byte-based:
# the name and the mode bit are both unreliable here (see the header),
# and the bytes are the only thing that says which kernel can run it.
binary_format() {
  path="$1"
  if [ ! -f "${path}" ]; then
    printf '%s' "missing"
    return 0
  fi
  head4="$(od -An -N4 -tx1 < "${path}" 2>/dev/null | tr -d ' \n')"
  case "${head4}" in
    7f454c46) printf '%s' "elf"; return 0 ;;                       # \x7F E L F
    feedface|feedfacf|cefaedfe|cffaedfe) printf '%s' "macho"; return 0 ;;
    cafebabe|bebafeca) printf '%s' "macho"; return 0 ;;            # fat Mach-O
  esac
  case "${head4}" in
    4d5a*)
      # DOS stub. A real PE image carries "PE\0\0" at the offset stored
      # in the little-endian uint32 at 0x3C; a bare MZ (a DOS .com-era
      # stub, or a truncated download) does not, and must not be
      # accepted as this platform's artefact.
      lfa="$(od -An -j 60 -N 4 -tx1 < "${path}" 2>/dev/null | tr -d ' \n')"
      if [ ${#lfa} -ne 8 ]; then
        printf '%s' "unknown"
        return 0
      fi
      # little-endian -> big-endian nibble pairs
      off_hex="$(printf '%s' "${lfa}" | cut -c7-8)$(printf '%s' "${lfa}" | cut -c5-6)$(printf '%s' "${lfa}" | cut -c3-4)$(printf '%s' "${lfa}" | cut -c1-2)"
      off_dec=$((0x${off_hex}))
      sig="$(od -An -j "${off_dec}" -N 4 -tx1 < "${path}" 2>/dev/null | tr -d ' \n')"
      if [ "${sig}" = "50450000" ]; then
        printf '%s' "pe"
      else
        printf '%s' "unknown"
      fi
      return 0
      ;;
  esac
  printf '%s' "unknown"
}

decide() {
  root="${1:-.}"
  suffix="$(host_exe_suffix)"
  want="$(host_format)"
  target="${root}/build/bin/repro${suffix}"

  if [ ! -f "${target}" ]; then
    printf 'bootstrap missing:%s\n' "build/bin/repro${suffix}"
    return 0
  fi

  got="$(binary_format "${target}")"
  if [ "${got}" != "${want}" ]; then
    printf 'bootstrap wrong-format:%s is %s, this host builds %s\n' \
      "build/bin/repro${suffix}" "${got}" "${want}"
    return 0
  fi

  # Only meaningful once the format is right: an artefact of the host
  # format that cannot be executed is as unusable as a missing one.
  if [ ! -x "${target}" ]; then
    printf 'bootstrap not-executable:%s\n' "build/bin/repro${suffix}"
    return 0
  fi

  existing=""
  for entry in ${BOOTSTRAP_SOURCE_ROOTS}; do
    if [ -e "${root}/${entry}" ]; then
      existing="${existing} ${root}/${entry}"
    fi
  done
  if [ -n "${existing}" ]; then
    # shellcheck disable=SC2086
    newer="$(find ${existing} -type f -newer "${target}" -print -quit 2>/dev/null || true)"
    if [ -n "${newer}" ]; then
      printf 'bootstrap stale:%s newer than build/bin/repro%s\n' \
        "${newer#"${root}/"}" "${suffix}"
      return 0
    fi
  fi

  printf 'skip fresh:build/bin/repro%s is %s and newer than its sources\n' \
    "${suffix}" "${want}"
}

case "${1:-decide}" in
  decide) decide "${2:-.}" ;;
  format) binary_format "${2:?usage: bootstrap_guard.sh format <path>}" ;;
  host-format) host_format; printf '\n' ;;
  host-exe) printf '%s%s\n' "${2:?usage: bootstrap_guard.sh host-exe <stem>}" "$(host_exe_suffix)" ;;
  *)
    echo "usage: bootstrap_guard.sh {decide [root]|format <path>|host-format|host-exe <stem>}" >&2
    exit 2
    ;;
esac
