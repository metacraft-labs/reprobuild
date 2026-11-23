#!/usr/bin/env bash
# Compiles, through the HOST C compiler, the test files that are the only
# programs reaching some library code, so a C error in that code fails lint
# instead of hiding until a whole-suite run reaches the test.
#
# WHY. Nim emits C only for the procs a program reaches. `just build` builds
# the entry points in apps/entrypoints.txt, and the `nim check` sweep never
# runs the C compiler, so a proc that no entry point calls is compiled by
# nothing but the tests that call it -- and those compile inside
# `.#test-builds`, hours into `just test`, where one failed compile is one red
# line among ~1800 cases. That is how `t_execution_lease_confinement` stopped
# compiling on Linux without anyone noticing: `descendantsOf` and
# `killProcessTree` (repro_distributed_worker/lease.nim) belong to the macOS
# Seatbelt backend, so no Linux entry point reaches them, and their empty
# `@[]` literals were emitted as the `seq[cint]` another module had
# instantiated (Nim, under ORC, does not tell two `int32` aliases with
# different C names apart there). gcc 14 and later reject that assignment
# (`-Wincompatible-pointer-types` is an error), so the whole test file -- all
# of its cases -- was lost on every Linux host with the dev shell's gcc 15.
#
# WHAT. Each source below is compiled with `nim c --noLinking:on`: Nim's
# codegen AND the C compiler run, the link does not (the link adds nothing
# this gate is about, and skipping it keeps the gate to about a minute per
# file). The compiler is whatever the dev shell puts first on PATH -- the
# compiler the suite itself uses.
#
# Add a source when it is the only program that reaches some library code
# on this host; the header comment of the entry says which code. Do not add
# one to "cover" a test that an entry point already reaches.
set -euo pipefail

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# source path | the library code only it reaches on Linux
readonly SOURCES=(
  'tests/integration/t_execution_lease_confinement.nim|repro_distributed_worker/lease.nim: descendantsOf, killProcessTree, startSeatbeltWrapper (the macOS backend, driven on Linux with a stand-in sandbox-exec)'
)

# Same source-path resolver the app build, the `nim check` sweep and the
# portable-closure gate use. See scripts/check_nim_sources.sh.
# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh
SHM_QUEUE_SRC="$(resolve_shm_queue_src)"
CLI_SPEC_SRC="$(resolve_cli_spec_src)"
ENTRYPOINTS_SRC="$(resolve_entrypoints_src)"
CONFUTILS_SRC="$(resolve_confutils_src)"
BEARSSL_SRC="$(resolve_bearssl_src)"
export SHM_QUEUE_SRC CLI_SPEC_SRC ENTRYPOINTS_SRC CONFUTILS_SRC BEARSSL_SRC

mkdir -p build/nimcache

failures=()
for entry in "${SOURCES[@]}"; do
  src="${entry%%|*}"
  if [[ ! -f "${src}" ]]; then
    # A listed source that is gone is a gate that has lost its subject; say
    # so rather than passing on nothing.
    failures+=("${src}: listed here but does not exist; remove or rename the entry")
    continue
  fi
  name="$(basename "${src}" .nim)"
  cache="build/nimcache/host-c-compile-${name}"
  log="${cache}.log"
  rm -rf "${cache}"
  mkdir -p "${cache}"
  printf 'check_host_c_compile_of_unreached_code: compiling %s\n' "${src}"
  if ! nim c --noLinking:on --hints:off \
       --nimcache:"${cache}" \
       "${src}" >"${log}" 2>&1; then
    grep -E 'error:|Error:' "${log}" | head -20 >&2 || tail -40 "${log}" >&2
    failures+=("${src}: does not compile (full log: ${log})")
  fi
done

if (( ${#failures[@]} > 0 )); then
  printf 'check_host_c_compile_of_unreached_code: %d of %d source(s) failed:\n' \
    "${#failures[@]}" "${#SOURCES[@]}" >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi
# Nim's default C backend invokes `gcc` from PATH (it does not read $CC).
printf 'check_host_c_compile_of_unreached_code: %d source(s) compile with %s\n' \
  "${#SOURCES[@]}" "$(command -v gcc || echo 'gcc (not on PATH?)')"
