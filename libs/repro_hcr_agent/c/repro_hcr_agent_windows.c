/*
 * HX-W-5 Windows lifecycle artifact and named-pipe protocol endpoint.
 *
 * This is deliberately separate from repro_hcr_agent.c: that translation unit
 * currently owns the POSIX socket and Linux/macOS patch paths. The exported
 * lifecycle ABI is shared through repro_hcr_agent.h; Windows patch application
 * remains unavailable until the W2-W4 pieces are joined behind this endpoint.
 *
 * Loader-lock rule: DllMain only disables thread notifications. The launcher
 * invokes ReproHcrWindowsBootstrap in a second remote thread after LoadLibraryW
 * has returned. All allocation, token inspection, pipe creation, and protocol
 * work therefore happens outside DllMain.
 */
#define REPRO_HCR_AGENT_BUILD_DLL 1

#include "repro_hcr_agent.h"
#include "repro_hcr_sha256.h"

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
#define REPRO_HCR_MAX_FRAME (1024u * 1024u)

static volatile LONG repro_hcr_started = 0;
static volatile LONG repro_hcr_session_open = 0;
static volatile LONG repro_hcr_messages_handled = 0;
static volatile LONG repro_hcr_start_status = ERROR_IO_PENDING;
static HANDLE repro_hcr_ready_event = NULL;
static repro_hcr_source_reload_handler repro_hcr_reload_handler = NULL;
static void *repro_hcr_reload_context = NULL;

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
      "\"%s\"]}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE,
      REPRO_HCR_WINDOWS_AGENT_PROFILE, (unsigned long)GetCurrentProcessId(),
      REPRO_HCR_WINDOWS_CAPABILITY);
  if (count <= 0 || (size_t)count >= sizeof(body)) {
    return -1;
  }
  return repro_hcr_send_json(pipe, body);
}

static int repro_hcr_send_patch_failure(HANDLE pipe, const char *patch_id) {
  char lifecycle[1024];
  char failure[1536];
  int lifecycle_count = snprintf(
      lifecycle, sizeof(lifecycle),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-lifecycle-2\"," \
      "\"kind\":\"lifecycleEvent\",\"lifecycleEvent\":{" \
      "\"patchId\":\"%s\",\"event\":\"hcr/patchFailed\"," \
      "\"sequence\":2}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id);
  int failure_count = snprintf(
      failure, sizeof(failure),
      "{\"schemaId\":\"%s\",\"transportScope\":\"%s\"," \
      "\"protocolVersion\":1,\"messageId\":\"agent-patch-failed-3\"," \
      "\"kind\":\"patchFailed\",\"patchFailed\":{\"patchId\":\"%s\"," \
      "\"stage\":\"applyDirectPatchRequest\"," \
      "\"message\":\"unsupported-host: Windows agent patch integration " \
      "is not enabled\"}}",
      REPRO_HCR_PROTOCOL_SCHEMA, REPRO_HCR_TRANSPORT_SCOPE, patch_id);
  if (lifecycle_count <= 0 || (size_t)lifecycle_count >= sizeof(lifecycle) ||
      failure_count <= 0 || (size_t)failure_count >= sizeof(failure)) {
    return -1;
  }
  if (repro_hcr_send_json(pipe, lifecycle) != 0) {
    return -1;
  }
  return repro_hcr_send_json(pipe, failure);
}

static DWORD WINAPI repro_hcr_pipe_thread(void *unused) {
  wchar_t pipe_name[128];
  PSECURITY_DESCRIPTOR descriptor = NULL;
  SECURITY_ATTRIBUTES attributes;
  HANDLE pipe = INVALID_HANDLE_VALUE;
  char *hello_ack = NULL;
  char *request = NULL;
  char patch_id[256];
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
  connected = ConnectNamedPipe(pipe, NULL);
  if (!connected) {
    failure = GetLastError();
    if (failure != ERROR_PIPE_CONNECTED) {
      CloseHandle(pipe);
      return 1;
    }
  }
  InterlockedExchange(&repro_hcr_session_open, 1);
  if (repro_hcr_send_hello(pipe) != 0) {
    goto done;
  }
  hello_ack = repro_hcr_read_frame_body(pipe);
  if (hello_ack == NULL ||
      !repro_hcr_json_has_string(hello_ack, "kind", "helloAck") ||
      !repro_hcr_json_has_string(hello_ack, "supportProfile",
                                 REPRO_HCR_WINDOWS_AGENT_PROFILE)) {
    goto done;
  }
  request = repro_hcr_read_frame_body(pipe);
  if (request == NULL ||
      !repro_hcr_json_has_string(request, "kind", "patchRequest") ||
      !repro_hcr_json_has_string(request, "supportProfile",
                                 REPRO_HCR_WINDOWS_AGENT_PROFILE) ||
      repro_hcr_json_string(request, "patchId", patch_id,
                            sizeof(patch_id)) != 0) {
    goto done;
  }
  InterlockedIncrement(&repro_hcr_messages_handled);
  (void)repro_hcr_send_patch_failure(pipe, patch_id);

done:
  free(hello_ack);
  free(request);
  InterlockedExchange(&repro_hcr_session_open, 0);
  FlushFileBuffers(pipe);
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  return 0;
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
int repro_hcr_agent_host_supports_direct_patch(void) { return 0; }
int repro_hcr_agent_host_membarrier_sync_core(void) { return 0; }
int repro_hcr_agent_host_quiescence_signal(void) { return 0; }
int repro_hcr_agent_last_publication_tier(void) { return 0; }
int repro_hcr_agent_last_on_stack_threads(void) { return -1; }
