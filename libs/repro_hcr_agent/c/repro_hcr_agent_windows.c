/*
 * HX-W-5 Windows lifecycle artifact and named-pipe protocol endpoint.
 *
 * This is deliberately separate from repro_hcr_agent.c: that translation unit
 * currently owns the POSIX socket and Linux/macOS patch paths. The exported
 * lifecycle ABI is shared through repro_hcr_agent.h. HWG-M1 joins the W1-W4
 * publication, quiescence, PE/PDB identity, unwind, and CFG pieces behind this
 * endpoint so the canonical injected DLL owns the complete transaction.
 *
 * Loader-lock rule: DllMain only disables thread notifications. The launcher
 * invokes ReproHcrWindowsBootstrap in a second remote thread after LoadLibraryW
 * has returned. All allocation, token inspection, pipe creation, and protocol
 * work therefore happens outside DllMain.
 */
#define REPRO_HCR_AGENT_BUILD_DLL 1

#include "repro_hcr_agent.h"
#include "repro_hcr_mcr_bridge.h"
#include "repro_hcr_sha256.h"
#include "repro_hcr_windows_pe_symbols.h"
#include "repro_hcr_windows_publish.h"
#include "repro_hcr_windows_unwind_cfg.h"

#include <windows.h>
#include <sddl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(REPRO_HCR_WINDOWS_MACOS_PROFILE_FALSIFIER)
#define REPRO_HCR_WINDOWS_AGENT_PROFILE \
  REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64
#elif !defined(REPRO_HCR_WINDOWS_AGENT_PROFILE)
#define REPRO_HCR_WINDOWS_AGENT_PROFILE \
  REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64
#endif

#define REPRO_HCR_PROTOCOL_SCHEMA "reprobuild.hcr.agent-protocol.message.v1"
#define REPRO_HCR_TRANSPORT_SCOPE "hcr-agent-protocol"
#define REPRO_HCR_WINDOWS_CAPABILITY "windows-named-pipe-transport"
#define REPRO_HCR_DIRECT_PATCH_CAPABILITY "direct-patch-injection"
#define REPRO_HCR_MAX_FRAME (1024u * 1024u)
#define REPRO_HCR_WINDOWS_BUNDLE_HEADER_BYTES 128u
#define REPRO_HCR_WINDOWS_BUNDLE_VERSION 1u
#define REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES 7u

static volatile LONG repro_hcr_started = 0;
static volatile LONG repro_hcr_session_open = 0;
static volatile LONG repro_hcr_messages_handled = 0;
static volatile LONG repro_hcr_start_status = ERROR_IO_PENDING;
static HANDLE repro_hcr_ready_event = NULL;
static repro_hcr_source_reload_handler repro_hcr_reload_handler = NULL;
static void *repro_hcr_reload_context = NULL;

struct repro_hcr_windows_patch_state {
  struct repro_hcr_windows_retained_module module;
  struct repro_hcr_windows_patch_registration registration;
  void *region;
  size_t allocation_size;
  uintptr_t target_entry;
  uintptr_t dispatch;
  LONG generation;
  struct repro_hcr_windows_patch_state *next;
};

struct repro_hcr_windows_bundle {
  struct repro_hcr_windows_pdb_identity identity;
  uint32_t target_rva;
  uint32_t first_instruction_length;
  uint8_t expected_padding[REPRO_HCR_WP_PADDING_BYTES];
  uint8_t expected_first_instruction[REPRO_HCR_WP_MAX_INSTRUCTION_BYTES];
  const uint8_t *region;
  uint32_t region_size;
  uint32_t function_table_offset;
  uint32_t function_table_count;
  uint32_t replacement_entry_offset;
  uint32_t *entry_offsets;
  uint32_t entry_count;
};

typedef struct repro_hcr_windows_code_patch_outcome {
  int attempted;
  int bridge_present;
  int bridge_result;
  int hash_selftest;
  unsigned tier;
  unsigned long long symbol_generation;
  char code_hash_before_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
  char code_hash_after_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
  char patch_bundle_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
} repro_hcr_windows_code_patch_outcome;

static struct repro_hcr_windows_patch_state *repro_hcr_patch_states = NULL;
static volatile LONG repro_hcr_symbol_generation = 0;
static volatile LONG repro_hcr_last_publication_tier = 0;
static volatile LONG repro_hcr_last_first_instruction_length = 0;
static repro_hcr_windows_code_patch_outcome repro_hcr_last_code_patch;

static int repro_hcr_write_all(HANDLE pipe, const void *bytes, size_t count) {
  const unsigned char *cursor = (const unsigned char *)bytes;
  size_t sent = 0;
  while (sent < count) {
    DWORD wrote = 0;
    DWORD chunk = (DWORD)((count - sent) > 0xffffffffu ? 0xffffffffu
                                                           : (count - sent));
    if (!WriteFile(pipe, cursor + sent, chunk, &wrote, NULL) || wrote == 0) {
      return -1;
    }
    sent += wrote;
  }
  return 0;
}

static int repro_hcr_read_all(HANDLE pipe, void *bytes, size_t count) {
  unsigned char *cursor = (unsigned char *)bytes;
  size_t received = 0;
  while (received < count) {
    DWORD got = 0;
    DWORD chunk = (DWORD)((count - received) > 0xffffffffu ? 0xffffffffu
                                                               : (count - received));
    if (!ReadFile(pipe, cursor + received, chunk, &got, NULL) || got == 0) {
      return -1;
    }
    received += got;
  }
  return 0;
}

static int repro_hcr_send_json(HANDLE pipe, const char *body) {
  char header[64];
  size_t body_len = strlen(body);
  int header_len = snprintf(header, sizeof(header),
                            "Content-Length: %zu\r\n\r\n", body_len);
  if (header_len <= 0 || (size_t)header_len >= sizeof(header)) {
    return -1;
  }
  if (repro_hcr_write_all(pipe, header, (size_t)header_len) != 0 ||
      repro_hcr_write_all(pipe, body, body_len) != 0) {
    return -1;
  }
  return FlushFileBuffers(pipe) ? 0 : -1;
}

static char *repro_hcr_read_frame_body(HANDLE pipe) {
  static const char prefix[] = "Content-Length:";
  char header[128];
  size_t used = 0;
  size_t content_length = 0;
  while (used + 1 < sizeof(header)) {
    if (repro_hcr_read_all(pipe, &header[used], 1) != 0) {
      return NULL;
    }
    used++;
    if (used >= 4 && memcmp(header + used - 4, "\r\n\r\n", 4) == 0) {
      break;
    }
  }
  if (used < 4 || used + 1 >= sizeof(header)) {
    return NULL;
  }
  header[used - 4] = '\0';
  if (_strnicmp(header, prefix, sizeof(prefix) - 1) != 0) {
    return NULL;
  }
  {
    const char *digits = header + sizeof(prefix) - 1;
    char *end = NULL;
    unsigned long parsed;
    while (*digits == ' ' || *digits == '\t') {
      digits++;
    }
    parsed = strtoul(digits, &end, 10);
    if (end == digits || (*end != '\0' && *end != '\r' && *end != '\n') ||
        parsed > REPRO_HCR_MAX_FRAME) {
      return NULL;
    }
    content_length = (size_t)parsed;
  }
  {
    char *body = (char *)malloc(content_length + 1);
    if (body == NULL) {
      return NULL;
    }
    if (repro_hcr_read_all(pipe, body, content_length) != 0) {
      free(body);
      return NULL;
    }
    body[content_length] = '\0';
    return body;
  }
}

static int repro_hcr_json_has_string(const char *json, const char *key,
                                     const char *value) {
  char needle[512];
  int count = snprintf(needle, sizeof(needle), "\"%s\":\"%s\"", key,
                       value);
  return count > 0 && (size_t)count < sizeof(needle) &&
         strstr(json, needle) != NULL;
}

static int repro_hcr_json_string(const char *json, const char *key, char *out,
                                 size_t capacity) {
  char needle[128];
  const char *cursor;
  size_t used = 0;
  int count = snprintf(needle, sizeof(needle), "\"%s\":\"", key);
  if (count <= 0 || (size_t)count >= sizeof(needle) || capacity == 0) {
    return -1;
  }
  cursor = strstr(json, needle);
  if (cursor == NULL) {
    return -1;
  }
  cursor += (size_t)count;
  while (*cursor != '\0' && *cursor != '"') {
    unsigned char ch = (unsigned char)*cursor++;
    if (ch < 0x20 || ch == '\\' || used + 1 >= capacity) {
      return -1;
    }
    out[used++] = (char)ch;
  }
  if (*cursor != '"') {
    return -1;
  }
  out[used] = '\0';
  return 0;
}

static char *repro_hcr_json_alloc_string_after(const char *json,
                                                const char *anchor,
                                                const char *key) {
  char needle[128];
  const char *cursor;
  const char *end;
  char *result;
  size_t length;
  int count;
  if (json == NULL || anchor == NULL || key == NULL) {
    return NULL;
  }
  cursor = strstr(json, anchor);
  if (cursor == NULL) {
    return NULL;
  }
  count = snprintf(needle, sizeof(needle), "\"%s\":\"", key);
  if (count <= 0 || (size_t)count >= sizeof(needle)) {
    return NULL;
  }
  cursor = strstr(cursor, needle);
  if (cursor == NULL) {
    return NULL;
  }
  cursor += (size_t)count;
  end = cursor;
  while (*end != '\0' && *end != '"') {
    unsigned char ch = (unsigned char)*end;
    if (ch < 0x20 || ch == '\\') {
      return NULL;
    }
    ++end;
  }
  if (*end != '"') {
    return NULL;
  }
  length = (size_t)(end - cursor);
  result = (char *)malloc(length + 1u);
  if (result == NULL) {
    return NULL;
  }
  memcpy(result, cursor, length);
  result[length] = '\0';
  return result;
}

static char *repro_hcr_json_first_array_string(const char *json,
                                                const char *key) {
  char needle[128];
  const char *cursor;
  const char *end;
  char *result;
  size_t length;
  int count = snprintf(needle, sizeof(needle), "\"%s\":[\"", key);
  if (count <= 0 || (size_t)count >= sizeof(needle)) {
    return NULL;
  }
  cursor = strstr(json, needle);
  if (cursor == NULL) {
    return NULL;
  }
  cursor += (size_t)count;
  end = cursor;
  while (*end != '\0' && *end != '"') {
    unsigned char ch = (unsigned char)*end;
    if (ch < 0x20 || ch == '\\') {
      return NULL;
    }
    ++end;
  }
  if (*end != '"') {
    return NULL;
  }
  length = (size_t)(end - cursor);
  result = (char *)malloc(length + 1u);
  if (result == NULL) {
    return NULL;
  }
  memcpy(result, cursor, length);
  result[length] = '\0';
  return result;
}

static int repro_hcr_hex_nibble(char ch) {
  if (ch >= '0' && ch <= '9') {
    return ch - '0';
  }
  if (ch >= 'a' && ch <= 'f') {
    return ch - 'a' + 10;
  }
  if (ch >= 'A' && ch <= 'F') {
    return ch - 'A' + 10;
  }
  return -1;
}

static uint8_t *repro_hcr_bytes_from_hex(const char *hex, size_t *length) {
  size_t index;
  size_t count;
  uint8_t *bytes;
  if (hex == NULL || length == NULL) {
    return NULL;
  }
  count = strlen(hex);
  if ((count & 1u) != 0 || count / 2u > REPRO_HCR_MAX_FRAME) {
    return NULL;
  }
  bytes = (uint8_t *)malloc(count / 2u == 0 ? 1u : count / 2u);
  if (bytes == NULL) {
    return NULL;
  }
  for (index = 0; index < count / 2u; ++index) {
    int high = repro_hcr_hex_nibble(hex[index * 2u]);
    int low = repro_hcr_hex_nibble(hex[index * 2u + 1u]);
    if (high < 0 || low < 0) {
      free(bytes);
      return NULL;
    }
    bytes[index] = (uint8_t)((high << 4) | low);
  }
  *length = count / 2u;
  return bytes;
}

static uint16_t repro_hcr_u16_le(const uint8_t *bytes) {
  return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t repro_hcr_u32_le(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static int repro_hcr_bundle_range_ok(size_t total, uint32_t offset,
                                     uint64_t count) {
  return (uint64_t)offset <= (uint64_t)total &&
         count <= (uint64_t)total - (uint64_t)offset;
}

static void repro_hcr_windows_bundle_release(
    struct repro_hcr_windows_bundle *bundle) {
  if (bundle != NULL) {
    free(bundle->entry_offsets);
    memset(bundle, 0, sizeof(*bundle));
  }
}

static int repro_hcr_windows_parse_bundle(
    const uint8_t *bytes, size_t length,
    struct repro_hcr_windows_bundle *bundle,
    char *failure, size_t failure_capacity) {
  static const uint8_t magic[8] = {'R', 'H', 'W', 'D', 'P', '1', 0, 0};
  uint32_t region_offset;
  uint32_t entries_offset;
  uint8_t digest[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint32_t index;
  int replacement_found = 0;
  if (bytes == NULL || bundle == NULL || failure == NULL ||
      failure_capacity == 0) {
    return -1;
  }
  memset(bundle, 0, sizeof(*bundle));
#define REPRO_HCR_BUNDLE_FAIL(text)                                             \
  do {                                                                          \
    snprintf(failure, failure_capacity, "windows-patch-bundle-invalid: %s",    \
             (text));                                                           \
    repro_hcr_windows_bundle_release(bundle);                                   \
    return -1;                                                                  \
  } while (0)
  if (length < REPRO_HCR_WINDOWS_BUNDLE_HEADER_BYTES) {
    REPRO_HCR_BUNDLE_FAIL("truncated header");
  }
  if (memcmp(bytes, magic, sizeof(magic)) != 0 ||
      repro_hcr_u16_le(bytes + 8) != REPRO_HCR_WINDOWS_BUNDLE_VERSION ||
      repro_hcr_u16_le(bytes + 10) != REPRO_HCR_WINDOWS_BUNDLE_HEADER_BYTES ||
      repro_hcr_u32_le(bytes + 12) != length) {
    REPRO_HCR_BUNDLE_FAIL("magic/version/header/length mismatch");
  }
  if (bytes[50] != 0 || bytes[51] != 0 || bytes[67] != 0) {
    REPRO_HCR_BUNDLE_FAIL("reserved header bytes are non-zero");
  }
  memcpy(bundle->identity.guid, bytes + 16, sizeof(bundle->identity.guid));
  bundle->identity.age = repro_hcr_u32_le(bytes + 32);
  bundle->target_rva = repro_hcr_u32_le(bytes + 36);
  bundle->first_instruction_length = repro_hcr_u32_le(bytes + 40);
  memcpy(bundle->expected_padding, bytes + 44,
         sizeof(bundle->expected_padding));
  memcpy(bundle->expected_first_instruction, bytes + 52,
         sizeof(bundle->expected_first_instruction));
  region_offset = repro_hcr_u32_le(bytes + 68);
  bundle->region_size = repro_hcr_u32_le(bytes + 72);
  bundle->function_table_offset = repro_hcr_u32_le(bytes + 76);
  bundle->function_table_count = repro_hcr_u32_le(bytes + 80);
  bundle->replacement_entry_offset = repro_hcr_u32_le(bytes + 84);
  entries_offset = repro_hcr_u32_le(bytes + 88);
  bundle->entry_count = repro_hcr_u32_le(bytes + 92);
  if (bundle->target_rva < REPRO_HCR_WP_PADDING_BYTES ||
      bundle->first_instruction_length < 2u ||
      bundle->first_instruction_length > REPRO_HCR_WP_MAX_INSTRUCTION_BYTES ||
      bundle->region_size == 0 || bundle->function_table_count == 0 ||
      bundle->entry_count == 0 ||
      bundle->entry_count != bundle->function_table_count ||
      region_offset < REPRO_HCR_WINDOWS_BUNDLE_HEADER_BYTES ||
      (region_offset & 15u) != 0 ||
      entries_offset < REPRO_HCR_WINDOWS_BUNDLE_HEADER_BYTES ||
      !repro_hcr_bundle_range_ok(length, entries_offset,
                                 (uint64_t)bundle->entry_count * 4u) ||
      !repro_hcr_bundle_range_ok(length, region_offset, bundle->region_size) ||
      (uint64_t)entries_offset + (uint64_t)bundle->entry_count * 4u >
          region_offset ||
      (uint64_t)region_offset + bundle->region_size != length ||
      !repro_hcr_bundle_range_ok(bundle->region_size,
                                 bundle->function_table_offset,
                                 (uint64_t)bundle->function_table_count *
                                     sizeof(RUNTIME_FUNCTION))) {
    REPRO_HCR_BUNDLE_FAIL("offset/count/geometry validation failed");
  }
  if (!repro_hcr_sha256_selftest()) {
    REPRO_HCR_BUNDLE_FAIL("SHA-256 self-test failed");
  }
  bundle->region = bytes + region_offset;
  repro_hcr_sha256(bundle->region, bundle->region_size, digest);
  if (memcmp(digest, bytes + 96, sizeof(digest)) != 0) {
    REPRO_HCR_BUNDLE_FAIL("region digest mismatch");
  }
  bundle->entry_offsets = (uint32_t *)calloc(
      bundle->entry_count, sizeof(*bundle->entry_offsets));
  if (bundle->entry_offsets == NULL) {
    REPRO_HCR_BUNDLE_FAIL("entry-offset allocation failed");
  }
  for (index = 0; index < bundle->entry_count; ++index) {
    uint32_t offset = repro_hcr_u32_le(bytes + entries_offset + index * 4u);
    if ((offset & 15u) != 0 || offset >= bundle->region_size ||
        (index > 0 && bundle->entry_offsets[index - 1] >= offset)) {
      REPRO_HCR_BUNDLE_FAIL("CFG entry set is invalid");
    }
    bundle->entry_offsets[index] = offset;
    if (offset == bundle->replacement_entry_offset) {
      replacement_found = 1;
    }
  }
  if (!replacement_found) {
    REPRO_HCR_BUNDLE_FAIL("replacement entry is not CFG-admitted");
  }
  return 0;
#undef REPRO_HCR_BUNDLE_FAIL
}

static const char *repro_hcr_windows_pe_status_name(
    enum repro_hcr_windows_pe_status status) {
  switch (status) {
  case REPRO_HCR_WINDOWS_PE_OK:
    return "ok";
  case REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_MISSING:
    return "target-codeview-identity-missing";
  case REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_CONFLICT:
    return "target-codeview-identity-conflict";
  case REPRO_HCR_WINDOWS_PE_MODULE_ABSENT:
    return "target-module-identity-absent";
  case REPRO_HCR_WINDOWS_PE_MODULE_AMBIGUOUS:
    return "target-module-identity-ambiguous";
  case REPRO_HCR_WINDOWS_PE_RETAIN_FAILED:
    return "target-module-retain-failed";
  case REPRO_HCR_WINDOWS_PE_REVALIDATION_FAILED:
    return "target-module-revalidation-failed";
  case REPRO_HCR_WINDOWS_PE_RVA_OUT_OF_RANGE:
    return "target-symbol-rva-out-of-range";
  default:
    return "target-pe-validation-failed";
  }
}

static const char *repro_hcr_windows_registration_status_name(
    enum repro_hcr_windows_registration_status status) {
  switch (status) {
  case REPRO_HCR_WINDOWS_REGISTRATION_OK:
    return "ok";
  case REPRO_HCR_WINDOWS_REGISTRATION_TABLE_OUT_OF_RANGE:
    return "windows-unwind-table-out-of-range";
  case REPRO_HCR_WINDOWS_REGISTRATION_TABLE_UNSORTED:
    return "windows-unwind-table-unsorted";
  case REPRO_HCR_WINDOWS_REGISTRATION_FUNCTION_RANGE_INVALID:
    return "windows-unwind-function-range-invalid";
  case REPRO_HCR_WINDOWS_REGISTRATION_UNWIND_INFO_INVALID:
    return "windows-unwind-info-invalid";
  case REPRO_HCR_WINDOWS_REGISTRATION_RTL_ADD_FAILED:
    return "windows-unwind-registration-failed";
  case REPRO_HCR_WINDOWS_REGISTRATION_CFG_QUERY_FAILED:
    return "windows-cfg-policy-query-failed";
  case REPRO_HCR_WINDOWS_REGISTRATION_CFG_TARGET_INVALID:
    return "windows-cfg-target-invalid";
  case REPRO_HCR_WINDOWS_REGISTRATION_CFG_UPDATE_FAILED:
    return "windows-cfg-registration-failed";
  default:
    return "windows-patch-registration-failed";
  }
}

static void *repro_hcr_windows_allocate_near(uintptr_t entry,
                                             uint32_t replacement_offset,
                                             size_t size) {
  SYSTEM_INFO info;
  uintptr_t granularity;
  uintptr_t anchor;
  uintptr_t step;
  uintptr_t max_steps;
  GetSystemInfo(&info);
  granularity = (uintptr_t)info.dwAllocationGranularity;
  if (granularity == 0 || (granularity & (granularity - 1u)) != 0) {
    return NULL;
  }
  anchor = entry & ~(granularity - 1u);
  max_steps = ((uintptr_t)INT32_MAX - replacement_offset) / granularity;
  for (step = 1; step <= max_steps; ++step) {
    uintptr_t distance = step * granularity;
    uintptr_t candidates[2];
    unsigned index;
    candidates[0] = anchor <= UINTPTR_MAX - distance ? anchor + distance : 0;
    candidates[1] = anchor >= distance ? anchor - distance : 0;
    for (index = 0; index < 2; ++index) {
      void *region;
      uintptr_t candidate = candidates[index];
      int64_t displacement;
      if (candidate < (uintptr_t)info.lpMinimumApplicationAddress ||
          candidate > (uintptr_t)info.lpMaximumApplicationAddress ||
          candidate > UINTPTR_MAX - size) {
        continue;
      }
      region = VirtualAlloc((void *)candidate, size,
                            MEM_RESERVE | MEM_COMMIT,
                            PAGE_EXECUTE_READ | PAGE_TARGETS_INVALID);
      if (region == NULL) {
        continue;
      }
      displacement = (int64_t)((uintptr_t)region + replacement_offset) -
                     (int64_t)entry;
      if ((uintptr_t)region == candidate && displacement >= INT32_MIN &&
          displacement <= INT32_MAX) {
        return region;
      }
      VirtualFree(region, 0, MEM_RELEASE);
    }
  }
  return NULL;
}

static void repro_hcr_windows_keep_failed_registration(
    struct repro_hcr_windows_patch_state *state) {
  state->next = repro_hcr_patch_states;
  repro_hcr_patch_states = state;
}

static struct repro_hcr_windows_patch_state *
repro_hcr_windows_find_patch_state(uintptr_t entry) {
  struct repro_hcr_windows_patch_state *state = repro_hcr_patch_states;
  while (state != NULL) {
    if (state->target_entry == entry) {
      return state;
    }
    state = state->next;
  }
  return NULL;
}

static void repro_hcr_windows_hex32(const uint8_t *digest, char *out) {
  static const char digits[] = "0123456789abcdef";
  unsigned i;
  for (i = 0; i < REPRO_HCR_SHA256_DIGEST_BYTES; ++i) {
    out[2 * i] = digits[(digest[i] >> 4) & 0x0f];
    out[2 * i + 1] = digits[digest[i] & 0x0f];
  }
  out[2 * REPRO_HCR_SHA256_DIGEST_BYTES] = '\0';
}

/* Stage0 maps ct_interpose_stage0.dll before the Windows loader runs. That
 * image intentionally has no LDR_DATA_TABLE_ENTRY, so GetModuleHandle cannot
 * discover it later even though its PE export directory is intact. Search
 * allocation bases only after the ordinary loader lookup fails. Every
 * dereference is guarded because an in-process address-space walk encounters
 * arbitrary private mappings. */
static FARPROC repro_hcr_windows_export_from_mapped_pe(
    uintptr_t base, const char *wanted) {
  FARPROC result = NULL;
  __try {
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *nt;
    const IMAGE_DATA_DIRECTORY *export_data;
    const IMAGE_EXPORT_DIRECTORY *exports;
    const DWORD *name_rvas;
    const WORD *name_ordinals;
    const DWORD *function_rvas;
    size_t image_size;
    size_t wanted_len;
    DWORD i;

    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0 ||
        (DWORD)dos->e_lfanew > 1024u * 1024u) {
      return NULL;
    }
    nt = (const IMAGE_NT_HEADERS64 *)(base + (DWORD)dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
      return NULL;
    }
    image_size = (size_t)nt->OptionalHeader.SizeOfImage;
    if (image_size < sizeof(IMAGE_DOS_HEADER) ||
        image_size > (size_t)2u * 1024u * 1024u * 1024u) {
      return NULL;
    }
    export_data = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (export_data->VirtualAddress == 0 || export_data->Size == 0 ||
        (size_t)export_data->VirtualAddress > image_size ||
        (size_t)export_data->Size >
            image_size - (size_t)export_data->VirtualAddress) {
      return NULL;
    }
    exports = (const IMAGE_EXPORT_DIRECTORY *)(
        base + (uintptr_t)export_data->VirtualAddress);
    if (exports->NumberOfNames == 0 || exports->NumberOfFunctions == 0 ||
        (size_t)exports->AddressOfNames > image_size ||
        (size_t)exports->NumberOfNames >
            (image_size - (size_t)exports->AddressOfNames) / sizeof(DWORD) ||
        (size_t)exports->AddressOfNameOrdinals > image_size ||
        (size_t)exports->NumberOfNames >
            (image_size - (size_t)exports->AddressOfNameOrdinals) /
                sizeof(WORD) ||
        (size_t)exports->AddressOfFunctions > image_size ||
        (size_t)exports->NumberOfFunctions >
            (image_size - (size_t)exports->AddressOfFunctions) /
                sizeof(DWORD)) {
      return NULL;
    }
    name_rvas = (const DWORD *)(base + (uintptr_t)exports->AddressOfNames);
    name_ordinals =
        (const WORD *)(base + (uintptr_t)exports->AddressOfNameOrdinals);
    function_rvas =
        (const DWORD *)(base + (uintptr_t)exports->AddressOfFunctions);
    wanted_len = strlen(wanted);
    for (i = 0; i < exports->NumberOfNames; ++i) {
      size_t name_rva = (size_t)name_rvas[i];
      WORD ordinal;
      DWORD function_rva;
      if (name_rva >= image_size || wanted_len >= image_size - name_rva ||
          memcmp((const void *)(base + name_rva), wanted, wanted_len) != 0 ||
          *(const char *)(base + name_rva + wanted_len) != '\0') {
        continue;
      }
      ordinal = name_ordinals[i];
      if ((DWORD)ordinal >= exports->NumberOfFunctions) {
        return NULL;
      }
      function_rva = function_rvas[ordinal];
      if ((size_t)function_rva >= image_size) {
        return NULL;
      }
      /* A function RVA inside the export directory is a forwarder string,
       * never the in-image recorder bridge we are looking for. */
      if ((size_t)function_rva >= (size_t)export_data->VirtualAddress &&
          (size_t)function_rva <
              (size_t)export_data->VirtualAddress + export_data->Size) {
        return NULL;
      }
      result = (FARPROC)(base + (uintptr_t)function_rva);
      return result;
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return NULL;
  }
  return result;
}

static FARPROC repro_hcr_windows_find_manual_mcr_bridge(void) {
  static const char bridge_name[] = "ct_repro_hcr_agent_did_patch_v2";
  SYSTEM_INFO info;
  uintptr_t cursor;
  uintptr_t maximum;
  uintptr_t last_allocation = 0;

  GetSystemInfo(&info);
  cursor = (uintptr_t)info.lpMinimumApplicationAddress;
  maximum = (uintptr_t)info.lpMaximumApplicationAddress;
  while (cursor <= maximum) {
    MEMORY_BASIC_INFORMATION memory;
    SIZE_T queried = VirtualQuery((const void *)cursor, &memory, sizeof(memory));
    uintptr_t next;
    uintptr_t allocation;
    if (queried == 0) {
      break;
    }
    next = (uintptr_t)memory.BaseAddress + (uintptr_t)memory.RegionSize;
    if (next <= cursor) {
      break;
    }
    allocation = (uintptr_t)memory.AllocationBase;
    if (allocation != 0 && allocation != last_allocation &&
        memory.State == MEM_COMMIT &&
        (memory.Protect & (PAGE_NOACCESS | PAGE_GUARD)) == 0) {
      FARPROC symbol;
      last_allocation = allocation;
      symbol = repro_hcr_windows_export_from_mapped_pe(allocation, bridge_name);
      if (symbol != NULL) {
        return symbol;
      }
    }
    cursor = next;
  }
  return NULL;
}

static int repro_hcr_windows_resolve_mcr_bridge(
    ct_repro_hcr_agent_did_patch_v2_fn *bridge_out) {
  static const wchar_t *module_names[] = {
      L"ct_interpose.dll", L"ct_interpose_stage0.dll"};
  unsigned i;
  *bridge_out = NULL;
  for (i = 0; i < sizeof(module_names) / sizeof(module_names[0]); ++i) {
    HMODULE module = GetModuleHandleW(module_names[i]);
    FARPROC symbol;
    if (module == NULL) {
      continue;
    }
    symbol = GetProcAddress(module, "ct_repro_hcr_agent_did_patch_v2");
    if (symbol != NULL) {
      *bridge_out = (ct_repro_hcr_agent_did_patch_v2_fn)(uintptr_t)symbol;
      return 1;
    }
  }
  {
    FARPROC symbol = repro_hcr_windows_find_manual_mcr_bridge();
    if (symbol != NULL) {
      *bridge_out = (ct_repro_hcr_agent_did_patch_v2_fn)(uintptr_t)symbol;
      return 1;
    }
  }
  return 0;
}

static void repro_hcr_windows_notify_code_patch(
    const char *patch_id, const char *changed_function,
    const uint8_t *patch_bundle, size_t patch_bundle_len,
    uintptr_t entry, uintptr_t dispatch,
    const uint8_t code_before[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES],
    const uint8_t code_after[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES]) {
  ct_repro_hcr_patch_note_v1 note;
  ct_repro_hcr_patch_site_v1 site;
  ct_repro_hcr_agent_did_patch_v2_fn bridge = NULL;
  uint8_t hash_before[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint8_t hash_after[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint8_t hash_bundle[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint64_t word_before = 0;
  uint64_t word_after = 0;
  char symbol_blob[1024];
  size_t symbol_len;

  memset(&repro_hcr_last_code_patch, 0, sizeof(repro_hcr_last_code_patch));
  repro_hcr_last_code_patch.attempted = 1;
  repro_hcr_last_code_patch.tier =
      (unsigned)repro_hcr_last_publication_tier;
  repro_hcr_last_code_patch.symbol_generation =
      (unsigned long long)repro_hcr_symbol_generation;
  repro_hcr_last_code_patch.hash_selftest = repro_hcr_sha256_selftest();
  if (!repro_hcr_last_code_patch.hash_selftest) {
    return;
  }

  repro_hcr_sha256(code_before, REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES,
                   hash_before);
  repro_hcr_sha256(code_after, REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES,
                   hash_after);
  repro_hcr_sha256(patch_bundle, patch_bundle_len, hash_bundle);
  repro_hcr_windows_hex32(
      hash_before, repro_hcr_last_code_patch.code_hash_before_hex);
  repro_hcr_windows_hex32(
      hash_after, repro_hcr_last_code_patch.code_hash_after_hex);
  repro_hcr_windows_hex32(
      hash_bundle, repro_hcr_last_code_patch.patch_bundle_hex);

  repro_hcr_last_code_patch.bridge_present =
      repro_hcr_windows_resolve_mcr_bridge(&bridge);
  if (!repro_hcr_last_code_patch.bridge_present) {
    return;
  }
  symbol_len = strlen(changed_function);
  if (symbol_len == 0 || symbol_len + 2 > sizeof(symbol_blob)) {
    repro_hcr_last_code_patch.bridge_result = -1;
    return;
  }
  memcpy(symbol_blob, changed_function, symbol_len);
  symbol_blob[symbol_len] = '\0';
  symbol_blob[symbol_len + 1] = '\0';
  memcpy(&word_before, code_before, REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES);
  memcpy(&word_after, code_after, REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES);

  memset(&site, 0, sizeof(site));
  site.entryAddress = (uint64_t)entry;
  site.sledAddress =
      (uint64_t)(entry - REPRO_HCR_WP_PADDING_BYTES);
  site.windowAddress = site.sledAddress;
  site.dispatchAddress = (uint64_t)dispatch;
  site.codeWordBefore = word_before;
  site.codeWordAfter = word_after;
  site.windowLength = REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES;
  site.generation = (uint32_t)repro_hcr_symbol_generation;

  memset(&note, 0, sizeof(note));
  note.structSize = (uint32_t)sizeof(note);
  note.noteVersion = 1u;
  note.publicationTier = (uint32_t)repro_hcr_last_publication_tier;
  note.siteCount = 1u;
  note.patchId = patch_id;
  note.patchedSymbols = symbol_blob;
  note.supportProfile = REPRO_HCR_WINDOWS_AGENT_PROFILE;
  note.patchBundle = patch_bundle;
  note.patchBundleLen = (uint64_t)patch_bundle_len;
  note.codeHashBefore = hash_before;
  note.codeHashAfter = hash_after;
  note.patchBundleHash = hash_bundle;
  note.sites = &site;
  repro_hcr_last_code_patch.bridge_result = bridge(&note);
}

static int repro_hcr_windows_apply_bundle(
    const uint8_t *bytes, size_t length, uintptr_t *entry_address,
    uintptr_t *dispatch_address, int *shared_library_positive,
    uint8_t code_before[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES],
    uint8_t code_after[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES],
    char *failure, size_t failure_capacity) {
  struct repro_hcr_windows_bundle bundle;
  struct repro_hcr_windows_patch_state *state = NULL;
  struct repro_hcr_windows_patch_state *previous_state = NULL;
  struct repro_hcr_windows_publish_request publish;
  enum repro_hcr_windows_pe_status pe_status;
  enum repro_hcr_windows_registration_status registration_status;
  uintptr_t entry = 0;
  void *dispatch = NULL;
  SYSTEM_INFO info;
  size_t allocation_size;
  DWORD ignored = 0;
  int publish_status;
  int prepared = 0;

  if (repro_hcr_windows_parse_bundle(bytes, length, &bundle, failure,
                                     failure_capacity) != 0) {
    return -1;
  }
  if (IsDebuggerPresent()) {
    snprintf(failure, failure_capacity,
             "windows-direct-debugger-unsupported: use debugger-managed mode");
    repro_hcr_windows_bundle_release(&bundle);
    return -1;
  }
  state = (struct repro_hcr_windows_patch_state *)calloc(1, sizeof(*state));
  if (state == NULL) {
    snprintf(failure, failure_capacity, "windows-patch-state-allocation-failed");
    repro_hcr_windows_bundle_release(&bundle);
    return -1;
  }
  pe_status = repro_hcr_windows_pe_retain_module(&bundle.identity,
                                                  &state->module);
  if (pe_status != REPRO_HCR_WINDOWS_PE_OK) {
    snprintf(failure, failure_capacity, "%s",
             repro_hcr_windows_pe_status_name(pe_status));
    goto failed;
  }
  pe_status = repro_hcr_windows_pe_resolve_rva(&state->module,
                                               bundle.target_rva, &entry);
  if (pe_status != REPRO_HCR_WINDOWS_PE_OK) {
    snprintf(failure, failure_capacity, "%s",
             repro_hcr_windows_pe_status_name(pe_status));
    goto failed;
  }
  previous_state = repro_hcr_windows_find_patch_state(entry);
  memset(&publish, 0, sizeof(publish));
  publish.entry = (uint8_t *)entry;
  publish.previous_dispatch = previous_state != NULL
      ? (const void *)previous_state->dispatch
      : NULL;
  publish.first_instruction_length = bundle.first_instruction_length;
  publish.quiescence_available = 1;
  memcpy(publish.expected_padding, bundle.expected_padding,
         sizeof(publish.expected_padding));
  memcpy(publish.expected_first_instruction,
         bundle.expected_first_instruction,
         sizeof(publish.expected_first_instruction));
  if (!repro_hcr_wp_geometry_valid(&publish) ||
      !repro_hcr_wp_live_bytes_match(&publish)) {
    snprintf(failure, failure_capacity,
             "windows-hotpatch-live-bytes-mismatch");
    goto failed;
  }

  GetSystemInfo(&info);
  if (info.dwPageSize == 0 ||
      bundle.region_size > SIZE_MAX - ((size_t)info.dwPageSize - 1u)) {
    snprintf(failure, failure_capacity, "windows-patch-region-size-invalid");
    goto failed;
  }
  allocation_size = ((size_t)bundle.region_size + info.dwPageSize - 1u) &
                    ~((size_t)info.dwPageSize - 1u);
  state->region = repro_hcr_windows_allocate_near(
      entry, bundle.replacement_entry_offset, allocation_size);
  state->allocation_size = allocation_size;
  if (state->region == NULL) {
    snprintf(failure, failure_capacity,
             "patch-body-out-of-rel32-range: no nearby executable region");
    goto failed;
  }
  if (!VirtualProtect(state->region, allocation_size, PAGE_READWRITE,
                      &ignored)) {
    snprintf(failure, failure_capacity,
             "windows-patch-region-write-protection-failed");
    goto failed;
  }
  memcpy(state->region, bundle.region, bundle.region_size);
  if (!VirtualProtect(state->region, allocation_size,
                      PAGE_EXECUTE_READ | PAGE_TARGETS_NO_UPDATE, &ignored) ||
      !FlushInstructionCache(GetCurrentProcess(), state->region,
                             bundle.region_size)) {
    snprintf(failure, failure_capacity,
             "windows-patch-region-execute-protection-failed");
    goto failed;
  }
  registration_status = repro_hcr_windows_prepare_patch_region(
      state->region, allocation_size, bundle.region_size,
      bundle.function_table_offset, bundle.function_table_count,
      bundle.entry_offsets, bundle.entry_count, &state->registration);
  if (registration_status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    snprintf(failure, failure_capacity, "%s",
             repro_hcr_windows_registration_status_name(registration_status));
    goto failed;
  }
  prepared = 1;
  registration_status = repro_hcr_windows_prepared_entry(
      &state->registration, bundle.replacement_entry_offset, &dispatch);
  if (registration_status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
    snprintf(failure, failure_capacity, "%s",
             repro_hcr_windows_registration_status_name(registration_status));
    goto failed;
  }
  publish.dispatch = dispatch;
  memcpy(code_before, (const void *)(entry - REPRO_HCR_WP_PADDING_BYTES),
         REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES);
  publish_status = repro_hcr_windows_publish_hotpatch(&publish);
  if (publish_status != REPRO_HCR_WP_OK) {
    snprintf(failure, failure_capacity, "%s",
             repro_hcr_wp_status_name(publish_status));
    goto failed;
  }
  memcpy(code_after, (const void *)(entry - REPRO_HCR_WP_PADDING_BYTES),
         REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES);
  state->target_entry = entry;
  state->dispatch = (uintptr_t)dispatch;
  state->generation =
      previous_state != NULL ? previous_state->generation + 1 : 1;
  state->next = repro_hcr_patch_states;
  repro_hcr_patch_states = state;
  *entry_address = entry;
  *dispatch_address = (uintptr_t)dispatch;
  *shared_library_positive =
      state->module.handle != GetModuleHandleW(NULL) ? 1 : 0;
  InterlockedExchange(&repro_hcr_symbol_generation, state->generation);
  InterlockedExchange(&repro_hcr_last_publication_tier, 2);
  InterlockedExchange(&repro_hcr_last_first_instruction_length,
                      (LONG)bundle.first_instruction_length);
  repro_hcr_windows_bundle_release(&bundle);
  return 0;

failed:
  repro_hcr_windows_bundle_release(&bundle);
  if (state != NULL) {
    if (prepared) {
      registration_status =
          repro_hcr_windows_rollback_patch_region(&state->registration);
      if (registration_status != REPRO_HCR_WINDOWS_REGISTRATION_OK) {
        repro_hcr_windows_keep_failed_registration(state);
        return -1;
      }
    }
    if (state->region != NULL) {
      VirtualFree(state->region, 0, MEM_RELEASE);
    }
    if (state->module.handle != NULL) {
      (void)repro_hcr_windows_pe_release_module(&state->module);
    }
    free(state);
  }
  return -1;
}

static PSECURITY_DESCRIPTOR repro_hcr_current_user_pipe_security(void) {
  HANDLE token = NULL;
  DWORD needed = 0;
  TOKEN_USER *token_user = NULL;
  LPWSTR sid = NULL;
  wchar_t sddl[256];
  PSECURITY_DESCRIPTOR descriptor = NULL;
  HANDLE heap = GetProcessHeap();

  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return NULL;
  }
  (void)GetTokenInformation(token, TokenUser, NULL, 0, &needed);
  if (needed == 0) {
    CloseHandle(token);
    return NULL;
  }
  token_user = (TOKEN_USER *)HeapAlloc(heap, HEAP_ZERO_MEMORY, needed);
  if (token_user == NULL ||
      !GetTokenInformation(token, TokenUser, token_user, needed, &needed) ||
      !ConvertSidToStringSidW(token_user->User.Sid, &sid)) {
    if (token_user != NULL) {
      HeapFree(heap, 0, token_user);
    }
    CloseHandle(token);
    return NULL;
  }
  if (swprintf_s(sddl, sizeof(sddl) / sizeof(sddl[0]),
                 L"D:P(A;;GA;;;%ls)", sid) <= 0 ||
      !ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl, SDDL_REVISION_1, &descriptor, NULL)) {
    descriptor = NULL;
  }
  LocalFree(sid);
  HeapFree(heap, 0, token_user);
  CloseHandle(token);
  return descriptor;
}

static int repro_hcr_pipe_name(wchar_t *out, size_t capacity) {
  int count = swprintf_s(out, capacity, L"\\\\.\\pipe\\repro-hcr-%lu",
                         (unsigned long)GetCurrentProcessId());
  return count > 0 && (size_t)count < capacity ? 0 : -1;
}

static int repro_hcr_send_hello(HANDLE pipe) {
  char body[1024];
  int count = snprintf(
      body, sizeof(body),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-hello-1\"," \
      "\"kind\":\"hello\",\"hello\":{\"supportProfile\":\"%s\"," \
      "\"agentPid\":%lu,\"capabilities\":[\"hcr-agent-protocol\"," \
      "\"%s\",\"%s\"]}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
      REPRO_HCR_WINDOWS_AGENT_PROFILE, (unsigned long)GetCurrentProcessId(),
      REPRO_HCR_WINDOWS_CAPABILITY, REPRO_HCR_DIRECT_PATCH_CAPABILITY);
  if (count <= 0 || (size_t)count >= sizeof(body)) {
    return -1;
  }
  return repro_hcr_send_json(pipe, body);
}

static int repro_hcr_send_lifecycle(HANDLE pipe, const char *patch_id,
                                    const char *event, unsigned sequence) {
  char lifecycle[1024];
  int lifecycle_count = snprintf(
      lifecycle, sizeof(lifecycle),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-lifecycle-2\"," \
      "\"kind\":\"lifecycleEvent\",\"lifecycleEvent\":{" \
      "\"patchId\":\"%s\",\"event\":\"%s\"," \
      "\"sequence\":%u}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id,
      event, sequence);
  if (lifecycle_count <= 0 || (size_t)lifecycle_count >= sizeof(lifecycle)) {
    return -1;
  }
  return repro_hcr_send_json(pipe, lifecycle);
}

static int repro_hcr_send_patch_failure(HANDLE pipe, const char *patch_id,
                                        const char *message) {
  char failure[2048];
  int failure_count = snprintf(
      failure, sizeof(failure),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-patch-failed-3\"," \
      "\"kind\":\"patchFailed\",\"patchFailed\":{\"patchId\":\"%s\"," \
      "\"stage\":\"applyDirectPatchRequest\"," \
      "\"message\":\"%s\"}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id, message);
  if (failure_count <= 0 || (size_t)failure_count >= sizeof(failure)) {
    return -1;
  }
  return repro_hcr_send_json(pipe, failure);
}

static int repro_hcr_send_patch_applied(HANDLE pipe, const char *patch_id,
                                        const char *changed_function,
                                        uintptr_t entry,
                                        uintptr_t dispatch,
                                        int shared_library_positive) {
  char applied[4096];
  int count = snprintf(
      applied, sizeof(applied),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-patch-applied-3\"," \
      "\"kind\":\"patchApplied\",\"patchApplied\":{\"patchId\":\"%s\"," \
      "\"changedFunctions\":[\"%s\"],\"symbolGeneration\":%ld," \
      "\"debugObjectDigest\":\"\",\"unwindMetadataDigest\":\"\"," \
      "\"sourceGenerationMapDigest\":\"unavailable:windows-agent-does-not-parse-source-generation-map\"," \
      "\"entryAddress\":\"0x%llx\",\"dispatchAddress\":\"0x%llx\"," \
      "\"oldCodeRetained\":true,\"sharedLibraryPositivePath\":%s," \
      "\"codePatchEvent\":{\"recorded\":%s,\"bridgePresent\":%s," \
      "\"bridgeResult\":%d,\"hashSelfTest\":%s," \
      "\"publicationTier\":%u," \
      "\"codeHashBefore\":\"sha256:%s\"," \
      "\"codeHashAfter\":\"sha256:%s\"," \
      "\"patchBundle\":\"sha256:%s\",\"claimHeld\":false}," \
      "\"windowsEvidence\":{\"publicationTier\":%ld," \
      "\"suspendedThreads\":%d,\"capturedContexts\":%d," \
      "\"quiescenceHeldAtStore\":%s,\"cacheFlushSucceeded\":%s," \
      "\"firstInstructionLength\":%ld}}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id,
      changed_function, repro_hcr_symbol_generation,
      (unsigned long long)entry, (unsigned long long)dispatch,
      shared_library_positive ? "true" : "false",
      repro_hcr_last_code_patch.bridge_result == 1 ? "true" : "false",
      repro_hcr_last_code_patch.bridge_present ? "true" : "false",
      repro_hcr_last_code_patch.bridge_result,
      repro_hcr_last_code_patch.hash_selftest ? "true" : "false",
      repro_hcr_last_code_patch.tier,
      repro_hcr_last_code_patch.code_hash_before_hex,
      repro_hcr_last_code_patch.code_hash_after_hex,
      repro_hcr_last_code_patch.patch_bundle_hex,
      repro_hcr_last_publication_tier,
      repro_hcr_wp_last_report.suspended_threads,
      repro_hcr_wp_last_report.captured_contexts,
      repro_hcr_wp_last_report.quiescence_held_at_store ? "true" : "false",
      repro_hcr_wp_last_report.cache_flush_succeeded ? "true" : "false",
      repro_hcr_last_first_instruction_length);
  if (count <= 0 || (size_t)count >= sizeof(applied)) {
    return -1;
  }
  return repro_hcr_send_json(pipe, applied);
}

static int repro_hcr_handle_patch_request(HANDLE pipe, const char *request) {
  char patch_id[256];
  char *changed_function = NULL;
  char *payload_hex = NULL;
  uint8_t *payload = NULL;
  size_t payload_length = 0;
  uintptr_t entry = 0;
  uintptr_t dispatch = 0;
  int shared_library_positive = 0;
  uint8_t code_before[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES] = {0};
  uint8_t code_after[REPRO_HCR_WINDOWS_PATCH_WINDOW_BYTES] = {0};
  char failure[1024];
  int ok = 0;

  failure[0] = '\0';
  if (repro_hcr_json_string(request, "patchId", patch_id,
                            sizeof(patch_id)) != 0) {
    strcpy_s(patch_id, sizeof(patch_id), "");
    snprintf(failure, sizeof(failure), "patch request is missing patchId");
  } else if (!repro_hcr_json_has_string(request, "mode", "direct")) {
    snprintf(failure, sizeof(failure), "windows-agent-requires-direct-mode");
  } else {
    changed_function = repro_hcr_json_first_array_string(
        request, "changedFunctions");
    payload_hex = repro_hcr_json_alloc_string_after(
        request, "\"directPatchPayload\":", "bytesHex");
    if (changed_function == NULL) {
      snprintf(failure, sizeof(failure),
               "patch request is missing changed function");
    } else if (payload_hex == NULL) {
      snprintf(failure, sizeof(failure),
               "patch request is missing direct patch bytes");
    } else {
      payload = repro_hcr_bytes_from_hex(payload_hex, &payload_length);
      if (payload == NULL) {
        snprintf(failure, sizeof(failure),
                 "windows-patch-bundle-invalid: bytesHex is not valid hex");
      }
    }
  }
  if (repro_hcr_send_lifecycle(pipe, patch_id, "hcr/patchApplying", 1) != 0) {
    goto done;
  }
  if (failure[0] == '\0' &&
      repro_hcr_windows_apply_bundle(
          payload, payload_length, &entry, &dispatch,
          &shared_library_positive, code_before, code_after,
          failure, sizeof(failure)) == 0) {
    ok = 1;
  }
  if (ok) {
    repro_hcr_windows_notify_code_patch(
        patch_id, changed_function, payload, payload_length,
        entry, dispatch, code_before, code_after);
    if (repro_hcr_send_lifecycle(pipe, patch_id, "hcr/patchApplied", 2) != 0 ||
        repro_hcr_send_patch_applied(pipe, patch_id, changed_function,
                                     entry, dispatch,
                                     shared_library_positive) != 0) {
      ok = 0;
    }
  } else {
    if (failure[0] == '\0') {
      snprintf(failure, sizeof(failure), "windows-direct-patch-failed");
    }
    if (repro_hcr_send_lifecycle(pipe, patch_id, "hcr/patchFailed", 2) != 0 ||
        repro_hcr_send_patch_failure(pipe, patch_id, failure) != 0) {
      goto done;
    }
  }

done:
  free(payload);
  free(payload_hex);
  free(changed_function);
  return ok ? 0 : -1;
}

static DWORD WINAPI repro_hcr_pipe_thread(void *unused) {
  wchar_t pipe_name[128];
  PSECURITY_DESCRIPTOR descriptor = NULL;
  SECURITY_ATTRIBUTES attributes;
  HANDLE pipe = INVALID_HANDLE_VALUE;
  char *hello_ack = NULL;
  char *request = NULL;
  BOOL connected;
  DWORD failure;
  (void)unused;

  ZeroMemory(&attributes, sizeof(attributes));
  descriptor = repro_hcr_current_user_pipe_security();
  if (descriptor == NULL ||
      repro_hcr_pipe_name(pipe_name,
                         sizeof(pipe_name) / sizeof(pipe_name[0])) != 0) {
    repro_hcr_start_status = ERROR_INVALID_SECURITY_DESCR;
    SetEvent(repro_hcr_ready_event);
    if (descriptor != NULL) {
      LocalFree(descriptor);
    }
    return 1;
  }
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  attributes.bInheritHandle = FALSE;
  pipe = CreateNamedPipeW(
      pipe_name,
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, 64 * 1024, 64 * 1024, 5000, &attributes);
  LocalFree(descriptor);
  if (pipe == INVALID_HANDLE_VALUE) {
    repro_hcr_start_status = (LONG)GetLastError();
    SetEvent(repro_hcr_ready_event);
    return 1;
  }

  repro_hcr_start_status = ERROR_SUCCESS;
  SetEvent(repro_hcr_ready_event);
  for (;;) {
    connected = ConnectNamedPipe(pipe, NULL);
    if (!connected) {
      failure = GetLastError();
      if (failure != ERROR_PIPE_CONNECTED) {
        CloseHandle(pipe);
        return 1;
      }
    }
    InterlockedExchange(&repro_hcr_session_open, 1);
    if (repro_hcr_send_hello(pipe) == 0) {
      hello_ack = repro_hcr_read_frame_body(pipe);
      if (hello_ack != NULL &&
          repro_hcr_json_has_string(hello_ack, "kind", "helloAck") &&
          repro_hcr_json_has_string(hello_ack, "supportProfile",
                                    REPRO_HCR_WINDOWS_AGENT_PROFILE)) {
        for (;;) {
          request = repro_hcr_read_frame_body(pipe);
          if (request == NULL) {
            break;
          }
          if (repro_hcr_json_has_string(request, "kind", "patchRequest") &&
              repro_hcr_json_has_string(request, "supportProfile",
                                        REPRO_HCR_WINDOWS_AGENT_PROFILE)) {
            InterlockedIncrement(&repro_hcr_messages_handled);
            (void)repro_hcr_handle_patch_request(pipe, request);
          }
          free(request);
          request = NULL;
        }
      }
    }

    free(hello_ack);
    hello_ack = NULL;
    free(request);
    request = NULL;
    InterlockedExchange(&repro_hcr_session_open, 0);
    FlushFileBuffers(pipe);
    DisconnectNamedPipe(pipe);
  }
}

static int repro_hcr_windows_start(void) {
  HANDLE thread;
  DWORD wait_result;
  if (InterlockedCompareExchange(&repro_hcr_started, 1, 0) != 0) {
    return repro_hcr_start_status == ERROR_SUCCESS ? 0 : -1;
  }
  repro_hcr_ready_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  if (repro_hcr_ready_event == NULL) {
    repro_hcr_start_status = (LONG)GetLastError();
    return -1;
  }
  thread = CreateThread(NULL, 0, repro_hcr_pipe_thread, NULL, 0, NULL);
  if (thread == NULL) {
    repro_hcr_start_status = (LONG)GetLastError();
    CloseHandle(repro_hcr_ready_event);
    repro_hcr_ready_event = NULL;
    return -1;
  }
  CloseHandle(thread);
  wait_result = WaitForSingleObject(repro_hcr_ready_event, 5000);
  CloseHandle(repro_hcr_ready_event);
  repro_hcr_ready_event = NULL;
  if (wait_result != WAIT_OBJECT_0 ||
      repro_hcr_start_status != ERROR_SUCCESS) {
    return -1;
  }
  return 0;
}

/* Loader-only entry used by the HX-W-5 launcher after LoadLibraryW returns. */
__declspec(dllexport) DWORD WINAPI ReproHcrWindowsBootstrap(void *unused) {
  (void)unused;
  return repro_hcr_windows_start() == 0 ? 0u : 1u;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
  (void)reserved;
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(instance);
  }
  return TRUE;
}

int repro_hcr_agent_start_from_env(const char *support_profile,
                                   const repro_hcr_agent_symbol *symbols,
                                   size_t symbol_count) {
  (void)symbols;
  (void)symbol_count;
  if (support_profile == NULL ||
      strcmp(support_profile, REPRO_HCR_WINDOWS_AGENT_PROFILE) != 0) {
    return -1;
  }
  return repro_hcr_windows_start();
}

int repro_hcr_agent_start_polling_from_env(
    const char *support_profile, const repro_hcr_agent_symbol *symbols,
    size_t symbol_count) {
  return repro_hcr_agent_start_from_env(support_profile, symbols, symbol_count);
}

int repro_hcr_agent_poll(void) { return 0; }
int repro_hcr_agent_poll_nonblocking(void) { return 0; }
int repro_hcr_agent_poll_session_open(void) {
  return (int)repro_hcr_session_open;
}
int repro_hcr_agent_poll_messages_handled(void) {
  return (int)repro_hcr_messages_handled;
}

int repro_hcr_agent_set_source_reload_handler(
    repro_hcr_source_reload_handler handler, void *ctx) {
  if (handler == NULL) {
    return -1;
  }
  repro_hcr_reload_handler = handler;
  repro_hcr_reload_context = ctx;
  return 0;
}

int repro_hcr_agent_advertises_source_reload(void) {
  return repro_hcr_reload_handler != NULL;
}

int repro_hcr_agent_sha256_hex(const void *data, size_t len, char *out,
                               size_t out_cap) {
  static const char digits[] = "0123456789abcdef";
  unsigned char digest[REPRO_HCR_SHA256_DIGEST_BYTES];
  size_t index;
  if ((data == NULL && len != 0) || out == NULL || out_cap < 65 ||
      !repro_hcr_sha256_selftest()) {
    return -1;
  }
  repro_hcr_sha256(data, len, digest);
  for (index = 0; index < sizeof(digest); ++index) {
    out[index * 2] = digits[digest[index] >> 4];
    out[index * 2 + 1] = digits[digest[index] & 0x0f];
  }
  out[64] = '\0';
  return 0;
}

const char *repro_hcr_agent_default_support_profile(void) {
  return REPRO_HCR_WINDOWS_AGENT_PROFILE;
}
int repro_hcr_agent_host_supports_direct_patch(void) { return 1; }
int repro_hcr_agent_host_membarrier_sync_core(void) { return 0; }
int repro_hcr_agent_host_quiescence_signal(void) { return 1; }
int repro_hcr_agent_last_publication_tier(void) {
  return (int)repro_hcr_last_publication_tier;
}
int repro_hcr_agent_last_on_stack_threads(void) {
  return repro_hcr_wp_last_report.captured_contexts;
}
