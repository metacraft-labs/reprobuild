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
#include "repro_hcr_linux_x86_64.h"
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif
#endif

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
  /* HLX-M7 widens this into the MCR `ct_repro_hcr_agent_did_patch` bridge
   * (patchId, patchedSymbols, code hashes). HLX-M0 deliberately does not
   * resolve the hook through `dlsym`, so the agent imposes no libdl link
   * requirement on the targets it is compiled into. */
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
  /* Deliberately no `dlsym` fallback on Linux. Design §7.1: `dlsym` cannot see
   * `static` or hidden functions, which are most of the interesting ones, and a
   * partial resolver that silently succeeds for exported symbols only would
   * hide that. HLX-M1 lands the real pipeline (`dl_iterate_phdr` load bias plus
   * on-disk `.symtab`/`.strtab`, build-id verified). Until then the Linux arm
   * resolves only symbols the target registered explicitly. */
  (void)target_symbol;
  (void)changed_function;
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
 */
static void *repro_hcr_apply_direct_patch(void *entry,
                                          const uint8_t *patch_bytes,
                                          size_t patch_len) {
  uint64_t entry_address;
  uint64_t sled_address;
  void *patch_page;

  if (entry == NULL) {
    memset(&repro_hcr_lx_last_report, 0, sizeof(repro_hcr_lx_last_report));
    repro_hcr_lx_last_report.refusal = REPRO_HCR_LX_REFUSED_INVALID_ARGUMENT;
    return NULL;
  }
  entry_address = (uint64_t)(uintptr_t)entry;
  sled_address = repro_hcr_lx_sled_address_for_entry(entry_address);
  patch_page = repro_hcr_lx_apply_direct_patch_at(entry_address, sled_address,
                                                  patch_bytes, patch_len);
  if (patch_page != NULL) {
    repro_hcr_notify_did_patch(entry, patch_page, patch_len);
  }
  return patch_page;
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

static const char *repro_hcr_direct_patch_failure_detail(void) {
  return repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal);
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
#endif

static char *repro_hcr_hello_json(const char *support_profile) {
  char *json = (char *)malloc(2048);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 2048,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-hello-1\","
           "\"kind\":\"hello\",\"hello\":{\"supportProfile\":\"%s\","
           "\"agentPid\":%ld,\"capabilities\":[%s]}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
           support_profile, (long)getpid(),
           repro_hcr_capabilities_json_array());
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

static char *repro_hcr_patch_applied_json(const char *patch_id,
                                          const char *changed_function,
                                          const char *debug_digest,
                                          const char *unwind_digest,
                                          void *entry,
                                          void *dispatch_entry) {
  char *json = (char *)malloc(4096);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 4096,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-patch-applied-1\","
           "\"kind\":\"patchApplied\",\"patchApplied\":{\"patchId\":\"%s\","
           "\"changedFunctions\":[\"%s\"],\"symbolGeneration\":1,"
           "\"debugObjectDigest\":\"%s\",\"unwindMetadataDigest\":\"%s\","
           "\"sourceGenerationMapDigest\":\"blake3-256:c-agent-source-generation-map\","
           "\"entryAddress\":\"0x%llx\","
           "\"dispatchAddress\":\"0x%llx\","
           "\"oldCodeRetained\":true,\"sharedLibraryPositivePath\":false}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id,
           changed_function, debug_digest == NULL ? "" : debug_digest,
           unwind_digest == NULL ? "" : unwind_digest,
           (unsigned long long)(uintptr_t)entry,
           (unsigned long long)(uintptr_t)dispatch_entry);
  return json;
}

static char *repro_hcr_patch_failed_json(const char *patch_id,
                                         const char *message) {
  char *json = (char *)malloc(2048);
  if (json == NULL) {
    return NULL;
  }
  snprintf(json, 2048,
           "{\"schemaId\":\"%s\",\"transportScope\":\"%s\","
           "\"protocolVersion\":1,\"messageId\":\"agent-patch-failed-1\","
           "\"kind\":\"patchFailed\",\"patchFailed\":{\"patchId\":\"%s\","
           "\"stage\":\"applyDirectPatchRequest\",\"message\":\"%s\"}}",
           REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
           patch_id == NULL ? "" : patch_id, message);
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

  char *patch = repro_hcr_read_frame_body(fd);
  if (patch == NULL) {
    close(fd);
    repro_hcr_free_args(args);
    return NULL;
  }

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
    failure_message = "target symbol was not found in process";
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
      repro_hcr_patch_failed_json(patch_id, failure_message));
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
  close(fd);
  repro_hcr_free_args(args);
  return NULL;
}

/* Design §4.4 and §5.2 both require work "at agent start": SYNC_CORE
 * registration, and the RW->RX round-trip probe on a provider-owned scratch
 * mapping. Both happen here, before any patch request can arrive. */
static void repro_hcr_agent_probe_host_once(void) {
#if defined(REPRO_HCR_TARGET_LINUX_X86_64)
  (void)repro_hcr_lx_capability_report();
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

int repro_hcr_agent_poll(void) {
  if (repro_hcr_poll_args == NULL || repro_hcr_poll_done) {
    return 0;
  }
  repro_hcr_agent_thread(repro_hcr_poll_args);
  repro_hcr_poll_args = NULL;
  repro_hcr_poll_done = 1;
  return 0;
}
