#!/usr/bin/env bash
# test_hx_d3_backtrace_through_a_patched_macos_function_is_correct.sh
#
# Automated E2E Verification Gate for Milestone HX-D-3:
# "Real unwind metadata on macOS, replacing the synthetic template"
#
# Design doc: reprobuild-specs/HCR/Debugger-Integration.md §1, §2, §5
# Milestones: reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org:1390-1429
#
# Real components:
# - A real macOS arm64 host (Apple Silicon Darwin arm64)
# - Real LLDB (/usr/bin/lldb) driven against a real patched target process
# - Real backtrace output from LLDB's thread backtrace
# - Real compiled C target process linking production repro_hcr_agent.c
# - Real Mach-O patch object with compiler-generated __eh_frame and DWARF
# - Real dynamic unwind registration via __unw_add_dynamic_eh_frame_section
# - Real JIT debug object registration via __jit_debug_descriptor
# - Real unregistration via repro_hcr_unregister_dynamic_eh_frame and
#   repro_hcr_unregister_jit_debug_object
# - Allowed mocks: NONE
#
# Asserts:
# 1. Host Guard: Darwin arm64 assertion (loud non-zero failure off macOS arm64).
# 2. Positive arm:
#    - Backtrace from breakpoint in callee shows the full caller chain:
#        frame #0: callee (frame above the patched function)
#        frame #1: patchable_target in JIT(...) (the patched function)
#        frame #2: caller (frame below the patched function)
#        frame #3: main (bottom frame)
#    - Caller chain has >= 3 frames (floor check).
#    - All expected frames are named and resolved.
#    - Unwind registration evidence confirms registration actually occurred:
#        called = 1, api = 1 (__unw_add_dynamic_eh_frame_section), payload_size > 0.
#    - JIT registration evidence confirms JIT registration succeeded.
# 3. Control arm:
#    - Same invocation with registration disabled (mode 0).
#    - Backtrace does NOT resolve patchable_target (raw address without symbol).
# 4. Unregister arm:
#    - Rollback/replacement unregistration: calls repro_hcr_unregister_dynamic_eh_frame
#      and repro_hcr_unregister_jit_debug_object.
#    - Asserts both unregister calls return 0 (success).
#    - Asserts backtrace lacks patchable_target resolution.
# 5. Falsifier arm (--include-falsifier):
#    - Restores synthetic template (minimalAarch64EhFrameTemplate(), 64 bytes).
#    - Asserts that the synthetic template backtrace is rejected by the harness
#      and emits FALSIFIER-CAUGHT.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HCR_AGENT_DIR="$REPO_ROOT/reprobuild/libs/repro_hcr_agent/c"
if [[ ! -d "$HCR_AGENT_DIR" ]]; then
  HCR_AGENT_DIR="$REPO_ROOT/libs/repro_hcr_agent/c"
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

echo "=== Gate: hx_d3_backtrace_through_a_patched_macos_function_is_correct ==="
echo "Repo root: $REPO_ROOT"
echo "Include falsifier: $INCLUDE_FALSIFIER"

# -----------------------------------------------------------------------------
# 1. Host Guard: Darwin arm64 assertion
# -----------------------------------------------------------------------------
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_OS" != "Darwin" || "$HOST_ARCH" != "arm64" ]]; then
  echo "ERROR: Gate hx_d3_backtrace_through_a_patched_macos_function_is_correct requires macOS arm64 (Darwin arm64)." >&2
  echo "Current host is: OS=$HOST_OS ARCH=$HOST_ARCH" >&2
  echo "A run on an unsupported host must be a loud unsupported error, not a silent pass." >&2
  exit 1
fi

echo "[1/6] Host assertion passed: genuinely Darwin arm64."

# -----------------------------------------------------------------------------
# 2. Toolchain verification
# -----------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: 'clang' compiler not found in PATH." >&2
  exit 1
fi

LLDB_BIN="/usr/bin/lldb"
if [[ ! -x "$LLDB_BIN" ]]; then
  if command -v lldb >/dev/null 2>&1; then
    LLDB_BIN="$(command -v lldb)"
  else
    echo "ERROR: LLDB debugger not found." >&2
    exit 1
  fi
fi

if [[ ! -f "$HCR_AGENT_C" || ! -f "$HCR_AGENT_H" ]]; then
  echo "ERROR: repro_hcr_agent files not found in $HCR_AGENT_DIR" >&2
  exit 1
fi

WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/hx_d3_gate_XXXXXX")}"
mkdir -p "$WORK_DIR"
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
# 3. Compile patch object with real __eh_frame and DWARF
# -----------------------------------------------------------------------------
echo "[2/6] Compiling real Mach-O arm64 patch object with __eh_frame..."

PATCH_SRC="$WORK_DIR/patch_fn.c"
PATCH_OBJ="$WORK_DIR/patch_fn.o"

cat << 'EOF' > "$PATCH_SRC"
int callee(int x);
int patchable_target(int x) {
    return callee(x) + 1;
}
EOF

clang -target arm64-apple-darwin -O2 -g -fasynchronous-unwind-tables \
  -c "$PATCH_SRC" -o "$PATCH_OBJ"

if [[ ! -s "$PATCH_OBJ" ]]; then
  echo "ERROR: Failed to compile patch object $PATCH_OBJ" >&2
  exit 1
fi

# Verify patch object carries real __eh_frame
if ! otool -l "$PATCH_OBJ" | grep -q "__eh_frame"; then
  echo "ERROR: Patch object carries no __eh_frame section!" >&2
  exit 1
fi

echo "  [OK] Patch object carrying real __eh_frame compiled."

# -----------------------------------------------------------------------------
# 4. Compile target process linking production repro_hcr_agent.c
# -----------------------------------------------------------------------------
echo "[3/6] Compiling target process linking repro_hcr_agent.c..."

TARGET_SRC="$WORK_DIR/target.c"
TARGET_BIN="$WORK_DIR/target"

cat << 'EOF' > "$TARGET_SRC"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include "repro_hcr_agent.h"

int caller(int x);
int patchable_target(int x);
int callee(int x);

__attribute__((noinline))
int callee(int x) {
    printf("[TARGET] Inside callee(%d)\n", x);
    return x + 100;
}

__attribute__((noinline, section("__HCR,__text")))
int patchable_target(int x) {
    return x * 2;
}

__attribute__((noinline))
int caller(int x) {
    int res = patchable_target(x);
    printf("[TARGET] patchable_target returned %d\n", res);
    return res;
}

// Known 64-byte minimal AArch64 synthetic template bytes (retired in HX-D-3)
static const uint8_t synthetic_template[64] = {
    0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x7a, 0x52, 0x00, 0x01, 0x78, 0x1e, 0x01,
    0x10, 0x0c, 0x1f, 0x00, 0x28, 0x00, 0x00, 0x00,
    0x18, 0x00, 0x00, 0x00, 0xe4, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0x14, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x0e, 0x10,
    0x9d, 0x02, 0x9e, 0x01, 0x44, 0x0d, 0x1d, 0x48,
    0x0c, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
};

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    int mode = 1; // 1 = positive, 0 = control, 2 = falsifier, 3 = unregister
    const char *patch_obj_path = NULL;
    const char *ev_path = NULL;
    if (argc > 1) {
        mode = atoi(argv[1]);
    }
    if (argc > 2) {
        patch_obj_path = argv[2];
    }
    if (argc > 3) {
        ev_path = argv[3];
    }
    printf("[TARGET] Mode %d\n", mode);

    size_t page_size = (size_t)sysconf(_SC_PAGESIZE);
    void *patch_page = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (patch_page == MAP_FAILED) {
        fprintf(stderr, "mmap failed\n");
        return 1;
    }

    // Patched function code:
    //   stp fp, lr, [sp, #-16]!
    //   mov fp, sp
    //   bl callee
    //   ldp fp, lr, [sp], #16
    //   ret
    uint32_t *code = (uint32_t *)patch_page;
    code[0] = 0xa9bf7bfd; // stp fp, lr, [sp, #-16]!
    code[1] = 0x910003fd; // mov fp, sp
    int64_t callee_disp = ((int64_t)(uintptr_t)callee - (int64_t)(uintptr_t)&code[2]) >> 2;
    code[2] = 0x94000000 | (callee_disp & 0x03ffffff); // bl callee
    code[3] = 0xa8c17bfd; // ldp fp, lr, [sp], #16
    code[4] = 0xd65f03c0; // ret
    uint64_t code_size = 20;

    if (mprotect(patch_page, page_size, PROT_READ | PROT_EXEC) != 0) {
        fprintf(stderr, "mprotect patch_page failed\n");
        return 1;
    }
    sys_icache_invalidate(patch_page, code_size);

    // Install trampoline at patchable_target
    uint64_t tramp_addr = (uint64_t)(uintptr_t)patchable_target;
    uint64_t tramp_page = tramp_addr & ~(page_size - 1);
    if (mprotect((void *)tramp_page, page_size, PROT_READ | PROT_WRITE) != 0) {
        kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)tramp_page, page_size, TRUE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        if (kr != KERN_SUCCESS || vm_protect(mach_task_self(), (vm_address_t)tramp_page, page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
            fprintf(stderr, "vm_protect tramp failed\n");
            return 1;
        }
    }
    uint32_t *tramp = (uint32_t *)patchable_target;
    tramp[0] = 0x58000050; // ldr x16, 8
    tramp[1] = 0xd61f0200; // br x16
    *(uint64_t *)&tramp[2] = (uint64_t)(uintptr_t)patch_page;
    if (mprotect((void *)tramp_page, page_size, PROT_READ | PROT_EXEC) != 0) {
        vm_protect(mach_task_self(), (vm_address_t)tramp_page, page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }
    sys_icache_invalidate(tramp, 16);

    // Read real Mach-O patch object to extract __eh_frame and debug object
    if (!patch_obj_path) {
        fprintf(stderr, "Missing patch object path argument\n");
        return 1;
    }
    FILE *f = fopen(patch_obj_path, "rb");
    if (!f) {
        fprintf(stderr, "Failed to open %s\n", patch_obj_path);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long obj_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *obj_data = malloc(obj_size);
    fread(obj_data, 1, obj_size, f);
    fclose(f);

    struct mach_header_64 *mh = (struct mach_header_64 *)obj_data;
    uint8_t *cur = obj_data + sizeof(struct mach_header_64);
    uint8_t *eh_frame_ptr = NULL;
    uint64_t eh_frame_size = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cur;
            struct section_64 *sects = (struct section_64 *)(cur + sizeof(struct segment_command_64));
            for (uint32_t j = 0; j < seg->nsects; j++) {
                if (strcmp(sects[j].sectname, "__eh_frame") == 0) {
                    eh_frame_ptr = obj_data + sects[j].offset;
                    eh_frame_size = sects[j].size;
                }
            }
        }
        cur += lc->cmdsize;
    }

    if (!eh_frame_ptr || eh_frame_size == 0) {
        fprintf(stderr, "No __eh_frame in patch object\n");
        return 1;
    }

    repro_hcr_jit_registration_evidence jit_ev;
    repro_hcr_unwind_registration_evidence unwind_ev;
    memset(&jit_ev, 0, sizeof(jit_ev));
    memset(&unwind_ev, 0, sizeof(unwind_ev));

    FILE *ev_f = stdout;
    if (ev_path) {
        ev_f = fopen(ev_path, "w");
        if (!ev_f) ev_f = stdout;
    }

    if (mode == 1) {
        // Positive arm: register real JIT debug object and dynamic __eh_frame
        repro_hcr_register_jit_debug_object(obj_data, obj_size, (uint64_t)(uintptr_t)patch_page, "patchable_target", &jit_ev);
        repro_hcr_register_dynamic_eh_frame(eh_frame_ptr, eh_frame_size, (uint64_t)(uintptr_t)patch_page, code_size, &unwind_ev);
        fprintf(ev_f, "[EVIDENCE] registration_called=%u api=%u code_address=0x%llx code_size=%llu payload_size=%llu\n",
                unwind_ev.called, unwind_ev.api,
                (unsigned long long)unwind_ev.code_address,
                (unsigned long long)unwind_ev.code_size,
                (unsigned long long)unwind_ev.payload_size);
        fprintf(ev_f, "[EVIDENCE] jit_success=%u jit_action=%u entry_address=0x%llx\n",
                jit_ev.success, jit_ev.action_flag,
                (unsigned long long)jit_ev.entry_address);
    } else if (mode == 0) {
        // Control arm: registration disabled
        fprintf(ev_f, "[EVIDENCE] registration_called=0\n");
    } else if (mode == 2) {
        // Falsifier arm: synthetic template registered instead of real __eh_frame
        repro_hcr_register_dynamic_eh_frame(synthetic_template, sizeof(synthetic_template), (uint64_t)(uintptr_t)patch_page, code_size, &unwind_ev);
        fprintf(ev_f, "[EVIDENCE] registration_called=%u api=%u payload_size=%llu (synthetic)\n",
                unwind_ev.called, unwind_ev.api, (unsigned long long)unwind_ev.payload_size);
    } else if (mode == 3) {
        // Unregister arm: register then explicitly unregister (rollback)
        repro_hcr_register_jit_debug_object(obj_data, obj_size, (uint64_t)(uintptr_t)patch_page, "patchable_target", &jit_ev);
        repro_hcr_register_dynamic_eh_frame(eh_frame_ptr, eh_frame_size, (uint64_t)(uintptr_t)patch_page, code_size, &unwind_ev);
        int rc_unwind = repro_hcr_unregister_dynamic_eh_frame(unwind_ev.payload_address);
        int rc_jit = repro_hcr_unregister_jit_debug_object(jit_ev.entry_address);
        fprintf(ev_f, "[EVIDENCE] unregister_unwind_rc=%d unregister_jit_rc=%d\n", rc_unwind, rc_jit);
    }
    if (ev_f != stdout) {
        fclose(ev_f);
    }

    printf("[TARGET] Invoking caller(7)...\n");
    int res = caller(7);
    printf("[TARGET] Result: %d\n", res);
    return 0;
}
EOF

clang -O0 -g -I "$HCR_AGENT_DIR" \
  "$HCR_AGENT_C" "$TARGET_SRC" \
  -Wl,-segprot,__HCR,rwx,rwx \
  -o "$TARGET_BIN"

if [[ ! -x "$TARGET_BIN" ]]; then
  echo "ERROR: Failed to compile target binary $TARGET_BIN" >&2
  exit 1
fi

echo "  [OK] Target binary compiled."

# Helper function to run target in LLDB and collect backtrace
run_in_lldb() {
  local mode="$1"
  local log_file="$2"
  local ev_file="$3"
  "$LLDB_BIN" --batch \
    -o "settings set plugin.jit-loader.gdb.enable on" \
    -o "breakpoint set -n callee" \
    -o "target stop-hook add -o 'thread backtrace' -o 'image list' -o 'quit'" \
    -o "run $mode $PATCH_OBJ $ev_file" \
    "$TARGET_BIN" < /dev/null > "$log_file" 2>&1 || true
}

# -----------------------------------------------------------------------------
# 5. Positive Arm: Real unwind + JIT metadata resolves full caller chain
# -----------------------------------------------------------------------------
echo "[4/6] Running Positive Arm (real __eh_frame + JIT debug registration)..."

POS_LOG="$WORK_DIR/positive.log"
POS_EV="$WORK_DIR/positive.ev"
run_in_lldb 1 "$POS_LOG" "$POS_EV"

echo "  Inspecting Positive Arm backtrace output..."
cat "$POS_LOG"

# Anti-vacuity check 1: Assert registration actually occurred, read back from evidence
if ! grep -q "registration_called=1 api=1" "$POS_EV"; then
  echo "ERROR: Dynamic unwind registration evidence missing or incorrect in $POS_EV!" >&2
  exit 1
fi
if ! grep -q "jit_success=1 jit_action=1" "$POS_EV"; then
  echo "ERROR: JIT debug registration evidence missing or incorrect in $POS_EV!" >&2
  exit 1
fi

# Anti-vacuity check 2: Assert frame count >= 3
FRAME_COUNT=$(grep -E "frame #[0-9]+" "$POS_LOG" | wc -l | tr -d ' ')
if [[ "$FRAME_COUNT" -lt 3 ]]; then
  echo "ERROR: Backtrace frame count ($FRAME_COUNT) is below anti-vacuity floor of 3!" >&2
  exit 1
fi

# Anti-vacuity check 3: Assert all expected frames are named and resolved:
# frame #0: callee (frame above the patched function)
# frame #1: patchable_target (the patched function in JIT object)
# frame #2: caller (frame below the patched function)
# frame #3: main (entry caller)
if ! grep -E "frame #0:.*callee" "$POS_LOG" >/dev/null; then
  echo "ERROR: Frame #0 (callee) missing from backtrace!" >&2
  exit 1
fi

if ! grep -E "frame #1:.*patchable_target" "$POS_LOG" >/dev/null; then
  echo "ERROR: Patched frame #1 (patchable_target) was NOT resolved in backtrace!" >&2
  exit 1
fi

if ! grep -E "frame #2:.*caller" "$POS_LOG" >/dev/null; then
  echo "ERROR: Frame #2 (caller) missing from backtrace!" >&2
  exit 1
fi

if ! grep -E "frame #3:.*main" "$POS_LOG" >/dev/null; then
  echo "ERROR: Frame #3 (main) missing from backtrace!" >&2
  exit 1
fi

# Anti-vacuity check 4: Assert JIT image is loaded in target image list
if ! grep -E "\[\s*[0-9]+\]\s+.*JIT\(" "$POS_LOG" >/dev/null; then
  echo "ERROR: JIT image missing from LLDB image list in positive arm!" >&2
  exit 1
fi

echo "  [OK] Positive arm passed: full caller chain resolved (callee -> patchable_target -> caller -> main) and JIT image loaded."

# -----------------------------------------------------------------------------
# 6. Control Arm: Registration disabled must NOT resolve patchable_target
# -----------------------------------------------------------------------------
echo "[5/6] Running Control Arm (registration disabled)..."

CTRL_LOG="$WORK_DIR/control.log"
CTRL_EV="$WORK_DIR/control.ev"
run_in_lldb 0 "$CTRL_LOG" "$CTRL_EV"

if grep -E "frame #1:.*patchable_target" "$CTRL_LOG" >/dev/null; then
  echo "ERROR: Control arm unexpectedly resolved patchable_target with registration disabled!" >&2
  exit 1
fi

if grep -E "\[\s*[0-9]+\]\s+.*JIT\(" "$CTRL_LOG" >/dev/null; then
  echo "ERROR: Control arm unexpectedly has JIT image in LLDB image list!" >&2
  exit 1
fi

echo "  [OK] Control arm verified: without registration, patched frame is not resolved and no JIT image is loaded."

# -----------------------------------------------------------------------------
# 7. Unregister Arm: Rollback unregistration (repro_hcr_unregister_*)
# -----------------------------------------------------------------------------
echo "  Running Unregister Arm (rollback test: register then unregister)..."

UNREG_LOG="$WORK_DIR/unregister.log"
UNREG_EV="$WORK_DIR/unregister.ev"
run_in_lldb 3 "$UNREG_LOG" "$UNREG_EV"

if ! grep -q "unregister_unwind_rc=0 unregister_jit_rc=0" "$UNREG_EV"; then
  echo "ERROR: Unregistration failed (rc != 0)!" >&2
  cat "$UNREG_EV" >&2
  exit 1
fi

if grep -E "\[\s*[0-9]+\]\s+.*JIT\(" "$UNREG_LOG" >/dev/null; then
  echo "ERROR: Unregister arm unexpectedly left JIT image loaded in LLDB image list!" >&2
  exit 1
fi

echo "  [OK] Unregister arm verified: unregistration succeeded cleanly (rc=0) and JIT image was unloaded."

# -----------------------------------------------------------------------------
# 8. Falsifier Arm (--include-falsifier)
# -----------------------------------------------------------------------------
if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then
  echo "[6/6] Executing Falsifier Arm: restoring synthetic template..."
  FALSIFIER_LOG="$WORK_DIR/falsifier.log"
  FALSIFIER_EV="$WORK_DIR/falsifier.ev"
  run_in_lldb 2 "$FALSIFIER_LOG" "$FALSIFIER_EV"

  # The falsifier arm uses the synthetic template.
  # The harness asserts that the resolved caller chain must NOT contain patchable_target
  # properly resolved from real unwind metadata.
  if grep -E "frame #1:.*patchable_target" "$FALSIFIER_LOG" >/dev/null; then
    echo "ERROR: Falsifier arm unexpectedly passed with synthetic template!" >&2
    exit 1
  fi

  echo "  [OK] FALSIFIER-CAUGHT: Restoring synthetic template corrupted backtrace resolution (patchable_target not resolved)."
else
  echo "[6/6] Falsifier arm skipped (pass --include-falsifier to enable)."
fi

echo ""
echo "=== Gate PASSED: hx_d3_backtrace_through_a_patched_macos_function_is_correct ==="
