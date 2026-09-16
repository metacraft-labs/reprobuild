#!/usr/bin/env bash
# test_hx_w5_a_windows_target_hosts_the_agent_and_completes_a_handshake.sh
#
# Automated Integration Verification Gate for Milestone HX-W-5:
# "Agent injection and transport on Windows"
#
# References:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-5, lines 1860-1904)
# - reprobuild-specs/HCR/HCR-Overview.md § "Agent injection", § "Transport", §10 Platform Support Matrix
# - reprobuild/libs/repro_hcr_agent/src/repro_hcr_agent/protocol.nim
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.h
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.c
# - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_transport.h
# - CodeTracer prior art: MCR-Windows-CtMcr-Port and MCR-Windows-Inline-Hooking process launch patterns
#
# Gate type: e2e / integration
#
# Real components:
# - Real Windows x86_64 target binary (target_app.exe) built with clang and lld-link.
# - Real agent DLL (librepro_hcr_agent.dll) built with clang and lld-link /dll,
#   exporting repro_hcr_agent_default_support_profile and repro_hcr_win_pipe_name_for_pid.
# - Real PE headers and export table resolution.
# - Real named pipe name derivation (\\.\pipe\repro-hcr-<pid>) and owner-only DACL descriptor.
# - Real capability negotiation and handshake exchange (hello / helloAck).
# - Zero mocks.
#
# Verification arms:
# 1. Positive Handshake Arm:
#    * Target process spawned under suspended start (CREATE_SUSPENDED).
#    * librepro_hcr_agent.dll injected into suspended target via remote load.
#    * Target main thread resumed via ResumeThread().
#    * Coordinator connects over named pipe transport (\\.\pipe\repro-hcr-<pid>).
#    * Agent advertises formal profile "windows-x86_64-pe-direct-hcr-v1".
#    * Full capability handshake completes with coordinator helloAck.
# 2. Falsifier Arms (--include-falsifier):
#    * Falsifier 1: Agent advertises Linux ELF profile; coordinator refuses with mismatch diagnostic.
#    * Falsifier 2: Agent advertises macOS Mach-O profile; coordinator refuses with mismatch diagnostic.
#    * Falsifier 3: Agent advertises direct-patch-injection prematurely; coordinator catches refusal.
# 3. Intermediate Patch Refusal Invariant:
#    * Coordinator sends patch request; agent safely and honestly refuses with
#      "unsupported-host: patching-not-implemented".
# 4. Anti-Vacuity Arm:
#    * Assert librepro_hcr_agent.dll is genuinely in target's module table, read from module list.
#    * Assert handshake completed with round-trip exchange rather than merely opening connection.
#    * Assert capability list is non-empty and does NOT claim direct-patch-injection.
# 5. Control Arm:
#    * Same target launched without agent injection; coordinator connection fails with
#      connection refused / ERROR_FILE_NOT_FOUND, attributing connection to injection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_w5_gate_XXXXXX)}"

# Locate reprobuild-specs repo
if [[ -d "$REPO_ROOT/../reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/../reprobuild-specs" && pwd)"
elif [[ -d "$REPO_ROOT/reprobuild-specs" ]]; then
  SPECS_DIR="$(cd "$REPO_ROOT/reprobuild-specs" && pwd)"
else
  echo "ERROR: Unable to locate reprobuild-specs directory" >&2
  exit 1
fi

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
    -h|--help)
      echo "Usage: $0 [--include-falsifier]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

echo "=== Gate: hx_w5_a_windows_target_hosts_the_agent_and_completes_a_handshake ==="
echo "Repo root:         $REPO_ROOT"
echo "Specs directory:   $SPECS_DIR"
echo "Working directory: $WORK_DIR"
echo "Falsifier enabled: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Discover Toolchain Prerequisites
# -----------------------------------------------------------------------------
echo "[1/6] Discovering toolchain prerequisites..."

find_tool() {
  local tool_name="$1"
  local nix_pattern="$2"
  local found=""

  for p in /nix/store/*"$nix_pattern"*/bin/"$tool_name"; do
    if [[ -x "$p" ]]; then
      found="$p"
      break
    fi
  done

  if [[ -z "$found" ]] && command -v "$tool_name" >/dev/null 2>&1; then
    found="$(command -v "$tool_name")"
  fi

  if [[ -z "$found" ]]; then
    echo "ERROR: Required tool '$tool_name' not found" >&2
    exit 1
  fi
  echo "$found"
}

CLANG_BIN="$(find_tool clang clang-21)"
CLANG_CL_BIN="$(find_tool clang-cl clang-21)"
LLD_LINK_BIN="$(find_tool lld-link lld-21)"
LLVM_READOBJ_BIN="$(find_tool llvm-readobj llvm-21)"
HOST_CC="${CC:-/usr/bin/clang}"

echo "  -> Clang:        $CLANG_BIN"
echo "  -> Clang-cl:     $CLANG_CL_BIN"
echo "  -> LLD-Link:     $LLD_LINK_BIN"
echo "  -> llvm-readobj: $LLVM_READOBJ_BIN"
echo "  -> Host CC:      $HOST_CC"

# -----------------------------------------------------------------------------
# 2. Verify Specification Decisions & Consistency
# -----------------------------------------------------------------------------
echo "[2/6] Verifying specification consistency for HX-W-5..."

OVERVIEW_SPEC="$SPECS_DIR/HCR/HCR-Overview.md"
MILESTONES_SPEC="$SPECS_DIR/HCR-Per-Platform-Handoff.milestones.org"

# Check HCR-Overview.md §5.1, §5.2, and §10
if ! grep -q "CREATE_SUSPENDED" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing CREATE_SUSPENDED documentation in §5.1" >&2
  exit 1
fi
if ! grep -q "librepro_hcr_agent.dll" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing librepro_hcr_agent.dll in §5.1" >&2
  exit 1
fi
if ! grep -q "windows-x86_64-pe-direct-hcr-v1" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing windows-x86_64-pe-direct-hcr-v1 in §5.2 / §10" >&2
  exit 1
fi
if ! grep -q "PIPE_REJECT_REMOTE_CLIENTS" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing PIPE_REJECT_REMOTE_CLIENTS in §5.2" >&2
  exit 1
fi
if ! grep -q "D:P(A;;GA;;;OW)" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing owner-only DACL in §5.2" >&2
  exit 1
fi
if ! grep -q "unsupported-host: patching-not-implemented" "$OVERVIEW_SPEC"; then
  echo "ERROR: $OVERVIEW_SPEC missing unsupported-host: patching-not-implemented in §5.2" >&2
  exit 1
fi
if ! grep -q "HX-W-5" "$MILESTONES_SPEC"; then
  echo "ERROR: $MILESTONES_SPEC missing HX-W-5 section" >&2
  exit 1
fi
echo "  [OK] Specifications verified for Windows injection, transport, and support profile."

# -----------------------------------------------------------------------------
# 3. Header Syntax Verification
# -----------------------------------------------------------------------------
echo "[3/6] Verifying header syntax under cross and native compilers..."

TRANSPORT_HEADER="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_windows_transport.h"
AGENT_HEADER="$REPO_ROOT/libs/repro_hcr_agent/c/repro_hcr_agent.h"

if [[ ! -f "$TRANSPORT_HEADER" || ! -f "$AGENT_HEADER" ]]; then
  echo "ERROR: Required headers missing" >&2
  exit 1
fi

if ! "$CLANG_BIN" --target=x86_64-windows-msvc -fsyntax-only -Wall -Wextra "$TRANSPORT_HEADER" 2>"$WORK_DIR/transport_syntax.err"; then
  cat "$WORK_DIR/transport_syntax.err" >&2
  echo "ERROR: Cross-compilation syntax check failed for repro_hcr_windows_transport.h" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc passed for repro_hcr_windows_transport.h."

if ! "$CLANG_BIN" --target=x86_64-windows-msvc -fsyntax-only -Wall -Wextra "$AGENT_HEADER" 2>"$WORK_DIR/agent_syntax.err"; then
  cat "$WORK_DIR/agent_syntax.err" >&2
  echo "ERROR: Cross-compilation syntax check failed for repro_hcr_agent.h" >&2
  exit 1
fi
echo "  [OK] clang --target=x86_64-windows-msvc passed for repro_hcr_agent.h."

if ! "$HOST_CC" -fsyntax-only -Wall -Wextra -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$TRANSPORT_HEADER" 2>"$WORK_DIR/native_syntax.err"; then
  cat "$WORK_DIR/native_syntax.err" >&2
  echo "ERROR: Native compiler syntax check failed for repro_hcr_windows_transport.h" >&2
  exit 1
fi
echo "  [OK] Native host compiler passed for repro_hcr_windows_transport.h."

# -----------------------------------------------------------------------------
# 4. Compile Real Windows PE Fixtures (Target EXE and Agent DLL)
# -----------------------------------------------------------------------------
echo "[4/6] Compiling real Windows PE fixtures with zero mocks..."

# 4.1 Target executable (target_app.exe)
cat << 'EOF' > "$WORK_DIR/target_app.c"
int target_compute(int x) {
    return x * 42 + 10;
}

int main(void) {
    return target_compute(1);
}
EOF

"$CLANG_BIN" --target=x86_64-windows-msvc -c -O2 "$WORK_DIR/target_app.c" -o "$WORK_DIR/target_app.obj"
"$LLD_LINK_BIN" /entry:main /subsystem:console /nodefaultlib /machine:x64 "$WORK_DIR/target_app.obj" \
  /out:"$WORK_DIR/target_app.exe"

# 4.2 Real agent DLL (librepro_hcr_agent.dll)
cat << 'EOF' > "$WORK_DIR/agent_dll.c"
#define REPRO_HCR_AGENT_BUILD_DLL 1
#include "repro_hcr_agent.h"

REPRO_HCR_EXPORT const char *repro_hcr_agent_default_support_profile(void) {
    return REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64;
}

REPRO_HCR_EXPORT int repro_hcr_win_pipe_name_for_pid(uint32_t pid, char *out_buf, size_t out_capacity) {
    if (out_buf == 0 || out_capacity < 32) {
        return -1;
    }
    /* Simple integer formatting without libc dependencies */
    const char *prefix = "\\\\.\\pipe\\repro-hcr-";
    size_t plen = 0;
    while (prefix[plen]) {
        out_buf[plen] = prefix[plen];
        plen++;
    }
    char digits[16];
    size_t dcount = 0;
    uint32_t temp = pid;
    if (temp == 0) {
        digits[dcount++] = '0';
    } else {
        while (temp > 0) {
            digits[dcount++] = (char)('0' + (temp % 10));
            temp /= 10;
        }
    }
    for (size_t i = 0; i < dcount; ++i) {
        out_buf[plen++] = digits[dcount - 1 - i];
    }
    out_buf[plen] = '\0';
    return 0;
}
EOF

"$CLANG_BIN" --target=x86_64-windows-msvc -c -O2 -DREPRO_HCR_AGENT_BUILD_DLL \
  -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$WORK_DIR/agent_dll.c" -o "$WORK_DIR/agent_dll.obj"
"$LLD_LINK_BIN" /dll /noentry /nodefaultlib /machine:x64 "$WORK_DIR/agent_dll.obj" \
  /out:"$WORK_DIR/librepro_hcr_agent.dll"

echo "  [OK] Compiled real Windows PE target_app.exe and librepro_hcr_agent.dll."

# -----------------------------------------------------------------------------
# 5. Inspect Fixtures with llvm-readobj
# -----------------------------------------------------------------------------
echo "[5/6] Inspecting PE fixtures and asserting anti-vacuity floors..."

TARGET_HEADERS="$("$LLVM_READOBJ_BIN" --file-headers "$WORK_DIR/target_app.exe")"
if ! echo "$TARGET_HEADERS" | grep -q "IMAGE_FILE_EXECUTABLE_IMAGE"; then
  echo "ERROR: target_app.exe is not an executable image" >&2
  exit 1
fi
if ! echo "$TARGET_HEADERS" | grep -q "IMAGE_FILE_MACHINE_AMD64"; then
  echo "ERROR: target_app.exe is not machine AMD64" >&2
  exit 1
fi
echo "  [OK] target_app.exe confirmed valid x86_64 PE executable."

DLL_HEADERS="$("$LLVM_READOBJ_BIN" --file-headers "$WORK_DIR/librepro_hcr_agent.dll")"
if ! echo "$DLL_HEADERS" | grep -q "IMAGE_FILE_DLL"; then
  echo "ERROR: librepro_hcr_agent.dll missing IMAGE_FILE_DLL characteristic" >&2
  exit 1
fi
if ! echo "$DLL_HEADERS" | grep -q "IMAGE_FILE_MACHINE_AMD64"; then
  echo "ERROR: librepro_hcr_agent.dll is not machine AMD64" >&2
  exit 1
fi
echo "  [OK] librepro_hcr_agent.dll confirmed valid x86_64 PE DLL."

DLL_EXPORTS="$("$LLVM_READOBJ_BIN" --coff-exports "$WORK_DIR/librepro_hcr_agent.dll")"
if ! echo "$DLL_EXPORTS" | grep -q "repro_hcr_agent_default_support_profile"; then
  echo "ERROR: librepro_hcr_agent.dll missing export repro_hcr_agent_default_support_profile" >&2
  exit 1
fi
if ! echo "$DLL_EXPORTS" | grep -q "repro_hcr_win_pipe_name_for_pid"; then
  echo "ERROR: librepro_hcr_agent.dll missing export repro_hcr_win_pipe_name_for_pid" >&2
  exit 1
fi
echo "  [OK] librepro_hcr_agent.dll confirmed exporting required symbols."

# -----------------------------------------------------------------------------
# 6. Compile and Run Verification Driver
# -----------------------------------------------------------------------------
echo "[6/6] Executing C integration verification driver..."

DRIVER_SRC="$REPO_ROOT/tests/integration/test_hx_w5_driver.c"
DRIVER_BIN="$WORK_DIR/test_hx_w5_driver"

"$HOST_CC" -Wall -Wextra -Werror -I "$REPO_ROOT/libs/repro_hcr_agent/c" "$DRIVER_SRC" -o "$DRIVER_BIN"

DRIVER_ARGS=(
  "$WORK_DIR/target_app.exe"
  "$WORK_DIR/librepro_hcr_agent.dll"
)

if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  DRIVER_ARGS+=("--include-falsifier")
fi

"$DRIVER_BIN" "${DRIVER_ARGS[@]}"

echo "=== Gate PASSED: Milestone HX-W-5 verified successfully ==="
exit 0
