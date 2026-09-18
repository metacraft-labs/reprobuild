#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNAME_S="$(uname -s 2>/dev/null || echo "Unknown")"

case "$UNAME_S" in
  Darwin*)
    LIB_PATH="$SCRIPT_DIR/build/librepro_hcr_agent.dylib"
    ;;
  Linux*)
    LIB_PATH="$SCRIPT_DIR/build/librepro_hcr_agent.so"
    ;;
  CYGWIN*|MINGW*|MSYS*|Windows*)
    LIB_PATH="$SCRIPT_DIR/build/repro_hcr_agent.dll"
    ;;
  *)
    LIB_PATH="$SCRIPT_DIR/build/librepro_hcr_agent.so"
    ;;
esac

if [[ ! -s "$LIB_PATH" ]]; then
  echo "Error: artifact missing or empty at $LIB_PATH" >&2
  exit 1
fi

EXPECTED_SYMBOLS=(
  # 15 repro_hcr_agent_* functions
  "repro_hcr_agent_start_from_env"
  "repro_hcr_agent_start_polling_from_env"
  "repro_hcr_agent_poll"
  "repro_hcr_agent_poll_nonblocking"
  "repro_hcr_agent_poll_session_open"
  "repro_hcr_agent_poll_messages_handled"
  "repro_hcr_agent_set_source_reload_handler"
  "repro_hcr_agent_advertises_source_reload"
  "repro_hcr_agent_sha256_hex"
  "repro_hcr_agent_default_support_profile"
  "repro_hcr_agent_host_supports_direct_patch"
  "repro_hcr_agent_host_membarrier_sync_core"
  "repro_hcr_agent_host_quiescence_signal"
  "repro_hcr_agent_last_publication_tier"
  "repro_hcr_agent_last_on_stack_threads"
  # 10 rb_hcr_* functions
  "rb_hcr_wants_reload"
  "rb_hcr_apply_reload"
  "rb_hcr_register_managed_type"
  "rb_hcr_unregister_managed_type"
  "rb_hcr_before_reload"
  "rb_hcr_after_reload"
  "rb_hcr_remove_before_reload"
  "rb_hcr_remove_after_reload"
  "rb_hcr_file_changed"
  "rb_hcr_type_changed"
  # 3 rb_hcr_padded_* functions — HCR-Overview.md § 13.5, added 2026-09-18.
  # These are the last three of § 13's thirteen; HLX-M8 bound the ten above.
  "rb_hcr_padded_alloc"
  "rb_hcr_padded_free"
  "rb_hcr_padded_capacity"
)

NM_OUTPUT="$(nm -gU "$LIB_PATH" 2>/dev/null || nm -g "$LIB_PATH")"
MISSING=0
for sym in "${EXPECTED_SYMBOLS[@]}"; do
  if ! echo "$NM_OUTPUT" | grep -q "[TDRB] _\?${sym}\b"; then
    echo "MISSING SYMBOL: $sym in $LIB_PATH" >&2
    MISSING=1
  fi
done

if [[ $MISSING -ne 0 ]]; then
  echo "FAILED: some symbols were missing in $LIB_PATH" >&2
  exit 1
fi

echo "[check_symbols] PASSED: all ${#EXPECTED_SYMBOLS[@]} symbols verified in $LIB_PATH"
