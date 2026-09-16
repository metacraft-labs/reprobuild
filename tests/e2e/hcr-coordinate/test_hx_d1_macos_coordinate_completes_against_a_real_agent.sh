#!/usr/bin/env bash
# test_hx_d1_macos_coordinate_completes_against_a_real_agent.sh
#
# Integration / E2E Gate for Milestone HX-D-1:
# "Run repro hcr coordinate on macOS, for the first time"
#
# Design doc: reprobuild-specs/HCR/CLI-Integration.md, reprobuild-specs/HCR/Patch-Loading-Lifecycle.md
# Milestones: reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:1289-1338
#
# Real components:
# - A real macOS arm64 host (Apple Silicon Darwin arm64)
# - Real `repro hcr coordinate` CLI invocation
# - Real compiled C target process linking production `repro_hcr_agent.c`
# - Real Unix domain socket IPC and Content-Length protocol framing
# - Real `B imm26` trampoline instruction installed in memory and decoded
# - Allowed mocks: NONE
#
# Arms:
# 1. Host Guard: Darwin arm64 assertion (loud non-zero failure off macOS arm64).
# 2. Control Arm: Target process with no patch applied reports 11 -> 11 with byte-identical entry bytes.
# 3. Positive Arm: Coordinator builds patch, delivers over wire, target transitions 11 -> 77,
#    entry bytes decode to `B imm26` resolving to agent dispatchAddress, all 3 artifacts emitted.
# 4. Falsifier 1 (--include-falsifier): Profile forced to Linux string; handshake refused, no artifacts.
# 5. Falsifier 2 (--include-falsifier): Publishing store neutered; target observable remains 11; gate goes red.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HCR_AGENT_DIR="$REPO_ROOT/libs/repro_hcr_agent/c"
HCR_AGENT_C="$HCR_AGENT_DIR/repro_hcr_agent.c"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
  esac
done

echo "=== Gate: test_hx_d1_macos_coordinate_completes_against_a_real_agent ==="
echo "Repo root: $REPO_ROOT"
echo "Include falsifier: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Host Guard: Darwin arm64 assertion
# -----------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_OS" != "Darwin" || "$HOST_ARCH" != "arm64" ]]; then
  echo "ERROR: Gate hx_d1_macos_coordinate requires macOS arm64 (Darwin arm64)." >&2
  echo "Current host is: OS=$HOST_OS ARCH=$HOST_ARCH" >&2
  echo "A run on an unsupported host must be a loud unsupported error, not a silent pass." >&2
  exit 1
fi

echo "[1/4] Host assertion passed: genuinely Darwin arm64."

# -----------------------------------------------------------------------------
# Verify toolchain availability
# -----------------------------------------------------------------------------
if ! command -v repro >/dev/null 2>&1; then
  echo "ERROR: 'repro' binary not found in PATH." >&2
  exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: 'clang' binary not found in PATH." >&2
  exit 1
fi

if [[ ! -f "$HCR_AGENT_C" ]]; then
  echo "ERROR: repro_hcr_agent.c not found at $HCR_AGENT_C" >&2
  exit 1
fi

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hx_d1_coordinate_XXXXXX")}"
cleanup() {
  if [[ -z "${PRESERVE_WORK:-}" ]]; then
    rm -rf "$WORK_DIR"
  else
    echo "Preserving work directory: $WORK_DIR"
  fi
}
trap cleanup EXIT

echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# Setup fixture project and target C source
# -----------------------------------------------------------------------------
PROJ_DIR="$WORK_DIR/project"
mkdir -p "$PROJ_DIR/src"
ARTIFACTS_DIR="$WORK_DIR/artifacts"
SOCK_PATH="$WORK_DIR/agent.sock"
EDIT_DRIVER="$WORK_DIR/edit_driver.sh"
TARGET_C="$WORK_DIR/target.c"
TARGET_BIN="$WORK_DIR/target"

cat << "EOF" > "$PROJ_DIR/reprobuild.nim"
import repro_dsl_stdlib

package hcrTestPkg:
  uses:
    "gcc >=1"

  build:
    let buildDir = fs.ensureDir(actionId = "build-dir", path = "build")
    let rawObj = gcc(
      source = "src/patchable.c",
      output = "build/patchable.raw.o",
      debug3 = true,
      compileOnly = true,
      after = @[buildDir])
    let obj = hcr.prepareObject(
      input = "build/patchable.raw.o",
      output = "build/patchable.o",
      after = @[rawObj])
    target("patchable-object", [obj])
    defaultBuildAction(obj)
EOF

cat << "EOF" > "$PROJ_DIR/src/patchable.c"
int reprobuild_hcr_patchable_value(void) {
  return 11;
}
EOF

cat << "EOF" > "$EDIT_DRIVER"
#!/bin/sh
cat << "EDIT_EOF" > "$1/src/patchable.c"
int reprobuild_hcr_patchable_value(void) {
  return 77;
}
EDIT_EOF
EOF
chmod +x "$EDIT_DRIVER"

cat << "EOF" > "$TARGET_C"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include "repro_hcr_agent.h"

__attribute__((noinline, used))
__attribute__((section("__HCR,__text")))
int reprobuild_hcr_patchable_value(void) {
  return 11;
}

static int (*volatile call_patchable)(void) = reprobuild_hcr_patchable_value;

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

int main(int argc, char **argv) {
  const char *mode = "normal";
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--mode=", 7) == 0) {
      mode = argv[i] + 7;
    }
  }

  uint64_t entry_addr = (uint64_t)(uintptr_t)reprobuild_hcr_patchable_value;
  unsigned char before_bytes[4];
  memcpy(before_bytes, (const void *)entry_addr, 4);

  int before = call_patchable();
  printf("TARGET_BEFORE=%d\n", before);
  fflush(stdout);

  if (strcmp(mode, "control") == 0) {
    int after = call_patchable();
    printf("TARGET_AFTER=%d\n", after);
    char hex_before[9], hex_after[9];
    dump_hex(hex_before, before_bytes, 4);
    dump_hex(hex_after, (const unsigned char *)entry_addr, 4);
    printf("TARGET_ENTRY_BEFORE_HEX=%s\n", hex_before);
    printf("TARGET_ENTRY_AFTER_HEX=%s\n", hex_after);
    fflush(stdout);
    return 0;
  }

  const char *profile = repro_hcr_agent_default_support_profile();
  if (strcmp(mode, "falsifier-profile") == 0) {
    profile = "linux-x86_64-elf-direct-hcr-v1";
  }

  repro_hcr_agent_symbol symbols[1];
  symbols[0].name = "reprobuild_hcr_patchable_value";
  symbols[0].address = (void *)reprobuild_hcr_patchable_value;

  int start_rc = repro_hcr_agent_start_polling_from_env(profile, symbols, 1);
  if (start_rc != 0) {
    fprintf(stderr, "start_polling failed: %d\n", start_rc);
    return 1;
  }

  int poll_rc = repro_hcr_agent_poll();
  if (poll_rc != 0) {
    fprintf(stderr, "poll failed: %d\n", poll_rc);
    return 2;
  }

  if (strcmp(mode, "falsifier-neuter-store") == 0) {
    long page_size = sysconf(_SC_PAGESIZE);
    uint64_t page = entry_addr & ~((uint64_t)page_size - 1);
    mprotect((void *)page, page_size, PROT_READ | PROT_WRITE);
    memcpy((void *)entry_addr, before_bytes, 4);
    mprotect((void *)page, page_size, PROT_READ | PROT_EXEC);
  }

  int after = call_patchable();
  printf("TARGET_AFTER=%d\n", after);

  unsigned char after_bytes[4];
  memcpy(after_bytes, (const void *)entry_addr, 4);
  char hex_before[9], hex_after[9];
  dump_hex(hex_before, before_bytes, 4);
  dump_hex(hex_after, after_bytes, 4);
  printf("TARGET_ENTRY_BEFORE_HEX=%s\n", hex_before);
  printf("TARGET_ENTRY_AFTER_HEX=%s\n", hex_after);
  printf("TARGET_ENTRY_ADDRESS=0x%llx\n", (unsigned long long)entry_addr);

  uint32_t inst = *(const uint32_t *)after_bytes;
  printf("TARGET_ENTRY_INST=0x%08x\n", inst);
  if ((inst & 0x7c000000u) == 0x14000000u) {
    uint32_t raw_imm = inst & 0x03ffffffu;
    int64_t imm = (raw_imm & 0x02000000u) ? (int64_t)(raw_imm | ~0x03ffffffULL) : (int64_t)raw_imm;
    uint64_t decoded_dest = (uint64_t)((int64_t)entry_addr + imm * 4);
    printf("TARGET_DECODED_DEST=0x%llx\n", (unsigned long long)decoded_dest);
  } else {
    printf("TARGET_DECODED_DEST=none\n");
  }
  fflush(stdout);
  return 0;
}
EOF

echo "Building initial patchable object via repro build..."
(cd "$PROJ_DIR" && repro build "$PROJ_DIR#patchable-object" --tool-provisioning=path --progress=none --log=actions)

echo "Compiling target process with clang and linking repro_hcr_agent.c..."
clang -Wl,-segprot,__HCR,rwx,rwx -I"$HCR_AGENT_DIR" "$TARGET_C" "$HCR_AGENT_C" -o "$TARGET_BIN"

# -----------------------------------------------------------------------------
# 2. Control Arm: No patch requested
# -----------------------------------------------------------------------------
echo "[2/4] Running Control Arm..."
CTRL_OUT="$("$TARGET_BIN" --mode=control)"
echo "$CTRL_OUT"

CTRL_BEFORE="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_BEFORE=/ {print $2}')"
CTRL_AFTER="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"
CTRL_HEX_BEFORE="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_ENTRY_BEFORE_HEX=/ {print $2}')"
CTRL_HEX_AFTER="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_ENTRY_AFTER_HEX=/ {print $2}')"

if [[ "$CTRL_BEFORE" != "11" || "$CTRL_AFTER" != "11" ]]; then
  echo "ERROR: Control arm observable changed unexpectedly ($CTRL_BEFORE -> $CTRL_AFTER)" >&2
  exit 1
fi

if [[ "$CTRL_HEX_BEFORE" != "$CTRL_HEX_AFTER" ]]; then
  echo "ERROR: Control arm entry bytes changed unexpectedly ($CTRL_HEX_BEFORE -> $CTRL_HEX_AFTER)" >&2
  exit 1
fi
echo "Control arm verified: observable (11 -> 11) and entry bytes unchanged."

# -----------------------------------------------------------------------------
# 3. Positive Arm: Real repro hcr coordinate run against live target
# -----------------------------------------------------------------------------
echo "[3/4] Running Positive Arm (repro hcr coordinate)..."
rm -f "$SOCK_PATH"
mkdir -p "$ARTIFACTS_DIR"

export REPRO_HCR_AGENT_SOCKET="$SOCK_PATH"

repro hcr coordinate \
  --project "$PROJ_DIR" \
  --target "patchable-object" \
  --socket "$SOCK_PATH" \
  --source-edit-driver "$EDIT_DRIVER" \
  --artifacts "$ARTIFACTS_DIR" &
COORD_PID=$!

# Wait briefly for coordinator to bind listener socket
for _ in {1..50}; do
  if [[ -S "$SOCK_PATH" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -S "$SOCK_PATH" ]]; then
  echo "ERROR: Coordinator failed to create socket at $SOCK_PATH" >&2
  wait "$COORD_PID" || true
  exit 1
fi

TARGET_OUT="$("$TARGET_BIN" --mode=normal)"
echo "Target output:"
echo "$TARGET_OUT"

wait "$COORD_PID"
COORD_RC=$?

if [[ "$COORD_RC" -ne 0 ]]; then
  echo "ERROR: Coordinator exited with non-zero code $COORD_RC" >&2
  exit 1
fi

TARGET_BEFORE="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_BEFORE=/ {print $2}')"
TARGET_AFTER="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"
TARGET_HEX_BEFORE="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_ENTRY_BEFORE_HEX=/ {print $2}')"
TARGET_HEX_AFTER="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_ENTRY_AFTER_HEX=/ {print $2}')"
TARGET_ENTRY_ADDR="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_ENTRY_ADDRESS=/ {print $2}')"
TARGET_DECODED_DEST="$(echo "$TARGET_OUT" | awk -F= '/^TARGET_DECODED_DEST=/ {print $2}')"

# Anti-vacuity assertions
if [[ "$TARGET_BEFORE" != "11" ]]; then
  echo "ERROR: Target before value expected 11, got '$TARGET_BEFORE'" >&2
  exit 1
fi

if [[ "$TARGET_AFTER" != "77" ]]; then
  echo "ERROR: Target after value expected 77, got '$TARGET_AFTER'" >&2
  exit 1
fi

if [[ "$TARGET_HEX_BEFORE" == "$TARGET_HEX_AFTER" ]]; then
  echo "ERROR: Target entry bytes did not change after patch" >&2
  exit 1
fi

if [[ "$TARGET_DECODED_DEST" == "none" || -z "$TARGET_DECODED_DEST" ]]; then
  echo "ERROR: Entry instruction failed to decode as ARM64 B imm26" >&2
  exit 1
fi

# Verify artifacts
ART_REPORT="$ARTIFACTS_DIR/hcr-coordinator-report.json"
ART_TRANSCRIPT="$ARTIFACTS_DIR/agent-protocol-transcript.json"
ART_METADATA="$ARTIFACTS_DIR/patch-bundle-metadata.json"

for art in "$ART_REPORT" "$ART_TRANSCRIPT" "$ART_METADATA"; do
  if [[ ! -s "$art" ]]; then
    echo "ERROR: Required artifact is missing or empty: $art" >&2
    exit 1
  fi
done

# Python verification helper to inspect artifact JSON structures and match dispatchAddress
python3 -c "
import json, sys

with open('$ART_TRANSCRIPT') as f:
    transcript = json.load(f)

messages = transcript.get('messages', [])
kinds = [m.get('kind') for m in messages]
for required_kind in ['hello', 'helloAck', 'patchRequest', 'patchApplied']:
    if required_kind not in kinds:
        sys.exit(f'Missing required transcript message kind: {required_kind}')

patch_applied = next(m['message']['patchApplied'] for m in messages if m.get('kind') == 'patchApplied')
wire_dispatch = patch_applied.get('dispatchAddress')
decoded_dest = '$TARGET_DECODED_DEST'

if wire_dispatch.lower() != decoded_dest.lower():
    sys.exit(f'dispatchAddress mismatch: wire={wire_dispatch} vs decoded={decoded_dest}')

with open('$ART_REPORT') as f:
    report = json.load(f)
if report.get('sessionState') != 'hssPatchFinished':
    sys.exit(f'Unexpected session state in report: {report.get(\"sessionState\")}')

with open('$ART_METADATA') as f:
    meta = json.load(f)
if meta.get('supportProfile') != 'macos-arm64-direct-hcr-in-codetracer-v1':
    sys.exit(f'Unexpected supportProfile in metadata: {meta.get(\"supportProfile\")}')

print('Artifact verification passed: transcript complete, dispatchAddress matches decoded B imm26 destination.')
"

echo "Positive arm verified successfully."

# -----------------------------------------------------------------------------
# 4. Falsifiers (--include-falsifier)
# -----------------------------------------------------------------------------
if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "[4/4] Running Falsifiers..."

  # Falsifier 1: Profile mismatch refusal
  echo "--- Falsifier 1: Profile mismatch refused ---"
  F1_SOCK="$WORK_DIR/f1.sock"
  F1_ARTIFACTS="$WORK_DIR/f1_artifacts"
  rm -rf "$F1_ARTIFACTS" "$F1_SOCK"
  mkdir -p "$F1_ARTIFACTS"

  export REPRO_HCR_AGENT_SOCKET="$F1_SOCK"

  F1_ERR_LOG="$WORK_DIR/f1_coord.err"
  repro hcr coordinate \
    --project "$PROJ_DIR" \
    --target "patchable-object" \
    --socket "$F1_SOCK" \
    --source-edit-driver "$EDIT_DRIVER" \
    --artifacts "$F1_ARTIFACTS" 2>"$F1_ERR_LOG" &
  F1_PID=$!

  for _ in {1..50}; do
    if [[ -S "$F1_SOCK" ]]; then
      break
    fi
    sleep 0.1
  done

  "$TARGET_BIN" --mode=falsifier-profile >/dev/null 2>&1 || true

  set +e
  wait "$F1_PID"
  F1_RC=$?
  set -e

  if [[ "$F1_RC" -eq 0 ]]; then
    echo "FALSIFIER ERROR: Coordinator succeeded unexpectedly when profile was mismatched" >&2
    exit 1
  fi

  if ! grep -q "agent support profile mismatch" "$F1_ERR_LOG"; then
    echo "FALSIFIER ERROR: Expected profile mismatch error in coordinator log: $(cat "$F1_ERR_LOG")" >&2
    exit 1
  fi

  # Assert no artifacts written before refusal
  if [[ -f "$F1_ARTIFACTS/hcr-coordinator-report.json" || -f "$F1_ARTIFACTS/agent-protocol-transcript.json" || -f "$F1_ARTIFACTS/patch-bundle-metadata.json" ]]; then
    echo "FALSIFIER ERROR: Artifacts were written despite handshake refusal" >&2
    exit 1
  fi
  echo "Falsifier 1 passed: handshake refused on profile mismatch, zero artifacts written."

  # Falsifier 2: Neutered publishing store -> gate fails on TARGET RETURN VALUE
  echo "--- Falsifier 2: Neutered publishing store ---"
  F2_SOCK="$WORK_DIR/f2.sock"
  F2_ARTIFACTS="$WORK_DIR/f2_artifacts"
  rm -rf "$F2_ARTIFACTS" "$F2_SOCK"
  mkdir -p "$F2_ARTIFACTS"

  export REPRO_HCR_AGENT_SOCKET="$F2_SOCK"

  repro hcr coordinate \
    --project "$PROJ_DIR" \
    --target "patchable-object" \
    --socket "$F2_SOCK" \
    --source-edit-driver "$EDIT_DRIVER" \
    --artifacts "$F2_ARTIFACTS" &
  F2_PID=$!

  for _ in {1..50}; do
    if [[ -S "$F2_SOCK" ]]; then
      break
    fi
    sleep 0.1
  done

  F2_TARGET_OUT="$("$TARGET_BIN" --mode=falsifier-neuter-store)"
  wait "$F2_PID"

  F2_TARGET_BEFORE="$(echo "$F2_TARGET_OUT" | awk -F= '/^TARGET_BEFORE=/ {print $2}')"
  F2_TARGET_AFTER="$(echo "$F2_TARGET_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"

  if [[ "$F2_TARGET_BEFORE" == "11" && "$F2_TARGET_AFTER" == "11" ]]; then
    echo "Falsifier 2 passed: target observable remained 11; gate correctly goes red on target observable."
  else
    echo "FALSIFIER ERROR: Expected target after value to remain 11 under neutered store, got '$F2_TARGET_AFTER'" >&2
    exit 1
  fi
else
  echo "[4/4] Falsifiers skipped (pass --include-falsifier to enable)."
fi

echo "=== ALL CHECKS PASSED ==="
exit 0
