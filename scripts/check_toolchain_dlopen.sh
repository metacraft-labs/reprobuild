#!/usr/bin/env bash
set -euo pipefail

# Regression guard for the "monitored `nim c` cannot load a toolchain library"
# class of breakage.
#
# Reprobuild compiles every project's provider binary with `nim c` run under
# automatic monitoring, which LD_PRELOADs `librepro_monitor_shim.so`. The shim
# interposes `dlopen`, so a forwarded `dlopen` is issued from the SHIM's DSO
# and glibc resolves the soname against the shim's DT_RUNPATH instead of the
# monitored binary's. Any library the toolchain loads by bare soname — libpcre
# for the Nim compiler's `re` support, for example — therefore stops resolving
# through the compiler's own RUNPATH and must be reachable via the
# process-global loader search path (`LD_LIBRARY_PATH`, set for the dev shell
# in flake.nix).
#
# When that path loses an entry the symptom is a build-wide outage: the very
# first `repro build` dies in "running provider compile" with
#
#     could not load: libpcre.so(.3|.1|)
#
# and nothing downstream — including the whole test suite — can run. This check
# reproduces the exact conditions (real toolchain, real shim, real compile) so
# the failure surfaces immediately with an actionable message instead of as an
# opaque provider-compile error, and asserts on behaviour rather than on the
# presence of any particular string in flake.nix.
#
# Usage: scripts/check_toolchain_dlopen.sh [shim-lib-dir]   (default build/lib)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/monitor_shim_probe.sh
source "${script_dir}/monitor_shim_probe.sh"

lib_dir="${1:-build/lib}"

case "$(uname -s)" in
  Linux)
    shim_env="LD_PRELOAD"
    shim_ext="so"
    ;;
  Darwin)
    shim_env="DYLD_INSERT_LIBRARIES"
    shim_ext="dylib"
    ;;
  *)
    echo "check_toolchain_dlopen: no interposing monitor on $(uname -s); skipping" >&2
    exit 0
    ;;
esac

if ! repro_monitor_shim_available "${lib_dir}"; then
  echo "check_toolchain_dlopen: no monitor shim in ${lib_dir};" \
    "build it first (scripts/run_tests.sh bootstraps it)" >&2
  exit 2
fi

# Match the platform extension exactly: the shim build leaves rotated
# `librepro_monitor_shim.so.old` copies next to the live artifact, and preloading
# a stale one would test the wrong thing.
shim="${lib_dir}/librepro_monitor_shim.${shim_ext}"
if [[ ! -f "${shim}" ]]; then
  echo "check_toolchain_dlopen: expected ${shim}; found only:" >&2
  ls -1 "${lib_dir}"/librepro_monitor_shim.* >&2 2>/dev/null || true
  exit 2
fi
shim="$(cd "$(dirname "${shim}")" && pwd -P)/$(basename "${shim}")"

nim="${REPRO_NIM_COMPILER:-}"
if [[ -z "${nim}" ]]; then
  nim="$(command -v nim || true)"
fi
if [[ -z "${nim}" ]]; then
  echo "check_toolchain_dlopen: no nim on PATH; set REPRO_NIM_COMPILER" >&2
  exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/repro-toolchain-dlopen.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

# Provider-shaped in the ways that matter for loader behaviour: a real `nim c`
# that runs the compiler front end, the C backend and the link step. Kept tiny
# so the guard costs a couple of seconds.
cat >"${work}/probe.nim" <<'NIM'
import std/[os, strutils]

when isMainModule:
  echo "provider-probe ", paramCount(), " ", "ok".toUpperAscii()
NIM

set +e
out="$(
  cd "${work}" &&
  env "${shim_env}=${shim}" IO_MON_MUTE=1 \
    "${nim}" c --skipUserCfg --skipParentCfg --hints:off --warnings:off \
      --nimcache:"${work}/nimcache" -o:"${work}/probe" "${work}/probe.nim" 2>&1
)"
status=$?
set -e

if [[ ${status} -ne 0 || "${out}" == *"could not load:"* ]]; then
  echo "check_toolchain_dlopen: FAILED" >&2
  echo "  compiler: ${nim}" >&2
  echo "  monitor shim (${shim_env}): ${shim}" >&2
  echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-<unset>}" >&2
  while IFS= read -r line; do
    echo "  | ${line}" >&2
  done <<<"${out}"
  if [[ "${out}" == *"could not load:"* ]]; then
    echo >&2
    echo "A library the toolchain dlopen()s by bare soname is not on the" >&2
    echo "process-global loader search path. Under the monitor shim the" >&2
    echo "compiler's own RUNPATH does not apply to its dlopen()s, so the" >&2
    echo "library must be added to the dev shell's LD_LIBRARY_PATH list in" >&2
    echo "flake.nix (see the comment above that attribute)." >&2
  fi
  exit 1
fi

# A zero exit status alone would also be reported by a compiler that silently
# did nothing, which would let the guard pass vacuously. Require the artifact
# the compile was supposed to produce, and require it to run: that is the only
# evidence that the front end, the C backend and the link step all completed.
if [[ ! -x "${work}/probe" ]]; then
  echo "check_toolchain_dlopen: FAILED" >&2
  echo "  compiler: ${nim}" >&2
  echo "  reported success but produced no ${work}/probe binary" >&2
  exit 1
fi
if ! probe_out="$("${work}/probe" 2>&1)" ||
    [[ "${probe_out}" != "provider-probe 0 OK" ]]; then
  echo "check_toolchain_dlopen: FAILED" >&2
  echo "  compiler: ${nim}" >&2
  echo "  compiled probe did not run as expected: ${probe_out}" >&2
  exit 1
fi

echo "check_toolchain_dlopen: ok (${nim} compiles under ${shim_env})"
