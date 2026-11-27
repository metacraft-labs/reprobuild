# shellcheck shell=bash
#
# The C-compile width of the bootstrap build (`scripts/build_apps.sh`, which
# `just build` and `just bootstrap` drive): the N in each `nim c
# --parallelBuild:N`, i.e. how many C compilers one Nim compile may run at once.
#
# The script builds `repro` without the engine, so no RunQuota lease sizes it;
# it still owes each nested `nim c` an explicit width, never Nim's 0 (one C
# compiler per online core). The sources, first match wins:
#
#   1. REPRO_BUILD_JOBS       the caller's explicit knob. Nothing else sets
#                             it, so unlike NIX_BUILD_CORES the dev shell does
#                             not replace it on entry. Empty means unset; any
#                             other value that is not a positive integer is
#                             refused, not ignored: a typo must not silently
#                             fall back to a wider build.
#   2. RUNQUOTA_RUN_WIDTH     the width a RunQuota lease granted the command
#                             (`runquota run` exports it; libs/repro_runquota
#                             GrantedWidthEnvVar). § Nested Parallelism: a
#                             wrapper translates the grant into the tool's
#                             native flag. Malformed or zero means no grant.
#   3. NIX_BUILD_CORES        only inside a real Nix build (IN_NIX_SHELL
#                             unset), where it is that build's per-derivation
#                             request and is passed through verbatim (0 keeps
#                             Nim's automatic width, as the package always
#                             had). Inside `nix develop` the shell derives it
#                             from the evaluating user's Nix `cores` setting
#                             and overwrites whatever the caller exported --
#                             on a host with `cores = 0` that is the CPU
#                             count -- so there it says nothing about the
#                             caller's budget and is not consulted.
#   4. a conservative default min(cores / 2, MemAvailable / 1 GiB, 8), at
#                             least 1. Nim's own default (0) is one C compiler
#                             per online core, which on a shared 32-core host
#                             ran three concurrent builds at 32 each while the
#                             host paged. Eight keeps one build's share of a
#                             machine that several builds use at once small;
#                             1 GiB is a deliberately generous allowance for
#                             one C compiler on Nim's generated sources.
#                             Every value read above is a decimal count of at
#                             most nine digits (_repro_build_width_count), so
#                             bash arithmetic cannot wrap it.
#
# The function prints "<width> <source>" so build_apps.sh can log where the
# width came from; a reader of the build log then sees both.

# Per-C-compiler memory allowance in MiB for the default (source 4).
REPRO_BUILD_WIDTH_MEM_PER_CC_MB=1024
# The default's ceiling (source 4). An explicit REPRO_BUILD_JOBS may exceed it.
REPRO_BUILD_WIDTH_DEFAULT_CAP=8

# Logical CPUs online, or 1 when it cannot be measured.
_repro_build_width_cores() {
  local n=""
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  if [[ ! "${n}" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    n="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  if [[ ! "${n}" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    n=1
  fi
  printf '%s\n' "${n}"
}

# MemAvailable in MiB, or empty when it cannot be measured (non-Linux): the
# memory term then does not bind and the core and cap terms decide.
_repro_build_width_mem_mb() {
  local kb=""
  if [[ -r /proc/meminfo ]]; then
    kb="$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  fi
  if [[ "${kb}" =~ ^[0-9]+$ ]] && (( kb > 0 )); then
    printf '%s\n' "$((kb / 1024))"
  else
    printf '\n'
  fi
}

# The default width (source 4).
#   $1 logical cores (default: measured)
#   $2 available memory in MiB (default: measured; empty = unmeasurable)
repro_default_build_width() {
  local cores="${1-$(_repro_build_width_cores)}"
  local mem_mb="${2-$(_repro_build_width_mem_mb)}"
  if [[ ! "${cores}" =~ ^[0-9]+$ ]] || (( cores < 1 )); then
    cores=1
  fi
  local width=$((cores / 2))
  if [[ "${mem_mb}" =~ ^[0-9]+$ ]]; then
    local by_mem=$((mem_mb / REPRO_BUILD_WIDTH_MEM_PER_CC_MB))
    if (( by_mem < width )); then
      width="${by_mem}"
    fi
  fi
  if (( width > REPRO_BUILD_WIDTH_DEFAULT_CAP )); then
    width="${REPRO_BUILD_WIDTH_DEFAULT_CAP}"
  fi
  if (( width < 1 )); then
    width=1
  fi
  printf '%s\n' "${width}"
}

# A decimal count of at most nine digits, leading zeros allowed, printed
# normalised ("08" -> 8); returns 1 for anything else. The digit bound keeps
# the value inside bash's 64-bit arithmetic: a longer string would wrap
# silently (20 nines become 7766279631452241919, 2^63 a negative number), and
# no host has a billion C compilers to run.
_repro_build_width_count() {
  local digits="${1-}"
  [[ "${digits}" =~ ^[0-9]+$ ]] || return 1
  digits="${digits#"${digits%%[!0]*}"}"
  (( ${#digits} <= 9 )) || return 1
  printf '%s\n' "$((10#${digits:-0}))"
}

# Resolve the width. Prints "<width> <source>" on stdout; returns 1 with one
# line on stderr when REPRO_BUILD_JOBS is set but not a positive integer.
# Arguments are passed to repro_default_build_width (tests pin them).
repro_build_width() {
  local n
  if [[ -n "${REPRO_BUILD_JOBS:-}" ]]; then
    if n="$(_repro_build_width_count "${REPRO_BUILD_JOBS}")" && (( n >= 1 )); then
      printf '%s REPRO_BUILD_JOBS\n' "${n}"
      return 0
    fi
    printf 'error: REPRO_BUILD_JOBS=%q is not a positive integer (at most nine digits); set it to the number of C compilers one Nim compile may run at once, or unset it for the default.\n' \
      "${REPRO_BUILD_JOBS}" >&2
    return 1
  fi

  if n="$(_repro_build_width_count "${RUNQUOTA_RUN_WIDTH:-}")" && (( n >= 1 )); then
    printf '%s RUNQUOTA_RUN_WIDTH\n' "${n}"
    return 0
  fi

  if [[ -z "${IN_NIX_SHELL:-}" ]] && n="$(_repro_build_width_count "${NIX_BUILD_CORES:-}")"; then
    printf '%s NIX_BUILD_CORES\n' "${n}"
    return 0
  fi

  printf '%s default\n' "$(repro_default_build_width "$@")"
}
