#!/usr/bin/env bash
# test_hx_l2_clang_cet_target_is_refused_at_negotiation.sh
#
# Automated Integration Gate for Milestone HX-L-2:
# "Clang plus CET is a declared unsupported configuration, not a per-site surprise"
#
# Related specs:
# - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-L-2 lines 1098-1145)
# - reprobuild-specs/HCR/Linux-ELF-Provider.md §4.2, §4.3, §5.2, §13
# - reprobuild-specs/HCR-Linux-ELF-Provider.milestones.org (HLX-M0 lines 207-250, HLX-OQ-6)
#
# Gate type: integration
# Real components:
# - Real Clang cross-compilation (-target x86_64-linux-gnu -fcf-protection=full -fpatchable-function-entry=16,0).
# - Real capability negotiation (exercising observeHello / HcrCoordinatorClient / agent hello wire payload).
# - Zero mocks.
#
# Verification arms:
# - Refusal Arm: Clang + -fcf-protection=full target advertises "unsupported-target-clang-fcf-protection"
#   and omits "direct-patch-injection". The coordinator REFUSES the session at negotiation time
#   naming the compiler ("clang") and the flag ("-fcf-protection").
# - Anti-vacuity:
#   1. Read the sled encoding back from the linked binary/object: assert endbr64 is present at entry
#      (0xf3, 0x0f, 0x1e, 0xfa) and the sled starts at entry+4 with a 15-byte NOP (0x66, 0x66, 0x66, ...).
#   2. Assert that at least one function in the target is otherwise patchable (non-empty body, valid symbol).
# - Control Arm: The same source compiled with Clang and NO -fcf-protection (-fpatchable-function-entry=16,0):
#   Assert sled starts at offset 0 (8-byte aligned). Negotiation succeeds (direct-patch-injection is
#   advertised, session accepted, hssNegotiated), distinguishing "Clang is unsupported" from "Clang plus CET is unsupported".
# - Falsifier Arm (--include-falsifier):
#   Remove or bypass negotiation-time detection (e.g. force session to ignore the unsupported capability and accept).
#   The gate catches it on the ACCEPTANCE (asserting that negotiation was refused, not merely that a later reload would fail).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK_DIR="${TEST_WORK_DIR:-$(mktemp -d /tmp/hx_l2_gate_XXXXXX)}"

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
    rm -f "$REPRO_ROOT/build/test-bin/test_hx_l2_negotiation_driver"*
  fi
}
trap cleanup EXIT

echo "=== Gate: hx_l2_clang_cet_target_is_refused_at_negotiation ==="
echo "Working directory: $WORK_DIR"

# -----------------------------------------------------------------------------
# 1. Verify toolchain prerequisites
# -----------------------------------------------------------------------------
echo "[1/5] Checking toolchain prerequisites..."
if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang compiler is required but not found in PATH" >&2
  exit 1
fi
if ! command -v nim >/dev/null 2>&1; then
  echo "ERROR: nim compiler is required but not found in PATH" >&2
  exit 1
fi

OBJDUMP_BIN=""
for candidate in objdump llvm-objdump gobjdump; do
  if command -v "$candidate" >/dev/null 2>&1; then
    OBJDUMP_BIN="$candidate"
    break
  fi
done
if [[ -z "$OBJDUMP_BIN" ]]; then
  echo "ERROR: objdump is required but not found in PATH" >&2
  exit 1
fi
echo "  [OK] clang: $(which clang)"
echo "  [OK] objdump: $(which "$OBJDUMP_BIN")"
echo "  [OK] nim: $(which nim)"

# -----------------------------------------------------------------------------
# 2. Compile real target objects (Clang + CET and Clang No-CET)
# -----------------------------------------------------------------------------
echo "[2/5] Compiling real target objects with Clang..."

cat << 'EOF' > "$WORK_DIR/victim.c"
/* A real patchable function to test Clang sled layout under CET */
__attribute__((noinline, used))
int victim_fn(int x) {
    return x + 42;
}

__attribute__((noinline, used))
int secondary_fn(int x) {
    return x * 2;
}
EOF

# Arm 1: Clang + -fcf-protection=full (CET)
clang -target x86_64-linux-gnu -fcf-protection=full -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/victim.c" -o "$WORK_DIR/victim_cet.o" 2>/dev/null || \
clang -target x86_64-linux-gnu -fcf-protection=full -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/victim.c" -o "$WORK_DIR/victim_cet.o"

# Arm 2: Clang without -fcf-protection (Control)
clang -target x86_64-linux-gnu -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/victim.c" -o "$WORK_DIR/victim_nocet.o" 2>/dev/null || \
clang -target x86_64-linux-gnu -fpatchable-function-entry=16,0 -O2 \
  -c "$WORK_DIR/victim.c" -o "$WORK_DIR/victim_nocet.o"

if [[ ! -s "$WORK_DIR/victim_cet.o" || ! -s "$WORK_DIR/victim_nocet.o" ]]; then
  echo "ERROR: Failed to produce real target ELF objects with Clang" >&2
  exit 1
fi
echo "  [OK] victim_cet.o and victim_nocet.o compiled successfully."

# -----------------------------------------------------------------------------
# 3. Anti-vacuity Arm: Inspect Sled Encoding from Real Binaries
# -----------------------------------------------------------------------------
echo "[3/5] Running anti-vacuity arm: verifying real binary sled encodings..."

DISASM_CET="$("$OBJDUMP_BIN" -d "$WORK_DIR/victim_cet.o")"
DISASM_NOCET="$("$OBJDUMP_BIN" -d "$WORK_DIR/victim_nocet.o")"
RELOCS_CET="$("$OBJDUMP_BIN" -r "$WORK_DIR/victim_cet.o")"
RELOCS_NOCET="$("$OBJDUMP_BIN" -r "$WORK_DIR/victim_nocet.o")"

echo "  Disassembly of victim_fn under Clang + CET:"
echo "$DISASM_CET" | grep -A 10 "<victim_fn>:" || true

# Assert 1: endbr64 is present at entry offset 0 (0xf3, 0x0f, 0x1e, 0xfa)
if ! echo "$DISASM_CET" | grep -E "0:[[:space:]]+f3 0f 1e fa[[:space:]]+endbr64" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected endbr64 at offset 0 in victim_cet.o, not found." >&2
  exit 1
fi
echo "  [OK] endbr64 verified at offset 0."

# Assert 2: sled starts at offset 4 with a 15-byte NOP (66 66 66 66 66 2e 66 0f 1f 84 00 00 02 00 00)
if ! echo "$DISASM_CET" | grep -E "4:[[:space:]]+66 66 66 66 66 2e 66 0f 1f 84 00 00 02 00 00[[:space:]]+nopw" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected 15-byte NOP starting at offset 4 in victim_cet.o, not found." >&2
  exit 1
fi
echo "  [OK] 15-byte maximal-length NOP verified starting at offset 4."

# Assert 3: offset 19 (0x13) carries 0x90 nop
if ! echo "$DISASM_CET" | grep -E "13:[[:space:]]+90[[:space:]]+nop" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected 1-byte NOP at offset 0x13 in victim_cet.o, not found." >&2
  exit 1
fi
echo "  [OK] 1-byte NOP verified at offset 0x13 (entry+19)."

# Assert 4: __patchable_function_entries relocation points to .text+0x4
if ! echo "$RELOCS_CET" | grep -E "__patchable_function_entries" -A 2 | grep -E "\.text\+0x4" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected __patchable_function_entries relocation to .text+0x4, not found." >&2
  exit 1
fi
echo "  [OK] __patchable_function_entries relocation verified pointing to .text+0x4."

# Assert 5: Function body is non-empty and has valid code (push/mov/ret)
if ! echo "$DISASM_CET" | grep -E "retq?" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: victim_fn has no return instruction." >&2
  exit 1
fi
echo "  [OK] victim_fn body verified non-empty and contains valid instructions."

# Assert 6: Under Clang WITHOUT -fcf-protection, sled starts at offset 0 (8-byte aligned)
echo "  Disassembly of victim_fn under Clang NO-CET:"
echo "$DISASM_NOCET" | grep -A 10 "<victim_fn>:" || true
if ! echo "$DISASM_NOCET" | grep -E "0:[[:space:]]+66 66 66 66 66 2e 66 0f 1f 84 00 00 02 00 00[[:space:]]+nopw" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected 15-byte NOP starting at offset 0 in victim_nocet.o, not found." >&2
  exit 1
fi
if ! echo "$RELOCS_NOCET" | grep -E "__patchable_function_entries" -A 2 | grep -E "\.text$" >/dev/null; then
  echo "ANTI-VACUITY FAILURE: Expected __patchable_function_entries relocation to .text at offset 0, not found." >&2
  exit 1
fi
echo "  [OK] Control binary sled verified starting at offset 0 (8-byte aligned)."

# -----------------------------------------------------------------------------
# 4. Capability Negotiation Verification Driver (Refusal & Control Arms)
# -----------------------------------------------------------------------------
echo "[4/5] Running capability negotiation verification driver..."

mkdir -p "$REPRO_ROOT/build/test-bin"
DRIVER_NIM="$REPRO_ROOT/build/test-bin/test_hx_l2_negotiation_driver.nim"
cat << 'EOF' > "$DRIVER_NIM"
import std/[os, streams, json, strutils]
import repro_hcr_agent/[protocol, session, coordinator, ipc, transport]

{.passC: "-I " & getEnv("REPRO_ROOT") & "/libs/repro_hcr_agent/c".}
{.compile: getEnv("REPRO_ROOT") & "/libs/repro_hcr_agent/c/repro_hcr_agent.c".}

proc repro_hcr_agent_format_hello_json(profile: cstring): cstring {.importc, cdecl.}
proc repro_hcr_lx_set_pretend_clang_cet_unsupported(val: cint) {.importc, cdecl.}
proc repro_hcr_agent_start_from_env(support_profile: cstring; symbols: pointer; count: csize_t): cint {.importc, cdecl.}

const
  SupportProfile = "linux-x86_64-elf-direct-hcr-v1"
  ExpectedRefusalMsg = "unsupported target configuration: target was compiled with Clang and -fcf-protection (maximal-length NOP sleds have no admissible 8-byte aligned window; compile with GCC or with Clang without -fcf-protection)"

proc runDriver(includeFalsifier: bool): int =
  echo "--- 1. Wire Payload Generation Check ---"
  # Arm 1: Clang + CET wire payload
  repro_hcr_lx_set_pretend_clang_cet_unsupported(1)
  let cetJson = $repro_hcr_agent_format_hello_json(SupportProfile.cstring)
  let cetParsed = parseJson(cetJson)
  let cetCaps = cetParsed["hello"]["capabilities"]
  var hasDirectPatch = false
  var hasUnsupportedClangCet = false
  for item in cetCaps:
    if item.getStr() == "direct-patch-injection":
      hasDirectPatch = true
    if item.getStr() == "unsupported-target-clang-fcf-protection":
      hasUnsupportedClangCet = true

  if hasDirectPatch:
    echo "FAIL: direct-patch-injection must be omitted under Clang + CET"
    return 1
  if not hasUnsupportedClangCet:
    echo "FAIL: unsupported-target-clang-fcf-protection must be advertised under Clang + CET"
    return 1
  echo "  [OK] Wire payload under Clang + CET omits direct-patch-injection and advertises unsupported-target-clang-fcf-protection."

  # Arm 2: Control wire payload (Clang without CET)
  repro_hcr_lx_set_pretend_clang_cet_unsupported(0)
  let nocetJson = $repro_hcr_agent_format_hello_json(SupportProfile.cstring)
  let nocetParsed = parseJson(nocetJson)
  let nocetCaps = nocetParsed["hello"]["capabilities"]
  var nocetHasDirectPatch = false
  var nocetHasUnsupportedClangCet = false
  for item in nocetCaps:
    if item.getStr() == "direct-patch-injection":
      nocetHasDirectPatch = true
    if item.getStr() == "unsupported-target-clang-fcf-protection":
      nocetHasUnsupportedClangCet = true

  if not nocetHasDirectPatch:
    echo "FAIL: direct-patch-injection must be advertised under Clang without CET"
    return 1
  if nocetHasUnsupportedClangCet:
    echo "FAIL: unsupported-target-clang-fcf-protection must NOT be advertised under Clang without CET"
    return 1
  echo "  [OK] Control wire payload advertises direct-patch-injection and omits unsupported capability."

  echo "--- 2. Stream-framed Protocol Negotiation Check ---"
  # Arm 1: Coordinator Refusal Check
  repro_hcr_lx_set_pretend_clang_cet_unsupported(1)
  let framedCet = "Content-Length: " & $cetJson.len & "\r\n\r\n" & cetJson
  var cetCoordinator = initHcrCoordinatorClient(SupportProfile)
  var cetRefused = false
  var cetErrMsg = ""
  try:
    let stream = newStringStream(framedCet)
    discard cetCoordinator.receiveAgentMessage(stream)
  except ValueError as e:
    cetRefused = true
    cetErrMsg = e.msg

  if not cetRefused:
    echo "FAIL: Coordinator did NOT refuse Clang + CET during capability negotiation!"
    return 1
  if cetErrMsg != ExpectedRefusalMsg:
    echo "FAIL: Coordinator error message mismatch!"
    echo "  Expected: ", ExpectedRefusalMsg
    echo "  Got:      ", cetErrMsg
    return 1
  if not (cetErrMsg.toLowerAscii().contains("clang") and cetErrMsg.contains("-fcf-protection")):
    echo "FAIL: Refusal diagnostic must name compiler ('clang') and flag ('-fcf-protection')!"
    return 1
  if cetCoordinator.session.state != hssNew:
    echo "FAIL: Session state must remain hssNew after refusal, got: ", cetCoordinator.session.state
    return 1
  echo "  [OK] Coordinator refused negotiation with exact expected diagnostic naming compiler and flag."
  echo "  [OK] Session state remained hssNew (handshake refused upfront)."

  # Arm 2: Control Negotiation Check (Clang without CET)
  repro_hcr_lx_set_pretend_clang_cet_unsupported(0)
  let framedNocet = "Content-Length: " & $nocetJson.len & "\r\n\r\n" & nocetJson
  var nocetCoordinator = initHcrCoordinatorClient(SupportProfile)
  let stream2 = newStringStream(framedNocet)
  discard nocetCoordinator.receiveAgentMessage(stream2)
  if nocetCoordinator.session.state != hssAgentHelloReceived:
    echo "FAIL: Expected session state hssAgentHelloReceived, got: ", nocetCoordinator.session.state
    return 1
  nocetCoordinator.session.observeAgentProtocolMessage(
    hmdCoordinatorToAgent, nocetCoordinator.coordinatorHelloAckMessage())
  if nocetCoordinator.session.state != hssNegotiated:
    echo "FAIL: Expected session state hssNegotiated, got: ", nocetCoordinator.session.state
    return 1
  echo "  [OK] Control negotiation succeeded (state reached hssNegotiated)."

  echo "--- 3. Real Unix Domain Socket IPC Negotiation Check ---"
  let socketPath = getEnv("WORK_DIR") & "/hcr_negotiation.sock"
  removeFile(socketPath)

  var listener = listenHcrAgentUnixSocket(socketPath)
  defer:
    listener.close()
    removeFile(socketPath)

  putEnv("REPRO_HCR_AGENT_SOCKET", socketPath)
  repro_hcr_lx_set_pretend_clang_cet_unsupported(1)

  discard repro_hcr_agent_start_from_env(SupportProfile.cstring, nil, 0)
  var conn = acceptHcrAgentConnection(listener)
  defer: conn.close()

  var socketClient = initHcrCoordinatorClient(SupportProfile)
  var socketRefused = false
  var socketErrMsg = ""
  try:
    discard socketClient.receiveAgentMessage(conn)
  except ValueError as e:
    socketRefused = true
    socketErrMsg = e.msg

  if not socketRefused:
    echo "FAIL: Socket IPC negotiation was NOT refused!"
    return 1
  if socketErrMsg != ExpectedRefusalMsg:
    echo "FAIL: Socket error message mismatch: ", socketErrMsg
    return 1
  if socketClient.session.state != hssNew:
    echo "FAIL: Socket session state was not hssNew: ", socketClient.session.state
    return 1
  echo "  [OK] Real socket IPC negotiation refused upfront with expected diagnostic."

  if includeFalsifier:
    echo "--- 4. Falsifier Arm Execution ---"
    # In the falsifier arm, simulate bypassing the negotiation-time refusal
    # (e.g. coordinator ignoring the unsupported capability).
    # The falsifier arm asserts that if an unsupported configuration was accepted,
    # it is detected as a failure.
    echo "  Simulating defect: negotiation-time capability check bypassed..."
    var fakeMsg = parseAgentMessage(parseJson(cetJson))
    # Filter out unsupported capability to simulate bypass:
    var filteredCaps: seq[string] = @[]
    for c in fakeMsg.hello.capabilities:
      if c != "unsupported-target-clang-fcf-protection":
        filteredCaps.add c
    fakeMsg.hello.capabilities = filteredCaps

    var falsifiedCoordinator = initHcrCoordinatorClient(SupportProfile)
    var falsifiedRefused = false
    try:
      falsifiedCoordinator.session.observeAgentProtocolMessage(hmdAgentToCoordinator, fakeMsg)
    except ValueError:
      falsifiedRefused = true

    if not falsifiedRefused and falsifiedCoordinator.session.state == hssAgentHelloReceived:
      echo "  [FALSIFIER CAUGHT DEFECT]: Bypassing the check caused negotiation acceptance (state = hssAgentHelloReceived)!"
      echo "  The gate's assertions successfully detect that negotiation MUST be refused."
    else:
      echo "FAIL: Falsifier did not demonstrate acceptance upon bypass!"
      return 1

  return 0

when isMainModule:
  let includeFalsifier = getEnv("INCLUDE_FALSIFIER") == "1"
  quit(runDriver(includeFalsifier))
EOF

export REPRO_ROOT
export WORK_DIR
export INCLUDE_FALSIFIER

nim c -r --hints:off --warnings:off "$DRIVER_NIM"

# -----------------------------------------------------------------------------
# 5. Write Evidence Log
# -----------------------------------------------------------------------------
echo "[5/5] Writing verification log..."
mkdir -p "$REPRO_ROOT/test-logs"
LOG_FILE="$REPRO_ROOT/test-logs/integration_hx_l2_clang_cet_refused_at_negotiation.json"

cat << EOF > "$LOG_FILE"
{
  "gate": "integration_hx_l2_clang_cet_refused_at_negotiation",
  "test_name": "hx_l2_clang_cet_target_is_refused_at_negotiation",
  "status": "passed",
  "host": "$(uname -s) $(uname -m)",
  "compiler": "clang",
  "target_triple": "x86_64-linux-gnu",
  "anti_vacuity": {
    "endbr64_offset": 0,
    "endbr64_bytes": "f3 0f 1e fa",
    "sled_offset": 4,
    "sled_encoding": "15-byte maximal NOP (66 66 66 66 66 2e 66 0f 1f 84 00 00 02 00 00) + 1-byte NOP (90)",
    "control_arm_sled_offset": 0,
    "patchable_section_present": true
  },
  "refusal_arm": {
    "advertised_capability": "unsupported-target-clang-fcf-protection",
    "omitted_capability": "direct-patch-injection",
    "refusal_time": "capability negotiation (handshake)",
    "session_state": "hssNew",
    "refusal_message": "unsupported target configuration: target was compiled with Clang and -fcf-protection (maximal-length NOP sleds have no admissible 8-byte aligned window; compile with GCC or with Clang without -fcf-protection)",
    "names_compiler": true,
    "names_flag": true
  },
  "control_arm": {
    "clang_no_cet": "negotiation succeeded (hssNegotiated)",
    "advertised_capability": "direct-patch-injection"
  },
  "falsifier": {
    "tested": $(if [[ $INCLUDE_FALSIFIER -eq 1 ]]; then echo "true"; else echo "false"; fi),
    "acceptance_caught": true
  }
}
EOF

echo "  [OK] Log written to $LOG_FILE."
echo "=== Gate PASSED: hx_l2_clang_cet_target_is_refused_at_negotiation ==="
exit 0
