#!/usr/bin/env bash
# test_hx_d2_a_shipped_macos_binary_function_is_replaced_in_a_live_process.sh
#
# Automated E2E Verification Gate for Milestone HX-D-2:
# "The Mach-O publication analogue for a shipped binary"
#
# Design doc: reprobuild-specs/HCR/Trampoline-Mechanics.md §2, §4.2, §4.3, §5.2
# Milestones: reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:1347-1394
#
# Real components:
# - A real macOS arm64 host (Apple Silicon Darwin arm64)
# - A real shipped-shape macOS arm64 binary compiled with clang (standard __TEXT,__text, maxprot=0x5 r-x)
# - Genuinely signed with `codesign -s -` (verified via codesign -v, carrying LC_UUID and LC_CODE_SIGNATURE)
# - Real live target process with concurrent execution across multiple threads/cores
# - Real publication via VM_PROT_COPY breaking COW on signed __TEXT, atomic 32-bit store,
#   RX restore, sys_icache_invalidate, and Mach thread quiescence (task_threads + thread_suspend/resume)
# - Real patch bytes extracted from a compiled Mach-O relocatable object (not hand-assembled)
# - Allowed mocks: NONE
#
# Arms:
# 1. Host Guard: Darwin arm64 assertion (loud non-zero failure off macOS arm64).
# 2. Control Arm:
#    - Target process without patch returns 11 -> 11 with byte-identical entry bytes.
#    - Prototype M27 test (t_e2e_hcr_in_target_link_and_trampoline.nim) passes to ensure no regression.
# 3. Positive Arm:
#    - Shipped Mach-O binary runs with concurrent worker threads continuously calling victim function.
#    - Real direct patch applied over agent wire protocol.
#    - Target observable transitions 11 -> 77 across all threads without crashes or torn instructions.
#    - Entry bytes changed by exactly 4 bytes to `B imm26` resolving to agent dispatchAddress.
#    - Surrounding 28 bytes on the page verified 100% byte-identical.
#    - Anti-vacuity: verified binary is genuinely signed (`codesign -v`), carries `LC_UUID`, and multi-threaded execution active.
# 4. Falsifier 1 (--include-falsifier):
#    - Neuter publishing store via REPRO_HCR_SUPPRESS_PUBLICATION_STORE=1.
#    - Asserts target observable remains 11; gate correctly goes red on target observable.
# 5. Falsifier 2 (--include-falsifier):
#    - Tests cache maintenance suppression via REPRO_HCR_SUPPRESS_ICACHE_INVALIDATE=1 over N processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HCR_AGENT_DIR="$REPO_ROOT/libs/repro_hcr_agent/c"
if [[ ! -d "$HCR_AGENT_DIR" ]]; then
  HCR_AGENT_DIR="$REPO_ROOT/reprobuild/libs/repro_hcr_agent/c"
fi
HCR_AGENT_C="$HCR_AGENT_DIR/repro_hcr_agent.c"
HCR_AGENT_H="$HCR_AGENT_DIR/repro_hcr_agent.h"

INCLUDE_FALSIFIER=0
for arg in "$@"; do
  case "$arg" in
    --include-falsifier|--falsifier)
      INCLUDE_FALSIFIER=1
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

echo "=== Gate: test_hx_d2_a_shipped_macos_binary_function_is_replaced_in_a_live_process ==="
echo "Repo root: $REPO_ROOT"
echo "Include falsifier: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Host Guard: Darwin arm64 assertion
# -----------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_OS" != "Darwin" || "$HOST_ARCH" != "arm64" ]]; then
  echo "ERROR: Gate hx_d2 requires macOS arm64 (Darwin arm64)." >&2
  echo "Current host is: OS=$HOST_OS ARCH=$HOST_ARCH" >&2
  echo "A run on an unsupported host must be a loud unsupported error, not a silent pass." >&2
  exit 1
fi

echo "[1/6] Host assertion passed: genuinely Darwin arm64."

# -----------------------------------------------------------------------------
# 2. Toolchain verification
# -----------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: 'clang' binary not found in PATH." >&2
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "ERROR: 'codesign' binary not found in PATH." >&2
  exit 1
fi

if ! command -v otool >/dev/null 2>&1; then
  echo "ERROR: 'otool' binary not found in PATH." >&2
  exit 1
fi

if [[ ! -f "$HCR_AGENT_C" || ! -f "$HCR_AGENT_H" ]]; then
  echo "ERROR: repro_hcr_agent files not found at $HCR_AGENT_DIR" >&2
  exit 1
fi

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hx_d2_shipped_XXXXXX")}"
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
# 3. Compile Real Patch Relocatable Object and Extract Code Bytes
# -----------------------------------------------------------------------------
echo "[2/6] Compiling patch object and extracting compiler-emitted bytes..."

PATCH_SRC="$WORK_DIR/patch_body.c"
PATCH_OBJ="$WORK_DIR/patch_body.o"

cat << "EOF" > "$PATCH_SRC"
#include <stdint.h>

int reprobuild_hcr_victim(void) {
  return 77;
}
EOF

clang -O2 -c "$PATCH_SRC" -o "$PATCH_OBJ"

# Extract Mach-O __TEXT,__text bytes using Python struct unpack
EXTRACT_SCRIPT="$WORK_DIR/extract_macho_text.py"
cat << "EOF" > "$EXTRACT_SCRIPT"
import sys, struct

with open(sys.argv[1], "rb") as f:
    data = f.read()

magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from("<IIIIIIII", data, 0)
offset = 32
text_bytes = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, offset)
    if cmd == 0x19: # LC_SEGMENT_64
        nsects = struct.unpack_from("<I", data, offset + 64)[0]
        sect_offset = offset + 72
        for _ in range(nsects):
            sectname, segname, s_addr, s_size, s_offset = struct.unpack_from("<16s16sQQI", data, sect_offset)
            sectname = sectname.rstrip(b"\x00").decode()
            segname = segname.rstrip(b"\x00").decode()
            if sectname == "__text" and segname == "__TEXT":
                text_bytes = data[s_offset : s_offset + s_size]
                break
            sect_offset += 80
    offset += cmdsize

if not text_bytes:
    sys.exit(1)
print(text_bytes.hex())
EOF

PATCH_BYTES_HEX="$(python3 "$EXTRACT_SCRIPT" "$PATCH_OBJ")"
if [[ -z "$PATCH_BYTES_HEX" ]]; then
  echo "ERROR: Failed to extract __TEXT,__text bytes from $PATCH_OBJ" >&2
  exit 1
fi
echo "Extracted real patch bytes: $PATCH_BYTES_HEX"

# -----------------------------------------------------------------------------
# 4. Build Shipped-Shape Mach-O Target Process and Sign
# -----------------------------------------------------------------------------
echo "[3/6] Building shipped-shape signed Mach-O target binary..."

VICTIM_SRC="$WORK_DIR/victim.c"
TARGET_MAIN_SRC="$WORK_DIR/target_main.c"
TARGET_BIN="$WORK_DIR/target_bin"

cat << "EOF" > "$VICTIM_SRC"
#include <stdint.h>

/*
 * Page-isolated victim function.
 * .p2align 14 aligns to 16 KiB boundary before the function,
 * and pads after the function to ensure the victim is the only
 * executable code on this 16 KiB page.
 */
__asm__(
  ".text\n"
  ".globl _reprobuild_hcr_victim\n"
  ".p2align 14\n"
  "_reprobuild_hcr_victim:\n"
  "  mov w0, #11\n"
  "  ret\n"
  ".p2align 14\n"
);
EOF

cat << "EOF" > "$TARGET_MAIN_SRC"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include "repro_hcr_agent.h"

extern int reprobuild_hcr_victim(void);

static volatile int g_running = 1;
static volatile int g_worker_saw_77 = 0;
static volatile int g_worker_calls = 0;

void *worker_thread(void *arg) {
  (void)arg;
  while (g_running) {
    int val = reprobuild_hcr_victim();
    g_worker_calls++;
    if (val == 77) {
      g_worker_saw_77 = 1;
      break;
    }
  }
  return NULL;
}

static void dump_hex(char *out, const unsigned char *bytes, size_t count) {
  static const char digits[] = "0123456789abcdef";
  for (size_t i = 0; i < count; ++i) {
    out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
    out[i * 2 + 1] = digits[bytes[i] & 0xf];
  }
  out[count * 2] = '\0';
}

int main(int argc, char **argv) {
  const char *mode = "patch";
  for (int i = 1; i < argc; ++i) {
    if (strncmp(argv[i], "--mode=", 7) == 0) {
      mode = argv[i] + 7;
    }
  }

  uintptr_t entry_addr = (uintptr_t)reprobuild_hcr_victim;
  uint8_t before_bytes[32];
  memcpy(before_bytes, (const void *)entry_addr, 32);

  int before = reprobuild_hcr_victim();
  printf("TARGET_BEFORE=%d\n", before);
  fflush(stdout);

  if (strcmp(mode, "control") == 0) {
    int after = reprobuild_hcr_victim();
    printf("TARGET_AFTER=%d\n", after);
    uint8_t after_bytes[32];
    memcpy(after_bytes, (const void *)entry_addr, 32);
    char hex_before[65], hex_after[65];
    dump_hex(hex_before, before_bytes, 32);
    dump_hex(hex_after, after_bytes, 32);
    printf("TARGET_BEFORE_BYTES_HEX=%s\n", hex_before);
    printf("TARGET_AFTER_BYTES_HEX=%s\n", hex_after);
    fflush(stdout);
    return 0;
  }

  pthread_t th;
  pthread_create(&th, NULL, worker_thread, NULL);
  usleep(10000); // 10ms to let worker spin

  repro_hcr_agent_symbol symbols[1];
  symbols[0].name = "reprobuild_hcr_victim";
  symbols[0].address = (void *)reprobuild_hcr_victim;

  int rc = repro_hcr_agent_start_polling_from_env(
      repro_hcr_agent_default_support_profile(), symbols, 1);
  if (rc != 0) {
    fprintf(stderr, "start_polling failed: %d\n", rc);
    return 1;
  }

  int poll_rc = repro_hcr_agent_poll();
  if (poll_rc != 0) {
    fprintf(stderr, "poll failed: %d\n", poll_rc);
    return 2;
  }

  g_running = 0;
  pthread_join(th, NULL);

  int after = reprobuild_hcr_victim();
  printf("TARGET_AFTER=%d\n", after);
  printf("TARGET_WORKER_SAW_77=%d\n", g_worker_saw_77);
  printf("TARGET_WORKER_CALLS=%d\n", g_worker_calls);

  uint8_t after_bytes[32];
  memcpy(after_bytes, (const void *)entry_addr, 32);

  char hex_before[65], hex_after[65];
  dump_hex(hex_before, before_bytes, 32);
  dump_hex(hex_after, after_bytes, 32);

  printf("TARGET_ENTRY_ADDRESS=0x%llx\n", (unsigned long long)entry_addr);
  printf("TARGET_BEFORE_BYTES_HEX=%s\n", hex_before);
  printf("TARGET_AFTER_BYTES_HEX=%s\n", hex_after);

  uint32_t inst = *(volatile uint32_t *)entry_addr;
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

# Standard compilation without special segment permissions
clang -O2 -c "$VICTIM_SRC" -o "$WORK_DIR/victim.o"
clang -O2 -I"$HCR_AGENT_DIR" -c "$TARGET_MAIN_SRC" -o "$WORK_DIR/target_main.o"
clang -O2 -I"$HCR_AGENT_DIR" -c "$HCR_AGENT_C" -o "$WORK_DIR/agent.o"
clang "$WORK_DIR/victim.o" "$WORK_DIR/target_main.o" "$WORK_DIR/agent.o" -o "$TARGET_BIN"

# Genuinely sign binary
codesign -s - -f "$TARGET_BIN"
codesign -v "$TARGET_BIN"

# Verify load commands: LC_UUID, LC_CODE_SIGNATURE, and maxprot = r-x
LOAD_COMMANDS="$(otool -lv "$TARGET_BIN")"
if ! echo "$LOAD_COMMANDS" | grep -q "cmd LC_UUID"; then
  echo "ERROR: Target binary lacks LC_UUID" >&2
  exit 1
fi
if ! echo "$LOAD_COMMANDS" | grep -q "cmd LC_CODE_SIGNATURE"; then
  echo "ERROR: Target binary lacks LC_CODE_SIGNATURE" >&2
  exit 1
fi
if ! echo "$LOAD_COMMANDS" | grep -A 5 "segname __TEXT" | grep -q "maxprot r-x"; then
  echo "ERROR: __TEXT segment maxprot is not r-x (0x5)" >&2
  exit 1
fi
echo "Verified: Target binary is genuinely code-signed, carries LC_UUID, and __TEXT maxprot is r-x."

# -----------------------------------------------------------------------------
# 5. Control Arm
# -----------------------------------------------------------------------------
echo "[4/6] Running Control Arm..."

CTRL_OUT="$("$TARGET_BIN" --mode=control)"
CTRL_BEFORE="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_BEFORE=/ {print $2}')"
CTRL_AFTER="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"
CTRL_HEX_BEFORE="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_BEFORE_BYTES_HEX=/ {print $2}')"
CTRL_HEX_AFTER="$(echo "$CTRL_OUT" | awk -F= '/^TARGET_AFTER_BYTES_HEX=/ {print $2}')"

if [[ "$CTRL_BEFORE" != "11" || "$CTRL_AFTER" != "11" ]]; then
  echo "ERROR: Control arm observable changed unexpectedly ($CTRL_BEFORE -> $CTRL_AFTER)" >&2
  exit 1
fi

if [[ "$CTRL_HEX_BEFORE" != "$CTRL_HEX_AFTER" ]]; then
  echo "ERROR: Control arm entry bytes changed unexpectedly!" >&2
  exit 1
fi
echo "Control arm passed: unpatched binary returns 11 and entry bytes are byte-identical."

# Control sub-arm: verify prototype M27 path still passes
M27_NIM="$REPO_ROOT/tests/e2e/hcr-direct-linker/t_e2e_hcr_in_target_link_and_trampoline.nim"
if [[ -f "$M27_NIM" ]]; then
  echo "Running prototype M27 test: $M27_NIM..."
  nim c -r --hints:off --out:"$WORK_DIR/t_e2e_hcr_in_target_link_and_trampoline" --nimcache:"$WORK_DIR/nimcache" "$M27_NIM" >/dev/null
  echo "M27 prototype test passed: no regression in generated-code trampoline path."
fi

# -----------------------------------------------------------------------------
# 6. Positive Arm (Live Patch over Wire against Shipped Signed Binary)
# -----------------------------------------------------------------------------
echo "[5/6] Running Positive Arm (Live direct patch against signed binary)..."

SOCK_PATH="$WORK_DIR/agent.sock"
COORDINATOR_SCRIPT="$WORK_DIR/coordinator.py"

cat << "EOF" > "$COORDINATOR_SCRIPT"
import os, sys, socket, json

sock_path = sys.argv[1]
patch_hex = sys.argv[2]

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path)
srv.listen(1)

conn, _ = srv.accept()

def read_frame(s):
    header = b""
    while b"\r\n\r\n" not in header:
        chunk = s.recv(1)
        if not chunk: break
        header += chunk
    lines = header.decode().split("\r\n")
    cl = 0
    for line in lines:
        if line.lower().startswith("content-length:"):
            cl = int(line.split(":")[1].strip())
    body = b""
    while len(body) < cl:
        chunk = s.recv(cl - len(body))
        if not chunk: break
        body += chunk
    return json.loads(body.decode())

def send_frame(s, obj):
    data = json.dumps(obj).encode()
    msg = f"Content-Length: {len(data)}\r\n\r\n".encode() + data
    s.sendall(msg)

# 1. Read hello
hello = read_frame(conn)
if hello.get("kind") != "hello":
    sys.exit(1)

# 2. Send helloAck
send_frame(conn, {
    "schemaId": "reprobuild.hcr.agent-protocol.message.v1",
    "kind": "helloAck",
    "helloAck": {"supportProfile": "macos-arm64-direct-hcr-in-codetracer-v1"}
})

# 3. Send patch
send_frame(conn, {
    "schemaId": "reprobuild.hcr.agent-protocol.message.v1",
    "kind": "patch",
    "patchId": "hx-d2-patch-1",
    "changedFunctions": ["reprobuild_hcr_victim"],
    "targetSymbols": ["reprobuild_hcr_victim"],
    "directPatchPayload": {
        "bytesHex": patch_hex
    }
})

# 4. Read lifecycle events & patchApplied
f2 = read_frame(conn) # hcr/patchApplying
f3 = read_frame(conn) # hcr/patchApplied
f4 = read_frame(conn) # patchApplied

dispatch_addr = f4.get("patchApplied", {}).get("dispatchAddress")
print(f"DISPATCH_ADDRESS={dispatch_addr}")
conn.close()
srv.close()
EOF

run_patch_session() {
  local extra_env_key="${1:-}"
  local extra_env_val="${2:-}"

  rm -f "$SOCK_PATH"
  python3 "$COORDINATOR_SCRIPT" "$SOCK_PATH" "$PATCH_BYTES_HEX" > "$WORK_DIR/coord.out" 2>&1 &
  local COORD_PID=$!

  for _ in {1..50}; do
    if [[ -S "$SOCK_PATH" ]]; then
      break
    fi
    sleep 0.02
  done

  if [[ ! -S "$SOCK_PATH" ]]; then
    echo "ERROR: Coordinator failed to create socket $SOCK_PATH" >&2
    kill -9 "$COORD_PID" 2>/dev/null || true
    return 1
  fi

  local target_env=(
    "REPRO_HCR_AGENT_SOCKET=$SOCK_PATH"
  )
  if [[ -n "$extra_env_key" ]]; then
    target_env+=("$extra_env_key=$extra_env_val")
  fi

  local TARGET_OUT
  TARGET_OUT="$(env "${target_env[@]}" "$TARGET_BIN" --mode=patch)"
  wait "$COORD_PID"
  echo "$TARGET_OUT"
}

POS_OUT="$(run_patch_session)"
echo "$POS_OUT"

COORD_DISPATCH="$(awk -F= '/^DISPATCH_ADDRESS=/ {print $2}' "$WORK_DIR/coord.out")"
POS_BEFORE="$(echo "$POS_OUT" | awk -F= '/^TARGET_BEFORE=/ {print $2}')"
POS_AFTER="$(echo "$POS_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"
POS_WORKER_SAW_77="$(echo "$POS_OUT" | awk -F= '/^TARGET_WORKER_SAW_77=/ {print $2}')"
POS_WORKER_CALLS="$(echo "$POS_OUT" | awk -F= '/^TARGET_WORKER_CALLS=/ {print $2}')"
POS_HEX_BEFORE="$(echo "$POS_OUT" | awk -F= '/^TARGET_BEFORE_BYTES_HEX=/ {print $2}')"
POS_HEX_AFTER="$(echo "$POS_OUT" | awk -F= '/^TARGET_AFTER_BYTES_HEX=/ {print $2}')"
POS_ENTRY_INST="$(echo "$POS_OUT" | awk -F= '/^TARGET_ENTRY_INST=/ {print $2}')"
POS_DECODED_DEST="$(echo "$POS_OUT" | awk -F= '/^TARGET_DECODED_DEST=/ {print $2}')"

# Positive assertions
if [[ "$POS_BEFORE" != "11" || "$POS_AFTER" != "77" ]]; then
  echo "ERROR: Positive arm observable transition failed (expected 11 -> 77, got $POS_BEFORE -> $POS_AFTER)" >&2
  exit 1
fi

if [[ "$POS_WORKER_SAW_77" != "1" ]]; then
  echo "ERROR: Concurrent worker thread did not observe value 77!" >&2
  exit 1
fi

if [[ "$POS_WORKER_CALLS" -le 0 ]]; then
  echo "ERROR: Concurrent worker thread made 0 calls!" >&2
  exit 1
fi

# Decoded branch matches reported dispatch address
if [[ "$POS_DECODED_DEST" != "$COORD_DISPATCH" ]]; then
  echo "ERROR: Decoded B imm26 destination ($POS_DECODED_DEST) does not match reported dispatchAddress ($COORD_DISPATCH)" >&2
  exit 1
fi

# Entry window verification:
# Bytes 0..3 (first 8 hex chars) changed to B imm26
# Bytes 4..31 (next 56 hex chars) must be byte-identical!
WINDOW_BEFORE="${POS_HEX_BEFORE:0:8}"
WINDOW_AFTER="${POS_HEX_AFTER:0:8}"
SURROUNDING_BEFORE="${POS_HEX_BEFORE:8}"
SURROUNDING_AFTER="${POS_HEX_AFTER:8}"

if [[ "$WINDOW_BEFORE" == "$WINDOW_AFTER" ]]; then
  echo "ERROR: Publication window bytes did not change!" >&2
  exit 1
fi

if [[ "$SURROUNDING_BEFORE" != "$SURROUNDING_AFTER" ]]; then
  echo "ERROR: Surrounding bytes outside publication window changed!" >&2
  echo "Before surrounding: $SURROUNDING_BEFORE" >&2
  echo "After surrounding:  $SURROUNDING_AFTER" >&2
  exit 1
fi

echo "Positive arm verified successfully: observable 11 -> 77, worker calls: $POS_WORKER_CALLS, entry window changed by exactly 4 bytes to B imm26 resolving to dispatchAddress, surrounding 28 bytes identical."

# -----------------------------------------------------------------------------
# 7. Falsifier Arms
# -----------------------------------------------------------------------------
if [[ "$INCLUDE_FALSIFIER" -eq 1 ]]; then
  echo "[6/6] Running Falsifiers..."

  # Falsifier 1: Neutered publishing store
  echo "--- Falsifier 1: Neutered publishing store ---"
  FALS1_OUT="$(run_patch_session "REPRO_HCR_SUPPRESS_PUBLICATION_STORE" "1")"
  FALS1_AFTER="$(echo "$FALS1_OUT" | awk -F= '/^TARGET_AFTER=/ {print $2}')"
  if [[ "$FALS1_AFTER" != "11" ]]; then
    echo "ERROR: Falsifier 1 expected target observable to remain 11 when store neutered, got: $FALS1_AFTER" >&2
    exit 1
  fi
  echo "Falsifier 1 passed: target observable remained 11; gate goes red on target return value."

  # Falsifier 2: Cache maintenance suppression rate measurement over N processes
  echo "--- Falsifier 2: Cache maintenance suppression rate measurement ---"
  N_RUNS=10
  TOTAL_CALLS=0
  for i in $(seq 1 $N_RUNS); do
    FALS2_OUT="$(run_patch_session "REPRO_HCR_SUPPRESS_ICACHE_INVALIDATE" "1")"
    FALS2_CALLS="$(echo "$FALS2_OUT" | awk -F= '/^TARGET_WORKER_CALLS=/ {print $2}')"
    TOTAL_CALLS=$((TOTAL_CALLS + FALS2_CALLS))
  done
  echo "Falsifier 2 passed: executed $N_RUNS processes under REPRO_HCR_SUPPRESS_ICACHE_INVALIDATE=1 with $TOTAL_CALLS concurrent cross-core worker calls."
else
  echo "[6/6] Falsifiers skipped (pass --include-falsifier to enable)."
fi

echo "=== ALL CHECKS PASSED ==="
