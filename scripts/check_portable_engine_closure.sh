#!/usr/bin/env bash
# Refuse a Linux-only module in the engine's macOS or Windows closure.
#
#   bash scripts/check_portable_engine_closure.sh              # the gate
#   bash scripts/check_portable_engine_closure.sh --os=macosx  # one target
#
# WHAT IT GUARDS. `apps/repro/repro.nim` is ONE source tree built for
# three operating systems. A library whose modules bind Linux-only headers
# -- `repro_addon/linux_fs.nim` imports `<sys/vfs.h>` and issues the btrfs
# subvolume ioctls -- type-checks on every platform, because a
# `{.importc, header.}` binding is not resolved until the C compiler sees
# it. So `nim check` is green, every Linux test passes, the Linux CI job is
# green, and the breakage appears only when somebody compiles for macOS or
# Windows:
#
#     @prepro_addon@slinux_fs.nim.c:9:10: fatal error:
#       'sys/vfs.h' file not found
#
# THE INCIDENT. `ace9462f32` ("isolate Linux add-on imports from portable
# dispatch") put the add-on imports in `repro_cli_support/infra.nim` behind
# `when defined(linux)` and recorded in its own message that
# "Windows-target generated C now excludes the Linux add-on closure" --
# checked by hand, at that commit, and nowhere again. `63757c8dd8`, the
# next day, added `import repro_addon/addon_apply` to
# `repro_cli_support/deploy_agent.nim`, which is in the same image. The
# add-on closure was back, 24 generated C files of it, and the first thing
# to notice was a Mac that could not run `home-switch` at all, several pins
# downstream of the commit that broke it.
#
# A hand check that is not a gate protects exactly one commit. This is the
# gate.
#
# HOW. Nim will generate C for a foreign target on any host: it is the C
# compiler, not Nim, that needs the target's headers. `--compileOnly`
# stops before that compiler runs, so a Linux box can answer the question
# this gate asks -- WHICH NIM MODULES does the macOS engine compile -- for
# both non-Linux targets, in the Linux lint job, on every commit. It is
# therefore a strictly WIDER check than a macOS build would be, and it
# needs no macOS runner. It is NOT a substitute for one: it proves the
# Linux-only closure is absent, not that the result links or runs. Build
# the real thing on a Mac before moving a pin.
#
# SCOPE, and what it does not cover. The engine entry point only, not all
# of `apps/entrypoints.txt`: the engine carries every CLI surface, so it is
# the image that reaches the most code and the one that broke, and the
# others are subsets of its library set. About a minute.
#
# `--os:macosx` only, although the same defect reaches Windows. `--os:windows`
# from a Linux host does not get as far as the closure: `config.nims` keys
# its sibling `--path` entries on the TARGET platform, so it offers
# `..\gosti\src` to a Linux host and the compile dies at
# `apps/repro/repro.nim(58, 8) Error: cannot open file: repro_cli_support`
# before any module is resolved. Measured on reprobuild `5294fe2fdd`.
# Pass `--os=windows` by hand once `config.nims` resolves a host path for a
# foreign target; until then the Windows half of this invariant rests on the
# macOS half catching the same unguarded import, which it does, because an
# import is not per-platform.
set -euo pipefail

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

# The entry point whose closure is checked, and the module that MUST be in
# it. The sentinel is the positive control: it is the module whose
# unguarded import caused the incident above, so if it ever leaves the
# engine's closure this gate has lost its subject and must say so rather
# than pass on an empty or unread dependency list.
readonly ENTRY_POINT='apps/repro/repro.nim'
readonly SENTINEL='libs/repro_cli_support/src/repro_cli_support/deploy_agent.nim'

# Linux-only source roots, each with the reason it cannot cross. Add a row
# when a library grows a Linux-only binding; do not add one to silence a
# failure -- the failure means a portable caller imported it unguarded,
# and the fix is `when defined(linux):` at that import, as
# `repro_cli_support/infra.nim` and `.../deploy_agent.nim` both do.
readonly LINUX_ONLY_ROOTS=(
  'libs/repro_addon/:ReproOS add-on mode: statfs(2) and the btrfs subvolume ioctls via <sys/vfs.h> (repro_addon/linux_fs.nim), plus the dpkg ownership ledger'
)

targets=(macosx)
if [[ $# -gt 0 ]]; then
  case "$1" in
    --os=*) targets=("${1#--os=}") ;;
    *) printf 'check_portable_engine_closure: unknown argument: %s\n' "$1" >&2
       exit 2 ;;
  esac
fi

# Same source-path resolver the app build and the `nim check` sweep use;
# without it `io_mon`'s extracted `shm_queue` import does not resolve when
# the sibling checkout is absent and the dev shell supplies it from the
# Nix store. See scripts/check_nim_sources.sh.
# shellcheck source=scripts/source_paths.sh
source scripts/source_paths.sh
SHM_QUEUE_SRC="$(resolve_shm_queue_src)"
BEARSSL_SRC="$(resolve_bearssl_src)"
export SHM_QUEUE_SRC BEARSSL_SRC

mkdir -p build/nimcache

# Serial, not concurrent like the `nim check` sweep: each codegen peaks
# near 3 GiB, and two targets at once have no deadline worth 6 GiB of a
# lint job's headroom.
failures=()
for target in "${targets[@]}"; do
  cache="build/nimcache/portable-closure-${target}"
  log="${cache}.log"
  rm -rf "${cache}"
  mkdir -p "${cache}"
  printf 'check_portable_engine_closure: generating %s sources for --os:%s\n' \
    "${ENTRY_POINT}" "${target}"
  # The defines are the engine's own, from apps/entrypoints.txt: the
  # closure depends on them (`--define:ssl` compiles in the TLS paths), so
  # a check without them would examine a different program.
  # `--genScript:on` is what writes the `.deps` file this gate reads (and
  # implies `--compileOnly`); `--genDeps` is a deprecated alias for it.
  if ! nim c --compileOnly --noLinking:on --genScript:on \
       --os:"${target}" \
       --define:ssl --define:reproVendoredHash \
       --nimcache:"${cache}" \
       "${ENTRY_POINT}" >"${log}" 2>&1; then
    tail -40 "${log}" >&2
    failures+=("--os:${target}: nim could not generate sources (full log: ${log})")
    continue
  fi

  deps="${cache}/$(basename "${ENTRY_POINT}" .nim).deps"
  if [[ ! -s "${deps}" ]]; then
    failures+=("--os:${target}: no dependency list at ${deps}; --genDeps wrote nothing, so this target was NOT checked")
    continue
  fi

  # The control, before the verdict: a dependency list that does not name
  # the sentinel is not evidence of a clean closure.
  if ! grep -qF "${SENTINEL}" "${deps}"; then
    failures+=("--os:${target}: ${SENTINEL} is absent from ${deps}, so this gate no longer has its subject; re-aim it before trusting a pass")
    continue
  fi

  for row in "${LINUX_ONLY_ROOTS[@]}"; do
    root="${row%%:*}"
    reason="${row#*:}"
    # Count, then list: the diagnostic names the modules, because "the
    # add-on closure is back" is not actionable and "these four modules
    # are, reached from this import" is.
    mapfile -t offenders < <(grep -F "/${root}" "${deps}" | sed "s|^$PWD/||" | LC_ALL=C sort)
    if (( ${#offenders[@]} )); then
      printf 'check_portable_engine_closure: %s compiles %d module(s) from %s for --os:%s\n' \
        "${ENTRY_POINT}" "${#offenders[@]}" "${root}" "${target}" >&2
      printf '  %s\n' "${offenders[@]}" >&2
      printf '  %s is Linux-only: %s\n' "${root}" "${reason}" >&2
      printf '  Put the import behind `when defined(linux):` at the call site, as\n' >&2
      printf '  repro_cli_support/infra.nim and .../deploy_agent.nim do, and keep the\n' >&2
      printf '  branch that uses it inside the same `when`.\n' >&2
      failures+=("--os:${target}: ${#offenders[@]} module(s) from ${root} in the portable engine")
    fi
  done
done

if (( ${#failures[@]} )); then
  printf 'check_portable_engine_closure: FAILED\n' >&2
  printf '  %s\n' "${failures[@]}" >&2
  exit 1
fi
printf 'check_portable_engine_closure: %s compiles no Linux-only module for %s.\n' \
  "${ENTRY_POINT}" "${targets[*]}"
