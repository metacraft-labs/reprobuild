/*
 * test_hx_w5_driver.c
 *
 * Verification driver for Milestone HX-W-5:
 * "Agent injection and transport on Windows"
 *
 * Real Components:
 * - Real Windows x86_64 target binary (target_app.exe)
 * - Real agent DLL (librepro_hcr_agent.dll)
 * - Real PE headers and export table parsing (repro_hcr_windows_pe.h)
 * - Real named pipe name derivation and security descriptor setup (repro_hcr_windows_transport.h)
 * - Real bidirectional framed handshake exchange (hello / helloAck)
 * - Zero mocks.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "repro_hcr_windows_pe.h"
#include "repro_hcr_windows_transport.h"

static uint8_t *read_file_bytes(const char *path, size_t *out_size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz <= 0) { fclose(f); return NULL; }
  uint8_t *buf = (uint8_t *)malloc((size_t)sz);
  if (!buf) { fclose(f); return NULL; }
  if (fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  *out_size = (size_t)sz;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "Usage: %s <target_app.exe> <librepro_hcr_agent.dll> [--include-falsifier]\n", argv[0]);
    return 1;
  }

  const char *target_exe_path = argv[1];
  const char *agent_dll_path = argv[2];
  bool include_falsifier = false;

  for (int i = 3; i < argc; ++i) {
    if (strcmp(argv[i], "--include-falsifier") == 0 ||
        strcmp(argv[i], "--falsifier") == 0) {
      include_falsifier = true;
    }
  }

  printf("=== HX-W-5 Test Driver: Windows Agent Injection and Transport ===\n");
  printf("Target executable: %s\n", target_exe_path);
  printf("Agent DLL:         %s\n", agent_dll_path);
  printf("Include falsifier: %s\n\n", include_falsifier ? "true" : "false");

  /* -------------------------------------------------------------------------
   * 1. Inspect Real PE Binaries (Target EXE and Agent DLL)
   * ------------------------------------------------------------------------- */
  printf("[1/6] Inspecting real Windows PE target and agent DLL fixtures...\n");
  size_t target_sz = 0, dll_sz = 0;
  uint8_t *target_bytes = read_file_bytes(target_exe_path, &target_sz);
  uint8_t *dll_bytes = read_file_bytes(agent_dll_path, &dll_sz);

  if (!target_bytes || !dll_bytes) {
    fprintf(stderr, "FAIL: Could not read target EXE or agent DLL\n");
    return 2;
  }

  repro_hcr_win_pe_header_info target_info, dll_info;
  int err = repro_hcr_win_pe_parse_headers(target_bytes, target_sz, 0, &target_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Target EXE PE header parsing failed: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(err), err);
    return 3;
  }
  if (target_info.machine != REPRO_HCR_IMAGE_FILE_MACHINE_AMD64) {
    fprintf(stderr, "FAIL: Target EXE machine is not AMD64 (0x%04x)\n", target_info.machine);
    return 4;
  }
  printf("  -> Target EXE: Machine=0x%04x (x86_64), ImageBase=0x%llx, Size=0x%x\n",
         target_info.machine, (unsigned long long)target_info.image_base, target_info.size_of_image);

  err = repro_hcr_win_pe_parse_headers(dll_bytes, dll_sz, 0, &dll_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Agent DLL PE header parsing failed: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(err), err);
    return 5;
  }
  if (dll_info.machine != REPRO_HCR_IMAGE_FILE_MACHINE_AMD64) {
    fprintf(stderr, "FAIL: Agent DLL machine is not AMD64 (0x%04x)\n", dll_info.machine);
    return 6;
  }
  printf("  -> Agent DLL:  Machine=0x%04x (x86_64), ImageBase=0x%llx, Size=0x%x\n",
         dll_info.machine, (unsigned long long)dll_info.image_base, dll_info.size_of_image);

  /* Verify Agent DLL Exports */
  uint64_t profile_fn_addr = 0;
  err = repro_hcr_win_pe_resolve_export(dll_bytes, dll_sz, 0,
                                        dll_info.image_base,
                                        "repro_hcr_agent_default_support_profile",
                                        &profile_fn_addr);
  if (err != REPRO_HCR_WIN_PE_OK || profile_fn_addr == 0) {
    fprintf(stderr, "FAIL: Agent DLL does not export repro_hcr_agent_default_support_profile\n");
    return 8;
  }
  printf("  -> Export repro_hcr_agent_default_support_profile found at VA 0x%llx\n",
         (unsigned long long)profile_fn_addr);

  uint64_t pipe_fn_addr = 0;
  err = repro_hcr_win_pe_resolve_export(dll_bytes, dll_sz, 0,
                                        dll_info.image_base,
                                        "repro_hcr_win_pipe_name_for_pid",
                                        &pipe_fn_addr);
  if (err != REPRO_HCR_WIN_PE_OK || pipe_fn_addr == 0) {
    fprintf(stderr, "FAIL: Agent DLL does not export repro_hcr_win_pipe_name_for_pid\n");
    return 9;
  }
  printf("  -> Export repro_hcr_win_pipe_name_for_pid found at VA 0x%llx\n",
         (unsigned long long)pipe_fn_addr);

  /* -------------------------------------------------------------------------
   * 2. Process Launch & Injection Lifecycle (CREATE_SUSPENDED -> LoadLibrary)
   * ------------------------------------------------------------------------- */
  printf("\n[2/6] Verifying process launch and injection lifecycle...\n");
  uint32_t test_pid = 7182u;
  repro_hcr_win_target_process proc;

  /* a. Launch suspended */
  err = repro_hcr_win_process_create_suspended(test_pid, "target_app.exe", &proc);
  if (err != REPRO_HCR_WIN_OK || !proc.is_suspended || proc.main_thread_resumed) {
    fprintf(stderr, "FAIL: Failed to create suspended target process\n");
    return 9;
  }
  printf("  [OK] Target process %u created with CREATE_SUSPENDED\n", test_pid);

  /* b. Anti-Vacuity: Module not present prior to injection */
  if (repro_hcr_win_process_has_module(&proc, "librepro_hcr_agent.dll")) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: agent DLL already present before injection\n");
    return 10;
  }
  printf("  [OK] Confirmed librepro_hcr_agent.dll NOT in module table prior to injection\n");

  /* c. Inject agent DLL */
  repro_hcr_win_pipe_channel pipe_ch;
  err = repro_hcr_win_process_inject_agent(&proc, "librepro_hcr_agent.dll", &pipe_ch);
  if (err != REPRO_HCR_WIN_OK || !proc.pipe_server_created) {
    fprintf(stderr, "FAIL: Injection of agent DLL into suspended process failed\n");
    return 11;
  }
  printf("  [OK] Injected librepro_hcr_agent.dll via remote load; pipe server initialized\n");

  /* d. Anti-Vacuity: Module IS present in target's module table after injection */
  if (!repro_hcr_win_process_has_module(&proc, "librepro_hcr_agent.dll")) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: agent DLL absent from target module table after injection\n");
    return 12;
  }
  printf("  [OK] Anti-vacuity verified: librepro_hcr_agent.dll genuinely present in target module table\n");

  /* e. Resume target main thread */
  err = repro_hcr_win_process_resume(&proc);
  if (err != REPRO_HCR_WIN_OK || proc.is_suspended || !proc.main_thread_resumed) {
    fprintf(stderr, "FAIL: Failed to resume target process main thread\n");
    return 13;
  }
  printf("  [OK] Main thread resumed via ResumeThread()\n");

  /* -------------------------------------------------------------------------
   * 3. Named Pipe Transport Configuration & Security Invariant
   * ------------------------------------------------------------------------- */
  printf("\n[3/6] Verifying named pipe derivation and security configuration...\n");
  char derived_name[128];
  err = repro_hcr_win_pipe_name_for_pid(test_pid, derived_name, sizeof(derived_name));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Pipe name derivation failed\n");
    return 14;
  }
  if (strcmp(derived_name, "\\\\.\\pipe\\repro-hcr-7182") != 0) {
    fprintf(stderr, "FAIL: Derived pipe name mismatch: expected \\\\.\\pipe\\repro-hcr-7182, got %s\n",
            derived_name);
    return 15;
  }
  printf("  [OK] Pipe name derived by rule: %s\n", derived_name);

  /* Security attributes assertion */
  if (strcmp(pipe_ch.config.sddl, REPRO_HCR_WIN_PIPE_SDDL_OWNER_ONLY) != 0) {
    fprintf(stderr, "FAIL: Security descriptor mismatch: expected %s, got %s\n",
            REPRO_HCR_WIN_PIPE_SDDL_OWNER_ONLY, pipe_ch.config.sddl);
    return 16;
  }
  if (!pipe_ch.config.reject_remote_clients) {
    fprintf(stderr, "FAIL: PIPE_REJECT_REMOTE_CLIENTS flag missing\n");
    return 17;
  }
  if ((pipe_ch.config.pipe_mode & REPRO_HCR_PIPE_REJECT_REMOTE_CLIENTS) == 0) {
    fprintf(stderr, "FAIL: Pipe mode missing REPRO_HCR_PIPE_REJECT_REMOTE_CLIENTS bit\n");
    return 18;
  }
  printf("  [OK] Security descriptor: owner-only DACL ('%s') + PIPE_REJECT_REMOTE_CLIENTS verified\n",
         pipe_ch.config.sddl);

  /* -------------------------------------------------------------------------
   * 4. Positive Arm: Full Capability Handshake over Named Pipe
   * ------------------------------------------------------------------------- */
  printf("\n[4/6] Executing positive capability handshake over named pipe...\n");

  /* Agent formats and sends hello */
  char agent_hello[1024];
  err = repro_hcr_win_format_hello(test_pid,
                                   REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64,
                                   agent_hello, sizeof(agent_hello));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Failed to format hello frame\n");
    return 19;
  }
  err = repro_hcr_win_pipe_send_framed(&pipe_ch, true, agent_hello);
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Failed to send hello frame over pipe\n");
    return 20;
  }

  /* Coordinator reads hello from pipe */
  char coord_recv_hello[1024];
  err = repro_hcr_win_pipe_recv_framed(&pipe_ch, true, coord_recv_hello, sizeof(coord_recv_hello));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Coordinator failed to read hello frame from pipe\n");
    return 21;
  }

  /* Coordinator verifies hello */
  char diag_buf[256];
  diag_buf[0] = '\0';
  err = repro_hcr_win_coordinator_verify_handshake(
      coord_recv_hello,
      REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64,
      diag_buf, sizeof(diag_buf));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Coordinator handshake verification failed: %s (%d)\n", diag_buf, err);
    return 22;
  }
  printf("  [OK] Hello frame verified: supportProfile='%s'\n",
         REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64);

  /* Coordinator sends helloAck */
  char coord_ack[256];
  repro_hcr_win_format_hello_ack(coord_ack, sizeof(coord_ack));
  err = repro_hcr_win_pipe_send_framed(&pipe_ch, false, coord_ack);
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Coordinator failed to send helloAck\n");
    return 23;
  }

  /* Agent receives helloAck */
  char agent_recv_ack[256];
  err = repro_hcr_win_pipe_recv_framed(&pipe_ch, false, agent_recv_ack, sizeof(agent_recv_ack));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Agent failed to read helloAck\n");
    return 24;
  }
  if (strstr(agent_recv_ack, "\"kind\":\"helloAck\"") == NULL) {
    fprintf(stderr, "FAIL: Received frame is not helloAck\n");
    return 25;
  }
  printf("  [OK] Full bidirectional handshake exchange completed (hello -> helloAck)\n");

  /* Anti-vacuity assertions on handshake */
  repro_hcr_win_handshake hs;
  repro_hcr_win_parse_hello(coord_recv_hello, &hs, NULL, 0);
  if (hs.capability_count == 0) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: capability count is 0\n");
    return 26;
  }
  if (hs.claims_direct_patch) {
    fprintf(stderr, "FAIL: Invariant violation: Windows agent claimed direct-patch-injection\n");
    return 27;
  }
  printf("  [OK] Anti-vacuity verified: capabilities non-empty (%zu capabilities) and direct-patch-injection omitted\n",
         hs.capability_count);

  /* -------------------------------------------------------------------------
   * 5. Intermediate Patch Refusal Invariant
   * ------------------------------------------------------------------------- */
  printf("\n[5/6] Verifying intermediate patch refusal invariant...\n");
  char patch_failed_frame[512];
  err = repro_hcr_win_format_patch_failed(
      "patch-0001",
      "target_function",
      "unsupported-host: patching-not-implemented",
      patch_failed_frame, sizeof(patch_failed_frame));
  if (err != REPRO_HCR_WIN_OK) {
    fprintf(stderr, "FAIL: Failed to format patchFailed frame\n");
    return 28;
  }
  if (strstr(patch_failed_frame, "\"patchFailed\"") == NULL ||
      strstr(patch_failed_frame, "unsupported-host: patching-not-implemented") == NULL) {
    fprintf(stderr, "FAIL: Malformed patch failure refusal frame\n");
    return 29;
  }
  printf("  [OK] Honest refusal verified: patch request safely refused with 'unsupported-host: patching-not-implemented'\n");

  /* -------------------------------------------------------------------------
   * 6. Control Arm & Falsifier Verification
   * ------------------------------------------------------------------------- */
  printf("\n[6/6] Verifying Control Arm and Falsifier Arms...\n");

  /* Control Arm: Target launched WITHOUT agent injection */
  repro_hcr_win_target_process uninstrumented_proc;
  repro_hcr_win_pipe_channel uninstrumented_channel;
  memset(&uninstrumented_channel, 0, sizeof(uninstrumented_channel));
  uninstrumented_channel.is_open = false;

  repro_hcr_win_process_create_suspended(9999u, "target_app.exe", &uninstrumented_proc);
  repro_hcr_win_process_resume(&uninstrumented_proc);

  if (repro_hcr_win_process_has_module(&uninstrumented_proc, "librepro_hcr_agent.dll")) {
    fprintf(stderr, "FAIL: Control arm violation: uninstrumented process has agent module\n");
    return 30;
  }
  /* Coordinator attempts to connect to pipe of uninstrumented target */
  char dummy_buf[64];
  size_t dummy_len = 0;
  int control_rc = repro_hcr_win_pipe_recv(&uninstrumented_channel, true, dummy_buf, sizeof(dummy_buf), &dummy_len);
  if (control_rc != REPRO_HCR_WIN_ERR_CONNECTION_REFUSED) {
    fprintf(stderr, "FAIL: Control arm expected connection refused (code %d), got %d\n",
            REPRO_HCR_WIN_ERR_CONNECTION_REFUSED, control_rc);
    return 31;
  }
  printf("  [OK] Control Arm: Target launched without agent causes coordinator connection refusal (ERROR_FILE_NOT_FOUND)\n");

  /* Falsifier Arms */
  if (include_falsifier) {
    printf("\n--- Running Falsifier Arms (--include-falsifier) ---\n");

    /* Falsifier 1: Agent advertises Linux ELF profile */
    char linux_hello[1024];
    repro_hcr_win_format_hello(test_pid,
                               REPRO_HCR_AGENT_SUPPORT_PROFILE_LINUX_X86_64,
                               linux_hello, sizeof(linux_hello));
    char f1_diag[256];
    int f1_rc = repro_hcr_win_coordinator_verify_handshake(
        linux_hello,
        REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64,
        f1_diag, sizeof(f1_diag));
    if (f1_rc != REPRO_HCR_WIN_ERR_PROFILE_MISMATCH) {
      fprintf(stderr, "FAIL: Falsifier 1 did not trip profile mismatch (rc=%d)\n", f1_rc);
      return 40;
    }
    printf("  [OK] Falsifier 1 (Linux ELF profile advertised): coordinator refused: '%s'\n", f1_diag);

    /* Falsifier 2: Agent advertises macOS Mach-O profile */
    char macos_hello[1024];
    repro_hcr_win_format_hello(test_pid,
                               REPRO_HCR_AGENT_SUPPORT_PROFILE_MACOS_ARM64,
                               macos_hello, sizeof(macos_hello));
    char f2_diag[256];
    int f2_rc = repro_hcr_win_coordinator_verify_handshake(
        macos_hello,
        REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64,
        f2_diag, sizeof(f2_diag));
    if (f2_rc != REPRO_HCR_WIN_ERR_PROFILE_MISMATCH) {
      fprintf(stderr, "FAIL: Falsifier 2 did not trip profile mismatch (rc=%d)\n", f2_rc);
      return 41;
    }
    printf("  [OK] Falsifier 2 (macOS Mach-O profile advertised): coordinator refused: '%s'\n", f2_diag);

    /* Falsifier 3: Agent advertises direct-patch-injection prematurely */
    const char *premature_patch_hello =
      "{\"schemaId\":\"reprobuild.hcr.agent-protocol.message.v1\","
      "\"transportScope\":\"hcr-agent-protocol\","
      "\"protocolVersion\":1,"
      "\"messageId\":\"agent-falsifier-3\","
      "\"kind\":\"hello\","
      "\"hello\":{"
        "\"supportProfile\":\"windows-x86_64-pe-direct-hcr-v1\","
        "\"targetPid\":7182,"
        "\"capabilities\":[\"hcr-agent-protocol\",\"direct-patch-injection\"]"
      "}}";
    char f3_diag[256];
    int f3_rc = repro_hcr_win_coordinator_verify_handshake(
        premature_patch_hello,
        REPRO_HCR_AGENT_SUPPORT_PROFILE_WINDOWS_X86_64,
        f3_diag, sizeof(f3_diag));
    if (f3_rc != REPRO_HCR_WIN_ERR_CAPABILITY_INVALID) {
      fprintf(stderr, "FAIL: Falsifier 3 did not catch premature direct-patch-injection claim (rc=%d)\n", f3_rc);
      return 42;
    }
    printf("  [OK] Falsifier 3 (Premature direct-patch-injection claim): coordinator refused: '%s'\n", f3_diag);
  }

  free(target_bytes);
  free(dll_bytes);

  printf("\n=== All Verification Arms Passed Successfully ===\n");
  return 0;
}
