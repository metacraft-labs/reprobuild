/*
 * `dl_iterate_phdr` (design §7.2, HLX-M1's ELF symbol resolution) is declared
 * behind `__USE_GNU` in glibc's <link.h>, and glibc latches its feature macros
 * on the FIRST libc header a translation unit includes — so this must come
 * before every include, including "repro_hcr_agent.h".
 *
 * Guarded on __linux__ so the Apple arm is byte-for-byte the translation unit
 * it was before HLX-M1: on Darwin the macro is never defined and nothing below
 * this line changes.
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include "repro_hcr_agent.h"

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

/*
 * Platform selection.
 *
 * Historically this file carried five `#if defined(__APPLE__) &&
 * defined(__aarch64__)` guards with an inert `#else`. HLX-M0 opens each of them
 * into a three-way selection: the Apple arm64 arm (unchanged), a Linux x86_64
 * arm, and the pre-existing fallback. `REPRO_HCR_TARGET_APPLE_ARM64` is defined
 * exactly when the old condition held, so the Apple behaviour is preserved by
 * construction.
 */
#if defined(__APPLE__) && defined(__aarch64__)
#define REPRO_HCR_TARGET_APPLE_ARM64 1
#elif defined(__linux__) && defined(__x86_64__)
#define REPRO_HCR_TARGET_LINUX_X86_64 1
#endif

#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/arm64/reloc.h>
#include <libkern/OSCacheControl.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
#include "repro_hcr_sha256.h"
#include "repro_hcr_mcr_bridge.h"
#include "repro_hcr_linux_x86_64.h"
#include "repro_hcr_linux_elf_symbols.h"
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif
#endif

/*
 * GDH-M4 needs a digest on EVERY platform, not only the Linux direct-patch
 * arm: the source-reload handler must recompute `snapshotDigest` over the
 * bytes it was handed, and a refusal reason the host cannot evaluate
 * (`digest-mismatch`) would be decoration. The header is guarded and
 * dependency-free, so including it a second time here costs nothing on the
 * Linux arm and adds nothing but the digest on the others.
 */
#include "repro_hcr_sha256.h"

#include <poll.h>

#define REPRO_HCR_AGENT_SOCKET_ENV "REPRO_HCR_AGENT_SOCKET"
#define REPRO_HCR_PROTOCOL_SCHEMA "reprobuild.hcr.agent-protocol.message.v1"
#define REPRO_HCR_TRANSPORT_SCOPE "hcr-agent-protocol"

typedef struct repro_hcr_agent_thread_args {
  char *socket_path;
  char *support_profile;
  repro_hcr_agent_symbol *symbols;
  size_t symbol_count;
} repro_hcr_agent_thread_args;

static repro_hcr_agent_thread_args *repro_hcr_poll_args = NULL;
static int repro_hcr_poll_done = 0;

/*
 * The polled session's own state (GDH-M4).
 *
 * Before GDH-M4 there was none: `repro_hcr_agent_poll` ran the whole
 * connect/handshake/one-patch/close sequence and then latched
 * `repro_hcr_poll_done`. A long-running session with MORE THAN ONE reload
 * could not be served at all, which is why every gate in this campaign that
 * needed two patches in one process was blocked. The fd now outlives a poll.
 */
typedef struct repro_hcr_poll_session {
  int fd;
  int connected;   /* connect + hello attempted */
  int hello_acked; /* the coordinator's helloAck has been read */
  int open;
  int messages;
} repro_hcr_poll_session;

static repro_hcr_poll_session repro_hcr_poll_state = {-1, 0, 0, 0, 0};

static repro_hcr_source_reload_handler repro_hcr_source_reload_fn = NULL;
static void *repro_hcr_source_reload_ctx = NULL;

static void repro_hcr_notify_did_patch(void *entry, void *dispatch_entry,
                                       size_t patch_len) {
#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
  typedef void (*repro_hcr_did_patch_hook)(void *, void *, size_t);
  static int resolved = 0;
  static repro_hcr_did_patch_hook hook = NULL;
  if (!resolved) {
    hook = (repro_hcr_did_patch_hook)dlsym(RTLD_DEFAULT,
                                           "ct_repro_hcr_agent_did_patch");
    resolved = 1;
  }
  const char *debug = getenv("CT_EXC_DEBUG");
  if (debug != NULL && debug[0] != '\0') {
    int log_fd = open("/tmp/ct_bp_debug.log", O_WRONLY | O_CREAT | O_APPEND,
                      0644);
    if (log_fd >= 0) {
      char buf[256];
      int n = snprintf(buf, sizeof(buf),
                       "[hcr-agent-hook] entry=%p dispatch=%p len=%llu found=%d\n",
                       entry, dispatch_entry, (unsigned long long)patch_len,
                       hook != NULL);
      if (n > 0) {
        write(log_fd, buf, (size_t)n);
      }
      close(log_fd);
    }
  }
  if (hook != NULL) {
    hook(entry, dispatch_entry, patch_len);
  }
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
  /* HLX-M7 landed the widened bridge as `repro_hcr_notify_code_patch` below.
   * It carries the whole `CodePatchEvent` — patchId, patchedSymbols, the
   * bundle and the code hashes — and is called from the agent thread, where
   * those strings exist; three untyped words here could not carry any of it.
   * The three-argument hook stays untouched so the Apple arm's behaviour is
   * preserved by construction, and the Linux arm still resolves nothing
   * through `dlsym`: the bridge binds a WEAK undefined symbol at load time, so
   * the agent still imposes no libdl link requirement on its targets. */
  (void)entry;
  (void)dispatch_entry;
  (void)patch_len;
#else
  (void)entry;
  (void)dispatch_entry;
  (void)patch_len;
#endif
}

static void repro_hcr_free_args(repro_hcr_agent_thread_args *args) {
  if (args == NULL) {
    return;
  }
  free(args->socket_path);
  free(args->support_profile);
  if (args->symbols != NULL) {
    for (size_t i = 0; i < args->symbol_count; ++i) {
      free((void *)args->symbols[i].name);
    }
    free(args->symbols);
  }
  free(args);
}

static repro_hcr_agent_thread_args *repro_hcr_make_args(
    const char *socket_path, const char *support_profile,
    const repro_hcr_agent_symbol *symbols, size_t symbol_count) {
  repro_hcr_agent_thread_args *args =
      (repro_hcr_agent_thread_args *)calloc(1, sizeof(*args));
  if (args == NULL) {
    return NULL;
  }
  args->socket_path = strdup(socket_path);
  args->support_profile = strdup(support_profile);
  args->symbol_count = symbol_count;
  if (symbol_count > 0) {
    args->symbols = (repro_hcr_agent_symbol *)calloc(symbol_count,
                                                     sizeof(args->symbols[0]));
    if (args->symbols == NULL) {
      repro_hcr_free_args(args);
      return NULL;
    }
    for (size_t i = 0; i < symbol_count; ++i) {
      args->symbols[i].name = strdup(symbols[i].name);
      args->symbols[i].address = symbols[i].address;
      if (args->symbols[i].name == NULL) {
        repro_hcr_free_args(args);
        return NULL;
      }
    }
  }
  if (args->socket_path == NULL || args->support_profile == NULL) {
    repro_hcr_free_args(args);
    return NULL;
  }
  return args;
}

static int repro_hcr_write_all(int fd, const char *data, size_t len) {
  size_t written = 0;
  while (written < len) {
    ssize_t rc = send(fd, data + written, len - written, 0);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (rc == 0) {
      return -1;
    }
    written += (size_t)rc;
  }
  return 0;
}

static int repro_hcr_read_exact(int fd, char *data, size_t len) {
  size_t read_count = 0;
  while (read_count < len) {
    ssize_t rc = recv(fd, data + read_count, len - read_count, 0);
    if (rc < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    if (rc == 0) {
      return -1;
    }
    read_count += (size_t)rc;
  }
  return 0;
}

static int repro_hcr_read_line(int fd, char *buffer, size_t capacity) {
  if (capacity == 0) {
    return -1;
  }
  size_t len = 0;
  while (len + 1 < capacity) {
    char ch = '\0';
    if (repro_hcr_read_exact(fd, &ch, 1) != 0) {
      return -1;
    }
    if (ch == '\n') {
      if (len > 0 && buffer[len - 1] == '\r') {
        len--;
      }
      buffer[len] = '\0';
      return (int)len;
    }
    buffer[len++] = ch;
  }
  return -1;
}

static char *repro_hcr_read_frame_body(int fd) {
  char line[256];
  if (repro_hcr_read_line(fd, line, sizeof(line)) < 0) {
    return NULL;
  }
  const char *prefix = "content-length:";
  size_t prefix_len = strlen(prefix);
  if (strncasecmp(line, prefix, prefix_len) != 0) {
    return NULL;
  }
  const char *raw_len = line + prefix_len;
  while (*raw_len == ' ' || *raw_len == '\t') {
    raw_len++;
  }
  long content_len = strtol(raw_len, NULL, 10);
  if (content_len < 0 || content_len > 16 * 1024 * 1024) {
    return NULL;
  }
  while (1) {
    int rc = repro_hcr_read_line(fd, line, sizeof(line));
    if (rc < 0) {
      return NULL;
    }
    if (rc == 0) {
      break;
    }
  }
  char *body = (char *)calloc((size_t)content_len + 1, 1);
  if (body == NULL) {
    return NULL;
  }
  if (repro_hcr_read_exact(fd, body, (size_t)content_len) != 0) {
    free(body);
    return NULL;
  }
  body[content_len] = '\0';
  return body;
}

static int repro_hcr_send_json(int fd, const char *json) {
  char header[128];
  int header_len = snprintf(header, sizeof(header), "Content-Length: %zu\r\n\r\n",
                            strlen(json));
  if (header_len <= 0 || (size_t)header_len >= sizeof(header)) {
    return -1;
  }
  if (repro_hcr_write_all(fd, header, (size_t)header_len) != 0) {
    return -1;
  }
  return repro_hcr_write_all(fd, json, strlen(json));
}

static int repro_hcr_connect_with_retry(const char *path) {
  for (int attempt = 0; attempt < 500; ++attempt) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
      return -1;
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
      close(fd);
      return -1;
    }
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
      return fd;
    }
    close(fd);
    usleep(10000);
  }
  return -1;
}

static char *repro_hcr_strdup_range(const char *start, const char *end) {
  if (start == NULL || end == NULL || end < start) {
    return NULL;
  }
  size_t len = (size_t)(end - start);
  char *value = (char *)malloc(len + 1);
  if (value == NULL) {
    return NULL;
  }
  memcpy(value, start, len);
  value[len] = '\0';
  return value;
}

static const char *repro_hcr_skip_ws(const char *p) {
  while (p != NULL && *p != '\0' && isspace((unsigned char)*p)) {
    p++;
  }
  return p;
}

static char *repro_hcr_json_string_after(const char *json, const char *key) {
  const char *p = strstr(json, key);
  if (p == NULL) {
    return NULL;
  }
  p = strchr(p + strlen(key), ':');
  if (p == NULL) {
    return NULL;
  }
  p = repro_hcr_skip_ws(p + 1);
  if (*p != '"') {
    return NULL;
  }
  p++;
  const char *end = p;
  while (*end != '\0') {
    if (*end == '"' && (end == p || end[-1] != '\\')) {
      return repro_hcr_strdup_range(p, end);
    }
    end++;
  }
  return NULL;
}

static char *repro_hcr_json_first_array_string_after(const char *json,
                                                     const char *key) {
  const char *p = strstr(json, key);
  if (p == NULL) {
    return NULL;
  }
  p = strchr(p + strlen(key), '[');
  if (p == NULL) {
    return NULL;
  }
  p = repro_hcr_skip_ws(p + 1);
  if (*p != '"') {
    return NULL;
  }
  p++;
  const char *end = p;
  while (*end != '\0') {
    if (*end == '"' && (end == p || end[-1] != '\\')) {
      return repro_hcr_strdup_range(p, end);
    }
    end++;
  }
  return NULL;
}

static char *repro_hcr_json_payload_field(const char *json,
                                          const char *payload_key,
                                          const char *field_key) {
  const char *payload = strstr(json, payload_key);
  if (payload == NULL) {
    return NULL;
  }
  return repro_hcr_json_string_after(payload, field_key);
}

static int repro_hcr_hex_value(char ch) {
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

static uint8_t *repro_hcr_bytes_from_hex(const char *hex, size_t *out_len) {
  size_t hex_len = strlen(hex);
  if ((hex_len % 2) != 0) {
    return NULL;
  }
  size_t len = hex_len / 2;
  uint8_t *bytes = (uint8_t *)malloc(len == 0 ? 1 : len);
  if (bytes == NULL) {
    return NULL;
  }
  for (size_t i = 0; i < len; ++i) {
    int hi = repro_hcr_hex_value(hex[i * 2]);
    int lo = repro_hcr_hex_value(hex[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      free(bytes);
      return NULL;
    }
    bytes[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = len;
  return bytes;
}

static int repro_hcr_symbol_matches(const char *registered_name,
                                    const char *requested_name) {
  if (registered_name == NULL || requested_name == NULL) {
    return 0;
  }
  if (strcmp(registered_name, requested_name) == 0) {
    return 1;
  }
  if (registered_name[0] == '_' &&
      strcmp(registered_name + 1, requested_name) == 0) {
    return 1;
  }
  if (requested_name[0] == '_' &&
      strcmp(registered_name, requested_name + 1) == 0) {
    return 1;
  }
  return 0;
}

/* HLX-M4 §6.2 step 5: the extent of the function the current request targets,
 * filled in by ELF resolution. 0 means unknown — a registered-table symbol
 * carries no size, and neither does a hand-written asm symbol. */
static uint64_t repro_hcr_lx_target_function_size = 0;

static void *repro_hcr_find_symbol(repro_hcr_agent_thread_args *args,
                                   const char *target_symbol,
                                   const char *changed_function) {
  for (size_t i = 0; i < args->symbol_count; ++i) {
    if (repro_hcr_symbol_matches(args->symbols[i].name, target_symbol) ||
        repro_hcr_symbol_matches(args->symbols[i].name, changed_function)) {
      return args->symbols[i].address;
    }
  }
#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
  if (target_symbol != NULL && target_symbol[0] != '\0') {
    void *resolved = dlsym(RTLD_DEFAULT, target_symbol);
    if (resolved != NULL) {
      return resolved;
    }
  }
  if (changed_function != NULL && changed_function[0] != '\0') {
    void *resolved = dlsym(RTLD_DEFAULT, changed_function);
    if (resolved != NULL) {
      return resolved;
    }
  }
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
  /*
   * HLX-M1: the real ELF pipeline (design §7.2) — `dl_iterate_phdr` load bias
   * plus the object's on-disk `.symtab`/`.strtab`, falling back to
   * `.dynsym`/`.dynstr`, build-id verified before a single symbol byte is
   * trusted, `SHN_XINDEX` expanded, symbol versions resolved, `STT_GNU_IFUNC`
   * refused, and `STB_LOCAL` collisions refused rather than guessed.
   *
   * There is still deliberately NO `dlsym` fallback (design §7.1): `dlsym` sees
   * only `.dynsym`, so it cannot see the `static` and hidden functions this
   * resolver exists to reach, and adding it would silently mask a failure of
   * the real path with a partial answer for exported symbols only.
   *
   * The refusal is recorded rather than collapsed into NULL so the coordinator
   * receives the named cause on the wire instead of a generic "not found".
   */
  {
    uint64_t resolved;
    int refusal = REPRO_HCR_ELF_OK;
    /* Cleared here, not only on success: otherwise a refusal recorded by an
     * earlier request would still be sitting in the global when a later
     * request failed for a different reason, and the wire would carry the
     * wrong named cause. */
    repro_hcr_elf_last_symbol_refusal = REPRO_HCR_ELF_OK;
    /* HLX-M4: capture the resolved function's extent for on-stack detection
     * (§6.2 step 5). 0 means "unknown", which the detector must not read as
     * "nothing is on stack". */
    repro_hcr_lx_target_function_size = 0;
    repro_hcr_elf_last_resolved_size = &repro_hcr_lx_target_function_size;
    if (target_symbol != NULL && target_symbol[0] != '\0') {
      resolved = repro_hcr_elf_resolve_function_address(target_symbol,
                                                        &refusal);
      if (resolved != 0) {
        repro_hcr_elf_last_symbol_refusal = REPRO_HCR_ELF_OK;
        return (void *)(uintptr_t)resolved;
      }
      repro_hcr_elf_last_symbol_refusal = refusal;
    }
    if (changed_function != NULL && changed_function[0] != '\0' &&
        (target_symbol == NULL || strcmp(target_symbol, changed_function) != 0)) {
      resolved = repro_hcr_elf_resolve_function_address(changed_function,
                                                        &refusal);
      if (resolved != 0) {
        repro_hcr_elf_last_symbol_refusal = REPRO_HCR_ELF_OK;
        return (void *)(uintptr_t)resolved;
      }
      repro_hcr_elf_last_symbol_refusal = refusal;
    }
  }
#endif
  return NULL;
}

#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
enum {
  REPRO_HCR_JIT_NOACTION = 0,
  REPRO_HCR_JIT_REGISTER_FN = 1,
  REPRO_HCR_JIT_UNREGISTER_FN = 2
};

struct jit_code_entry {
  struct jit_code_entry *next_entry;
  struct jit_code_entry *prev_entry;
  const char *symfile_addr;
  uint64_t symfile_size;
};

struct jit_descriptor {
  uint32_t version;
  uint32_t action_flag;
  struct jit_code_entry *relevant_entry;
  struct jit_code_entry *first_entry;
};

struct repro_hcr_jit_record {
  struct jit_code_entry entry;
  uint8_t *debug_bytes;
  uint64_t debug_size;
};

typedef struct repro_hcr_jit_registration_evidence {
  uint64_t descriptor_address;
  uint32_t descriptor_version;
  uint32_t action_flag;
  uint64_t relevant_entry_address;
  uint64_t first_entry_address;
  uint64_t entry_address;
  uint64_t entry_next_address;
  uint64_t entry_prev_address;
  uint64_t symfile_address;
  uint64_t symfile_size;
  uint64_t retained_debug_object_address;
  uint64_t retained_debug_object_size;
  uint64_t register_hook_call_count;
  uint32_t rebased_section_ordinal;
  uint64_t rebased_section_address;
  uint64_t rebased_symbol_value;
  int32_t applied_relocations;
  uint32_t success;
} repro_hcr_jit_registration_evidence;

typedef struct repro_hcr_unwind_registration_evidence {
  uint64_t payload_address;
  uint64_t payload_size;
  uint64_t code_address;
  uint64_t code_size;
  uint32_t api;
  uint32_t called;
  int64_t patched_pc_relative;
  uint64_t patched_range;
} repro_hcr_unwind_registration_evidence;

__attribute__((used, visibility("default")))
struct jit_descriptor __jit_debug_descriptor = {
  1,
  REPRO_HCR_JIT_NOACTION,
  0,
  0
};

static pthread_mutex_t repro_hcr_jit_mutex = PTHREAD_MUTEX_INITIALIZER;
static uint64_t repro_hcr_jit_register_hook_calls = 0;

__attribute__((noinline, used, visibility("default")))
void __jit_debug_register_code(void) {
  repro_hcr_jit_register_hook_calls += 1;
  __asm__ volatile("" ::: "memory");
}

static void repro_hcr_fill_jit_evidence(
    struct repro_hcr_jit_record *record,
    repro_hcr_jit_registration_evidence *out) {
  memset(out, 0, sizeof(*out));
  out->descriptor_address = (uint64_t)(uintptr_t)&__jit_debug_descriptor;
  out->descriptor_version = __jit_debug_descriptor.version;
  out->action_flag = __jit_debug_descriptor.action_flag;
  out->relevant_entry_address =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.relevant_entry;
  out->first_entry_address =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.first_entry;
  if (record != 0) {
    out->entry_address = (uint64_t)(uintptr_t)&record->entry;
    out->entry_next_address = (uint64_t)(uintptr_t)record->entry.next_entry;
    out->entry_prev_address = (uint64_t)(uintptr_t)record->entry.prev_entry;
    out->symfile_address = (uint64_t)(uintptr_t)record->entry.symfile_addr;
    out->symfile_size = record->entry.symfile_size;
    out->retained_debug_object_address =
        (uint64_t)(uintptr_t)record->debug_bytes;
    out->retained_debug_object_size = record->debug_size;
  }
  out->register_hook_call_count = repro_hcr_jit_register_hook_calls;
  out->success = 1;
}

typedef struct repro_hcr_symbol_section {
  uint32_t section_ordinal;
  uint64_t symbol_value;
  int found;
} repro_hcr_symbol_section;

static int repro_hcr_find_macho_symbol_section(
    const uint8_t *bytes, uint64_t size, const char *symbol_name,
    repro_hcr_symbol_section *out) {
  if (bytes == 0 || out == 0 || size < sizeof(struct mach_header_64)) {
    return 0;
  }
  memset(out, 0, sizeof(*out));

  const struct mach_header_64 *header =
      (const struct mach_header_64 *)bytes;
  if (header->magic != MH_MAGIC_64 || header->filetype != MH_OBJECT ||
      header->sizeofcmds > size - sizeof(*header)) {
    return 0;
  }

  const uint8_t *cursor = bytes + sizeof(*header);
  const uint8_t *end = cursor + header->sizeofcmds;
  const struct symtab_command *symtab = 0;
  for (uint32_t i = 0; i < header->ncmds; ++i) {
    if ((size_t)(end - cursor) < sizeof(struct load_command)) {
      return -1;
    }
    const struct load_command *command =
        (const struct load_command *)cursor;
    if (command->cmdsize < sizeof(*command) ||
        cursor + command->cmdsize > end) {
      return -1;
    }
    if (command->cmd == LC_SYMTAB) {
      if (command->cmdsize < sizeof(struct symtab_command)) {
        return -1;
      }
      symtab = (const struct symtab_command *)cursor;
    }
    cursor += command->cmdsize;
  }

  if (symtab == 0 || symtab->nsyms == 0 || symtab->strsize == 0) {
    return 0;
  }
  uint64_t symbols_size = (uint64_t)symtab->nsyms * sizeof(struct nlist_64);
  if (symtab->symoff > size || symbols_size > size - symtab->symoff ||
      symtab->stroff > size || symtab->strsize > size - symtab->stroff) {
    return -1;
  }

  const struct nlist_64 *symbols =
      (const struct nlist_64 *)(const void *)(bytes + symtab->symoff);
  const char *strings = (const char *)(const void *)(bytes + symtab->stroff);
  repro_hcr_symbol_section fallback;
  memset(&fallback, 0, sizeof(fallback));
  int fallback_count = 0;

  for (uint32_t i = 0; i < symtab->nsyms; ++i) {
    if ((symbols[i].n_type & N_TYPE) != N_SECT ||
        symbols[i].n_sect == NO_SECT ||
        symbols[i].n_un.n_strx >= symtab->strsize) {
      continue;
    }
    const char *name = strings + symbols[i].n_un.n_strx;
    if (memchr(name, '\0', symtab->strsize - symbols[i].n_un.n_strx) == 0) {
      return -1;
    }
    if (symbol_name != 0 && symbol_name[0] != '\0' &&
        repro_hcr_symbol_matches(name, symbol_name)) {
      out->section_ordinal = symbols[i].n_sect;
      out->symbol_value = symbols[i].n_value;
      out->found = 1;
      return 1;
    }
    if ((symbols[i].n_type & N_EXT) != 0 && name[0] != '\0') {
      fallback.section_ordinal = symbols[i].n_sect;
      fallback.symbol_value = symbols[i].n_value;
      fallback.found = 1;
      fallback_count++;
    }
  }

  if (fallback_count == 1) {
    *out = fallback;
    return 1;
  }
  return 0;
}

static int repro_hcr_rebase_macho_debug_object(
    uint8_t *bytes, uint64_t size, uint64_t code_address,
    const char *symbol_name, repro_hcr_jit_registration_evidence *out) {
  if (bytes == 0 || size < sizeof(struct mach_header_64) || code_address == 0) {
    return 0;
  }

  struct mach_header_64 *header = (struct mach_header_64 *)bytes;
  if (header->magic != MH_MAGIC_64 || header->filetype != MH_OBJECT) {
    return 0;
  }
  if (header->sizeofcmds > size - sizeof(*header)) {
    return -1;
  }

  uint8_t *cursor = bytes + sizeof(*header);
  uint8_t *end = cursor + header->sizeofcmds;
  uint32_t hcr_text_section = 0;
  uint64_t hcr_section_address = code_address;
  uint32_t section_ordinal = 0;
  repro_hcr_symbol_section symbol_section;
  int symbol_section_status = repro_hcr_find_macho_symbol_section(
      bytes, size, symbol_name, &symbol_section);
  if (symbol_section_status < 0) {
    return -1;
  }
  for (uint32_t i = 0; i < header->ncmds; ++i) {
    if ((size_t)(end - cursor) < sizeof(struct load_command)) {
      return -1;
    }
    struct load_command *command = (struct load_command *)cursor;
    if (command->cmdsize < sizeof(*command) || cursor + command->cmdsize > end) {
      return -1;
    }
    if (command->cmd == LC_SEGMENT_64) {
      if (command->cmdsize < sizeof(struct segment_command_64)) {
        return -1;
      }
      struct segment_command_64 *segment =
          (struct segment_command_64 *)cursor;
      size_t required_size = sizeof(*segment) +
                             (size_t)segment->nsects * sizeof(struct section_64);
      if (command->cmdsize < required_size) {
        return -1;
      }
      struct section_64 *section =
          (struct section_64 *)(cursor + sizeof(*segment));
      for (uint32_t section_index = 0; section_index < segment->nsects;
           ++section_index) {
        ++section_ordinal;
        if (symbol_section.found &&
            section_ordinal == symbol_section.section_ordinal) {
          hcr_section_address = code_address - symbol_section.symbol_value;
          section[section_index].addr = hcr_section_address;
          hcr_text_section = section_ordinal;
        } else if (!symbol_section.found &&
            strncmp(section[section_index].sectname, "__text",
                    sizeof(section[section_index].sectname)) == 0 &&
            strncmp(section[section_index].segname, "__HCR",
                    sizeof(section[section_index].segname)) == 0 &&
            section[section_index].size != 0) {
          section[section_index].addr = hcr_section_address;
          hcr_text_section = section_ordinal;
        }
      }
    }
    cursor += command->cmdsize;
  }
  if (hcr_text_section == 0) {
    if (symbol_name != 0 && symbol_name[0] != '\0') {
      return -1;
    }
    return 0;
  }

  cursor = bytes + sizeof(*header);
  int applied_relocations = 0;
  for (uint32_t i = 0; i < header->ncmds; ++i) {
    struct load_command *command = (struct load_command *)cursor;
    if (command->cmd == LC_SEGMENT_64) {
      struct segment_command_64 *segment =
          (struct segment_command_64 *)cursor;
      struct section_64 *section =
          (struct section_64 *)(cursor + sizeof(*segment));
      for (uint32_t section_index = 0; section_index < segment->nsects;
           ++section_index) {
        struct section_64 *current = &section[section_index];
        if (current->nreloc == 0) {
          continue;
        }
        uint64_t reloc_bytes =
            (uint64_t)current->nreloc * sizeof(struct relocation_info);
        if (current->reloff > size || reloc_bytes > size - current->reloff) {
          return -1;
        }
        struct relocation_info *relocations =
            (struct relocation_info *)(bytes + current->reloff);
        for (uint32_t relocation_index = 0;
             relocation_index < current->nreloc; ++relocation_index) {
          struct relocation_info *relocation = &relocations[relocation_index];
          if (relocation->r_extern || relocation->r_pcrel ||
              relocation->r_symbolnum != hcr_text_section ||
              relocation->r_length != 3 ||
              relocation->r_type != ARM64_RELOC_UNSIGNED ||
              relocation->r_address < 0) {
            continue;
          }
          uint64_t patch_offset = (uint64_t)current->offset +
                                  (uint64_t)relocation->r_address;
          if (patch_offset > size || sizeof(uint64_t) > size - patch_offset) {
            return -1;
          }
          uint64_t value = 0;
          memcpy(&value, bytes + patch_offset, sizeof(value));
          value += hcr_section_address;
          memcpy(bytes + patch_offset, &value, sizeof(value));
          ++applied_relocations;
        }
      }
    }
    cursor += command->cmdsize;
  }

  if (out != 0) {
    out->rebased_section_ordinal = hcr_text_section;
    out->rebased_section_address = hcr_section_address;
    out->rebased_symbol_value =
        symbol_section.found ? symbol_section.symbol_value : 0;
    out->applied_relocations = applied_relocations;
  }
  return applied_relocations;
}

static int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    const char *symbol_name,
    repro_hcr_jit_registration_evidence *out) {
  if (bytes == 0 || size == 0 || out == 0) {
    return -1;
  }

  struct repro_hcr_jit_record *record =
      (struct repro_hcr_jit_record *)calloc(1, sizeof(*record));
  if (record == 0) {
    return -2;
  }

  record->debug_bytes = (uint8_t *)malloc((size_t)size);
  if (record->debug_bytes == 0) {
    free(record);
    return -3;
  }
  memcpy(record->debug_bytes, bytes, (size_t)size);
  repro_hcr_jit_registration_evidence rebase_evidence;
  memset(&rebase_evidence, 0, sizeof(rebase_evidence));
  if (repro_hcr_rebase_macho_debug_object(record->debug_bytes, size,
                                          code_address, symbol_name,
                                          &rebase_evidence) < 0) {
    free(record->debug_bytes);
    free(record);
    return -4;
  }
  record->debug_size = size;
  record->entry.symfile_addr = (const char *)record->debug_bytes;
  record->entry.symfile_size = size;

  pthread_mutex_lock(&repro_hcr_jit_mutex);
  record->entry.next_entry = __jit_debug_descriptor.first_entry;
  record->entry.prev_entry = 0;
  if (__jit_debug_descriptor.first_entry != 0) {
    __jit_debug_descriptor.first_entry->prev_entry = &record->entry;
  }
  __jit_debug_descriptor.first_entry = &record->entry;
  __jit_debug_descriptor.relevant_entry = &record->entry;
  __jit_debug_descriptor.action_flag = REPRO_HCR_JIT_REGISTER_FN;
  __jit_debug_register_code();
  repro_hcr_fill_jit_evidence(record, out);
  out->rebased_section_ordinal = rebase_evidence.rebased_section_ordinal;
  out->rebased_section_address = rebase_evidence.rebased_section_address;
  out->rebased_symbol_value = rebase_evidence.rebased_symbol_value;
  out->applied_relocations = rebase_evidence.applied_relocations;
  pthread_mutex_unlock(&repro_hcr_jit_mutex);
  return 0;
}

extern void __register_frame(const void *) __attribute__((weak_import));
extern void __unw_add_dynamic_eh_frame_section(const void *)
    __attribute__((weak_import));

static int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    repro_hcr_unwind_registration_evidence *out) {
  if (bytes == 0 || size == 0 || out == 0) {
    return -1;
  }

  uint8_t *retained = (uint8_t *)malloc((size_t)size);
  if (retained == 0) {
    return -2;
  }
  memcpy(retained, bytes, (size_t)size);

  int64_t patched_pc_relative = 0;
  uint64_t patched_range = code_size;
  if (size >= 0x2c && code_address != 0 && code_size != 0) {
    patched_pc_relative =
        (int64_t)code_address - (int64_t)((uintptr_t)retained + 0x1c);
    memcpy(retained + 0x1c, &patched_pc_relative, sizeof(patched_pc_relative));
    memcpy(retained + 0x24, &patched_range, sizeof(patched_range));
  }

  memset(out, 0, sizeof(*out));
  out->payload_address = (uint64_t)(uintptr_t)retained;
  out->payload_size = size;
  out->code_address = code_address;
  out->code_size = code_size;
  out->patched_pc_relative = patched_pc_relative;
  out->patched_range = patched_range;

  if (__unw_add_dynamic_eh_frame_section != 0) {
    __unw_add_dynamic_eh_frame_section(retained);
    out->api = 1;
    out->called = 1;
    return 0;
  }

  if (__register_frame != 0) {
    __register_frame(retained);
    out->api = 2;
    out->called = 1;
    return 0;
  }

  out->api = 0;
  out->called = 0;
  return -3;
}
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
/*
 * Unwinding and debugger integration on Linux/ELF is HLX-M5, not HLX-M0.
 *
 * The Mach-O path above cannot be translated: it rebases `section_64.addr` and
 * applies `ARM64_RELOC_UNSIGNED`, whereas ELF needs an `ET_REL` symfile with
 * `.text` `sh_addr` set to the live patch address and `R_X86_64_64` applied to
 * `.debug_*`, plus a relocated compiler-generated `.eh_frame` registered
 * through `__register_frame` (whose libgcc-vs-LLVM-libunwind ABI split is
 * `HLX-OQ-4`). Returning -1 here means a Linux patch request that carries a
 * debug-object or unwind-metadata payload fails loudly rather than silently
 * registering nothing.
 */
typedef struct repro_hcr_jit_registration_evidence {
  uint32_t success;
} repro_hcr_jit_registration_evidence;

typedef struct repro_hcr_unwind_registration_evidence {
  uint32_t called;
} repro_hcr_unwind_registration_evidence;

static int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    const char *symbol_name,
    repro_hcr_jit_registration_evidence *out) {
  (void)bytes;
  (void)size;
  (void)code_address;
  (void)symbol_name;
  (void)out;
  return -1;
}

static int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    repro_hcr_unwind_registration_evidence *out) {
  (void)bytes;
  (void)size;
  (void)code_address;
  (void)code_size;
  (void)out;
  return -1;
}
#else
typedef struct repro_hcr_jit_registration_evidence {
  uint32_t success;
} repro_hcr_jit_registration_evidence;

typedef struct repro_hcr_unwind_registration_evidence {
  uint32_t called;
} repro_hcr_unwind_registration_evidence;

static int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    const char *symbol_name,
    repro_hcr_jit_registration_evidence *out) {
  (void)bytes;
  (void)size;
  (void)code_address;
  (void)symbol_name;
  (void)out;
  return -1;
}

static int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    repro_hcr_unwind_registration_evidence *out) {
  (void)bytes;
  (void)size;
  (void)code_address;
  (void)code_size;
  (void)out;
  return -1;
}
#endif

#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
static uint64_t repro_hcr_page_start(uint64_t address, size_t page_size) {
  return address & ~((uint64_t)page_size - 1u);
}

static int repro_hcr_branch_reachable(uint64_t source, uint64_t destination) {
  if ((destination & 0x3u) != 0) {
    return 0;
  }
  int64_t displacement = (int64_t)destination - (int64_t)source;
  if ((displacement % 4) != 0) {
    return 0;
  }
  int64_t words = displacement / 4;
  return words >= -(1ll << 25) && words <= ((1ll << 25) - 1);
}

static void *repro_hcr_map_patch_page_near(uint64_t near_address,
                                           size_t page_size) {
  uint64_t base = repro_hcr_page_start(near_address, page_size);
  size_t max_pages = (128u * 1024u * 1024u) / page_size;
  for (size_t distance = 1; distance <= max_pages; ++distance) {
    for (int direction_index = 0; direction_index < 2; ++direction_index) {
      int64_t direction = direction_index == 0 ? 1 : -1;
      int64_t hint_signed = (int64_t)base + direction * (int64_t)(distance * page_size);
      if (hint_signed <= 0) {
        continue;
      }
      void *mapped = mmap((void *)(uintptr_t)hint_signed, page_size,
                          PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
      if (mapped == MAP_FAILED) {
        continue;
      }
      if (repro_hcr_branch_reachable(near_address, (uint64_t)(uintptr_t)mapped)) {
        return mapped;
      }
      munmap(mapped, page_size);
    }
  }
  return NULL;
}

static uint32_t repro_hcr_branch_word(uint64_t source, uint64_t destination) {
  int64_t displacement = (int64_t)destination - (int64_t)source;
  int64_t words = displacement / 4;
  return 0x14000000u | ((uint32_t)words & 0x03ffffffu);
}

static void repro_hcr_write_u32_le(uint8_t *dst, uint32_t word) {
  dst[0] = (uint8_t)(word & 0xffu);
  dst[1] = (uint8_t)((word >> 8) & 0xffu);
  dst[2] = (uint8_t)((word >> 16) & 0xffu);
  dst[3] = (uint8_t)((word >> 24) & 0xffu);
}

static void *repro_hcr_apply_direct_patch(void *entry, const uint8_t *patch_bytes,
                                          size_t patch_len) {
  if (entry == NULL || patch_bytes == NULL || patch_len == 0) {
    return NULL;
  }
  long page_size_raw = sysconf(_SC_PAGESIZE);
  if (page_size_raw <= 0) {
    return NULL;
  }
  size_t page_size = (size_t)page_size_raw;
  if (patch_len > page_size) {
    return NULL;
  }

  uint64_t entry_address = (uint64_t)(uintptr_t)entry;
  void *patch_page = repro_hcr_map_patch_page_near(entry_address, page_size);
  if (patch_page == NULL) {
    return NULL;
  }
  memcpy(patch_page, patch_bytes, patch_len);
  if (mprotect(patch_page, page_size, PROT_READ | PROT_EXEC) != 0) {
    munmap(patch_page, page_size);
    return NULL;
  }
  sys_icache_invalidate(patch_page, patch_len);

  uint64_t page = repro_hcr_page_start(entry_address, page_size);
  uint32_t branch = repro_hcr_branch_word(entry_address,
                                          (uint64_t)(uintptr_t)patch_page);
  uint8_t branch_bytes[4];
  repro_hcr_write_u32_le(branch_bytes, branch);
  void *page_ptr = (void *)(uintptr_t)page;
  if (mprotect(page_ptr, page_size, PROT_READ | PROT_WRITE) != 0) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page,
                                  (vm_size_t)page_size, TRUE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS ||
        vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)page_size,
                   FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
      return NULL;
    }
  }
  memcpy(entry, branch_bytes, sizeof(branch_bytes));
  if (mprotect(page_ptr, page_size, PROT_READ | PROT_EXEC) != 0 &&
      vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)page_size,
                 FALSE, VM_PROT_READ | VM_PROT_EXECUTE) != KERN_SUCCESS) {
    return NULL;
  }
  sys_icache_invalidate(entry, sizeof(branch_bytes));
  repro_hcr_notify_did_patch(entry, patch_page, patch_len);
  return patch_page;
}

#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)

/* ---------------------------------------------------------------------------
 * Linux x86_64 ELF direct entry patching (HLX-M0).
 *
 * The Mach `vm_protect` max-protection ceiling fallback of the Apple arm above
 * is deliberately NOT translated here (design §5.1): raising a Mach region's
 * maximum protection has no Linux analogue — ELF `PT_LOAD` has `p_flags` and no
 * separate maximum — and the `__HCR` segment scheme that supports it has no ELF
 * counterpart either.
 *
 * Single-threaded scope: HLX-M0 proves a Linux patch path exists. It does not
 * exercise the cross-core and in-window-PC hazards of design §4.4 and §6.1, and
 * nothing here may be reported as safe for a multithreaded target until
 * HLX-M4.
 * ------------------------------------------------------------------------- */

static size_t repro_hcr_lx_page_size(void) {
  long value = sysconf(_SC_PAGESIZE);
  return value > 0 ? (size_t)value : 4096u;
}

static void *repro_hcr_lx_map_anonymous(void *hint, size_t length,
                                        int protection, int extra_flags) {
  int prot = 0;
  void *mapped;
  if ((protection & REPRO_HCR_LX_PROT_READ) != 0) {
    prot |= PROT_READ;
  }
  if ((protection & REPRO_HCR_LX_PROT_WRITE) != 0) {
    prot |= PROT_WRITE;
  }
  if ((protection & REPRO_HCR_LX_PROT_EXEC) != 0) {
    prot |= PROT_EXEC;
  }
  mapped = mmap(hint, length, prot,
                MAP_PRIVATE | MAP_ANONYMOUS | extra_flags, -1, 0);
  return mapped == MAP_FAILED ? NULL : mapped;
}

static int repro_hcr_lx_unmap(void *address, size_t length) {
  return munmap(address, length);
}

/*
 * Thin wrapper: resolve the sled from the runtime-mapped
 * `__patchable_function_entries` section (design §4.2 — never derived from the
 * symbol address) and hand off to the shared implementation in
 * `repro_hcr_linux_x86_64.h`.
 *
 * HLX-M4 added the tier selection around that hand-off, and it is a POLICY, not
 * an optimisation. `HLX-OQ-2` is resolved by requiring tier 2 whenever the
 * target has more than one thread:
 *
 *   - design §6.1 point 4 is a real hazard, not a hypothetical one. The
 *     patchable sled is executable instructions, so an interrupt can leave a
 *     thread's PC at window byte 1..7, and on resume that thread decodes the
 *     tail of our freshly written `E9 rel32` as an instruction. Neither the
 *     aligned store nor `SYNC_CORE` addresses it.
 *   - the ONLY in-process remedy is to read the parked PC out of a
 *     `ucontext_t` and move it, which is tier 2 (§6.2 step 6). `/proc` cannot
 *     supply that PC, measured.
 *
 * So: one thread means no other PC to be caught, and tier 1 is sound. More than
 * one thread means quiesce or refuse. The thread count is read at patch time,
 * not at agent start, because a target can spawn its threads long after the
 * agent's handshake — Godot does exactly that.
 */
/* 0 until the first publication, so a gate can tell "tier 1 was chosen" from
 * "no publication happened". Every path through `repro_hcr_apply_direct_patch`
 * assigns it before the store, so 0 never reaches the `CodePatchEvent`. */
static uint32_t repro_hcr_lx_last_publication_tier = 0;

/* §6.2 step 5: how many parked threads had the target function on their stack
 * at the last publication. -1 means NOT DETERMINED — either the publication was
 * tier 1 (no parked PCs to read) or the symbol carried no extent. It is a
 * distinct value from 0 on purpose. */
static int32_t repro_hcr_lx_on_stack_threads = -1;

static void *repro_hcr_apply_direct_patch(void *entry,
                                          const uint8_t *patch_bytes,
                                          size_t patch_len) {
  uint64_t entry_address;
  uint64_t sled_address;
  void *patch_page;
  int32_t thread_count;
  int quiesced = 0;

  if (entry == NULL) {
    memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return NULL;
  }
  entry_address = (uint64_t)(uintptr_t)entry;
  sled_address = repro_hcr_lx_sled_address_for_entry(entry_address);

  thread_count = repro_hcr_lx_enumerate_tids(
      repro_hcr_lx_quiesce_scratch_a, REPRO_HCR_LX_MAX_QUIESCE_THREADS);
  repro_hcr_lx_last_publication_tier =
      REPRO_HCR_PUBLICATION_TIER_NO_QUIESCENCE;

  /* A failed enumeration is treated as "multithreaded", never as "probably
   * fine": the whole point of the rule is that an unobserved thread is the
   * dangerous case. */
  if (thread_count != 1) {
    int status = repro_hcr_lx_quiesce_begin(0);
    if (status != REPRO_HCR_LX_QUIESCE_OK) {
      /* §6.3: bounded wait, then release all parked threads, write nothing,
       * and report. Nothing has touched target text at this point, so the
       * abort is safe by construction rather than by cleanup. */
      memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
      repro_hcr_lx_last_report.refusal =
          REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED;
      return NULL;
    }
    quiesced = 1;
    repro_hcr_lx_last_publication_tier = REPRO_HCR_PUBLICATION_TIER_QUIESCED;

    /*
     * §6.2 step 5 — on-stack detection, which is only possible with every
     * thread parked and its PC and frames captured. Recorded BEFORE the
     * publication because the answer is about the pre-publication state.
     *
     * `repro_hcr_lx_target_function_size == 0` means the resolver could not
     * give an extent. That is reported as "unknown", not as "nothing on
     * stack": a detector that answers "clear" when it cannot see is exactly
     * the silent self-pass this campaign keeps finding.
     */
    if (repro_hcr_lx_target_function_size > 0) {
      repro_hcr_lx_on_stack_threads = repro_hcr_lx_quiesce_threads_on_stack_in(
          entry_address, entry_address + repro_hcr_lx_target_function_size);
    } else {
      repro_hcr_lx_on_stack_threads = -1;
    }
  } else {
    repro_hcr_lx_on_stack_threads = -1;
  }

  patch_page = repro_hcr_lx_apply_direct_patch_at(entry_address, sled_address,
                                                  patch_bytes, patch_len);

  if (quiesced) {
    (void)repro_hcr_lx_quiesce_release();
  }

  if (patch_page != NULL) {
    repro_hcr_notify_did_patch(entry, patch_page, patch_len);
  }
  return patch_page;
}

/* ---------------------------------------------------------------------------
 * HLX-M7 — emitting the `CodePatchEvent` (design §10.3, protocol §7.2).
 *
 * WHAT THIS FIXES. Measured on the Godot demo before this existed: a recording
 * taken while this provider patched a live engine function had an IDENTICAL SET
 * OF EVENT KINDS to a control recording with no patch. Nothing in the container
 * said the process's text had changed, so a replay would have run the ORIGINAL
 * code's semantics against events the NEW code produced — wrong, and silently
 * so, from the patch point onwards.
 *
 * THE HASHES ARE HASHES. `codeHashBefore` / `codeHashAfter` are SHA-256 over
 * the bytes that actually changed — the published 8-byte window, before and
 * after the store — not over the whole `.text`, which under ASLR is neither
 * stable nor cheap (§10.3). They are computed from
 * `repro_hcr_lx_last_report.original_word` / `.published_word`, which are read
 * out of live target memory by the publication path itself, and the same words
 * are carried in the event's per-site record so a consumer can recompute both
 * digests and check them. `repro_hcr_sha256_selftest` runs first: a hash
 * function that silently computed the wrong thing would place a plausible
 * 32-byte value in a protocol field, which is the one failure mode nothing
 * downstream could detect.
 *
 * TIER. HLX-M4 (quiescence) is not done, so publication is tier 1 and the
 * event's geid is an APPROXIMATE boundary. §10.3 requires that be recorded
 * rather than hidden, so the tier is a field and the recorder prints it.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_code_patch_outcome {
  int attempted;       /* a patch was published, so an event was owed        */
  int bridge_present;  /* libct_interpose was in this process                */
  int bridge_result;   /* 1 recorded, 0 not recording, <0 refused            */
  int hash_selftest;   /* SHA-256 self-test outcome                          */
  unsigned tier;
  unsigned long long symbol_generation;
  char code_hash_before_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
  char code_hash_after_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
  char patch_bundle_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
} repro_hcr_code_patch_outcome;

static repro_hcr_code_patch_outcome repro_hcr_last_code_patch;

static void repro_hcr_hex32(const uint8_t *digest, char *out) {
  static const char digits[] = "0123456789abcdef";
  int i;
  for (i = 0; i < REPRO_HCR_SHA256_DIGEST_BYTES; ++i) {
    out[2 * i] = digits[(digest[i] >> 4) & 0x0F];
    out[2 * i + 1] = digits[digest[i] & 0x0F];
  }
  out[2 * REPRO_HCR_SHA256_DIGEST_BYTES] = '\0';
}

/*
 * Build the NUL-separated, DOUBLE-NUL-terminated symbol blob the note ABI
 * wants. `changed_function` is the name the client asked to be replaced;
 * `target_symbol` is the mangled symbol that was actually resolved in the
 * process. Both are recorded when they differ, because §7.2's `patchedSymbols`
 * has to be usable BY A READER OF THE TRACE, who has the binary and not the
 * client's request.
 */
static size_t repro_hcr_build_symbol_blob(const char *changed_function,
                                          const char *target_symbol,
                                          char *out, size_t out_cap) {
  size_t used = 0;
  const char *names[2];
  int count = 0;
  int i;

  if (changed_function != NULL && changed_function[0] != '\0') {
    names[count++] = changed_function;
  }
  if (target_symbol != NULL && target_symbol[0] != '\0' &&
      (count == 0 || strcmp(target_symbol, names[0]) != 0)) {
    names[count++] = target_symbol;
  }
  if (count == 0 || out_cap < 2) {
    return 0;
  }
  for (i = 0; i < count; ++i) {
    size_t n = strlen(names[i]);
    if (used + n + 2 > out_cap) {
      break;
    }
    memcpy(out + used, names[i], n);
    used += n;
    out[used++] = '\0';
  }
  if (used == 0 || used + 1 > out_cap) {
    return 0;
  }
  out[used] = '\0';   /* the terminating empty name */
  return used;
}

static void repro_hcr_notify_code_patch(const char *patch_id,
                                        const char *changed_function,
                                        const char *target_symbol,
                                        const char *support_profile,
                                        void *entry,
                                        const uint8_t *patch_bytes,
                                        size_t patch_len) {
  ct_repro_hcr_patch_note_v1 note;
  ct_repro_hcr_patch_site_v1 site;
  uint8_t hash_before[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint8_t hash_after[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint8_t hash_bundle[REPRO_HCR_SHA256_DIGEST_BYTES];
  uint8_t word_before[8];
  uint8_t word_after[8];
  char symbol_blob[1024];
  size_t symbol_blob_len;
  size_t i;

  memset(&repro_hcr_last_code_patch, 0, sizeof(repro_hcr_last_code_patch));
  repro_hcr_last_code_patch.attempted = 1;
  /* HLX-M4: the OBSERVED tier, not a literal.
   *
   * This line read `= REPRO_HCR_PUBLICATION_TIER_NO_QUIESCENCE` until
   * 2026-09-11 and it was the SECOND unconditional constant found in this one
   * reporting path — HLX-M7's review already caught `symbolGeneration` and
   * `oldCodeRetained` here. It was caught the same way both of those were: by
   * a real run reporting `publicationTier: 1` for a 33-thread Godot engine
   * that the agent had in fact quiesced. A field that is a constant looks
   * exactly like a field that is measured, right up until the measurement
   * disagrees with it. */
  repro_hcr_last_code_patch.tier = repro_hcr_lx_last_publication_tier;
  repro_hcr_last_code_patch.symbol_generation =
      (unsigned long long)repro_hcr_lx_last_report.generation;

  repro_hcr_last_code_patch.hash_selftest = repro_hcr_sha256_selftest();
  if (!repro_hcr_last_code_patch.hash_selftest) {
    /* Refusing to record beats recording a digest that is not one. The caller
     * turns this into a visible `codePatchEvent` failure in the response. */
    return;
  }

  /* The patched byte range, in the byte order it has in memory. The words are
   * hashed AS BYTES rather than as integers so the digest is over exactly the
   * bytes a reader would find at `windowAddress`, with no endianness step to
   * get wrong on either side. */
  for (i = 0; i < 8; ++i) {
    word_before[i] =
        (uint8_t)((repro_hcr_lx_last_report.original_word >> (8 * i)) & 0xFF);
    word_after[i] =
        (uint8_t)((repro_hcr_lx_last_report.published_word >> (8 * i)) & 0xFF);
  }
  repro_hcr_sha256(word_before, sizeof(word_before), hash_before);
  repro_hcr_sha256(word_after, sizeof(word_after), hash_after);
  repro_hcr_sha256(patch_bytes, patch_len, hash_bundle);

  repro_hcr_hex32(hash_before, repro_hcr_last_code_patch.code_hash_before_hex);
  repro_hcr_hex32(hash_after, repro_hcr_last_code_patch.code_hash_after_hex);
  repro_hcr_hex32(hash_bundle, repro_hcr_last_code_patch.patch_bundle_hex);

  repro_hcr_last_code_patch.bridge_present =
      (ct_repro_hcr_agent_did_patch_v2 != NULL) ? 1 : 0;
  if (!repro_hcr_last_code_patch.bridge_present) {
    /* No `libct_interpose` in this process: nothing is recording, so there is
     * no trace for the event to be missing from. */
    return;
  }

  symbol_blob_len = repro_hcr_build_symbol_blob(changed_function, target_symbol,
                                                symbol_blob,
                                                sizeof(symbol_blob));
  if (symbol_blob_len == 0) {
    return;
  }

  memset(&site, 0, sizeof(site));
  site.entryAddress = (uint64_t)(uintptr_t)entry;
  site.sledAddress = repro_hcr_lx_last_report.sled_address;
  site.windowAddress = repro_hcr_lx_last_report.window_address;
  site.dispatchAddress = repro_hcr_lx_last_report.dispatch_address;
  site.codeWordBefore = repro_hcr_lx_last_report.original_word;
  site.codeWordAfter = repro_hcr_lx_last_report.published_word;
  site.windowLength = REPRO_HCR_LX_WINDOW_BYTES;
  site.generation = (uint32_t)repro_hcr_lx_last_report.generation;

  memset(&note, 0, sizeof(note));
  note.structSize = (uint32_t)sizeof(note);
  note.noteVersion = 1u;
  /* HLX-M4: the tier is now an OBSERVATION of how this publication was made,
   * not a constant. Under tier 2 the geid boundary is exact — no thread was
   * running when the store landed — which is precisely the distinction §10.3
   * requires the event to carry and which `HLX-OQ-9` will need per trace. */
  note.publicationTier = repro_hcr_lx_last_publication_tier;
  note.siteCount = 1u;
  note.patchId = patch_id;
  note.patchedSymbols = symbol_blob;
  note.supportProfile = support_profile;
  note.patchBundle = patch_bytes;
  note.patchBundleLen = (uint64_t)patch_len;
  note.codeHashBefore = hash_before;
  note.codeHashAfter = hash_after;
  note.patchBundleHash = hash_bundle;
  note.sites = &site;

  repro_hcr_last_code_patch.bridge_result =
      ct_repro_hcr_agent_did_patch_v2(&note);
}

#else
static void *repro_hcr_apply_direct_patch(void *entry, const uint8_t *patch_bytes,
                                          size_t patch_len) {
  (void)entry;
  (void)patch_bytes;
  (void)patch_len;
  return NULL;
}
#endif

#if !defined(REPRO_HCR_TARGET_LINUX_X86_64)
/*
 * HLX-M7 is a Linux/x86_64 deliverable. On the Apple arm and the generic
 * fallback the notifier is inert and the `patchApplied` response is BYTE FOR
 * BYTE what it was before HLX-M7 — the campaign's standing rule that no macOS
 * outcome changes is preserved by construction, not by inspection.
 */
static void repro_hcr_notify_code_patch(const char *patch_id,
                                        const char *changed_function,
                                        const char *target_symbol,
                                        const char *support_profile,
                                        void *entry,
                                        const uint8_t *patch_bytes,
                                        size_t patch_len) {
  (void)patch_id;
  (void)changed_function;
  (void)target_symbol;
  (void)support_profile;
  (void)entry;
  (void)patch_bytes;
  (void)patch_len;
}
#endif

#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
/*
 * Capability negotiation is where an unsupported host is refused (design §5.2)
 * and where SYNC_CORE availability is recorded (design §4.4, an explicit HLX-M0
 * deliverable even though a single-threaded gate cannot exercise the hazard).
 * On a host where `PROT_EXEC` cannot be regained the agent does not advertise
 * `direct-patch-injection` at all, and any patch request it then receives is
 * refused before a single byte of target text is touched.
 */
static const char *repro_hcr_capabilities_json_array(void) {
  static char buffer[512];
  const repro_hcr_lx_capabilities *caps = repro_hcr_lx_capability_report();
  snprintf(buffer, sizeof(buffer),
           "\"hcr-agent-protocol\"%s,\"debug-object-payloads\","
           "\"unwind-metadata-payloads\",\"source-generation-metadata\","
           "\"linux-x86_64-elf-direct-hcr\",\"%s\",\"%s\"",
           caps->text_protection_roundtrip ? ",\"direct-patch-injection\"" : "",
           caps->membarrier_sync_core ? "membarrier-sync-core"
                                      : "membarrier-sync-core-unavailable",
           caps->text_protection_roundtrip
               ? "text-protection-roundtrip"
               : "unsupported-host-text-protection-roundtrip");
  return buffer;
}

static char repro_hcr_lx_failure_detail_buffer[160];

/*
 * The named cause, and — for `quiescence-failed` — the tids that caused it.
 *
 * Design §6.3 does not merely require a failure; it requires "a diagnostic
 * naming the unresponsive `tid`s". A bare `quiescence-failed` would tell an
 * operator that a patch did not apply and nothing about which thread to look
 * at, which is the shape of report this campaign has repeatedly called a wrong
 * answer with no diagnostic attached to it.
 */
static const char *repro_hcr_direct_patch_failure_detail(void) {
  const char *name = repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal);
  if (repro_hcr_lx_last_report.refusal != REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED) {
    return name;
  }
  {
    int written = snprintf(repro_hcr_lx_failure_detail_buffer,
                           sizeof(repro_hcr_lx_failure_detail_buffer),
                           "%s (%s; unresponsive tids:", name,
                           repro_hcr_lx_quiesce_status_name(
                               repro_hcr_lx_quiesce.last_status));
    int i;
    for (i = 0; i < repro_hcr_lx_quiesce.unresponsive_count &&
                written > 0 &&
                (size_t)written < sizeof(repro_hcr_lx_failure_detail_buffer) - 16;
         ++i) {
      written += snprintf(repro_hcr_lx_failure_detail_buffer + written,
                          sizeof(repro_hcr_lx_failure_detail_buffer) -
                              (size_t)written,
                          " %d", (int)repro_hcr_lx_quiesce.unresponsive_tids[i]);
    }
    if (repro_hcr_lx_quiesce.unresponsive_count == 0 && written > 0 &&
        (size_t)written < sizeof(repro_hcr_lx_failure_detail_buffer) - 8) {
      written += snprintf(repro_hcr_lx_failure_detail_buffer + written,
                          sizeof(repro_hcr_lx_failure_detail_buffer) -
                              (size_t)written,
                          " none");
    }
    if (written > 0 &&
        (size_t)written < sizeof(repro_hcr_lx_failure_detail_buffer) - 2) {
      repro_hcr_lx_failure_detail_buffer[written] = ')';
      repro_hcr_lx_failure_detail_buffer[written + 1] = '\0';
    }
  }
  return repro_hcr_lx_failure_detail_buffer;
}

/*
 * HLX-M1: the NAMED cause of a symbol-resolution failure. Design §7 makes four
 * distinct things possible — the object's build-id no longer matches the
 * mapped image, the name is an ambiguous `static`, the symbol is an IFUNC
 * whose `st_value` is a resolver, or the function genuinely is not there — and
 * reporting all four as "target symbol was not found in process" would be a
 * wrong answer with no diagnostic attached to it.
 */
static const char *repro_hcr_symbol_failure_detail(void) {
  return repro_hcr_elf_last_symbol_refusal_name();
}
#else
static const char *repro_hcr_capabilities_json_array(void) {
  return "\"hcr-agent-protocol\",\"direct-patch-injection\","
         "\"debug-object-payloads\",\"unwind-metadata-payloads\","
         "\"source-generation-metadata\"";
}

static const char *repro_hcr_direct_patch_failure_detail(void) {
  return "";
}

/* Apple arm64 and the generic fallback keep their previous behaviour: symbol
 * resolution there is the registered table plus `dlsym`, which has no named
 * refusal vocabulary, so the message is unchanged from before HLX-M1. */
static const char *repro_hcr_symbol_failure_detail(void) {
  return "";
}
#endif

/*
 * Design §4.4: `source-reload` is advertised by a host that can APPLY one, and
 * by no other. Registering the handler is therefore the only thing that adds
 * the capability — an agent with no handler advertises nothing and answers
 * `capability-not-negotiated`, which is the behaviour
 * `gdh4_unnegotiated_capability_is_refused_not_ignored` is aimed at. Tying the
 * two together means the advertised list cannot become a claim about a host
 * that has nothing to serve it with.
 */
static const char *repro_hcr_source_reload_capability_suffix(void) {
  if (repro_hcr_source_reload_fn == NULL) {
    return "";
  }
  return ",\"" REPRO_HCR_AGENT_CAPABILITY_SOURCE_RELOAD "\"";
}

static char *repro_hcr_hello_json(const char *support_profile) {
  char *json = (char *)malloc(2048);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 2048,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-hello-1\","
           "\"kind\":\"hello\",\"hello\":{\"supportProfile\":\"%s\","
           "\"agentPid\":%ld,\"capabilities\":[%s%s]}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
           support_profile, (long)getpid(),
           repro_hcr_capabilities_json_array(),
           repro_hcr_source_reload_capability_suffix());
  return json;
}

const char *repro_hcr_agent_default_support_profile(void) {
#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
  return REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64;
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64;
#else
  return "";
#endif
}

static char *repro_hcr_lifecycle_json(const char *patch_id, const char *event,
                                      int sequence) {
  char *json = (char *)malloc(2048);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 2048,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-lifecycle-%d\","
           "\"kind\":\"lifecycleEvent\",\"lifecycleEvent\":{\"patchId\":\"%s\","
           "\"event\":\"%s\",\"sequence\":%d}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, sequence,
           patch_id, event, sequence);
  return json;
}

/*
 * HLX-M7 — the `codePatchEvent` object appended to `patchApplied`.
 *
 * WHY THE RESPONSE CARRIES IT AT ALL, given the event is in the trace. Two
 * reasons, both about being able to check the trace:
 *
 *   1. The coordinator learns whether the event was RECORDED, and if not, why.
 *      Before this, a patch under `ct-mcr record` and a patch outside one were
 *      indistinguishable to the client — which is how a missing CodePatchEvent
 *      would go unnoticed for a second time.
 *   2. It gives a gate a SECOND, INDEPENDENT copy of the digests to compare the
 *      trace's against. A digest that matches here and in the container was
 *      computed once and transported twice; a digest the gate can also
 *      recompute from the patch object it built is a digest, full stop.
 *
 * Empty on every non-Linux arm, so the macOS `patchApplied` message is
 * unchanged byte for byte.
 */
static const char *repro_hcr_code_patch_json_fragment(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  static char buffer[768];
  if (!repro_hcr_last_code_patch.attempted) {
    return "";
  }
  snprintf(buffer, sizeof(buffer),
           ",\"codePatchEvent\":{\"recorded\":%s,\"bridgePresent\":%s,"
           "\"bridgeResult\":%d,\"hashSelfTest\":%s,\"publicationTier\":%u,"
           "\"codeHashBefore\":\"sha256:%s\",\"codeHashAfter\":\"sha256:%s\","
           "\"patchBundle\":\"sha256:%s\",\"claimHeld\":%s}",
           repro_hcr_last_code_patch.bridge_result == 1 ? "true" : "false",
           repro_hcr_last_code_patch.bridge_present ? "true" : "false",
           repro_hcr_last_code_patch.bridge_result,
           repro_hcr_last_code_patch.hash_selftest ? "true" : "false",
           repro_hcr_last_code_patch.tier,
           repro_hcr_last_code_patch.code_hash_before_hex,
           repro_hcr_last_code_patch.code_hash_after_hex,
           repro_hcr_last_code_patch.patch_bundle_hex,
           repro_hcr_lx_last_report.claim_held ? "true" : "false");
  return buffer;
#else
  return "";
#endif
}

static unsigned long long repro_hcr_symbol_generation(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  /* HLX-M7: the REAL generation, from the per-site table the re-patch rule of
   * design §4.5 already maintains. Until now this field was the literal `1`
   * inside the format string below, which looked like generation tracking and
   * was not; anything reading it as evidence of a second reload would have
   * been reading a constant. macOS keeps the literal because that arm has no
   * generation counter to report and HLX-M0 forbids changing its outcomes. */
  return (unsigned long long)repro_hcr_lx_last_report.generation;
#else
  return 1ull;
#endif
}

static char *repro_hcr_patch_applied_json(const char *patch_id,
                                          const char *changed_function,
                                          const char *debug_digest,
                                          const char *unwind_digest,
                                          void *entry,
                                          void *dispatch_entry) {
  char *json = (char *)malloc(8192);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 8192,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-patch-applied-1\","
           "\"kind\":\"patchApplied\",\"patchApplied\":{\"patchId\":\"%s\","
           "\"changedFunctions\":[\"%s\"],\"symbolGeneration\":%llu,"
           "\"debugObjectDigest\":\"%s\",\"unwindMetadataDigest\":\"%s\","
           /*
            * NOT A DIGEST, and it must not look like one.
            *
            * This field read `"blake3-256:c-agent-source-generation-map"` — a
            * fixed string wearing a hash algorithm's prefix, over a
            * `sourceGenerationMap` the C agent never parses. It is the FOURTH
            * constant found masquerading as an observation in this one
            * reporting path, after `symbolGeneration`, `oldCodeRetained` and
            * `publicationTier`, and it was the worst of them: a digest's
            * entire purpose is to be recomputable by the reader, so a forged
            * one is not merely uninformative, it invites a check that will
            * silently agree with nothing. The Nim reference agent computes
            * this honestly (`runtime.nim` `digestSourceGenerationMap`); the C
            * agent cannot, because it never reads the map.
            *
            * Until it does, it says so. The decoder requires a non-empty
            * string and nothing asserts the old value, so this is the honest
            * shape of the same field. Whichever milestone gives the C agent
            * source-generation metadata owns replacing it with a real digest.
            */
           "\"sourceGenerationMapDigest\":\"unavailable:"
           "c-agent-does-not-parse-source-generation-map\","
           "\"entryAddress\":\"0x%llx\","
           "\"dispatchAddress\":\"0x%llx\","
           "\"oldCodeRetained\":true,\"sharedLibraryPositivePath\":false%s}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id,
           changed_function, repro_hcr_symbol_generation(),
           debug_digest == NULL ? "" : debug_digest,
           unwind_digest == NULL ? "" : unwind_digest,
           (unsigned long long)(uintptr_t)entry,
           (unsigned long long)(uintptr_t)dispatch_entry,
           repro_hcr_code_patch_json_fragment());
  return json;
}

/*
 * HLX-M7 §10.1 — `skippedFunctions`.
 *
 * A function whose sled bytes MCR has already claimed is NOT a broken patch and
 * NOT a property of the target's code: the same function is patchable in the
 * same process a moment earlier or later. The claim map's rule ends "…never to
 * a silent skip", and reporting the refusal is the half of that rule this side
 * owns — the client is told which function was skipped and by whom, in a
 * structured field, instead of being handed a message it would have to parse.
 *
 * SCOPE, STATED RATHER THAN IMPLIED. The C agent applies exactly ONE changed
 * function per patch request, so today a claim conflict always skips the whole
 * patch and this rides on `patchFailed`. The `patchApplied`-with-skips shape
 * that a multi-function patch would need is a real gap and is recorded as one;
 * it is not reachable from this agent and is not simulated here.
 */
static const char *repro_hcr_skipped_functions_fragment(
    const char *changed_function) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  static char buffer[512];
  if (repro_hcr_lx_last_report.refusal !=
      REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER) {
    return "";
  }
  snprintf(buffer, sizeof(buffer),
           ",\"skippedFunctions\":[{\"function\":\"%s\","
           "\"reason\":\"claimed-by-recorder\",\"holder\":%u,"
           "\"windowAddress\":\"0x%llx\"}]",
           changed_function == NULL ? "" : changed_function,
           repro_hcr_lx_last_report.claim_holder,
           (unsigned long long)repro_hcr_lx_last_report.window_address);
  return buffer;
#else
  (void)changed_function;
  return "";
#endif
}

static char *repro_hcr_patch_failed_json(const char *patch_id,
                                         const char *changed_function,
                                         const char *message) {
  char *json = (char *)malloc(4096);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 4096,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-patch-failed-1\","
           "\"kind\":\"patchFailed\",\"patchFailed\":{\"patchId\":\"%s\","
           "\"stage\":\"applyDirectPatchRequest\",\"message\":\"%s\"%s}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
           patch_id == NULL ? "" : patch_id, message,
           repro_hcr_skipped_functions_fragment(changed_function));
  return json;
}

static int repro_hcr_send_owned_json(int fd, char *json) {
  if (json == NULL) {
    return -1;
  }
  int rc = repro_hcr_send_json(fd, json);
  free(json);
  return rc;
}

/* ==========================================================================
 * GDH-M4 — the `sourceChanged` / `sourceReloadResult` pair (design §4.3).
 * ========================================================================== */

int repro_hcr_agent_sha256_hex(const void *data, size_t len, char *out,
                               size_t out_cap) {
  uint8_t digest[REPRO_HCR_SHA256_DIGEST_BYTES];
  if (out == NULL || out_cap < 2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1) {
    return -1;
  }
  /* The self-test is not ceremony. A digest function that silently computes
   * the wrong thing would put a plausible 64-hex-digit value in a protocol
   * field that a reader has no way to challenge. */
  if (!repro_hcr_sha256_selftest()) {
    return -1;
  }
  repro_hcr_sha256(data, len, digest);
  {
    /* Spelled locally rather than through `repro_hcr_hex32`, which lives
     * inside the Linux direct-patch arm. The source-reload path is
     * platform-independent and must not drag a platform arm in with it. */
    static const char digits[] = "0123456789abcdef";
    int i;
    for (i = 0; i < REPRO_HCR_SHA256_DIGEST_BYTES; ++i) {
      out[2 * i] = digits[(digest[i] >> 4) & 0x0F];
      out[2 * i + 1] = digits[digest[i] & 0x0F];
    }
    out[2 * REPRO_HCR_SHA256_DIGEST_BYTES] = '\0';
  }
  return 0;
}

int repro_hcr_agent_set_source_reload_handler(
    repro_hcr_source_reload_handler handler, void *ctx) {
  if (handler == NULL) {
    return -1;
  }
  repro_hcr_source_reload_fn = handler;
  repro_hcr_source_reload_ctx = ctx;
  return 0;
}

int repro_hcr_agent_advertises_source_reload(void) {
  return repro_hcr_source_reload_fn != NULL ? 1 : 0;
}

static int repro_hcr_base64_value(char ch) {
  if (ch >= 'A' && ch <= 'Z') { return ch - 'A'; }
  if (ch >= 'a' && ch <= 'z') { return ch - 'a' + 26; }
  if (ch >= '0' && ch <= '9') { return ch - '0' + 52; }
  if (ch == '+') { return 62; }
  if (ch == '/') { return 63; }
  return -1;
}

/* Strict base64: anything that is not an alphabet character, padding, or
 * ASCII whitespace is a decode failure rather than a skipped byte. Silently
 * dropping a character would hand the host content that is not what the
 * coordinator sent, and the digest check further down would then report
 * `digest-mismatch` for a defect that is in this decoder. */
static unsigned char *repro_hcr_base64_decode(const char *text,
                                              size_t *out_len) {
  size_t text_len = strlen(text);
  unsigned char *out = (unsigned char *)malloc(text_len / 4 * 3 + 4);
  size_t used = 0;
  uint32_t accumulator = 0;
  int bits = 0;
  size_t i;
  if (out == NULL) {
    return NULL;
  }
  for (i = 0; i < text_len; ++i) {
    char ch = text[i];
    int value;
    if (ch == '=' ) {
      continue;
    }
    if (ch == '\n' || ch == '\r' || ch == ' ' || ch == '\t') {
      continue;
    }
    value = repro_hcr_base64_value(ch);
    if (value < 0) {
      free(out);
      return NULL;
    }
    accumulator = (accumulator << 6) | (uint32_t)value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[used++] = (unsigned char)((accumulator >> bits) & 0xFF);
    }
  }
  *out_len = used;
  return out;
}

/* Enough escaping for the fields this agent emits: paths, reason strings and
 * digests. A control character or a quote in one of them must not be able to
 * produce a frame the coordinator parses as something else. */
static void repro_hcr_json_escape(const char *value, char *out,
                                  size_t out_cap) {
  size_t used = 0;
  if (out_cap == 0) {
    return;
  }
  if (value == NULL) {
    out[0] = '\0';
    return;
  }
  for (; *value != '\0' && used + 7 < out_cap; ++value) {
    unsigned char ch = (unsigned char)*value;
    if (ch == '"' || ch == '\\') {
      out[used++] = '\\';
      out[used++] = (char)ch;
    } else if (ch < 0x20) {
      used += (size_t)snprintf(out + used, out_cap - used, "\\u%04x", ch);
    } else {
      out[used++] = (char)ch;
    }
  }
  out[used] = '\0';
}

/* The value of an unsigned integer field, or `fallback` when it is absent or
 * not an integer. `found` distinguishes the two, because "absent" and "zero"
 * are different answers and `lineCount: 0` is itself a refusal. */
static unsigned long long repro_hcr_json_uint_after(const char *json,
                                                    const char *key,
                                                    int *found) {
  const char *p = strstr(json, key);
  char *end = NULL;
  unsigned long long value;
  if (found != NULL) {
    *found = 0;
  }
  if (p == NULL) {
    return 0;
  }
  p = strchr(p + strlen(key), ':');
  if (p == NULL) {
    return 0;
  }
  p = repro_hcr_skip_ws(p + 1);
  if (*p < '0' || *p > '9') {
    return 0;
  }
  value = strtoull(p, &end, 10);
  if (end == p) {
    return 0;
  }
  if (found != NULL) {
    *found = 1;
  }
  return value;
}

static const char *repro_hcr_digest_algorithm_end(const char *digest) {
  return digest == NULL ? NULL : strchr(digest, ':');
}

/*
 * `outcome` vs `failed` on the wire — GDH-M8.
 *
 * `HcrSourceReloadOutcome` has had three values since GDH-M4 (design §4.3:
 * `"applied" | "refused" | "failed"`) and this agent only ever emitted two of
 * them: every non-applied answer said `failed`. So a coordinator could not tell
 * a deliberate, clean decline — nothing touched, session healthy — from a host
 * that broke while trying, which is precisely the distinction design §8.1 draws
 * between a failure at steps 1-3 and one at steps 4-6.
 *
 * The mapping is by reason and it is deliberately conservative:
 *
 *   `capability-not-negotiated` stays `failed`, because §4.4 says so in prose
 *     ("the host answers sourceReloadResult{outcome: \"failed\", reason:
 *     \"capability-not-negotiated\"}") — it is a coordinator defect, not a
 *     decline;
 *   `trace-closed` is `failed`, because the session IS degraded: the recorder
 *     closed its trace and the engine is running code the recording stops
 *     short of;
 *   `compile-error` is `failed` for the same reason and it is the one reason in
 *     §5.5 whose place here is NOT obvious, so it is stated. GDH-M8b: a v2 that
 *     parses and analyzes and then fails `GDScriptCompiler` cannot be refused
 *     before the swap — the compiler compiles INTO the live script — so by the
 *     time the host knows, the trace has committed to the new version and the
 *     engine has already taken the broken one. The recorder closes the trace and
 *     puts the engine back; both of those are degradations a coordinator has to
 *     act on. `refused` would say "nothing was touched", and something was;
 *     (GDH-M8b);
 *   everything else in §5.5's vocabulary is `refused` — the notification was
 *     understood and declined, and nothing was touched.
 */
static const char *repro_hcr_outcome_word(const char *reason) {
  if (reason != NULL &&
      (strcmp(reason, REPRO_HCR_RELOAD_REASON_CAPABILITY) == 0 ||
       strcmp(reason, REPRO_HCR_RELOAD_REASON_COMPILE_ERROR) == 0 ||
       strcmp(reason, REPRO_HCR_RELOAD_REASON_TRACE_CLOSED) == 0)) {
    return "failed";
  }
  return "refused";
}

static char *repro_hcr_source_reload_result_json(
    const char *reload_id, const char *source_path, unsigned int generation,
    const repro_hcr_source_reload_outcome *outcome, const char *whole_reason,
    const char *whole_detail) {
  char *json = (char *)malloc(4096);
  char reload_id_esc[256];
  char path_esc[1024];
  char reason_esc[256];
  char detail_esc[512];
  char digest_esc[160];
  int written;
  if (json == NULL) {
    return NULL;
  }
  repro_hcr_json_escape(reload_id, reload_id_esc, sizeof(reload_id_esc));
  repro_hcr_json_escape(source_path, path_esc, sizeof(path_esc));

  if (outcome != NULL && outcome->applied) {
#if defined(REPRO_HCR_GDH4_FALSIFY_HARDCODE_GENERATION)
    /* FALSIFIER ARM 1 (design §3 / GDH-G8): the acknowledged generation
     * becomes the literal 1 — the shipping `symbolGeneration: 1` defect
     * (`repro_hcr_agent.c`'s `patchApplied`) reproduced deliberately.
     *
     * NOTE ON WHAT THIS ARM DOES AND DOES NOT SHOW. The milestone says "the
     * gate must go red on the second notification". It goes red on the FIRST
     * as well, and that is a property of the design rather than a defect in
     * the arm: §4.3 numbered generations so that 1 is never a valid
     * notification value, precisely so that this hardcode is a protocol error
     * instead of a plausible one. An arm that fires everywhere has not been
     * shown to discriminate between one reload and two, so it is paired with
     * ARM 1b below, which does. */
    unsigned int acknowledged = 1u;
#elif defined(REPRO_HCR_GDH4_FALSIFY_LATCH_FIRST_GENERATION)
    /* FALSIFIER ARM 1b (GDH-G8, the discriminating half): every reload is
     * acknowledged with the generation of the FIRST one. A single-notification
     * session is then perfectly correct — which is the point — and only a
     * SECOND reload reveals it. This is the shape the campaign has repeatedly
     * shipped: a value that is coincidentally right for the one case anybody
     * ever exercised. */
    static unsigned int latched = 0u;
    unsigned int acknowledged;
    if (latched == 0u) {
      latched = generation;
    }
    acknowledged = latched;
#else
    unsigned int acknowledged = generation;
#endif
    int i;
    repro_hcr_json_escape(
        outcome->applied_digest == NULL ? "" : outcome->applied_digest,
        digest_esc, sizeof(digest_esc));
    written = snprintf(
        json, 4096,
        "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
        "\"protocolVersion\":2,\"messageId\":\"agent-source-reload-%d\","
        "\"kind\":\"sourceReloadResult\",\"sourceReloadResult\":{"
        "\"reloadId\":\"%s\",\"outcome\":\"applied\",\"reason\":\"\","
        "\"refusedFiles\":[],\"appliedFiles\":[{"
        "\"sourcePath\":\"%s\",\"generation\":%u,\"pathIndex\":%llu,"
        "\"stepIndex\":%llu,\"appliedDigest\":\"%s\",\"appliedLineCount\":%u,"
        "\"unpreservedState\":[",
        REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
        repro_hcr_poll_state.messages, reload_id_esc, path_esc, acknowledged,
        outcome->path_index, outcome->step_index, digest_esc,
        outcome->applied_line_count);
    if (written <= 0 || (size_t)written >= 4096) {
      free(json);
      return NULL;
    }
    for (i = 0; i < outcome->unpreserved_count &&
                i < REPRO_HCR_AGENT_MAX_UNPRESERVED; ++i) {
      char item_esc[128];
      repro_hcr_json_escape(outcome->unpreserved[i], item_esc,
                            sizeof(item_esc));
      written += snprintf(json + written, 4096 - (size_t)written, "%s\"%s\"",
                          i == 0 ? "" : ",", item_esc);
      if (written <= 0 || (size_t)written >= 4096) {
        free(json);
        return NULL;
      }
    }
    written += snprintf(json + written, 4096 - (size_t)written, "]}]}}");
    if (written <= 0 || (size_t)written >= 4096) {
      free(json);
      return NULL;
    }
    return json;
  }

  {
    const char *reason = whole_reason;
    /* GDH-M8: the agent's OWN refusals carry a detail too, and it used to be
     * dropped here — a `digest-mismatch` reached the coordinator with the
     * empty string where "expected sha256:…, the bytes hash to sha256:…" had
     * already been composed. A refusal with no diagnostic attached is the
     * failure shape this campaign keeps finding, so the detail is threaded
     * through rather than recomputed. */
    const char *detail = whole_detail == NULL ? "" : whole_detail;
    if (outcome != NULL && outcome->reason != NULL &&
        outcome->reason[0] != '\0') {
      reason = outcome->reason;
      detail = outcome->detail == NULL ? "" : outcome->detail;
    }
    if (reason == NULL || reason[0] == '\0') {
      /* §4.3 makes `reason` non-empty iff the outcome is not `applied`, and
       * the Nim parser refuses an empty one. A host that refused without
       * saying why would be reporting a wrong answer with no diagnostic
       * attached, which is the failure shape this campaign keeps finding. */
      reason = "unspecified-refusal";
    }
    repro_hcr_json_escape(reason, reason_esc, sizeof(reason_esc));
    repro_hcr_json_escape(detail, detail_esc, sizeof(detail_esc));
    written = snprintf(
        json, 4096,
        "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
        "\"protocolVersion\":2,\"messageId\":\"agent-source-reload-%d\","
        "\"kind\":\"sourceReloadResult\",\"sourceReloadResult\":{"
        "\"reloadId\":\"%s\",\"outcome\":\"%s\",\"reason\":\"%s\","
        "\"appliedFiles\":[],\"refusedFiles\":[{"
        "\"sourcePath\":\"%s\",\"generation\":%u,\"reason\":\"%s\","
        "\"detail\":\"%s\"}]}}",
        REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
        repro_hcr_poll_state.messages, reload_id_esc,
        repro_hcr_outcome_word(reason), reason_esc, path_esc,
        generation, reason_esc, detail_esc);
    if (written <= 0 || (size_t)written >= 4096) {
      free(json);
      return NULL;
    }
    return json;
  }
}

/*
 * Handle one `sourceChanged` frame and answer it. ALWAYS answers: design §4.4
 * is explicit that an ignored notification is worse than a refused session,
 * because a recording in which post-reload steps are attributed to v1 with
 * nothing saying so is a wrong answer with no diagnostic attached.
 */
static int repro_hcr_handle_source_changed(int fd, const char *body) {
  char *reload_id = repro_hcr_json_string_after(body, "\"reloadId\"");
  char *language = repro_hcr_json_string_after(body, "\"language\"");
  const char *files = strstr(body, "\"changedFiles\"");
  char *source_path = NULL;
  char *snapshot_digest = NULL;
  char *line_table_digest = NULL;
  char *content_encoding = NULL;
  char *content_b64 = NULL;
  unsigned char *content = NULL;
  size_t content_len = 0;
  unsigned int generation = 0;
  unsigned int line_count = 0;
  int found = 0;
  const char *refusal = NULL;
  char detail[256];
  char recomputed[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
  char tagged[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 16];
  repro_hcr_source_reload_outcome outcome;
  char *json = NULL;
  int rc = -1;

  detail[0] = '\0';
  memset(&outcome, 0, sizeof(outcome));

  if (reload_id == NULL) {
    /* Without a reloadId there is nothing to correlate an answer to, so this
     * is the one case that cannot be answered. It is reported as a hard
     * session error rather than dropped. */
    free(language);
    return -1;
  }

  if (files == NULL) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "no changedFiles array in notification");
    goto respond;
  }

  source_path = repro_hcr_json_string_after(files, "\"sourcePath\"");
  snapshot_digest = repro_hcr_json_string_after(files, "\"snapshotDigest\"");
  line_table_digest =
      repro_hcr_json_string_after(files, "\"lineTableDigest\"");
  content_encoding = repro_hcr_json_string_after(files, "\"contentEncoding\"");
  generation = (unsigned int)repro_hcr_json_uint_after(files, "\"generation\"",
                                                       &found);
  if (!found) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "changedFiles entry has no generation");
    goto respond;
  }
  line_count = (unsigned int)repro_hcr_json_uint_after(files, "\"lineCount\"",
                                                       &found);
  if (!found) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "changedFiles entry has no lineCount");
    goto respond;
  }

  if (source_path == NULL) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "changedFiles entry has no sourcePath");
    goto respond;
  }

  /* One file per notification is what this agent serves. More than one is
   * REFUSED BY NAME rather than silently reduced to the first — a silent skip
   * is how a reloaded file's text never reaches the trace while every call
   * reports success. */
  {
    const char *first = strstr(files, "\"sourcePath\"");
    const char *second =
        first == NULL ? NULL : strstr(first + 1, "\"sourcePath\"");
    if (second != NULL) {
      refusal = REPRO_HCR_RELOAD_REASON_MULTIPLE_FILES;
      snprintf(detail, sizeof(detail),
               "this host applies one changed file per notification");
      goto respond;
    }
  }

  if (generation < REPRO_HCR_AGENT_FIRST_RELOAD_GENERATION) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail),
             "generation %u is below the first valid reload generation %u",
             generation, REPRO_HCR_AGENT_FIRST_RELOAD_GENERATION);
    goto respond;
  }

  if (content_encoding == NULL || strcmp(content_encoding, "inline") != 0) {
    refusal = REPRO_HCR_RELOAD_REASON_ENCODING;
    snprintf(detail, sizeof(detail),
             "this host accepts only contentEncoding \"inline\"; a path handle "
             "races the next edit");
    goto respond;
  }

  content_b64 = repro_hcr_json_string_after(files, "\"content\"");
  if (content_b64 == NULL) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "inline notification carries no content");
    goto respond;
  }
  content = repro_hcr_base64_decode(content_b64, &content_len);
  if (content == NULL) {
    refusal = REPRO_HCR_RELOAD_REASON_PARSE_ERROR;
    snprintf(detail, sizeof(detail), "content is not valid base64");
    goto respond;
  }

  /* The digest is verified, and a digest in an algorithm this host does not
   * implement is REFUSED rather than skipped. Accepting bytes unverified while
   * a `snapshotDigest` field in the transcript makes them look verified is the
   * exact shape of silent self-pass this campaign exists to keep out. */
  {
    const char *colon = repro_hcr_digest_algorithm_end(snapshot_digest);
    if (snapshot_digest == NULL || colon == NULL) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "snapshotDigest carries no \"<alg>:<hex>\" tag");
      goto respond;
    }
    if ((size_t)(colon - snapshot_digest) != strlen("sha256") ||
        strncmp(snapshot_digest, "sha256", strlen("sha256")) != 0) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "this host implements sha256 only; it cannot verify %s",
               snapshot_digest);
      goto respond;
    }
    if (repro_hcr_agent_sha256_hex(content, content_len, recomputed,
                                   sizeof(recomputed)) != 0) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "the host's sha256 failed its own FIPS self-test");
      goto respond;
    }
#if defined(REPRO_HCR_GDH8_FALSIFY_SKIP_DIGEST_CHECK)
    /* FALSIFIER ARM (gdh8_digest_mismatch_is_refused_before_anything_is_
     * touched): compute the digest, report it, and DO NOT COMPARE IT. This is
     * the shape that matters — the transcript still carries a `snapshotDigest`
     * and an `appliedDigest`, so the bytes LOOK verified, and the host applies
     * content nobody checked.
     *
     * The gate must go red by observing the wrong version's tokens in stdout,
     * i.e. by the engine having reloaded, and not merely by the absence of an
     * error message: an arm that only deleted the error string would still be
     * killed by a harness that read the reply, which is the weaker test. */
    (void)colon;
#else
    if (strcmp(colon + 1, recomputed) != 0) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_MISMATCH;
      snprintf(detail, sizeof(detail), "expected %s, the bytes hash to sha256:%s",
               snapshot_digest, recomputed);
      goto respond;
    }
#endif
    snprintf(tagged, sizeof(tagged), "sha256:%s", recomputed);
  }

  /* The line count is verified too: §5.5 names `line-count-mismatch`, and the
   * count is what the trace writer lays the path's position space out with.
   * Counting it here, rather than trusting the field, is what makes the
   * refusal reachable. */
  {
    unsigned int counted = content_len == 0 ? 0u : 1u;
    size_t i;
    for (i = 0; i + 1 < content_len; ++i) {
      if (content[i] == '\n') {
        counted++;
      }
    }
    if (counted != line_count) {
      refusal = REPRO_HCR_RELOAD_REASON_LINE_COUNT;
      snprintf(detail, sizeof(detail),
               "notification says %u lines, the bytes have %u", line_count,
               counted);
      goto respond;
    }
    outcome.applied_line_count = counted;
  }

  /*
   * And the LINE TABLE, GDH-M8b.
   *
   * `line-table-mismatch` has been in §5.5's vocabulary, in this header and in
   * `protocol.nim`, since the wire was written, with NOTHING ANYWHERE EMITTING
   * IT. `lineTableDigest` is a MANDATORY field — `parseSourceChangedFile`
   * `requireStr`s it — so until now every notification carried a digest no
   * implementation ever compared. That is the exact state `parse-error` was in
   * before GDH-M8, and the consequence there was a wire vocabulary that promised
   * a check nobody ran. It is wired rather than deleted because deleting it
   * would leave the mandatory field behind with even less behind IT.
   *
   * WHAT IT CATCHES, STATED HONESTLY. `snapshotDigest` is verified first and
   * over the same bytes, so this cannot fire on corrupted content — by the time
   * it runs, the bytes are provably the ones the sender hashed. What it catches
   * is a sender whose TWO fields disagree with EACH OTHER: a `lineTableDigest`
   * computed over a different version's text than the `content` it travels with.
   * That is not hypothetical bookkeeping — §4.3 gives the line table its own
   * digest precisely because consumers map breakpoints and steps through it, so
   * a stale one puts v1's line boundaries on v2's source while every other field
   * agrees. This refuses it by name instead of applying it.
   *
   * The algorithm is `sourceLineStartOffsets` / `sourceLineTableDigest`
   * (`src/repro_hcr_agent/source_digest.nim`): offset 0 opens line 1, every byte
   * after a `\n` that is not past the end opens the next line, serialized as
   * decimal offsets joined by `,` and hashed with sha256. Serialized that way
   * exactly so a C host can reproduce it with no integer-encoding convention to
   * get wrong. It is hashed INCREMENTALLY here rather than built into a buffer
   * first: the string is ~11 bytes per line and a host that had to allocate it
   * would have a size limit this check must not have.
   */
  {
    const char *colon = repro_hcr_digest_algorithm_end(line_table_digest);
    if (line_table_digest == NULL || colon == NULL) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "lineTableDigest carries no \"<alg>:<hex>\" tag");
      goto respond;
    }
    if ((size_t)(colon - line_table_digest) != strlen("sha256") ||
        strncmp(line_table_digest, "sha256", strlen("sha256")) != 0) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "this host implements sha256 only; it cannot verify %s",
               line_table_digest);
      goto respond;
    }
    if (!repro_hcr_sha256_selftest()) {
      refusal = REPRO_HCR_RELOAD_REASON_DIGEST_ALGORITHM;
      snprintf(detail, sizeof(detail),
               "the host's sha256 failed its own FIPS self-test");
      goto respond;
    }
    {
      static const char hexdigits[] = "0123456789abcdef";
      repro_hcr_sha256_ctx ctx;
      uint8_t digest[REPRO_HCR_SHA256_DIGEST_BYTES];
      char table_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES + 1];
      char number[24];
      size_t i;
      int n;
      repro_hcr_sha256_init(&ctx);
      if (content_len > 0) {
        repro_hcr_sha256_update(&ctx, "0", 1u);
        for (i = 0; i < content_len; ++i) {
          if (content[i] == '\n' && i + 1 < content_len) {
            n = snprintf(number, sizeof(number), ",%llu",
                         (unsigned long long)(i + 1));
            if (n <= 0 || (size_t)n >= sizeof(number)) {
              refusal = REPRO_HCR_RELOAD_REASON_LINE_TABLE;
              snprintf(detail, sizeof(detail),
                       "a line-start offset in these bytes does not fit this "
                       "host's line-table serializer");
              goto respond;
            }
            repro_hcr_sha256_update(&ctx, number, (size_t)n);
          }
        }
      }
      repro_hcr_sha256_final(&ctx, digest);
      for (i = 0; i < (size_t)REPRO_HCR_SHA256_DIGEST_BYTES; ++i) {
        table_hex[2 * i] = hexdigits[(digest[i] >> 4) & 0xF];
        table_hex[2 * i + 1] = hexdigits[digest[i] & 0xF];
      }
      table_hex[2 * REPRO_HCR_SHA256_DIGEST_BYTES] = '\0';
#if defined(REPRO_HCR_GDH8B_FALSIFY_SKIP_LINE_TABLE_CHECK)
      /* FALSIFIER ARM (gdh8_a_stale_line_table_digest_is_refused_by_name):
       * compute the line-table digest and DO NOT COMPARE IT — which is the
       * state this whole block was written to leave. The notification still
       * carries a `lineTableDigest` and the reply still carries an
       * `appliedDigest`, so the table LOOKS verified, and the host applies a
       * version whose line boundaries a consumer will read out of the wrong
       * text. The gate must go red by observing the reload APPLY — i.e. by
       * v2's own tokens in stdout — and not merely by a missing error
       * string. */
      (void)colon;
      (void)table_hex;
#else
      if (strcmp(colon + 1, table_hex) != 0) {
        refusal = REPRO_HCR_RELOAD_REASON_LINE_TABLE;
        snprintf(detail, sizeof(detail),
                 "expected %s, the bytes' line table hashes to sha256:%s",
                 line_table_digest, table_hex);
        goto respond;
      }
#endif
    }
  }

  if (repro_hcr_source_reload_fn == NULL) {
#if defined(REPRO_HCR_GDH4_FALSIFY_IGNORE_UNKNOWN_KIND)
    /* FALSIFIER ARM: the host IGNORES a notification it cannot serve. Design
     * §4.4 forbids exactly this, and the gate must see the absence of a reply
     * as "no reply", with the transcript, rather than as a timeout.
     *
     * `rc = 0` on purpose: the session stays OPEN and healthy, so what the
     * coordinator observes is silence and not a closed socket. A closed socket
     * would be a different — and more detectable — defect, and an arm that
     * modelled the easier one would not have been shown to catch this one. */
    rc = 0;
    goto cleanup;
#else
    refusal = REPRO_HCR_RELOAD_REASON_CAPABILITY;
    snprintf(detail, sizeof(detail),
             "this host did not advertise \"%s\" in its hello",
             REPRO_HCR_AGENT_CAPABILITY_SOURCE_RELOAD);
    goto respond;
#endif
  }

  {
    repro_hcr_source_changed_file file;
    int handler_rc;
    memset(&file, 0, sizeof(file));
    file.source_path = source_path;
    file.generation = generation;
    file.snapshot_digest = snapshot_digest;
    file.line_table_digest = line_table_digest;
    file.line_count = line_count;
    file.content_encoding = content_encoding;
    file.content = content;
    file.content_length = content_len;

    outcome.applied_digest = tagged;
    handler_rc = repro_hcr_source_reload_fn(repro_hcr_source_reload_ctx,
                                            reload_id,
                                            language == NULL ? "" : language,
                                            &file, &outcome);
    if (handler_rc != 0 && outcome.applied) {
      /* A handler that answered "applied" and then failed is contradicting
       * itself; the refusal wins, because an over-reported apply is the
       * failure mode that puts the wrong version in the trace. */
      outcome.applied = 0;
      if (outcome.reason == NULL || outcome.reason[0] == '\0') {
        outcome.reason = REPRO_HCR_RELOAD_REASON_WRITER_REFUSED;
      }
    }
    if (outcome.applied && outcome.applied_line_count == 0) {
      outcome.applied_line_count = line_count;
    }
    if (outcome.applied &&
        (outcome.applied_digest == NULL || outcome.applied_digest[0] == '\0')) {
      outcome.applied_digest = tagged;
    }
  }

respond:
  json = repro_hcr_source_reload_result_json(
      reload_id, source_path == NULL ? "" : source_path, generation,
      refusal == NULL ? &outcome : NULL, refusal, detail);
  if (json != NULL) {
    rc = repro_hcr_send_json(fd, json);
    free(json);
  }

#if defined(REPRO_HCR_GDH4_FALSIFY_IGNORE_UNKNOWN_KIND)
cleanup:
#endif
  free(reload_id);
  free(language);
  free(source_path);
  free(snapshot_digest);
  free(line_table_digest);
  free(content_encoding);
  free(content_b64);
  free(content);
  return rc;
}

static void repro_hcr_handle_patch_frame(repro_hcr_agent_thread_args *args,
                                         int fd, char *patch);

/*
 * Dispatch one coordinator frame by its `kind`.
 *
 * Before GDH-M4 there was no dispatch at all: the frame after `helloAck` was
 * ASSUMED to be a patch request. A `sourceChanged` sent to such an agent would
 * have been parsed as a patch, found to have no `patchId`, and answered
 * `patchFailed` — a wrong answer wearing the right protocol's clothes.
 */
static int repro_hcr_dispatch_frame(repro_hcr_agent_thread_args *args, int fd,
                                    char *body) {
  char *kind = repro_hcr_json_string_after(body, "\"kind\"");
  int rc = 0;
  if (kind != NULL && strcmp(kind, "sourceChanged") == 0) {
    rc = repro_hcr_handle_source_changed(fd, body);
    free(kind);
    free(body);
    return rc;
  }
  free(kind);
  repro_hcr_handle_patch_frame(args, fd, body);
  return 0;
}

static void *repro_hcr_agent_thread(void *raw_args) {
  repro_hcr_agent_thread_args *args = (repro_hcr_agent_thread_args *)raw_args;
  int fd = repro_hcr_connect_with_retry(args->socket_path);
  if (fd < 0) {
    repro_hcr_free_args(args);
    return NULL;
  }

  if (repro_hcr_send_owned_json(fd, repro_hcr_hello_json(args->support_profile)) != 0) {
    close(fd);
    repro_hcr_free_args(args);
    return NULL;
  }

  char *hello_ack = repro_hcr_read_frame_body(fd);
  free(hello_ack);

  /*
   * GDH-M4: the session loop.
   *
   * This used to be `read one frame, apply, reply, close`. There was no loop
   * anywhere in this function, and `repro_hcr_agent_poll` latched
   * `repro_hcr_poll_done` after calling it once — so a process could be served
   * exactly one patch in its lifetime, and no gate in the GDScript hot-reload
   * campaign that needed a SECOND reload could run at all. The loop ends when
   * the peer closes, which `repro_hcr_read_frame_body` reports as NULL: a
   * named end of session, not a stall.
   */
  for (;;) {
    char *frame = repro_hcr_read_frame_body(fd);
    if (frame == NULL) {
      break;
    }
    if (repro_hcr_dispatch_frame(args, fd, frame) != 0) {
      break;
    }
  }

  close(fd);
  repro_hcr_free_args(args);
  return NULL;
}

static void repro_hcr_handle_patch_frame(repro_hcr_agent_thread_args *args,
                                         int fd, char *patch) {
  char *patch_id = repro_hcr_json_string_after(patch, "\"patchId\"");
  char *changed_function =
      repro_hcr_json_first_array_string_after(patch, "\"changedFunctions\"");
  char *target_symbol =
      repro_hcr_json_first_array_string_after(patch, "\"targetSymbols\"");
  char *patch_hex =
      repro_hcr_json_payload_field(patch, "\"directPatchPayload\"", "\"bytesHex\"");
  char *debug_hex =
      repro_hcr_json_payload_field(patch, "\"debugObjectPayload\"", "\"bytesHex\"");
  char *unwind_hex =
      repro_hcr_json_payload_field(patch, "\"unwindMetadataPayload\"", "\"bytesHex\"");
  char *debug_digest =
      repro_hcr_json_payload_field(patch, "\"debugObjectPayload\"", "\"digest\"");
  char *unwind_digest =
      repro_hcr_json_payload_field(patch, "\"unwindMetadataPayload\"", "\"digest\"");

#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  /* An empty `bytesHex` means the coordinator sent no debug/unwind payload at
   * all, which is not a registration failure. The Apple arm's behaviour is
   * deliberately left untouched: HLX-M0 must not change any macOS outcome, and
   * every macOS gate sends real payloads. HLX-M5 lands ELF `.eh_frame` and GDB
   * JIT registration, at which point a non-empty payload starts succeeding here
   * instead of failing. */
  if (debug_hex != NULL && debug_hex[0] == '\0') {
    free(debug_hex);
    debug_hex = NULL;
  }
  if (unwind_hex != NULL && unwind_hex[0] == '\0') {
    free(unwind_hex);
    unwind_hex = NULL;
  }
#endif

  int ok = 0;
  size_t patch_len = 0;
  size_t debug_len = 0;
  size_t unwind_len = 0;
  uint8_t *patch_bytes = NULL;
  uint8_t *debug_bytes = NULL;
  uint8_t *unwind_bytes = NULL;
  void *dispatch_entry = NULL;
  void *entry = repro_hcr_find_symbol(args, target_symbol, changed_function);
  char failure_detail[192];
  const char *failure_message = "C agent failed to apply direct patch";
  failure_detail[0] = '\0';
  if (patch_id == NULL) {
    failure_message = "patch request is missing patchId";
  } else if (changed_function == NULL) {
    failure_message = "patch request is missing changed function";
  } else if (patch_hex == NULL) {
    failure_message = "patch request is missing direct patch bytes";
  } else if (entry == NULL) {
    const char *symbol_detail = repro_hcr_symbol_failure_detail();
    if (symbol_detail != NULL && symbol_detail[0] != '\0' &&
        strcmp(symbol_detail, "ok") != 0) {
      snprintf(failure_detail, sizeof(failure_detail),
               "symbol resolution refused: %s", symbol_detail);
      failure_message = failure_detail;
    } else {
      failure_message = "target symbol was not found in process";
    }
  }
  if (patch_id != NULL && changed_function != NULL && patch_hex != NULL &&
      entry != NULL) {
    patch_bytes = repro_hcr_bytes_from_hex(patch_hex, &patch_len);
    if (patch_bytes != NULL) {
      repro_hcr_send_owned_json(fd,
        repro_hcr_lifecycle_json(patch_id, "hcr/patchApplying", 1));
      void *patch_entry = repro_hcr_apply_direct_patch(entry, patch_bytes,
                                                       patch_len);
      dispatch_entry = patch_entry;
      ok = dispatch_entry != NULL;
      if (ok) {
        /* HLX-M7 — record the code-version boundary while the words that
         * changed are still in `repro_hcr_lx_last_report`, and BEFORE the
         * lifecycle/patchApplied messages go out, so the response can say
         * whether the trace carries the event.  Nothing after the publishing
         * store may run before this: every event the target emits from here on
         * was produced by the NEW code, and an event recorded late would put
         * the boundary in the wrong place. */
        repro_hcr_notify_code_patch(patch_id, changed_function, target_symbol,
                                    args->support_profile, entry, patch_bytes,
                                    patch_len);
      }
      if (!ok) {
        const char *detail = repro_hcr_direct_patch_failure_detail();
        if (detail != NULL && detail[0] != '\0') {
          snprintf(failure_detail, sizeof(failure_detail),
                   "direct patch refused: %s", detail);
          failure_message = failure_detail;
        } else {
          failure_message = "direct patch branch installation failed";
        }
      }
      if (ok && debug_hex != NULL) {
        debug_bytes = repro_hcr_bytes_from_hex(debug_hex, &debug_len);
        repro_hcr_jit_registration_evidence jit_evidence;
        const char *debug_symbol =
            changed_function != NULL ? changed_function : target_symbol;
        if (debug_bytes == NULL || debug_len == 0 ||
            repro_hcr_register_jit_debug_object(
              debug_bytes, (uint64_t)debug_len,
              (uint64_t)(uintptr_t)dispatch_entry, debug_symbol,
              &jit_evidence) != 0) {
          ok = 0;
          failure_message = "JIT debug object registration failed";
        }
      }
      if (ok && unwind_hex != NULL) {
        unwind_bytes = repro_hcr_bytes_from_hex(unwind_hex, &unwind_len);
        repro_hcr_unwind_registration_evidence unwind_evidence;
        if (unwind_bytes == NULL || unwind_len == 0 ||
            repro_hcr_register_dynamic_eh_frame(
              unwind_bytes, (uint64_t)unwind_len,
              (uint64_t)(uintptr_t)dispatch_entry, (uint64_t)patch_len,
              &unwind_evidence) != 0) {
          ok = 0;
          failure_message = "dynamic unwind registration failed";
        }
      }
    } else {
      failure_message = "direct patch bytes are not valid hex";
    }
  }

  if (ok) {
    repro_hcr_send_owned_json(fd,
      repro_hcr_lifecycle_json(patch_id, "hcr/patchApplied", 2));
    repro_hcr_send_owned_json(fd,
      repro_hcr_patch_applied_json(patch_id, changed_function, debug_digest,
                                   unwind_digest, entry, dispatch_entry));
  } else {
    repro_hcr_send_owned_json(fd,
      repro_hcr_lifecycle_json(patch_id == NULL ? "" : patch_id,
                               "hcr/patchFailed", 2));
    repro_hcr_send_owned_json(fd,
      repro_hcr_patch_failed_json(patch_id, changed_function, failure_message));
  }

  free(patch_bytes);
  free(debug_bytes);
  free(unwind_bytes);
  free(patch_id);
  free(changed_function);
  free(target_symbol);
  free(patch_hex);
  free(debug_hex);
  free(unwind_hex);
  free(debug_digest);
  free(unwind_digest);
  free(patch);
  /* No `close(fd)` and no `repro_hcr_free_args` here any more: the connection
   * and the args outlive a single patch now, and freeing them would have been
   * the one-patch-per-process limit relocated rather than removed. */
}

/* Design §4.4 and §5.2 both require work "at agent start": SYNC_CORE
 * registration, and the RW->RX round-trip probe on a provider-owned scratch
 * mapping. Both happen here, before any patch request can arrive. */
static void repro_hcr_agent_probe_host_once(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  (void)repro_hcr_lx_capability_report();
  /* HLX-M4, design §6.2 step 1: register the quiescence handler at AGENT START,
   * not at patch time. Two reasons, both load-bearing. Installing a handler is
   * a process-wide disposition change; doing it while other threads are already
   * being signalled is a race. And `sigaction` is not on the allocation-free
   * path the protocol requires between signalling and release, so it has to
   * happen before the first `tgkill` can ever be issued. */
  (void)repro_hcr_lx_quiesce_install(0);
#endif
}

int repro_hcr_agent_host_quiescence_signal(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  repro_hcr_agent_probe_host_once();
  return repro_hcr_lx_quiesce.installed ? repro_hcr_lx_quiesce.signo : 0;
#else
  return 0;
#endif
}

int repro_hcr_agent_host_supports_direct_patch(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return repro_hcr_lx_capability_report()->text_protection_roundtrip;
#elif defined(REPRO_HCR_TARGET_APPLE_ARM64)
  return 1;
#else
  return 0;
#endif
}

int repro_hcr_agent_host_membarrier_sync_core(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return repro_hcr_lx_capability_report()->membarrier_sync_core;
#else
  return 0;
#endif
}

int repro_hcr_agent_last_publication_tier(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return (int)repro_hcr_lx_last_publication_tier;
#else
  return 0;
#endif
}

int repro_hcr_agent_last_on_stack_threads(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return (int)repro_hcr_lx_on_stack_threads;
#else
  return -1;
#endif
}

int repro_hcr_agent_start_from_env(const char *support_profile,
                                   const repro_hcr_agent_symbol *symbols,
                                   size_t symbol_count) {
  const char *socket_path;
  repro_hcr_agent_probe_host_once();
  socket_path = getenv(REPRO_HCR_AGENT_SOCKET_ENV);
  if (socket_path == NULL || socket_path[0] == '\0') {
    return 0;
  }
  if (support_profile == NULL || support_profile[0] == '\0') {
    return -1;
  }

  repro_hcr_agent_thread_args *args =
      repro_hcr_make_args(socket_path, support_profile, symbols, symbol_count);
  if (args == NULL) {
    return -1;
  }

  pthread_t thread;
  if (pthread_create(&thread, NULL, repro_hcr_agent_thread, args) != 0) {
    repro_hcr_free_args(args);
    return -1;
  }
  pthread_detach(thread);
  return 0;
}

int repro_hcr_agent_start_polling_from_env(const char *support_profile,
                                           const repro_hcr_agent_symbol *symbols,
                                           size_t symbol_count) {
  const char *socket_path;
  repro_hcr_agent_probe_host_once();
  socket_path = getenv(REPRO_HCR_AGENT_SOCKET_ENV);
  if (socket_path == NULL || socket_path[0] == '\0') {
    return 0;
  }
  if (support_profile == NULL || support_profile[0] == '\0') {
    return -1;
  }
  if (repro_hcr_poll_args != NULL || repro_hcr_poll_done) {
    return 0;
  }
  repro_hcr_poll_args =
      repro_hcr_make_args(socket_path, support_profile, symbols, symbol_count);
  return repro_hcr_poll_args == NULL ? -1 : 0;
}

static int repro_hcr_poll_readable(int fd) {
  struct pollfd pfd;
  int rc;
  pfd.fd = fd;
  pfd.events = POLLIN;
  pfd.revents = 0;
  do {
    rc = poll(&pfd, 1, 0);
  } while (rc < 0 && errno == EINTR);
  if (rc <= 0) {
    return 0;
  }
  /* POLLHUP with no POLLIN means the peer closed with nothing left to read;
   * reporting it as readable lets `read_frame_body` turn it into the same
   * NULL — one end-of-session path, not two. */
  return (pfd.revents & (POLLIN | POLLHUP | POLLERR)) != 0;
}

static void repro_hcr_poll_end_session(void) {
  if (repro_hcr_poll_state.fd >= 0) {
    close(repro_hcr_poll_state.fd);
  }
  repro_hcr_poll_state.fd = -1;
  repro_hcr_poll_state.open = 0;
  if (repro_hcr_poll_args != NULL) {
    repro_hcr_free_args(repro_hcr_poll_args);
    repro_hcr_poll_args = NULL;
  }
  repro_hcr_poll_done = 1;
}

int repro_hcr_agent_poll_session_open(void) {
  return repro_hcr_poll_state.open;
}

int repro_hcr_agent_poll_messages_handled(void) {
  return repro_hcr_poll_state.messages;
}

/*
 * GDH-M4's drain-and-return poll. See the contract on the declaration in
 * `repro_hcr_agent.h`.
 *
 * The first call deliberately BLOCKS for one frame. That is not a leftover:
 * HLX-M0's target (`tests/e2e/hcr-linux-direct/hcr_lx_m0_target.c`) calls
 * `poll()` exactly once and its gate asserts the patched function returns 77
 * by the time it returned. A poll that answered "nothing available yet" would
 * turn that gate red for a reason that has nothing to do with what it
 * measures, so the FIRST frame keeps the old blocking behaviour and only the
 * frames after it are drained non-blocking.
 */
static int repro_hcr_agent_poll_internal(int block_for_first) {
  if (repro_hcr_poll_done && !repro_hcr_poll_state.open) {
    return 0;
  }

  if (!repro_hcr_poll_state.connected) {
    if (repro_hcr_poll_args == NULL) {
      return 0;
    }
    repro_hcr_poll_state.fd =
        repro_hcr_connect_with_retry(repro_hcr_poll_args->socket_path);
    repro_hcr_poll_state.connected = 1;
    if (repro_hcr_poll_state.fd < 0) {
      repro_hcr_poll_end_session();
      return 0;
    }
    if (repro_hcr_send_owned_json(
            repro_hcr_poll_state.fd,
            repro_hcr_hello_json(repro_hcr_poll_args->support_profile)) != 0) {
      repro_hcr_poll_end_session();
      return 0;
    }
  }

  if (!repro_hcr_poll_state.hello_acked) {
    if (!block_for_first && !repro_hcr_poll_readable(repro_hcr_poll_state.fd)) {
      return 0; /* the coordinator has not answered yet; try again next call */
    }
    {
      char *hello_ack = repro_hcr_read_frame_body(repro_hcr_poll_state.fd);
      if (hello_ack == NULL) {
        repro_hcr_poll_end_session();
        return 0;
      }
      free(hello_ack);
    }
    repro_hcr_poll_state.hello_acked = 1;
    repro_hcr_poll_state.open = 1;

    if (block_for_first) {
      /* The first frame, blocking — see the note above. */
      char *frame = repro_hcr_read_frame_body(repro_hcr_poll_state.fd);
      if (frame == NULL) {
        repro_hcr_poll_end_session();
        return 0;
      }
      repro_hcr_poll_state.messages++;
      if (repro_hcr_dispatch_frame(repro_hcr_poll_args,
                                   repro_hcr_poll_state.fd, frame) != 0) {
        repro_hcr_poll_end_session();
        return 0;
      }
#if defined(REPRO_HCR_GDH4_FALSIFY_ONE_SHOT_POLL)
      /* FALSIFIER ARM: the pre-GDH-M4 behaviour restored verbatim — the
       * session is torn down after the FIRST message. A second notification is
       * then never read, and the coordinator sees the socket close. The gate
       * must report that as a named end of session, not as a timeout. */
      repro_hcr_poll_end_session();
      return 0;
#endif
    }
  }

  if (!repro_hcr_poll_state.open) {
    return 0;
  }

  while (repro_hcr_poll_readable(repro_hcr_poll_state.fd)) {
    char *frame = repro_hcr_read_frame_body(repro_hcr_poll_state.fd);
    if (frame == NULL) {
      repro_hcr_poll_end_session();
      return 0;
    }
    repro_hcr_poll_state.messages++;
    if (repro_hcr_dispatch_frame(repro_hcr_poll_args, repro_hcr_poll_state.fd,
                                 frame) != 0) {
      repro_hcr_poll_end_session();
      return 0;
    }
#if defined(REPRO_HCR_GDH4_FALSIFY_ONE_SHOT_POLL)
    repro_hcr_poll_end_session();
    return 0;
#endif
  }
  return 0;
}

int repro_hcr_agent_poll(void) { return repro_hcr_agent_poll_internal(1); }

/*
 * GDH-M5's engine seam calls this, once per frame, and it must never stop the
 * frame.
 *
 * `repro_hcr_agent_poll` blocks for the FIRST frame so HLX-M0's one-shot
 * target keeps working. An engine cannot afford that: its first safe point
 * would freeze the main loop until a coordinator chose to send something, and
 * a driver that waits for tick 8 before reloading would deadlock against an
 * engine stopped at tick 0. That was not hypothetical — it is why this
 * function exists. Here the handshake itself is incremental: connect and
 * `hello` on the first call, `helloAck` whenever it becomes readable, then
 * drain whatever is already there.
 */
int repro_hcr_agent_poll_nonblocking(void) {
  return repro_hcr_agent_poll_internal(0);
}
