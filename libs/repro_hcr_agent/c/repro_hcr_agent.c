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
#elif (defined(_WIN32) || defined(_WIN64) || defined(__CYGWIN__)) && (defined(__x86_64__) || defined(_M_X64))
#define REPRO_HCR_TARGET_WINDOWS_X86_64 1
#endif

#define REPRO_HCR_AGENT_CAPABILITY_UNSUPPORTED_CLANG_FCF_PROTECTION \
  "unsupported-target-clang-fcf-protection"

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
/* HLX-M5. Must follow `repro_hcr_linux_x86_64.h`: the retained `.eh_frame`
 * copy is placed with that header's `repro_hcr_lx_map_patch_page_near`, for the
 * arithmetic reason the unwind header's PLACEMENT note gives. This is also the
 * translation unit that owns `__jit_debug_descriptor` and
 * `__jit_debug_register_code` on Linux (design §8.3). */
#include "repro_hcr_linux_unwind.h"
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
#include "repro_hcr_dispatch_table.c"

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

#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
/* HLX-M4 §6.2 step 5: the extent of the function the current request targets,
 * filled in by ELF resolution. 0 means unknown — a registered-table symbol
 * carries no size, and neither does a hand-written asm symbol. */
static uint64_t repro_hcr_lx_target_function_size = 0;
#endif

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

int repro_hcr_register_jit_debug_object(
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

int repro_hcr_register_dynamic_eh_frame(
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

extern void __deregister_frame(const void *) __attribute__((weak_import));
extern void __unw_remove_dynamic_eh_frame_section(const void *)
    __attribute__((weak_import));

int repro_hcr_unregister_dynamic_eh_frame(uint64_t payload_address) {
  if (payload_address == 0) {
    return -1;
  }
  const void *ptr = (const void *)(uintptr_t)payload_address;
  if (__unw_remove_dynamic_eh_frame_section != 0) {
    __unw_remove_dynamic_eh_frame_section(ptr);
  } else if (__deregister_frame != 0) {
    __deregister_frame(ptr);
  } else {
    return -2;
  }
  free((void *)ptr);
  return 0;
}

int repro_hcr_unregister_jit_debug_object(uint64_t entry_address) {
  if (entry_address == 0) {
    return -1;
  }
  pthread_mutex_lock(&repro_hcr_jit_mutex);
  struct jit_code_entry *target =
      (struct jit_code_entry *)(uintptr_t)entry_address;

  if (target->prev_entry != 0) {
    target->prev_entry->next_entry = target->next_entry;
  } else if (__jit_debug_descriptor.first_entry == target) {
    __jit_debug_descriptor.first_entry = target->next_entry;
  }
  if (target->next_entry != 0) {
    target->next_entry->prev_entry = target->prev_entry;
  }
  target->prev_entry = 0;
  target->next_entry = 0;

  __jit_debug_descriptor.relevant_entry = target;
  __jit_debug_descriptor.action_flag = REPRO_HCR_JIT_UNREGISTER_FN;
  __jit_debug_register_code();
  __jit_debug_descriptor.relevant_entry = 0;
  __jit_debug_descriptor.action_flag = REPRO_HCR_JIT_NOACTION;

  struct repro_hcr_jit_record *record =
      (struct repro_hcr_jit_record *)target;
  if (record->debug_bytes != 0) {
    free(record->debug_bytes);
    record->debug_bytes = 0;
  }
  free(record);
  pthread_mutex_unlock(&repro_hcr_jit_mutex);
  return 0;
}
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
/*
 * HLX-M5 — unwinding and debugger integration on Linux/ELF.
 *
 * The Mach-O path above is not translated; it is replaced. That arm rebases
 * `section_64.addr`, applies `ARM64_RELOC_UNSIGNED`, and patches a hardcoded
 * 64-byte `.eh_frame` template at fixed offsets 0x1c/0x24. The ELF arm rebases
 * an `ET_REL` symfile's section addresses, applies `R_X86_64_64` (and the other
 * relocation types the compiler emits into `.debug_*`), and relocates the
 * COMPILER-GENERATED `.eh_frame`'s FDE `initial_location` — no template, at
 * offsets found by walking the CIE rather than assumed. The mechanics live in
 * `repro_hcr_linux_unwind.h`; what follows is the agent's evidence surface over
 * them, and the bookkeeping that lets rollback undo what was registered.
 *
 * `HLX-OQ-4` (the libgcc versus LLVM libunwind `__register_frame` ABI) is
 * resolved there by probe-and-verify, not by identifying the library.
 */
int repro_hcr_register_jit_debug_object(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    const char *symbol_name,
    repro_hcr_jit_registration_evidence *out) {
  repro_hcr_lxu_symfile_evidence symfile;
  uint64_t entry_address = 0;
  int rc;

  if (bytes == NULL || size == 0 || out == NULL) {
    return -1;
  }
  memset(out, 0, sizeof(*out));
  rc = repro_hcr_lxu_register_jit_symfile(bytes, size, code_address,
                                          symbol_name, &entry_address,
                                          &symfile);
  if (rc != REPRO_HCR_LXU_OK) {
    return rc;
  }

  out->descriptor_address = (uint64_t)(uintptr_t)&__jit_debug_descriptor;
  out->descriptor_version = __jit_debug_descriptor.version;
  out->action_flag = __jit_debug_descriptor.action_flag;
  out->relevant_entry_address =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.relevant_entry;
  out->first_entry_address =
      (uint64_t)(uintptr_t)__jit_debug_descriptor.first_entry;
  out->entry_address = entry_address;
  {
    const struct repro_hcr_lxu_jit_code_entry *entry =
        (const struct repro_hcr_lxu_jit_code_entry *)(uintptr_t)entry_address;
    out->entry_next_address = (uint64_t)(uintptr_t)entry->next_entry;
    out->entry_prev_address = (uint64_t)(uintptr_t)entry->prev_entry;
    out->symfile_address = (uint64_t)(uintptr_t)entry->symfile_addr;
    out->symfile_size = entry->symfile_size;
    out->retained_debug_object_address = out->symfile_address;
    out->retained_debug_object_size = entry->symfile_size;
  }
  out->register_hook_call_count = repro_hcr_lxu_jit_register_calls;
  out->rebased_section_ordinal = symfile.text_section_index;
  out->rebased_section_address = symfile.text_section_address;
  out->rebased_symbol_value = symfile.symbol_value;
  out->applied_relocations = symfile.applied_relocations;
  out->success = 1;

  /* Hand the entry to the transaction so rollback can take it back out of the
   * descriptor list (design §11). A registration nobody recorded is one
   * rollback cannot undo. */
  (void)repro_hcr_lx_txn_record_registration(code_address, entry_address, 0);
  return 0;
}

int repro_hcr_register_dynamic_eh_frame(
    const uint8_t *bytes,
    uint64_t size,
    uint64_t code_address,
    uint64_t code_size,
    repro_hcr_unwind_registration_evidence *out) {
  uint64_t payload_address = 0;
  uint32_t fde_count = 0;
  int convention = REPRO_HCR_LXU_CONVENTION_UNKNOWN;
  int rc;

  if (bytes == NULL || size == 0 || out == NULL) {
    return -1;
  }
  memset(out, 0, sizeof(*out));
  rc = repro_hcr_lxu_register_eh_frame(bytes, size, code_address, code_size,
                                       &payload_address, &fde_count,
                                       &convention);
  if (rc != REPRO_HCR_LXU_OK) {
    return rc;
  }

  out->payload_address = payload_address;
  out->payload_size = size;
  out->code_address = code_address;
  out->code_size = code_size;
  /*
   * `api` keeps the macOS arm's vocabulary so one reader serves both: 1 was
   * `__unw_add_dynamic_eh_frame_section` and 2 was `__register_frame`. On
   * Linux the first branch is REMOVED (design §8.2 deliverable), so this is
   * always 2 — and the interesting question, which ARGUMENT that function
   * wanted, is reported by `patched_range`'s companion below rather than
   * conflated into this field.
   */
  out->api = 2;
  out->called = 1;
  out->patched_pc_relative = (int64_t)code_address - (int64_t)payload_address;
  out->patched_range = code_size;
  (void)fde_count;
  (void)convention;

  (void)repro_hcr_lx_txn_record_registration(code_address, 0, payload_address);
  return 0;
}

int repro_hcr_unregister_dynamic_eh_frame(uint64_t payload_address) {
  return repro_hcr_lxu_unregister_eh_frame(payload_address);
}

int repro_hcr_unregister_jit_debug_object(uint64_t entry_address) {
  return repro_hcr_lxu_unregister_jit_symfile(entry_address);
}

#else
int repro_hcr_register_jit_debug_object(
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

int repro_hcr_register_dynamic_eh_frame(
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

int repro_hcr_unregister_dynamic_eh_frame(uint64_t payload_address) {
  (void)payload_address;
  return -1;
}

int repro_hcr_unregister_jit_debug_object(uint64_t entry_address) {
  (void)entry_address;
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

/* ---------------------------------------------------------------------------
 * HLX-M3 — retention evidence for the Apple arm (design §11.1 defect 1).
 *
 * `"oldCodeRetained":true` was a hardcoded literal in
 * `repro_hcr_patch_applied_json`, and the design document's objection to it was
 * precise: this arm saved no original bytes anywhere, so the field asserted an
 * invariant instead of observing one. Since `session.nim:197` REJECTS a
 * `false`, the literal was the only reason the handshake completed.
 *
 * The fix is not to print `false` — the old code genuinely is retained on this
 * arm, because the original body is in-place text that is never freed and the
 * patch page is never unmapped once published. What was missing was the
 * RECORD. These two statics are it: the original 32-bit instruction at the
 * entry, saved before the branch is stored, and the retained patch page. The
 * reporting path now computes the field from them, the same shape the Nim
 * runtime uses at `runtime.nim:126` (`retainedRegionAddresses.len > 0`).
 *
 * Unverified on macOS by this milestone's author: HLX-M3's gates run on Linux
 * x86_64. The change is additive — nothing existing reads these — and the
 * reported value for a successful patch is the same `true` the literal
 * produced, so no macOS outcome changes unless the save itself fails, which is
 * exactly when the old literal was lying.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_APPLE_MAX_RETAINED 128

typedef struct repro_hcr_apple_retained_site {
  int used;
  uint64_t entry_address;
  uint32_t original_word;   /* the rollback target, saved before the store */
  uint64_t patch_page;
  uint64_t patch_page_len;
} repro_hcr_apple_retained_site;

static repro_hcr_apple_retained_site
    repro_hcr_apple_retained[REPRO_HCR_APPLE_MAX_RETAINED];
static int repro_hcr_apple_retained_count = 0;
/* Retention observed for the MOST RECENT publication, which is what the
 * response is about. A cumulative count would report `true` for a patch that
 * retained nothing as long as an earlier one had. */
static int repro_hcr_apple_last_retained = 0;
/* HLX-M3 defect 2: set when both protection restores failed and the target's
 * text page was therefore left writable. Recorded rather than reported as a
 * total failure, because by then the trampoline is live. */
static int repro_hcr_apple_text_left_writable = 0;

static int repro_hcr_apple_retain(uint64_t entry_address,
                                  uint32_t original_word,
                                  void *patch_page, size_t patch_page_len) {
  int i;
  for (i = 0; i < repro_hcr_apple_retained_count; ++i) {
    if (repro_hcr_apple_retained[i].used &&
        repro_hcr_apple_retained[i].entry_address == entry_address) {
      /* Re-patch: the ORIGINAL word stays the original (design §4.5), only the
       * newest body is recorded. The superseded page is not unmapped. */
      repro_hcr_apple_retained[i].patch_page = (uint64_t)(uintptr_t)patch_page;
      repro_hcr_apple_retained[i].patch_page_len = (uint64_t)patch_page_len;
      return 1;
    }
  }
  if (repro_hcr_apple_retained_count >= REPRO_HCR_APPLE_MAX_RETAINED) {
    return 0;
  }
  i = repro_hcr_apple_retained_count++;
  repro_hcr_apple_retained[i].used = 1;
  repro_hcr_apple_retained[i].entry_address = entry_address;
  repro_hcr_apple_retained[i].original_word = original_word;
  repro_hcr_apple_retained[i].patch_page = (uint64_t)(uintptr_t)patch_page;
  repro_hcr_apple_retained[i].patch_page_len = (uint64_t)patch_page_len;
  return 1;
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
  void *page_ptr = (void *)(uintptr_t)page;
  /* Mach thread quiescence on macOS (HX-D-2 / HX-S-6):
   * macOS lacks membarrier(MEMBARRIER_CMD_PRIVATE_EXPEDITED_SYNC_CORE).
   * For multi-threaded targets, quiescence via Mach task_threads + thread_suspend
   * (excluding the calling thread) is mandatory before writing cross-modifying code.
   * Resuming from Mach thread suspension forces kernel context synchronization (ERET)
   * on all remote threads.
   */
  mach_port_t self_thread = mach_thread_self();
  thread_act_array_t thread_list = NULL;
  mach_msg_type_number_t thread_count = 0;
  kern_return_t kr_threads = task_threads(mach_task_self(), &thread_list, &thread_count);
  const char *suppress_quiesce_env = getenv("REPRO_HCR_SUPPRESS_QUIESCENCE");
  int suppress_quiesce = (suppress_quiesce_env != NULL && strcmp(suppress_quiesce_env, "1") == 0);
  int quiesced = 0;
  if (!suppress_quiesce && kr_threads == KERN_SUCCESS && thread_count > 1) {
    for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
      if (thread_list[i] != self_thread) {
        thread_suspend(thread_list[i]);
      }
    }
    quiesced = 1;
  }

  /* Make text page writable. Shipped Mach-O binaries have maxprot = r-x (0x5).
   * Standard mprotect and vm_protect without VM_PROT_COPY fail with KERN_PROTECTION_FAILURE.
   * VM_PROT_COPY breaks copy-on-write and allocates a private writable page.
   */
  int page_writable = 0;
  if (mprotect(page_ptr, page_size, PROT_READ | PROT_WRITE) == 0) {
    page_writable = 1;
  } else {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page,
                                  (vm_size_t)page_size, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) {
      page_writable = 1;
    }
  }

  if (!page_writable) {
    if (quiesced) {
      for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
        if (thread_list[i] != self_thread) {
          thread_resume(thread_list[i]);
        }
      }
    }
    if (kr_threads == KERN_SUCCESS) {
      for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
        mach_port_deallocate(mach_task_self(), thread_list[i]);
      }
      vm_deallocate(mach_task_self(), (vm_address_t)thread_list,
                    thread_count * sizeof(thread_act_t));
    }
    mach_port_deallocate(mach_task_self(), self_thread);
    /*
     * HLX-M3, design §11.1 defect 3 — KEEP THIS `munmap`.
     *
     * This return happens BEFORE any write, so it is a clean abort and not a
     * partial patch; the defect was that the patch page mapped and protected
     * above was never released, leaking a page per refused patch. It was fixed
     * by `ed4046f5b` before HLX-M3 opened, which is why the milestone's
     * deliverable is ticked as verified-already-fixed rather than re-fixed.
     * The comment is here so a future rewrite of this cleanup block does not
     * silently drop it again: every pre-store return on this arm must unmap
     * the page, and every post-store return must NOT (a live trampoline points
     * into it).
     */
    munmap(patch_page, page_size);
    return NULL;
  }

  /* Atomically write the 32-bit branch instruction (B imm26).
   * REPRO_HCR_SUPPRESS_PUBLICATION_STORE allows testing falsifier arms.
   */
  const char *suppress_store_env = getenv("REPRO_HCR_SUPPRESS_PUBLICATION_STORE");
  int suppress_store = (suppress_store_env != NULL && strcmp(suppress_store_env, "1") == 0);
  /* HLX-M3, design §11.2: read and save the original aligned word BEFORE the
   * store. This is the whole of what rollback needs, and its absence is what
   * made `oldCodeRetained` a literal on this arm. */
  uint32_t original_word = *(volatile uint32_t *)entry;
  repro_hcr_apple_last_retained =
      repro_hcr_apple_retain((uint64_t)(uintptr_t)entry, original_word,
                             patch_page, page_size);
  if (!suppress_store) {
    *(volatile uint32_t *)entry = branch;
  }

  /* Restore RX permissions. */
  int restored = 0;
  if (mprotect(page_ptr, page_size, PROT_READ | PROT_EXEC) == 0) {
    restored = 1;
  } else if (vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)page_size,
                        FALSE, VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
    restored = 1;
  }

  /* Invalidate instruction cache unless suppressed for testing. */
  const char *suppress_icache_env = getenv("REPRO_HCR_SUPPRESS_ICACHE_INVALIDATE");
  int suppress_icache = (suppress_icache_env != NULL && strcmp(suppress_icache_env, "1") == 0);
  if (!suppress_icache) {
    sys_icache_invalidate(entry, sizeof(uint32_t));
  }

  /* Resume threads after publication and cache maintenance. */
  if (quiesced) {
    for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
      if (thread_list[i] != self_thread) {
        thread_resume(thread_list[i]);
      }
    }
  }
  if (kr_threads == KERN_SUCCESS) {
    for (mach_msg_type_number_t i = 0; i < thread_count; ++i) {
      mach_port_deallocate(mach_task_self(), thread_list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)thread_list,
                  thread_count * sizeof(thread_act_t));
  }
  mach_port_deallocate(mach_task_self(), self_thread);

  /*
   * HLX-M3, design §11.1 defect 2.
   *
   * This read `if (!restored) { return NULL; }`, and NULL is reported to the
   * coordinator as total failure ("direct patch branch installation failed").
   * But the branch above is ALREADY LIVE by the time control gets here: the
   * caller was told the reload had failed for a process that was in fact
   * running patched code — the mirror image of the defect this whole milestone
   * is about. The honest report is success plus a recorded degradation, which
   * is what the Linux arm has always done with `text_left_writable`.
   *
   * The second half of the defect is that this path is reached ONLY when both
   * the `mprotect(RX)` and the `vm_protect(RX)` restore failed, which also
   * leaves the target's text page WRITABLE. Both restores are retried here,
   * now that the other threads have been resumed and whatever transient
   * condition refused them (a Mach region split mid-operation is the observed
   * one) has had a chance to clear. If they still refuse, the page is left
   * writable and that fact is RECORDED rather than converted into a false
   * failure report.
   */
  if (!restored) {
    if (mprotect(page_ptr, page_size, PROT_READ | PROT_EXEC) == 0) {
      restored = 1;
    } else if (vm_protect(mach_task_self(), (vm_address_t)page,
                          (vm_size_t)page_size, FALSE,
                          VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
      restored = 1;
    }
  }
  repro_hcr_apple_text_left_writable = restored ? 0 : 1;

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

/*
 * HLX-M8. The agent-level twin of the provider split just above it: one
 * transaction, two named halves, so the rb_hcr_* lifecycle can run the
 * application's before-reload callbacks between the caller's pre-flight and
 * Phase F and still reach exactly the same code.
 *
 * `repro_hcr_apply_direct_patch` is now the composition of the two, so there is
 * ONE implementation rather than a second copy for the ABI path to drift away
 * from. Quiescence spans both halves exactly as it did before this split —
 * moving it would have changed what every existing HLX-M4 gate measures, and
 * suspending threads slightly earlier than step 21 is a superset of what
 * Phase G requires, not a reordering of it.
 */
typedef struct repro_hcr_direct_patch_txn {
  void *entry;
  size_t patch_len;
  int quiesced;
  int prepared;
} repro_hcr_direct_patch_txn;

static int repro_hcr_prepare_direct_patch(repro_hcr_direct_patch_txn *txn,
                                          void *entry,
                                          const uint8_t *patch_bytes,
                                          size_t patch_len);
static void *repro_hcr_commit_direct_patch(repro_hcr_direct_patch_txn *txn);
static void repro_hcr_abort_direct_patch(repro_hcr_direct_patch_txn *txn);

REPRO_HCR_LX_MAYBE_UNUSED static void *repro_hcr_apply_direct_patch(
    void *entry, const uint8_t *patch_bytes, size_t patch_len) {
  repro_hcr_direct_patch_txn txn;
  if (repro_hcr_prepare_direct_patch(&txn, entry, patch_bytes, patch_len) !=
      REPRO_HCR_LX_OK) {
    repro_hcr_abort_direct_patch(&txn);
    return NULL;
  }
  return repro_hcr_commit_direct_patch(&txn);
}

static int repro_hcr_prepare_direct_patch(repro_hcr_direct_patch_txn *txn,
                                          void *entry,
                                          const uint8_t *patch_bytes,
                                          size_t patch_len) {
  uint64_t entry_address;
  uint64_t sled_address;
  int32_t thread_count;
  int quiesced = 0;
  int prepare_rc;

  memset(txn, 0, sizeof(*txn));
  txn->entry = entry;
  txn->patch_len = patch_len;

  if (entry == NULL) {
    memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
  }
  entry_address = (uint64_t)(uintptr_t)entry;
  /*
   * HLX-M2. The sled is looked up in the OBJECT THAT OWNS `entry_address`,
   * which may be the main executable or any `dlopen`'d shared library — the
   * `dl_iterate_phdr` walk that gives HLX-M1 the per-object load bias for
   * symbols gives it for sled tables too. Before this, the table came from the
   * linker-synthesised `__start_`/`__stop_` symbols, which name only the image
   * the agent itself was linked into, so a function in a shared library
   * resolved and then refused `absent-sled`.
   *
   * Called HERE, before quiescence begins: it opens and maps a file, which is
   * neither async-signal-safe nor something to do with every other thread
   * parked.
   */
  sled_address = repro_hcr_elf_sled_address_for_entry(entry_address);

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
      return REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED;
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

  /*
   * HLX-M3 (design §11.2): rollback has to "unregister JIT symfiles and
   * `.eh_frame` sections". The registration functions live in this translation
   * unit and the transaction lives in a header the test probe also includes,
   * so the two are joined by pointers installed here rather than by name.
   *
   * HLX-M5 made this REACHABLE. Both registrations now succeed on Linux and
   * `repro_hcr_lx_txn_record_registration` writes the per-site fields
   * (`jit_entry_address`, `eh_frame_payload_address`), so a rollback after a
   * registered patch actually calls back through here. The hooks are the
   * unwind header's own functions rather than agent wrappers around them:
   * one owner per behaviour, so there is no second copy to drift.
   */
  repro_hcr_lx_unregister_jit_hook = repro_hcr_lxu_unregister_jit_symfile;
  repro_hcr_lx_unregister_eh_frame_hook = repro_hcr_lxu_unregister_eh_frame;

  /* Phase F (§3.2: the in-memory link). Provider-owned memory only; target
   * text is untouched until the commit below. A refusal here is what §3.3
   * step 38 is about. */
  prepare_rc = repro_hcr_lx_prepare_direct_patch_at(entry_address, sled_address,
                                                    patch_bytes, patch_len);
  txn->quiesced = quiesced;
  if (prepare_rc != REPRO_HCR_LX_OK) {
    return prepare_rc;
  }
  txn->prepared = 1;
  return REPRO_HCR_LX_OK;
}

/* Phase G (steps 21-27). The first byte written to target text. */
static void *repro_hcr_commit_direct_patch(repro_hcr_direct_patch_txn *txn) {
  void *patch_page = NULL;
  if (txn->prepared) {
    patch_page = repro_hcr_lx_commit_direct_patch();
  }
  if (txn->quiesced) {
    (void)repro_hcr_lx_quiesce_release();
    txn->quiesced = 0;
  }
  if (patch_page != NULL) {
    repro_hcr_notify_did_patch(txn->entry, patch_page, txn->patch_len);
  }
  return patch_page;
}

/* Release whatever the prepare half acquired without touching target text.
 * `repro_hcr_lx_txn_prepare` has already discarded any site it prepared before
 * the one that refused, so the only thing left to undo here is quiescence. */
static void repro_hcr_abort_direct_patch(repro_hcr_direct_patch_txn *txn) {
  if (txn->quiesced) {
    (void)repro_hcr_lx_quiesce_release();
    txn->quiesced = 0;
  }
  txn->prepared = 0;
}

/* ---------------------------------------------------------------------------
 * HLX-M2 — evidence surface for the gates, and ONE lever.
 *
 * Why these are here rather than in the probe shim. The HLX-M4 fixtures link
 * `repro_hcr_linux_x86_64_probe.c` INSTEAD of the agent, so the probe's copies
 * of the provider statics are the ones they drive. An e2e gate that goes over
 * the real wire links the AGENT, and the agent's copies are different objects —
 * a probe setter would arm a provider that is not the one publishing. So the
 * two gates that need to see (and, once, steer) the agent's own publication ask
 * the agent directly.
 *
 * Every accessor below is a read of state the production path already recorded.
 * The single writer, `repro_hcr_agent_force_far_patch_body_for_tests`, does not
 * fake a distance: it removes the near-first preference for the body page, and
 * `repro_hcr_lx_map_patch_page_far` then refuses to return a page that is NOT
 * outside `rel32` reach. The gate measures the resulting gap from the addresses
 * reported here rather than believing the flag.
 *
 * The `_for_tests` suffix is the contract. Nothing in the agent's own code
 * calls any of them, and `repro_hcr_lx_force_far_patch_body` is 0 unless a test
 * sets it.
 * ------------------------------------------------------------------------- */

void repro_hcr_agent_force_far_patch_body_for_tests(int enabled) {
  repro_hcr_lx_force_far_patch_body = enabled;
}

int repro_hcr_agent_last_trampoline_kind_for_tests(void) {
  return repro_hcr_lx_last_report.trampoline_kind;
}

unsigned long long repro_hcr_agent_last_island_address_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_last_report.island_address;
}

long long repro_hcr_agent_last_body_displacement_for_tests(void) {
  return (long long)repro_hcr_lx_last_report.body_displacement;
}

unsigned long long repro_hcr_agent_last_window_address_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_last_report.window_address;
}

unsigned long long repro_hcr_agent_last_dispatch_address_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_last_report.dispatch_address;
}

const char *repro_hcr_agent_last_refusal_name_for_tests(void) {
  return repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal);
}

const char *repro_hcr_agent_last_sled_status_name_for_tests(void) {
  return repro_hcr_elf_sled_status_name(repro_hcr_elf_last_sled_lookup.status);
}

const char *repro_hcr_agent_last_sled_object_path_for_tests(void) {
  return repro_hcr_elf_last_sled_lookup.object_path;
}

int repro_hcr_agent_last_sled_is_main_executable_for_tests(void) {
  return repro_hcr_elf_last_sled_lookup.is_main_executable;
}

unsigned long long repro_hcr_agent_last_sled_section_start_for_tests(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.section_start;
}

unsigned long long repro_hcr_agent_last_sled_entry_count_for_tests(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.entry_count;
}

unsigned long long repro_hcr_agent_last_sled_load_bias_for_tests(void) {
  return (unsigned long long)repro_hcr_elf_last_sled_lookup.load_bias;
}

unsigned long long repro_hcr_agent_island_alloc_count_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_island_alloc_count;
}

/* Trampoline-Mechanics §5.1 strategy 2. `scan` counts how many times the
 * `/proc/self/maps` gap finder was ASKED; `hit` how many times it placed a page.
 * A gate asserting "no island could be placed" needs the first to be non-zero,
 * or the refusal would be evidence that strategy 2 never ran rather than that
 * it found nothing. */
unsigned long long repro_hcr_agent_gap_scan_count_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_gap_scan_count;
}

unsigned long long repro_hcr_agent_gap_hit_count_for_tests(void) {
  return (unsigned long long)repro_hcr_lx_gap_hit_count;
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
 * HLX-M8, off Linux/x86_64: the Phase F / Phase G boundary is NOT exposed.
 *
 * The Apple arm and the generic fallback still publish through a single
 * `repro_hcr_apply_direct_patch` call, so there is no point at which the
 * in-memory link has completed and target text is still untouched. The
 * rb_hcr_* lifecycle therefore runs its Phases F and G together on these
 * hosts, and a §3.3 step 38 late-load failure is indistinguishable from a
 * Phase G failure here. That is stated rather than papered over: splitting
 * the Mach-O publication path is a macOS-milestone deliverable, not this
 * one's, and the campaign's rule is that no macOS outcome changes here.
 */
typedef struct repro_hcr_direct_patch_txn {
  void *entry;
  const uint8_t *patch_bytes;
  size_t patch_len;
  int prepared;
} repro_hcr_direct_patch_txn;

static int repro_hcr_prepare_direct_patch(repro_hcr_direct_patch_txn *txn,
                                          void *entry,
                                          const uint8_t *patch_bytes,
                                          size_t patch_len) {
  memset(txn, 0, sizeof(*txn));
  txn->entry = entry;
  txn->patch_bytes = patch_bytes;
  txn->patch_len = patch_len;
  if (entry == NULL || patch_bytes == NULL || patch_len == 0) {
    return -1;
  }
  txn->prepared = 1;
  return 0;
}

static void *repro_hcr_commit_direct_patch(repro_hcr_direct_patch_txn *txn) {
  if (!txn->prepared) {
    return NULL;
  }
  return repro_hcr_apply_direct_patch(txn->entry, txn->patch_bytes,
                                      txn->patch_len);
}

static void repro_hcr_abort_direct_patch(repro_hcr_direct_patch_txn *txn) {
  txn->prepared = 0;
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
  int direct_patch = caps->text_protection_roundtrip && !caps->clang_cet_unsupported;
  snprintf(buffer, sizeof(buffer),
           "\"hcr-agent-protocol\"%s,\"debug-object-payloads\","
           "\"unwind-metadata-payloads\",\"source-generation-metadata\","
           "\"linux-x86_64-elf-direct-hcr\",\"%s\",\"%s\"%s",
           direct_patch ? ",\"direct-patch-injection\"" : "",
           caps->membarrier_sync_core ? "membarrier-sync-core"
                                      : "membarrier-sync-core-unavailable",
           caps->text_protection_roundtrip
               ? "text-protection-roundtrip"
               : "unsupported-host-text-protection-roundtrip",
           caps->clang_cet_unsupported
               ? ",\"" REPRO_HCR_AGENT_CAPABILITY_UNSUPPORTED_CLANG_FCF_PROTECTION "\""
               : "");
  return buffer;
}

void repro_hcr_lx_set_pretend_clang_cet_unsupported(int val) {
  repro_hcr_lx_internal_set_pretend_clang_cet_unsupported(val);
}

/* HLX-M2 widened this from 160: the sled lookup's detail names the object path
 * and the two build-ids, and a truncated path is exactly the part of that
 * message an operator needs. */
static char repro_hcr_lx_failure_detail_buffer[768];

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
  /*
   * HLX-M2. `absent-sled` now has FIVE distinguishable causes — no loaded
   * object maps the address, the object's file is unreadable or malformed, its
   * build-id no longer matches the mapped image, it carries no
   * `__patchable_function_entries` at all, or it has one and this function is
   * not in it. A bare `absent-sled` makes "you built this library without the
   * patchable profile" and "you rebuilt it since it was loaded" the same
   * report, which is the one distinction whoever is debugging a failed patch
   * needs most. The lookup's own named status and detail are appended.
   */
  if (repro_hcr_lx_last_report.refusal == REPRO_HCR_LX_REFUSED_ABSENT_SLED &&
      repro_hcr_elf_last_sled_lookup.status != REPRO_HCR_ELF_SLED_OK) {
    snprintf(repro_hcr_lx_failure_detail_buffer,
             sizeof(repro_hcr_lx_failure_detail_buffer), "%s (%s: %s)", name,
             repro_hcr_elf_sled_status_name(
                 repro_hcr_elf_last_sled_lookup.status),
             repro_hcr_elf_last_sled_lookup.detail);
    return repro_hcr_lx_failure_detail_buffer;
  }
  if (repro_hcr_lx_last_report.refusal !=
      REPRO_HCR_LX_REFUSED_QUIESCENCE_FAILED) {
    return name;
  }
  /*
   * A thread that BLOCKS the quiescence signal gets its own sentence, because
   * the generic one sends the operator the wrong way. `quiescence-timeout`
   * plus a list of tids reads as "they were slow"; the remedy it suggests is a
   * longer deadline, and no deadline can help a thread the kernel will never
   * deliver the signal to. So this reports the NAME and the MASK of each such
   * thread and says the deadline is not the problem.
   *
   * Measured example, on a Godot process rendering through Mesa:
   *   quiescence-failed (quiescence-signal-blocked; 3 of 3 threads that did
   *   not park still BLOCK signal 37, out of 38 threads: 1234 name=llvmpipe-0
   *   SigBlk=fffffffe3ffbfaff, ...; masks read for 3 thread(s), unreadable for
   *   0. The deadline is not the problem ...)
   *
   * NOTHING HERE MAY CONTAIN A DOUBLE QUOTE OR A BACKSLASH. This string is
   * pasted into a JSON string field on the coordinator wire with no escaping,
   * so a thread named `say"hi` would produce a message the coordinator cannot
   * parse — measured, as `JsonParsingError: } expected`, the first time this
   * diagnostic ran against a real Mesa process. The thread names are
   * sanitised where they are collected, in the quiescence header.
   */
  if (repro_hcr_lx_quiesce.last_status ==
      REPRO_HCR_LX_QUIESCE_SIGNAL_BLOCKED) {
    int written = snprintf(
        repro_hcr_lx_failure_detail_buffer,
        sizeof(repro_hcr_lx_failure_detail_buffer),
        "%s (%s; %d of %d threads that did not park still BLOCK signal %d, "
        "out of %d threads:",
        name,
        repro_hcr_lx_quiesce_status_name(repro_hcr_lx_quiesce.last_status),
        (int)repro_hcr_lx_quiesce.blocked_count,
        (int)repro_hcr_lx_quiesce.unresponsive_count,
        (int)repro_hcr_lx_quiesce.signo,
        (int)repro_hcr_lx_quiesce.slot_count + 1);
    int i;
    int named = repro_hcr_lx_quiesce.blocked_count;
    if (named > REPRO_HCR_LX_MAX_BLOCKED_THREADS) {
      named = REPRO_HCR_LX_MAX_BLOCKED_THREADS;
    }
    for (i = 0; i < named && written > 0 &&
                (size_t)written <
                    sizeof(repro_hcr_lx_failure_detail_buffer) - 96;
         ++i) {
      written += snprintf(
          repro_hcr_lx_failure_detail_buffer + written,
          sizeof(repro_hcr_lx_failure_detail_buffer) - (size_t)written,
          "%s %d name=%s SigBlk=%016llx", i == 0 ? "" : ",",
          (int)repro_hcr_lx_quiesce.blocked_tids[i],
          repro_hcr_lx_quiesce.blocked_names[i],
          (unsigned long long)repro_hcr_lx_quiesce.blocked_masks[i]);
    }
    if (written > 0 &&
        (size_t)written < sizeof(repro_hcr_lx_failure_detail_buffer) - 8) {
      if (i < repro_hcr_lx_quiesce.blocked_count) {
        written += snprintf(
            repro_hcr_lx_failure_detail_buffer + written,
            sizeof(repro_hcr_lx_failure_detail_buffer) - (size_t)written,
            " (+%d more)", (int)repro_hcr_lx_quiesce.blocked_count - i);
      }
    }
    if (written > 0 &&
        (size_t)written < sizeof(repro_hcr_lx_failure_detail_buffer) - 8) {
      (void)snprintf(
          repro_hcr_lx_failure_detail_buffer + written,
          sizeof(repro_hcr_lx_failure_detail_buffer) - (size_t)written,
          "; masks read for %d thread(s), unreadable for %d. The deadline is "
          "not the problem: these threads were created with the signal "
          "masked. Run the target without the component that creates them, or "
          "publish before it starts.)",
          (int)repro_hcr_lx_quiesce.sigmask_read_ok,
          (int)repro_hcr_lx_quiesce.sigmask_read_failed);
    }
    return repro_hcr_lx_failure_detail_buffer;
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
static char repro_hcr_lx_symbol_detail_buffer[768];

static const char *repro_hcr_symbol_failure_detail(void) {
  const char *name = repro_hcr_elf_last_symbol_refusal_name();
  const char *why = repro_hcr_elf_last_symbol_detail_text();
  if (why == NULL || why[0] == '\0') {
    return name;
  }
  /* Same shape as the sled path's `absent-sled (status: detail)`: the NAME is
   * the class and the DETAIL is which object and why. `elf-build-id-absent`
   * from a resolve can mean either "the library you asked about has no
   * build-id" or "some other object in this process could not be verified, so
   * I cannot say your symbol is absent", and those have different remedies. */
  snprintf(repro_hcr_lx_symbol_detail_buffer,
           sizeof(repro_hcr_lx_symbol_detail_buffer), "%s (%s)", name, why);
  return repro_hcr_lx_symbol_detail_buffer;
}
#else
static int repro_hcr_pretend_clang_cet_unsupported = 0;

void repro_hcr_lx_set_pretend_clang_cet_unsupported(int val) {
  repro_hcr_pretend_clang_cet_unsupported = val;
}

static const char *repro_hcr_capabilities_json_array(void) {
  static char buffer[512];
  if (repro_hcr_pretend_clang_cet_unsupported) {
    snprintf(buffer, sizeof(buffer),
             "\"hcr-agent-protocol\",\"debug-object-payloads\","
             "\"unwind-metadata-payloads\",\"source-generation-metadata\","
             "\"" REPRO_HCR_AGENT_CAPABILITY_UNSUPPORTED_CLANG_FCF_PROTECTION "\"");
    return buffer;
  }
#if defined(_WIN32) || defined(_WIN64) || defined(REPRO_HCR_TARGET_WINDOWS_X86_64)
  return "\"hcr-agent-protocol\",\"debug-object-payloads\","
         "\"unwind-metadata-payloads\",\"source-generation-metadata\","
         "\"windows-x86_64-pe-direct-hcr\"";
#else
  return "\"hcr-agent-protocol\",\"direct-patch-injection\","
         "\"debug-object-payloads\",\"unwind-metadata-payloads\","
         "\"source-generation-metadata\"";
#endif
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

char *repro_hcr_agent_format_hello_json(const char *support_profile) {
  return repro_hcr_hello_json(support_profile);
}

const char *repro_hcr_agent_default_support_profile(void) {
#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
  return REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64;
#elif defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64;
#elif defined(_WIN32) || defined(_WIN64) || defined(REPRO_HCR_TARGET_WINDOWS_X86_64)
  return REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64;
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

/*
 * HLX-M3, design §11.1 defect 1 — `oldCodeRetained`, COMPUTED.
 *
 * The format string below read `"oldCodeRetained":true` as a literal. The C
 * agent saved no original bytes anywhere, so the field asserted the invariant
 * instead of observing it, and because `session.nim:197` rejects a `false` the
 * literal was the only reason the handshake completed — the invariant was
 * unverified, not satisfied. It was the second of four constants found
 * masquerading as observations in this one reporting path.
 *
 * Both arms now report what actually happened, in the same shape the Nim
 * runtime uses at `runtime.nim:126` (`retainedRegionAddresses.len > 0`):
 *
 *   - Linux reads `repro_hcr_lx_last_report.old_code_retained`, which the
 *     transaction sets from the site table's saved ORIGINAL aligned word plus
 *     one retained body per generation (§4.5 retains superseded bodies);
 *   - macOS reads the per-publication retention record added above.
 *
 * A `false` reaching the wire is a real protocol violation for a direct
 * profile and is meant to fail the handshake. That is the point: the check
 * exists to catch a provider that cannot restore the old code, and until now
 * nothing could ever trip it.
 */
/*
 * The two Apple-arm observations, exported for whichever gate next runs on
 * macOS. Neither is read by the agent, and neither is reachable from a Linux
 * build: they exist so the defect-2 repair (the target's text page was left
 * writable, and that is now RECORDED instead of being reported as a total
 * failure) and the defect-1 repair (retention is observed) are assertable
 * rather than merely readable. HLX-M3's own gates run on Linux x86_64 and do
 * not touch them.
 */
#if defined(REPRO_HCR_TARGET_APPLE_ARM64)
int repro_hcr_agent_last_text_left_writable_for_tests(void) {
  return repro_hcr_apple_text_left_writable;
}

int repro_hcr_agent_retained_site_count_for_tests(void) {
  return repro_hcr_apple_retained_count;
}
#endif

static int repro_hcr_old_code_retained(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return repro_hcr_lx_last_report.old_code_retained;
#elif defined(REPRO_HCR_TARGET_APPLE_ARM64)
  return repro_hcr_apple_last_retained;
#else
  return 0;
#endif
}

static int repro_hcr_shared_library_positive_path = 0;

static int repro_hcr_get_shared_library_positive_path(void) {
  return repro_hcr_shared_library_positive_path;
}

static void repro_hcr_set_shared_library_positive_path(int val) {
  repro_hcr_shared_library_positive_path = val;
}

static char *repro_hcr_patch_applied_json(const char *patch_id,
                                          const char *changed_function,
                                          const char *debug_digest,
                                          const char *unwind_digest,
                                          void *entry,
                                          void *dispatch_entry,
                                          int shared_library_positive_path) {
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
           /* HLX-M3: an observation, not a literal. See
            * `repro_hcr_old_code_retained` above. */
           "\"oldCodeRetained\":%s,\"sharedLibraryPositivePath\":%s%s}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id,
           changed_function, repro_hcr_symbol_generation(),
           debug_digest == NULL ? "" : debug_digest,
           unwind_digest == NULL ? "" : unwind_digest,
           (unsigned long long)(uintptr_t)entry,
           (unsigned long long)(uintptr_t)dispatch_entry,
           repro_hcr_old_code_retained() ? "true" : "false",
           shared_library_positive_path ? "true" : "false",
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
  /*
   * HLX-M2 adds `island-unplaceable` to the reasons that are reported as a
   * SKIPPED FUNCTION rather than only as a failure message, and it belongs in
   * the same category for the same reason `claimed-by-recorder` does: it is not
   * a property of the target's code. The function's sled is fine, its entry is
   * fine, and it would patch cleanly in a process whose +/-2 GiB region around
   * that window had a page free. The milestone's deliverable says so in as many
   * words — "refuse the function with a named diagnostic and report it in
   * `skippedFunctions`; never widen the store".
   */
  /*
   * HLX-M3, design §11.3. "Map failures onto the existing protocol error codes
   * and `skippedFunctions` rather than inventing new ones."
   *
   * The dividing line is whose property the refusal is, and it is the same
   * line §11.3 draws: a PER-FUNCTION refusal is reported in
   * `skippedFunctions`; a whole-patch or host-level refusal rides on
   * `patchFailed`'s message alone. No new code, no new field and no new reason
   * string is introduced — every `reason` below is a name
   * `repro_hcr_lx_refusal_name` already produced.
   *
   * Per-function (this function, in this process, right now):
   *   absent-sled, non-nop-sled, short-sled, misaligned-entry,
   *   sled-window-not-instruction-boundary, entry-modified-externally,
   *   patch-body-out-of-rel32-range, island-unplaceable, claimed-by-recorder,
   *   site-table-full.
   *
   * NOT per-function, and deliberately left off this list because reporting
   * them as a skipped FUNCTION would suggest the next function might fare
   * better: unsupported-host, sync-core-unavailable, quiescence-failed,
   * text-protection-failed, patch-memory-unavailable,
   * patch-memory-protection-failed, invalid-argument.
   *
   * `entry-modified-externally` is the §4.5 addition and is the one a reload
   * workflow actually meets: the window this provider published into was
   * changed behind its back, so the function is skipped rather than
   * overwritten, and the rest of the patch is unaffected.
   */
  int refusal = repro_hcr_lx_last_report.refusal;
  const char *reason;
  switch (refusal) {
    case REPRO_HCR_LX_REFUSED_CLAIMED_BY_RECORDER:
    case REPRO_HCR_LX_REFUSED_ISLAND_UNPLACEABLE:
    case REPRO_HCR_LX_REFUSED_ABSENT_SLED:
    case REPRO_HCR_LX_REFUSED_NON_NOP_SLED:
    case REPRO_HCR_LX_REFUSED_SHORT_SLED:
    case REPRO_HCR_LX_REFUSED_MISALIGNED_ENTRY:
    case REPRO_HCR_LX_REFUSED_WINDOW_NOT_INSTRUCTION_BOUNDARY:
    case REPRO_HCR_LX_REFUSED_ENTRY_MODIFIED_EXTERNALLY:
    case REPRO_HCR_LX_REFUSED_TARGET_OUT_OF_RANGE:
    case REPRO_HCR_LX_REFUSED_SITE_TABLE_FULL:
      reason = repro_hcr_lx_refusal_name(refusal);
      break;
    default:
      return "";
  }
  snprintf(buffer, sizeof(buffer),
           ",\"skippedFunctions\":[{\"function\":\"%s\","
           "\"reason\":\"%s\",\"holder\":%u,"
           "\"windowAddress\":\"0x%llx\"}]",
           changed_function == NULL ? "" : changed_function, reason,
           repro_hcr_lx_last_report.claim_holder,
           (unsigned long long)repro_hcr_lx_last_report.window_address);
  return buffer;
#else
  (void)changed_function;
  return "";
#endif
}

/*
 * DEFECT FOUND AND FIXED 2026-09-18 (HLX-M8), and it pre-dates this milestone.
 *
 * `repro_hcr_patch_failed_json` pasted `message` into the JSON document raw.
 * Most refusal strings are plain text, but the ELF resolver's are not: it
 * QUOTES the symbol it could not resolve (`"hcr_lx_m8_absent" is in none of
 * the N object(s) parsed …`, `repro_hcr_linux_elf_symbols.h:1390-1452`), so an
 * unresolvable-symbol refusal produced a `patchFailed` frame the coordinator
 * could not parse. The coordinator then raised a JSON error instead of
 * reporting a named refusal — a diagnostic destroyed by the thing it was
 * diagnosing, and an agent whose ONLY way of saying "I could not find that
 * symbol" was to corrupt the session.
 *
 * Nothing drove an unresolvable symbol over the socket until HLX-M8's
 * `integration_hcr_linux_rejected_patch_never_fires_before_reload` gate did,
 * which is why it survived. The escaper already existed for the source-reload
 * fields; it was simply defined BELOW this function and therefore unreachable
 * from it. Forward-declared rather than duplicated: one escaper, one
 * behaviour. The escape is applied only to the free-text field; `patchId` is
 * coordinator-supplied and constrained by the schema.
 */
static void repro_hcr_json_escape(const char *value, char *out,
                                  size_t out_cap);

static char *repro_hcr_patch_failed_json(const char *patch_id,
                                         const char *changed_function,
                                         const char *message) {
  char escaped[2048];
  char *json = (char *)malloc(4096);
  if (json == NULL) {
    return NULL;
  }
  repro_hcr_json_escape(message, escaped, sizeof(escaped));
  snprintf(json, 4096,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-patch-failed-1\","
           "\"kind\":\"patchFailed\",\"patchFailed\":{\"patchId\":\"%s\","
           "\"stage\":\"applyDirectPatchRequest\",\"message\":\"%s\"%s}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
           patch_id == NULL ? "" : patch_id, escaped,
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

/*
 * ===========================================================================
 * HLX-M8 — the rb_hcr_* application ABI, and the reload lifecycle behind it.
 *
 * Specified by:
 *   - reprobuild-specs/HCR/HCR-Overview.md § 13 (the API), § 7.4 (the
 *     layout-change acceptance rule).
 *   - reprobuild-specs/HCR/Patch-Loading-Lifecycle.md § 3.1 (the NORMATIVE
 *     phase order), § 3.2 (Direct Patch Injection keeps that structure),
 *     § 3.3 step 38 (late load failure), § 3.4 (synchronized vs automatic).
 *   - reprobuild-specs/HCR/Linux-ELF-Provider.md § 9 (TLS).
 * Bound by IsoNim at isonim/src/isonim/native/hcr.nim, whose test double
 * isonim/tests/helpers/hcr_stub.nim is the cross-repo shape contract.
 *
 * THE PHASE ORDER, which is the thing most worth getting right here.
 * § 3.1 numbers the steps and says they "must execute in the specified order":
 *
 *   prepare (C/D)  parse, § 7.4 acceptance, symbol resolution, byte decode.
 *                  Touches no target memory and fires no callback, so a
 *                  refusal here leaves the process byte-identical. This is
 *                  HLX-M8's "before_reload fires only after prepare has fully
 *                  succeeded" — the IsoNim never-blank-the-surface contract.
 *   latch          the introspection window opens (see OPEN-1 below).
 *   Phase E 12-15  before_reload callbacks. OLD code is still the only code in
 *                  the process; the application serializes and destroys.
 *   Phase F 16-20  the load. Direct Patch Injection replaces it with the
 *                  in-memory link (§ 3.2): allocate the body page, copy the
 *                  bytes, plan the branch. Still no target write.
 *   Phase G 21-27  trampolines. The single naturally aligned 8-byte store.
 *                  NEW CODE BECOMES LIVE HERE.
 *   Phase H 28-29  after_reload callbacks. New code is live; the application
 *                  recreates and deserializes.
 *
 * This was contested: IsoNim's design doc had before_reload AFTER trampoline
 * installation. It was adjudicated on 2026-09-17 in favour of the order above
 * and IsoNim was re-shaped; Patch-Loading-Lifecycle.md is unamended. The
 * ordering is not a convention that could have gone the other way — at Phase E
 * nothing is loaded and no prologue is overwritten, so a before-reload callback
 * physically cannot observe new code.
 *
 * OPEN-1 — WHEN THE INTROSPECTION WINDOW OPENS. § 13.6's own usage example
 * calls rb_hcr_type_changed INSIDE a before-reload callback, so the answer set
 * must already describe the incoming patch by Phase E; HLX-M8 says it must
 * describe the APPLIED one. The only latch point at which both are true is the
 * instant prepare succeeds — after the last point a patch can be refused
 * outright, before the first before-callback. A patch refused in prepare never
 * reaches the latch, so "requested" and "applied" stay distinct, which is the
 * whole of HLX-M8's rb_hcr_file_changed deliverable. Same choice the IsoNim
 * stub documents, arrived at from the same two sentences.
 *
 * OPEN-5 — WHAT STEP 38 CANNOT TELL THE APPLICATION. Step 38 obliges this
 * agent to fire after_reload with ZERO changed_types when the load fails after
 * before_reload has run. But zero changed_types is also what an ordinary patch
 * with no layout change carries, RbHcrReloadInfo has no status field, and
 * rb_hcr_file_changed is defined over the APPLIED reload so it answers "no"
 * both for a failed load and for a file that was simply not in the patch. An
 * application restricted to the ten PORTABLE rb_hcr_* functions therefore
 * cannot distinguish "the patch failed, restore what you saved" from "the
 * patch applied and changed no layouts". No discriminator is invented in that
 * set: adding one is an ABI change owned by HCR-Overview § 13.3, and it is
 * raised as an open question rather than answered in code.
 *
 * Stated precisely, because the difference matters to anyone reading this as a
 * claim about the whole header: the repro_hcr_rb_* evidence functions below
 * DO separate the two cases (repro_hcr_rb_last_code_swapped answers 0 for a
 * failed load and 1 for an applied no-layout-change patch). They are this
 * provider's own surface, not part of § 13's portable set and not bound by
 * IsoNim, so they are not an answer to OPEN-5 — but "CANNOT distinguish" would
 * be false about the header as shipped.
 * ===========================================================================
 */

#define RB_HCR_MAX_CALLBACKS 64
#define RB_HCR_MAX_MANAGED_TYPES 128
#define RB_HCR_MAX_CHANGED_FILES 64
#define RB_HCR_MAX_CHANGED_TYPES 64
#define RB_HCR_TRACE_CAPACITY 512
#define RB_HCR_DIAGNOSTIC_CAPACITY 1024

typedef struct {
  RbHcrReloadCallback callback;
  void *user_data;
} rb_hcr_callback_entry;

typedef struct {
  char *name;
  uint32_t old_size;
  uint32_t new_size;
} rb_hcr_type_change_record;

static rb_hcr_callback_entry rb_hcr_before_callbacks[RB_HCR_MAX_CALLBACKS];
static size_t rb_hcr_before_callback_count = 0;

static rb_hcr_callback_entry rb_hcr_after_callbacks[RB_HCR_MAX_CALLBACKS];
static size_t rb_hcr_after_callback_count = 0;

/* § 13.2: "the canonical type name as it appears in debug info". The registry
 * stores the caller's `const char*` and does NOT copy it — matching the shipped
 * baseline this replaced, and matching what the IsoNim stub records as pinned.
 * Matching is exact strcmp; there is no glob (stub OPEN-2). */
static const char *rb_hcr_managed_types[RB_HCR_MAX_MANAGED_TYPES];
static size_t rb_hcr_managed_type_count = 0;

/* The introspection window: what the most recent APPLIED reload listed.
 * Owned copies, because the wire buffer they were parsed out of is freed when
 * the frame is. */
typedef struct {
  char *files[RB_HCR_MAX_CHANGED_FILES];
  size_t file_count;
  char *types[RB_HCR_MAX_CHANGED_TYPES];
  size_t type_count;
} rb_hcr_applied_window;

static rb_hcr_applied_window rb_hcr_applied;
static rb_hcr_applied_window rb_hcr_applied_saved;

/* Evidence surface. Every field below is a read of state the production
 * lifecycle already recorded; nothing here is written by a test. The lifecycle
 * trace is the same vocabulary the IsoNim stub emits, so the two repos'
 * gates assert the same words. */
static char rb_hcr_trace[RB_HCR_TRACE_CAPACITY];
static size_t rb_hcr_trace_len = 0;
static int rb_hcr_last_before_fired = 0;
static int rb_hcr_last_after_fired = 0;
static int rb_hcr_last_code_swapped = 0;
static char rb_hcr_last_rejection[RB_HCR_DIAGNOSTIC_CAPACITY];
static char rb_hcr_last_unmanaged[RB_HCR_DIAGNOSTIC_CAPACITY];
static unsigned long rb_hcr_apply_calls = 0;

static void rb_hcr_trace_reset(void) {
  rb_hcr_trace[0] = '\0';
  rb_hcr_trace_len = 0;
}

static void rb_hcr_trace_add(const char *phase) {
  size_t need = strlen(phase);
  if (rb_hcr_trace_len + need + 2 >= sizeof(rb_hcr_trace)) {
    return;
  }
  if (rb_hcr_trace_len > 0) {
    rb_hcr_trace[rb_hcr_trace_len++] = ',';
  }
  memcpy(rb_hcr_trace + rb_hcr_trace_len, phase, need);
  rb_hcr_trace_len += need;
  rb_hcr_trace[rb_hcr_trace_len] = '\0';
}

const char *repro_hcr_rb_lifecycle_trace(void) { return rb_hcr_trace; }
int repro_hcr_rb_last_before_callbacks_fired(void) {
  return rb_hcr_last_before_fired;
}
int repro_hcr_rb_last_after_callbacks_fired(void) {
  return rb_hcr_last_after_fired;
}
int repro_hcr_rb_last_code_swapped(void) { return rb_hcr_last_code_swapped; }
const char *repro_hcr_rb_last_rejection(void) { return rb_hcr_last_rejection; }
const char *repro_hcr_rb_last_unmanaged_types(void) {
  return rb_hcr_last_unmanaged;
}
unsigned long repro_hcr_rb_apply_reload_calls(void) {
  return rb_hcr_apply_calls;
}

/*
 * Registry evidence — the half of § 13 that has no platform in it.
 *
 * Declared and motivated in repro_hcr_agent.h next to the seven lifecycle
 * readers. Reads only; the out-of-range answers are 0/NULL so a gate that
 * walks past `*_count()` gets a value rather than a fault.
 */
size_t repro_hcr_rb_before_callback_count(void) {
  return rb_hcr_before_callback_count;
}

size_t repro_hcr_rb_after_callback_count(void) {
  return rb_hcr_after_callback_count;
}

RbHcrReloadCallback repro_hcr_rb_before_callback_at(size_t index) {
  if (index >= rb_hcr_before_callback_count) {
    return NULL;
  }
  return rb_hcr_before_callbacks[index].callback;
}

void *repro_hcr_rb_before_user_data_at(size_t index) {
  if (index >= rb_hcr_before_callback_count) {
    return NULL;
  }
  return rb_hcr_before_callbacks[index].user_data;
}

RbHcrReloadCallback repro_hcr_rb_after_callback_at(size_t index) {
  if (index >= rb_hcr_after_callback_count) {
    return NULL;
  }
  return rb_hcr_after_callbacks[index].callback;
}

void *repro_hcr_rb_after_user_data_at(size_t index) {
  if (index >= rb_hcr_after_callback_count) {
    return NULL;
  }
  return rb_hcr_after_callbacks[index].user_data;
}

size_t repro_hcr_rb_managed_type_count(void) {
  return rb_hcr_managed_type_count;
}

const char *repro_hcr_rb_managed_type_at(size_t index) {
  if (index >= rb_hcr_managed_type_count) {
    return NULL;
  }
  return rb_hcr_managed_types[index];
}

/* -------------------------------------------------------------------------
 * § 3.4 — synchronized vs automatic mode.
 *
 * Automatic is the default, and with no callbacks registered the lifecycle
 * below is observationally identical to the pre-HLX-M8 agent: the same wire
 * messages in the same order through the same publication path. In
 * synchronized mode the frame handler parks the patch and answers nothing;
 * rb_hcr_wants_reload() then answers true and the application's own thread
 * runs every phase inside rb_hcr_apply_reload(), which is what an application
 * with a frame loop needs — the callbacks must not run on the agent thread
 * while the renderer is mid-frame.
 * ---------------------------------------------------------------------- */
static int rb_hcr_synchronized_mode = -1;

static int rb_hcr_synchronized(void) {
  if (rb_hcr_synchronized_mode < 0) {
    const char *value = getenv("REPRO_HCR_SYNCHRONIZED");
    rb_hcr_synchronized_mode =
        (value != NULL && value[0] != '\0' && value[0] != '0') ? 1 : 0;
  }
  return rb_hcr_synchronized_mode;
}

void repro_hcr_agent_set_synchronized_mode(int enabled) {
  rb_hcr_synchronized_mode = enabled ? 1 : 0;
}

int repro_hcr_agent_synchronized_mode(void) { return rb_hcr_synchronized(); }

/* -------------------------------------------------------------------------
 * The parsed patch request. Owns every string in it.
 * ---------------------------------------------------------------------- */
typedef struct {
  int active;
  int fd;
  repro_hcr_agent_thread_args *args;
  char *raw;
  char *patch_id;
  char *changed_function;
  char *target_symbol;
  char *patch_hex;
  char *debug_hex;
  char *unwind_hex;
  char *debug_digest;
  char *unwind_digest;
  char *files[RB_HCR_MAX_CHANGED_FILES];
  size_t file_count;
  rb_hcr_type_change_record types[RB_HCR_MAX_CHANGED_TYPES];
  size_t type_count;
} rb_hcr_reload_request;

static rb_hcr_reload_request rb_hcr_pending;

static void rb_hcr_request_release(rb_hcr_reload_request *req) {
  size_t i;
  free(req->raw);
  free(req->patch_id);
  free(req->changed_function);
  free(req->target_symbol);
  free(req->patch_hex);
  free(req->debug_hex);
  free(req->unwind_hex);
  free(req->debug_digest);
  free(req->unwind_digest);
  for (i = 0; i < req->file_count; ++i) {
    free(req->files[i]);
  }
  for (i = 0; i < req->type_count; ++i) {
    free(req->types[i].name);
  }
  memset(req, 0, sizeof(*req));
}

/* -------------------------------------------------------------------------
 * JSON array readers. The agent's parser is a string scanner by design (no
 * allocator-heavy JSON library in a process that may be mid-quiescence), so
 * these follow the same shape as the single-value readers above.
 * ---------------------------------------------------------------------- */
static size_t repro_hcr_json_array_strings(const char *json, const char *key,
                                           char **out, size_t max_out) {
  const char *p = strstr(json, key);
  size_t count = 0;
  if (p == NULL) {
    return 0;
  }
  p = strchr(p + strlen(key), '[');
  if (p == NULL) {
    return 0;
  }
  p++;
  for (;;) {
    const char *end;
    p = repro_hcr_skip_ws(p);
    if (*p == '\0' || *p == ']') {
      break;
    }
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p != '"') {
      break;
    }
    p++;
    end = p;
    while (*end != '\0' && !(*end == '"' && (end == p || end[-1] != '\\'))) {
      end++;
    }
    if (*end != '"') {
      break;
    }
    if (count < max_out) {
      char *value = repro_hcr_strdup_range(p, end);
      if (value != NULL) {
        out[count++] = value;
      }
    }
    p = end + 1;
  }
  return count;
}

static uint32_t repro_hcr_json_u32_after(const char *json, const char *key) {
  const char *p = strstr(json, key);
  if (p == NULL) {
    return 0;
  }
  p = strchr(p + strlen(key), ':');
  if (p == NULL) {
    return 0;
  }
  p = repro_hcr_skip_ws(p + 1);
  return (uint32_t)strtoul(p, NULL, 10);
}

/* `changedTypes` is an array of flat objects, so a `{`..`}` walk is enough and
 * no nesting has to be tracked. A malformed element ends the scan rather than
 * being guessed at — a half-read layout delta is worse than none. */
static size_t repro_hcr_json_array_type_changes(
    const char *json, const char *key, rb_hcr_type_change_record *out,
    size_t max_out) {
  const char *p = strstr(json, key);
  size_t count = 0;
  if (p == NULL) {
    return 0;
  }
  p = strchr(p + strlen(key), '[');
  if (p == NULL) {
    return 0;
  }
  p++;
  for (;;) {
    const char *close;
    char *element;
    char *name;
    p = repro_hcr_skip_ws(p);
    if (*p == '\0' || *p == ']') {
      break;
    }
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p != '{') {
      break;
    }
    close = strchr(p, '}');
    if (close == NULL) {
      break;
    }
    element = repro_hcr_strdup_range(p, close + 1);
    if (element == NULL) {
      break;
    }
    name = repro_hcr_json_string_after(element, "\"typeName\"");
    if (name != NULL && count < max_out) {
      out[count].name = name;
      out[count].old_size = repro_hcr_json_u32_after(element, "\"oldSize\"");
      out[count].new_size = repro_hcr_json_u32_after(element, "\"newSize\"");
      count++;
    } else {
      free(name);
    }
    free(element);
    p = close + 1;
  }
  return count;
}

/* -------------------------------------------------------------------------
 * The introspection window.
 * ---------------------------------------------------------------------- */
static void rb_hcr_window_clear(rb_hcr_applied_window *window) {
  size_t i;
  for (i = 0; i < window->file_count; ++i) {
    free(window->files[i]);
  }
  for (i = 0; i < window->type_count; ++i) {
    free(window->types[i]);
  }
  memset(window, 0, sizeof(*window));
}

/* Latch: the previous window is SAVED rather than dropped, because Phase F can
 * still fail below and rb_hcr_file_changed is defined over the most recent
 * APPLIED reload. A patch that dies at load was not applied, so it must not
 * move the answer — and by then the before-callbacks have already run and may
 * already have consulted it. § 3.3 step 38's "any introspection window latched
 * before Phase E has to be rolled back". */
static void rb_hcr_window_latch(const rb_hcr_reload_request *req) {
  size_t i;
  rb_hcr_window_clear(&rb_hcr_applied_saved);
  rb_hcr_applied_saved = rb_hcr_applied;
  memset(&rb_hcr_applied, 0, sizeof(rb_hcr_applied));
  for (i = 0; i < req->file_count; ++i) {
    char *copy = repro_hcr_strdup_range(req->files[i],
                                        req->files[i] + strlen(req->files[i]));
    if (copy != NULL) {
      rb_hcr_applied.files[rb_hcr_applied.file_count++] = copy;
    }
  }
  for (i = 0; i < req->type_count; ++i) {
    const char *name = req->types[i].name;
    char *copy = repro_hcr_strdup_range(name, name + strlen(name));
    if (copy != NULL) {
      rb_hcr_applied.types[rb_hcr_applied.type_count++] = copy;
    }
  }
}

static void rb_hcr_window_unlatch(void) {
  rb_hcr_window_clear(&rb_hcr_applied);
  rb_hcr_applied = rb_hcr_applied_saved;
  memset(&rb_hcr_applied_saved, 0, sizeof(rb_hcr_applied_saved));
}

/* -------------------------------------------------------------------------
 * Callback dispatch.
 * ---------------------------------------------------------------------- */
static int rb_hcr_fire(const rb_hcr_callback_entry *list, size_t count,
                       const rb_hcr_reload_request *req,
                       int include_changed_types) {
  /* § 13.3: the agent owns this storage and the application must not retain
   * pointers past the callback's return. Stack-local on purpose. */
  const char *files[RB_HCR_MAX_CHANGED_FILES];
  RbHcrTypeChange types[RB_HCR_MAX_CHANGED_TYPES];
  rb_hcr_callback_entry snapshot[RB_HCR_MAX_CALLBACKS];
  RbHcrReloadInfo info;
  size_t i;
  int fired = 0;

  for (i = 0; i < req->file_count; ++i) {
    files[i] = req->files[i];
  }
  if (include_changed_types) {
    for (i = 0; i < req->type_count; ++i) {
      types[i].type_name = req->types[i].name;
      types[i].old_size = req->types[i].old_size;
      types[i].new_size = req->types[i].new_size;
    }
  }

  info.changed_files = req->file_count > 0 ? files : NULL;
  info.changed_files_count = (uint32_t)req->file_count;
  info.changed_types =
      (include_changed_types && req->type_count > 0) ? types : NULL;
  info.changed_types_count =
      include_changed_types ? (uint32_t)req->type_count : 0u;

  /* Iterate over a copy: a callback may register or remove callbacks, and the
   * live array must not be re-read mid-dispatch. Registration order is the
   * dispatch order (§ 13.3). */
  memcpy(snapshot, list, count * sizeof(rb_hcr_callback_entry));
  for (i = 0; i < count; ++i) {
    if (snapshot[i].callback != NULL) {
      snapshot[i].callback(&info, snapshot[i].user_data);
      fired++;
    }
  }
  return fired;
}

static int rb_hcr_is_managed(const char *type_name) {
  size_t i;
  if (type_name == NULL) {
    return 0;
  }
  for (i = 0; i < rb_hcr_managed_type_count; ++i) {
    if (rb_hcr_managed_types[i] != NULL &&
        strcmp(rb_hcr_managed_types[i], type_name) == 0) {
      return 1;
    }
  }
  return 0;
}

/* -------------------------------------------------------------------------
 * The lifecycle itself.
 * ---------------------------------------------------------------------- */
static void rb_hcr_reject(rb_hcr_reload_request *req, const char *reason) {
  snprintf(rb_hcr_last_rejection, sizeof(rb_hcr_last_rejection), "%s", reason);
  rb_hcr_trace_add("reject");
  repro_hcr_send_owned_json(
      req->fd, repro_hcr_lifecycle_json(
                   req->patch_id == NULL ? "" : req->patch_id,
                   "hcr/patchFailed", 2));
  repro_hcr_send_owned_json(
      req->fd, repro_hcr_patch_failed_json(req->patch_id, req->changed_function,
                                           reason));
}

static void rb_hcr_run_lifecycle(rb_hcr_reload_request *req) {
  void *entry;
  uint8_t *patch_bytes = NULL;
  uint8_t *debug_bytes = NULL;
  uint8_t *unwind_bytes = NULL;
  size_t patch_len = 0;
  size_t debug_len = 0;
  size_t unwind_len = 0;
  void *dispatch_entry = NULL;
  repro_hcr_direct_patch_txn txn;
  char failure_detail[832];
  const char *failure_message = "C agent failed to apply direct patch";
  int ok = 0;
  size_t i;

  rb_hcr_trace_reset();
  rb_hcr_last_before_fired = 0;
  rb_hcr_last_after_fired = 0;
  rb_hcr_last_code_swapped = 0;
  rb_hcr_last_rejection[0] = '\0';
  rb_hcr_last_unmanaged[0] = '\0';
  failure_detail[0] = '\0';

  /* ---- prepare (Phases C/D). No target memory, no callback. ------------ */
  rb_hcr_trace_add("prepare");

  if (req->patch_id == NULL) {
    rb_hcr_reject(req, "patch request is missing patchId");
    return;
  }
  if (req->changed_function == NULL) {
    rb_hcr_reject(req, "patch request is missing changed function");
    return;
  }
  if (req->patch_hex == NULL) {
    rb_hcr_reject(req, "patch request is missing direct patch bytes");
    return;
  }

#if defined(REPRO_HCR_FALSIFY_LATCH_ON_REQUEST)
  /* FALSIFIER BUILD ONLY. Latches the introspection window on the REQUESTED
   * patch instead of the accepted one, which is the defect HLX-M8's
   * rb_hcr_file_changed deliverable names: "conflating requested with applied
   * tells a program to migrate state it does not have". A gate that asserts
   * rb_hcr_file_changed answers false after a refused patch must go RED when
   * this is defined, or it was asserting nothing. Never defined by any
   * production or default test build. */
  rb_hcr_window_latch(req);
#endif

  /* § 7.4 — the acceptance rule. "If all layout-changed types in a patch are
   * managed, the patch is accepted; if any are unmanaged, the patch is
   * rejected with IncompatibleChange listing the unmanaged types." Evaluated
   * BEFORE anything else can fire, so a rejected patch leaves the process
   * untouched — HLX-M8's never-blank-the-surface deliverable. */
  {
    size_t unmanaged = 0;
    for (i = 0; i < req->type_count; ++i) {
      if (!rb_hcr_is_managed(req->types[i].name)) {
        size_t used = strlen(rb_hcr_last_unmanaged);
        snprintf(rb_hcr_last_unmanaged + used,
                 sizeof(rb_hcr_last_unmanaged) - used, "%s%s",
                 unmanaged == 0 ? "" : ", ", req->types[i].name);
        unmanaged++;
      }
    }
    if (unmanaged > 0) {
      char message[RB_HCR_DIAGNOSTIC_CAPACITY + 64];
      snprintf(message, sizeof(message),
               "IncompatibleChange: unmanaged layout-changed types: %s",
               rb_hcr_last_unmanaged);
      rb_hcr_reject(req, message);
      return;
    }
  }

  /* § 3.4 step 43: "The agent must reject automatic mode for patches with
   * layout changes and log a diagnostic instructing the application to use
   * synchronized mode." A layout migration runs application code in both
   * callback sets; running it on the agent thread while the application is
   * mid-frame is the hazard the rule exists for. */
  if (req->type_count > 0 && !rb_hcr_synchronized()) {
    rb_hcr_reject(req,
                  "IncompatibleChange: patch carries layout changes but the "
                  "agent is in automatic mode; the application must enable "
                  "synchronized mode (REPRO_HCR_SYNCHRONIZED=1 or "
                  "repro_hcr_agent_set_synchronized_mode) and drive "
                  "rb_hcr_apply_reload");
    return;
  }

  entry = repro_hcr_find_symbol(req->args, req->target_symbol,
                                req->changed_function);
  if (entry == NULL) {
    const char *symbol_detail = repro_hcr_symbol_failure_detail();
    if (symbol_detail != NULL && symbol_detail[0] != '\0' &&
        strcmp(symbol_detail, "ok") != 0) {
      snprintf(failure_detail, sizeof(failure_detail),
               "symbol resolution refused: %s", symbol_detail);
      rb_hcr_reject(req, failure_detail);
    } else {
      rb_hcr_reject(req, "target symbol was not found in process");
    }
    return;
  }

  patch_bytes = repro_hcr_bytes_from_hex(req->patch_hex, &patch_len);
  if (patch_bytes == NULL) {
    rb_hcr_reject(req, "direct patch bytes are not valid hex");
    return;
  }

  /* Prepare has fully succeeded. From here the patch has been accepted and the
   * lifecycle runs to completion; only Phases F and G can still fail, and both
   * of those owe the application an after_reload. */
  repro_hcr_send_owned_json(
      req->fd, repro_hcr_lifecycle_json(req->patch_id, "hcr/patchApplying", 1));

  /* ---- latch (OPEN-1) -------------------------------------------------- */
  rb_hcr_window_latch(req);
  rb_hcr_trace_add("latch");

  /* ---- Phase E (12-15) ------------------------------------------------- */
#if !defined(REPRO_HCR_FALSIFY_BEFORE_RELOAD_AFTER_SWAP)
  rb_hcr_trace_add("before");
  rb_hcr_last_before_fired =
      rb_hcr_fire(rb_hcr_before_callbacks, rb_hcr_before_callback_count, req, 1);
#endif

  /* ---- Phase F (16-20): the in-memory link (§ 3.2) --------------------- */
  rb_hcr_trace_add("load");
  if (repro_hcr_prepare_direct_patch(&txn, entry, patch_bytes, patch_len) != 0) {
    /* § 3.3 STEP 38. Before-reload has already fired, so the agent MUST still
     * invoke after-reload — with ZERO changed_types — so the application can
     * restore what it saved. No code was swapped, nothing is marked applied,
     * and the window latched above is rolled back so rb_hcr_file_changed does
     * not answer true for a reload that never happened. */
    const char *detail = repro_hcr_direct_patch_failure_detail();
    repro_hcr_abort_direct_patch(&txn);
    rb_hcr_window_unlatch();
    rb_hcr_trace_add("load-failed");
#if !defined(REPRO_HCR_FALSIFY_SKIP_STEP38)
    rb_hcr_trace_add("after");
    rb_hcr_last_after_fired = rb_hcr_fire(rb_hcr_after_callbacks,
                                          rb_hcr_after_callback_count, req, 0);
#endif
    if (detail != NULL && detail[0] != '\0') {
      snprintf(failure_detail, sizeof(failure_detail),
               "direct patch refused: %s", detail);
      failure_message = failure_detail;
    } else {
      failure_message = "direct patch in-memory link failed";
    }
    snprintf(rb_hcr_last_rejection, sizeof(rb_hcr_last_rejection), "%s",
             failure_message);
    repro_hcr_send_owned_json(
        req->fd,
        repro_hcr_lifecycle_json(req->patch_id, "hcr/patchFailed", 2));
    repro_hcr_send_owned_json(
        req->fd, repro_hcr_patch_failed_json(req->patch_id,
                                             req->changed_function,
                                             failure_message));
    free(patch_bytes);
    return;
  }

  /* ---- Phase G (21-27): NEW CODE BECOMES LIVE -------------------------- */
  dispatch_entry = repro_hcr_commit_direct_patch(&txn);
  ok = dispatch_entry != NULL;
  repro_hcr_set_shared_library_positive_path(0);
  if (getenv("REPRO_HCR_TEST_SHARED_LIBRARY_POSITIVE_PATH") != NULL) {
    repro_hcr_set_shared_library_positive_path(1);
  }
  if (!ok) {
    /* The commit refused or rolled back. Target text is either untouched or
     * restored (HLX-M3), but before_reload has fired, so the same obligation
     * as step 38 applies: after_reload with zero changed_types. */
    const char *detail = repro_hcr_direct_patch_failure_detail();
    rb_hcr_window_unlatch();
    rb_hcr_trace_add("commit-failed");
    rb_hcr_trace_add("after");
    rb_hcr_last_after_fired = rb_hcr_fire(rb_hcr_after_callbacks,
                                          rb_hcr_after_callback_count, req, 0);
    if (detail != NULL && detail[0] != '\0') {
      snprintf(failure_detail, sizeof(failure_detail),
               "direct patch refused: %s", detail);
      failure_message = failure_detail;
    } else {
      failure_message = "direct patch branch installation failed";
    }
    snprintf(rb_hcr_last_rejection, sizeof(rb_hcr_last_rejection), "%s",
             failure_message);
    repro_hcr_send_owned_json(
        req->fd,
        repro_hcr_lifecycle_json(req->patch_id, "hcr/patchFailed", 2));
    repro_hcr_send_owned_json(
        req->fd, repro_hcr_patch_failed_json(req->patch_id,
                                             req->changed_function,
                                             failure_message));
    free(patch_bytes);
    return;
  }
  rb_hcr_last_code_swapped = 1;
  rb_hcr_trace_add("trampolines");

#if defined(REPRO_HCR_FALSIFY_BEFORE_RELOAD_AFTER_SWAP)
  /* FALSIFIER BUILD ONLY. This is the ordering IsoNim's design doc asked for
   * and Patch-Loading-Lifecycle.md § 3.1 forbids: before-reload fired AFTER
   * trampoline installation, so the callback observes NEW code. Any gate whose
   * before-callback asserts it still sees the OLD body must go RED here. It is
   * a falsifier and not an option: the resolution of 2026-09-17 settled the
   * order, and this exists only so the gate can prove it measures it. */
  rb_hcr_trace_add("before");
  rb_hcr_last_before_fired =
      rb_hcr_fire(rb_hcr_before_callbacks, rb_hcr_before_callback_count, req, 1);
#endif

  /* HLX-M7 — record the code-version boundary while the words that changed are
   * still in `repro_hcr_lx_last_report`, and BEFORE anything the new code can
   * emit. The after-reload callbacks below run NEW code, so this must precede
   * them or the recorded boundary lands in the wrong place. */
  repro_hcr_notify_code_patch(req->patch_id, req->changed_function,
                              req->target_symbol,
                              req->args->support_profile, entry, patch_bytes,
                              patch_len);

  /* Phase I step 31 — debugger and unwinder registration. Kept here, between
   * the commit and the after-reload callbacks, exactly where it was before
   * HLX-M8: a debugger that stops inside an after-reload callback must already
   * be able to attribute the patched frame. A failure here is reported on the
   * wire, but the code IS live and the layouts DID change, so the after-reload
   * callbacks below still receive the FULL changed_types — this is not step 38,
   * and telling the application "nothing to migrate" would be false. */
  if (req->debug_hex != NULL) {
    repro_hcr_jit_registration_evidence jit_evidence;
    const char *debug_symbol = req->changed_function != NULL
                                   ? req->changed_function
                                   : req->target_symbol;
    debug_bytes = repro_hcr_bytes_from_hex(req->debug_hex, &debug_len);
    if (debug_bytes == NULL || debug_len == 0 ||
        repro_hcr_register_jit_debug_object(
            debug_bytes, (uint64_t)debug_len,
            (uint64_t)(uintptr_t)dispatch_entry, debug_symbol,
            &jit_evidence) != 0) {
      ok = 0;
      failure_message = "JIT debug object registration failed";
    }
  }
  if (ok && req->unwind_hex != NULL) {
    repro_hcr_unwind_registration_evidence unwind_evidence;
    unwind_bytes = repro_hcr_bytes_from_hex(req->unwind_hex, &unwind_len);
    if (unwind_bytes == NULL || unwind_len == 0 ||
        repro_hcr_register_dynamic_eh_frame(
            unwind_bytes, (uint64_t)unwind_len,
            (uint64_t)(uintptr_t)dispatch_entry, (uint64_t)patch_len,
            &unwind_evidence) != 0) {
      ok = 0;
      failure_message = "dynamic unwind registration failed";
    }
  }

  /* ---- Phase H (28-29) ------------------------------------------------- */
  rb_hcr_trace_add("after");
  rb_hcr_last_after_fired =
      rb_hcr_fire(rb_hcr_after_callbacks, rb_hcr_after_callback_count, req, 1);

  if (ok) {
    repro_hcr_send_owned_json(
        req->fd,
        repro_hcr_lifecycle_json(req->patch_id, "hcr/patchApplied", 2));
    repro_hcr_send_owned_json(
        req->fd,
        repro_hcr_patch_applied_json(req->patch_id, req->changed_function,
                                     req->debug_digest, req->unwind_digest,
                                     entry, dispatch_entry,
                                     repro_hcr_get_shared_library_positive_path()));
  } else {
    snprintf(rb_hcr_last_rejection, sizeof(rb_hcr_last_rejection), "%s",
             failure_message);
    repro_hcr_send_owned_json(
        req->fd,
        repro_hcr_lifecycle_json(req->patch_id, "hcr/patchFailed", 2));
    repro_hcr_send_owned_json(
        req->fd, repro_hcr_patch_failed_json(req->patch_id,
                                             req->changed_function,
                                             failure_message));
  }

  free(patch_bytes);
  free(debug_bytes);
  free(unwind_bytes);
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
   * every macOS gate sends real payloads.
   *
   * HLX-M5 landed ELF `.eh_frame` and GDB JIT registration, so a NON-empty
   * payload now succeeds here instead of failing.
   *
   * CORRECTED 2026-09-17 REVIEW. An earlier draft of this comment said "no
   * Linux coordinator path sends these two fields yet". That is wrong, and the
   * accurate split matters because it says which production path is untested:
   *
   *   - `scripts/hcr_patch_driver.nim` (:444-451, :542-549) sends BOTH fields
   *     EMPTY under `HcrLinuxX86_64DirectSupportProfile`. That is the driver
   *     the flame/Godot demo and the CodeTracer front end use, so those patches
   *     do take this normalisation.
   *   - `repro watch --hcr` and `repro hcr coordinate`
   *     (`repro_cli_support.nim:24949-24957`, `:29029-29037`) send both fields
   *     NON-EMPTY on Linux — `CodetracerHcrSupportProfile` is host-derived
   *     (`:24383-24391`) and `hcrUnwindMetadataFor` has a real ELF branch
   *     (`:24454-24469`). Neither call site carries a platform guard.
   *
   * What IS absent is gate coverage: no gate drives a non-empty payload through
   * this frame. Every `tests/e2e/hcr-linux-*` socket gate passes `[]` for both,
   * and the HLX-M5 gates reach the same registration functions through a second
   * caller (`tests/e2e/hcr-linux-unwind/`, argv-driven), not over the socket. */
  if (debug_hex != NULL && debug_hex[0] == '\0') {
    free(debug_hex);
    debug_hex = NULL;
  }
  if (unwind_hex != NULL && unwind_hex[0] == '\0') {
    free(unwind_hex);
    unwind_hex = NULL;
  }
#endif

#if defined(_WIN32) || defined(_WIN64) || defined(REPRO_HCR_TARGET_WINDOWS_X86_64)
  /* HX-W-5: Windows agent does not implement patching yet; safely and honestly refuse */
  repro_hcr_send_owned_json(fd,
    repro_hcr_lifecycle_json(patch_id == NULL ? "" : patch_id, "hcr/patchFailed", 1));
  repro_hcr_send_owned_json(fd,
    repro_hcr_patch_failed_json(patch_id, changed_function,
                                "unsupported-host: patching-not-implemented"));
  free(patch_id);
  free(changed_function);
  free(target_symbol);
  free(patch_hex);
  free(debug_hex);
  free(unwind_hex);
  free(debug_digest);
  free(unwind_digest);
  free(patch);
  return;
#endif

  /* HLX-M8: everything below builds a request and hands it to the lifecycle.
   * The publication itself has not moved — `rb_hcr_run_lifecycle` reaches the
   * same `repro_hcr_prepare_direct_patch` / `repro_hcr_commit_direct_patch`
   * pair `repro_hcr_apply_direct_patch` composes, sends the same wire messages
   * in the same order, and with no application callbacks registered and no
   * `changedTypes` in the request it is observationally the agent that shipped
   * before this milestone. What is new is that the application now gets its
   * two callbacks, on the two sides of the code swap. */
  rb_hcr_reload_request request;
  memset(&request, 0, sizeof(request));
  request.fd = fd;
  request.args = args;
  request.raw = patch;
  request.patch_id = patch_id;
  request.changed_function = changed_function;
  request.target_symbol = target_symbol;
  request.patch_hex = patch_hex;
  request.debug_hex = debug_hex;
  request.unwind_hex = unwind_hex;
  request.debug_digest = debug_digest;
  request.unwind_digest = unwind_digest;
  request.file_count = repro_hcr_json_array_strings(
      patch, "\"changedFiles\"", request.files, RB_HCR_MAX_CHANGED_FILES);
  request.type_count = repro_hcr_json_array_type_changes(
      patch, "\"changedTypes\"", request.types, RB_HCR_MAX_CHANGED_TYPES);

  if (rb_hcr_synchronized()) {
    /* § 3.4 step 41: Phase E blocks until `rb_hcr_apply_reload()` is called.
     * The request is parked and NOTHING is answered on the wire yet — the
     * coordinator is waiting for the outcome of a lifecycle the application
     * has not run. A second patch arriving while one is parked replaces it,
     * which is § 3.4's coalescing. */
    if (rb_hcr_pending.active) {
      rb_hcr_request_release(&rb_hcr_pending);
    }
    rb_hcr_pending = request;
    rb_hcr_pending.active = 1;
    return;
  }

  rb_hcr_run_lifecycle(&request);
  rb_hcr_request_release(&request);
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

/*
 * HLX-M5 / HLX-OQ-4. Which `__register_frame` convention this process's
 * unwinder was measured to want, and the two counters behind that measurement,
 * exported so a gate can assert WHICH convention answered rather than only
 * that registration succeeded. Picking the wrong one silently is the whole
 * hazard `HLX-OQ-4` names, and a gate that can only see "it worked" cannot
 * tell a correct choice from a lucky one.
 *
 * "undetermined" on the non-Linux arms is the honest answer, not a default:
 * neither has a `__register_frame` ABI question to answer.
 */
const char *repro_hcr_agent_register_frame_convention(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return repro_hcr_lxu_convention_name(repro_hcr_lxu_convention);
#else
  return "undetermined";
#endif
}

unsigned long long repro_hcr_agent_register_frame_probe_attempts(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return (unsigned long long)repro_hcr_lxu_probe_attempts;
#else
  return 0ull;
#endif
}

unsigned long long repro_hcr_agent_register_frame_fallback_attempts(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  return (unsigned long long)repro_hcr_lxu_fallback_attempts;
#else
  return 0ull;
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

/*
 * ===========================================================================
 * Application Runtime ABI: rb_hcr_*
 * Specified in reprobuild-specs/HCR/HCR-Overview.md § 13.
 * Bound by IsoNim (isonim/src/isonim/native/hcr.nim).
 *
 * HLX-M8 replaced the baseline bodies that used to live here. The registry,
 * the phase order and the lifecycle are defined above, next to the patch-frame
 * handler that drives them; the ten exported functions below are the thin
 * application-facing surface over that state.
 *
 * What changed, and what deliberately did not:
 *
 *   - rb_hcr_wants_reload() was `return false`. It now answers whether a patch
 *     is parked waiting for the application (§ 13.1: non-blocking, false when
 *     nothing is pending).
 *   - rb_hcr_apply_reload() was a commented no-op. It now runs the whole
 *     § 3.1 lifecycle on the CALLER's thread, which is the point of
 *     synchronized mode: the callbacks must not run on the agent thread while
 *     the application is mid-frame.
 *   - rb_hcr_file_changed() / rb_hcr_type_changed() were `return false`. They
 *     now answer over the most recent APPLIED reload — never the most recent
 *     requested one. A patch refused in prepare never latches, and a patch
 *     that dies at Phase F un-latches (§ 3.3 step 38), because conflating
 *     requested with applied tells a program to migrate state it does not
 *     have (GDScript-Hot-Reload-Multi-Version-Sources.md § 4.5).
 *   - the four registration functions and the two managed-type functions keep
 *     the baseline's exact semantics — idempotent on (callback, user_data),
 *     removal matching on both fields, de-duplication by name, the pointer
 *     stored rather than copied, and a silent drop past the capacities. Those
 *     were not placeholders; they are what the IsoNim stub records as pinned
 *     by the shipped implementation, so changing them would have broken a
 *     contract rather than completed one.
 * ===========================================================================
 */

bool rb_hcr_wants_reload(void) {
  /* § 13.1: non-blocking. In automatic mode nothing is ever parked, so this
   * answers false and an application that polls it simply never sees a patch
   * it has to drive — which is correct, because the agent already drove it. */
  return rb_hcr_pending.active != 0;
}

void rb_hcr_apply_reload(void) {
  rb_hcr_apply_calls++;
  if (!rb_hcr_pending.active) {
    /* § 13.1 says this blocks until the reload completes; with nothing pending
     * there is nothing to complete. The IsoNim stub calls the same case
     * `no-patch-pending` and treats it as a no-op. */
    rb_hcr_trace_reset();
    rb_hcr_trace_add("reject:no-patch-pending");
    return;
  }
  rb_hcr_pending.active = 0;
  rb_hcr_run_lifecycle(&rb_hcr_pending);
  rb_hcr_request_release(&rb_hcr_pending);
}

void rb_hcr_register_managed_type(const char *type_name) {
  size_t i;
  if (type_name == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_managed_type_count; ++i) {
    if (rb_hcr_managed_types[i] != NULL &&
        strcmp(rb_hcr_managed_types[i], type_name) == 0) {
      return;
    }
  }
  if (rb_hcr_managed_type_count < RB_HCR_MAX_MANAGED_TYPES) {
    rb_hcr_managed_types[rb_hcr_managed_type_count++] = type_name;
  }
}

void rb_hcr_unregister_managed_type(const char *type_name) {
  size_t i;
  size_t j;
  if (type_name == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_managed_type_count; ++i) {
    if (rb_hcr_managed_types[i] != NULL &&
        strcmp(rb_hcr_managed_types[i], type_name) == 0) {
      for (j = i; j + 1 < rb_hcr_managed_type_count; ++j) {
        rb_hcr_managed_types[j] = rb_hcr_managed_types[j + 1];
      }
      rb_hcr_managed_type_count--;
      return;
    }
  }
}

void rb_hcr_before_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_before_callback_count; ++i) {
    if (rb_hcr_before_callbacks[i].callback == callback &&
        rb_hcr_before_callbacks[i].user_data == user_data) {
      return;
    }
  }
  if (rb_hcr_before_callback_count < RB_HCR_MAX_CALLBACKS) {
    rb_hcr_before_callbacks[rb_hcr_before_callback_count].callback = callback;
    rb_hcr_before_callbacks[rb_hcr_before_callback_count].user_data = user_data;
    rb_hcr_before_callback_count++;
  }
}

void rb_hcr_after_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_after_callback_count; ++i) {
    if (rb_hcr_after_callbacks[i].callback == callback &&
        rb_hcr_after_callbacks[i].user_data == user_data) {
      return;
    }
  }
  if (rb_hcr_after_callback_count < RB_HCR_MAX_CALLBACKS) {
    rb_hcr_after_callbacks[rb_hcr_after_callback_count].callback = callback;
    rb_hcr_after_callbacks[rb_hcr_after_callback_count].user_data = user_data;
    rb_hcr_after_callback_count++;
  }
}

void rb_hcr_remove_before_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  size_t j;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_before_callback_count; ++i) {
    if (rb_hcr_before_callbacks[i].callback == callback &&
        rb_hcr_before_callbacks[i].user_data == user_data) {
      for (j = i; j + 1 < rb_hcr_before_callback_count; ++j) {
        rb_hcr_before_callbacks[j] = rb_hcr_before_callbacks[j + 1];
      }
      rb_hcr_before_callback_count--;
      return;
    }
  }
}

void rb_hcr_remove_after_reload(RbHcrReloadCallback callback, void *user_data) {
  size_t i;
  size_t j;
  if (callback == NULL) {
    return;
  }
  for (i = 0; i < rb_hcr_after_callback_count; ++i) {
    if (rb_hcr_after_callbacks[i].callback == callback &&
        rb_hcr_after_callbacks[i].user_data == user_data) {
      for (j = i; j + 1 < rb_hcr_after_callback_count; ++j) {
        rb_hcr_after_callbacks[j] = rb_hcr_after_callbacks[j + 1];
      }
      rb_hcr_after_callback_count--;
      return;
    }
  }
}

bool rb_hcr_file_changed(const char *file_path) {
  size_t i;
  if (file_path == NULL) {
    return false;
  }
  for (i = 0; i < rb_hcr_applied.file_count; ++i) {
    if (rb_hcr_applied.files[i] != NULL &&
        strcmp(rb_hcr_applied.files[i], file_path) == 0) {
      return true;
    }
  }
  return false;
}

bool rb_hcr_type_changed(const char *type_name) {
  size_t i;
  if (type_name == NULL) {
    return false;
  }
  for (i = 0; i < rb_hcr_applied.type_count; ++i) {
    if (rb_hcr_applied.types[i] != NULL &&
        strcmp(rb_hcr_applied.types[i], type_name) == 0) {
      return true;
    }
  }
  return false;
}

/*
 * HX-W-2: Windows Thread Quiescence and IP Adjustment
 * Exposes the quiescence lifecycle and test hooks for the Windows agent.
 */
#if defined(_WIN32)
#include "repro_hcr_windows_quiesce.h"

int repro_hcr_win_agent_quiesce_begin(uint64_t timeout_ns) {
  repro_hcr_win_quiesce_install();
  return repro_hcr_win_quiesce_begin(timeout_ns);
}

int repro_hcr_win_agent_quiesce_release(void) {
  return repro_hcr_win_quiesce_release();
}

int repro_hcr_win_agent_quiesce_is_held(void) {
  return repro_hcr_win_quiesce_is_held();
}

void repro_hcr_win_agent_quiesce_set_suppress_adjust(int val) {
  repro_hcr_win_quiesce_set_suppress_adjust(val);
}

void repro_hcr_win_agent_quiesce_set_single_snapshot_only(int val) {
  repro_hcr_win_quiesce_set_single_snapshot_only(val);
}
#else
static int s_win_agent_pretend_quiesce_held = 0;
static int s_win_agent_suppress_adjust = 0;
static int s_win_agent_single_snapshot_only = 0;

int repro_hcr_win_agent_quiesce_begin(uint64_t timeout_ns) {
  (void)timeout_ns;
  s_win_agent_pretend_quiesce_held = 1;
  return 0;
}

int repro_hcr_win_agent_quiesce_release(void) {
  s_win_agent_pretend_quiesce_held = 0;
  return 0;
}

int repro_hcr_win_agent_quiesce_is_held(void) {
  return s_win_agent_pretend_quiesce_held;
}

void repro_hcr_win_agent_quiesce_set_suppress_adjust(int val) {
  s_win_agent_suppress_adjust = val;
}

void repro_hcr_win_agent_quiesce_set_single_snapshot_only(int val) {
  s_win_agent_single_snapshot_only = val;
}
#endif

/*
 * HX-W-5: Windows Named Pipe Name Derivation
 */
int repro_hcr_win_pipe_name_for_pid(uint32_t pid, char *out_buf, size_t out_capacity) {
  if (out_buf == NULL || out_capacity < 32) {
    return -1;
  }
  int written = snprintf(out_buf, out_capacity, "\\\\.\\pipe\\repro-hcr-%u", (unsigned int)pid);
  if (written <= 0 || (size_t)written >= out_capacity) {
    return -1;
  }
  return 0;
}


