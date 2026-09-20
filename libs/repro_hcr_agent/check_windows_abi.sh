#!/usr/bin/env bash
# HWX-M0: the thirteen rb_hcr_* functions must be DEFINED on the Windows arm,
# not merely declared.
#
# WHY THIS EXISTS. `repro_hcr_agent.h` declares them unconditionally. Until
# 2026-09-20 `repro_hcr_agent_windows.c` defined NONE, so a Windows application
# that linked the agent failed at LINK time with five undefined symbols. A
# linker error names a symbol and never a reason, so no diagnostic the agent
# could write ever reached the developer -- and no in-tree gate could see it,
# because every gate builds the POSIX arm.
#
# WHY IT RUNS ON LINUX. It does not need Windows. clang implements SEH for the
# mingw target where gcc does not (`__try`/`__except`, which this TU uses), so
# the translation unit compiles here; mingw's own linker then links it, because
# a nix-wrapped clang reaches for Linux binutils and dies on `i386pep`.
# Optionally wine runs the result.
#
# This checks that the ABI LINKS and RUNS. It does NOT check that Windows
# applies patches -- the lifecycle is deliberately unwired and refuses by name.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

need() { command -v "$1" >/dev/null || { echo "check_windows_abi: missing $1" >&2; exit 2; }; }

CLANG="${REPRO_HCR_WIN_CLANG:-clang}"
MINGW_CC="${REPRO_HCR_WIN_MINGW_CC:-x86_64-w64-mingw32-gcc}"
need "$CLANG"; need "$MINGW_CC"
MINGW_INC="${REPRO_HCR_WIN_MINGW_INCLUDE:-}"
[ -n "$MINGW_INC" ] || { echo "check_windows_abi: set REPRO_HCR_WIN_MINGW_INCLUDE" >&2; exit 2; }

cat > "$work/embedder.c" <<'CEOF'
#include "repro_hcr_agent.h"
#include <stdio.h>
static void before(const RbHcrReloadInfo *i, void *u){ (void)i; (void)u; }
int main(void){
  rb_hcr_register_managed_type("Foo");
  rb_hcr_before_reload(before, 0);
  printf("wants_reload=%d\n", (int)rb_hcr_wants_reload());
  rb_hcr_apply_reload();
  printf("file_changed=%d\n", (int)rb_hcr_file_changed("a.c"));
  return 0;
}
CEOF

"$CLANG" --target=x86_64-w64-windows-gnu -fms-extensions -O1 \
  -isystem "$MINGW_INC" -I "$here/c" -c -o "$work/agent.o" \
  "$here/c/repro_hcr_agent_windows.c"
"$CLANG" --target=x86_64-w64-windows-gnu -fms-extensions -O1 \
  -isystem "$MINGW_INC" -I "$here/c" -c -o "$work/embedder.o" "$work/embedder.c"

link_args=()
[ -n "${REPRO_HCR_WIN_EXTRA_LIBDIR:-}" ] && link_args+=("-L$REPRO_HCR_WIN_EXTRA_LIBDIR")
if ! "$MINGW_CC" "${link_args[@]+"${link_args[@]}"}" -o "$work/embedder.exe" \
       "$work/embedder.o" "$work/agent.o" -lmincore 2> "$work/link.err"; then
  echo "check_windows_abi: FAILED -- the embedder does not link." >&2
  grep -oE "undefined reference to \`rb_hcr_[a-z_]+'" "$work/link.err" | sort -u >&2 || true
  echo "  This is the declared-but-undefined ABI. See HWX-M0." >&2
  exit 1
fi

# Every one of the thirteen must be a DEFINED symbol in the agent object.
missing=0
for sym in wants_reload apply_reload register_managed_type unregister_managed_type \
           before_reload after_reload remove_before_reload remove_after_reload \
           file_changed type_changed padded_alloc padded_free padded_capacity; do
  if ! "${MINGW_CC%-gcc}-nm" --defined-only "$work/agent.o" 2>/dev/null \
        | grep -q " rb_hcr_$sym$"; then
    echo "check_windows_abi: rb_hcr_$sym is NOT defined in the Windows object" >&2
    missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] || { echo "check_windows_abi: $missing of 13 undefined" >&2; exit 1; }

echo "check_windows_abi: PASSED -- embedder links; all 13 rb_hcr_* defined."
if [ -n "${REPRO_HCR_WIN_WINE:-}" ]; then
  out="$("$REPRO_HCR_WIN_WINE" "$work/embedder.exe" 2>/dev/null)"
  case "$out" in
    *wants_reload=0*file_changed=0*) echo "check_windows_abi: wine run OK -- $(echo "$out" | tr '\n' ' ')" ;;
    *) echo "check_windows_abi: wine ran but output was unexpected: $out" >&2; exit 1 ;;
  esac
fi
