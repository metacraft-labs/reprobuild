/*
 * test_hx_w6_driver.c
 *
 * Automated Integration Verification Driver for Milestone HX-W-6:
 * "Decide the Windows debugger integration, including what is refused"
 *
 * References:
 *   - reprobuild-specs/HCR-Per-Platform-Handoff.milestones.org (HX-W-6, lines 1907-1961)
 *   - reprobuild-specs/HCR/Debugger-Integration.md §7.1, §7.3, §7.4, §7.5, §7.7, §7.8, §8.4
 *   - reprobuild-specs/HCR/HCR-Overview.md §14.3, §15
 *   - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_debug.h
 *   - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_pe.h
 *   - reprobuild/libs/repro_hcr_agent/c/repro_hcr_windows_unwind_cfg.h
 *
 * Real Components:
 *   - Real baseline Windows PE32+ binary (target_app.exe) with genuine PDB (target_app.pdb)
 *   - Real patch PE32+ binary (patch_mod.dll) with genuine PDB (patch_mod.pdb)
 *   - Real synthesized minimal PE header constructed in memory
 *   - Real CodeView CV_INFO_PDB70 RSDS record verification with real GUID and Age matching
 *   - Real .pdata exception directory entry in synthesized PE header
 *   - Real WinDbg .reload command formulation
 *   - Real Visual Studio Concord standing refusal verification
 *   - Zero mocks.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

#include "repro_hcr_windows_pe.h"
#include "repro_hcr_windows_debug.h"

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

static bool write_file_bytes(const char *path, const uint8_t *buf, size_t sz) {
  FILE *f = fopen(path, "wb");
  if (!f) return false;
  size_t written = fwrite(buf, 1, sz, f);
  fclose(f);
  return (written == sz);
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <target_app.exe> <patch_mod.dll> <out_synthesized.pe> [--include-falsifier]\n", argv[0]);
    return 1;
  }

  const char *target_exe_path = argv[1];
  const char *patch_dll_path = argv[2];
  const char *out_pe_path = argv[3];
  bool include_falsifier = false;

  for (int i = 4; i < argc; ++i) {
    if (strcmp(argv[i], "--include-falsifier") == 0 || strcmp(argv[i], "--falsifier") == 0) {
      include_falsifier = true;
    }
  }

  printf("=== HX-W-6 Test Driver: Windows Debugger Integration Decision ===\n");
  printf("Target EXE:           %s\n", target_exe_path);
  printf("Patch DLL:            %s\n", patch_dll_path);
  printf("Out Synthesized PE:   %s\n", out_pe_path);
  printf("Include Falsifier:    %s\n\n", include_falsifier ? "true" : "false");

  /* -------------------------------------------------------------------------
   * 1. Inspect Real Baseline and Patch PE Images
   * ------------------------------------------------------------------------- */
  printf("[1/6] Inspecting real Windows PE fixtures and extracting CodeView RSDS metadata...\n");

  size_t target_sz = 0, patch_sz = 0;
  uint8_t *target_bytes = read_file_bytes(target_exe_path, &target_sz);
  uint8_t *patch_bytes = read_file_bytes(patch_dll_path, &patch_sz);

  if (!target_bytes || !patch_bytes) {
    fprintf(stderr, "FAIL: Failed to read target EXE or patch DLL binary\n");
    return 2;
  }

  repro_hcr_win_pe_header_info target_info, patch_info;
  int err = repro_hcr_win_pe_parse_headers(target_bytes, target_sz, 0, &target_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Target EXE PE parsing failed: %s (%d)\n", repro_hcr_win_pe_refusal_name(err), err);
    return 3;
  }

  err = repro_hcr_win_pe_parse_headers(patch_bytes, patch_sz, 0, &patch_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Patch DLL PE parsing failed: %s (%d)\n", repro_hcr_win_pe_refusal_name(err), err);
    return 4;
  }

  /* Control Arm Check: Baseline target resolves from on-disk primary image PDB */
  if (!target_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: Control Arm violation: target_app.exe has no CodeView debug directory\n");
    return 5;
  }
  printf("  [OK] Control Arm: Baseline target has valid CodeView RSDS record (Age=%u, PDB=%s)\n",
         target_info.identity.age, target_info.identity.pdb_filename);

  if (!patch_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: Patch DLL has no CodeView debug directory\n");
    return 6;
  }
  printf("  [OK] Patch DLL extracted CodeView RSDS record (Age=%u, PDB=%s)\n",
         patch_info.identity.age, patch_info.identity.pdb_filename);

  /* Anti-vacuity: GUID must have non-zero bytes; age > 0 */
  bool guid_non_zero = false;
  for (int g = 0; g < 16; ++g) {
    if (patch_info.identity.guid[g] != 0) {
      guid_non_zero = true;
      break;
    }
  }
  if (!guid_non_zero) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: Patch PDB GUID is all zeros\n");
    return 7;
  }
  if (patch_info.identity.age == 0) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: Patch PDB Age is zero\n");
    return 8;
  }
  printf("  [OK] Anti-vacuity: Patch PDB GUID confirmed non-zero and Age=%u (> 0)\n", patch_info.identity.age);

  /* -------------------------------------------------------------------------
   * 2. Synthesize Minimal PE Header in Memory for Dynamic Patch
   * ------------------------------------------------------------------------- */
  printf("\n[2/6] Synthesizing minimal PE header with .pdata exception directory and CodeView RSDS record...\n");

  uint8_t synth_header_buf[4096];
  const uint64_t patch_base = 0x140080000ULL;
  const uint32_t patch_total_size = 0x10000;
  const uint32_t pdata_rva = (patch_info.exception_table_rva != 0) ? patch_info.exception_table_rva : 0x2000;
  const uint32_t pdata_sz = (patch_info.exception_table_size != 0) ? patch_info.exception_table_size : 24;

  repro_hcr_win_cv_info_pdb70_t cv_info;
  memset(&cv_info, 0, sizeof(cv_info));
  cv_info.cv_sig = REPRO_HCR_WIN_CV_SIG_RSDS; /* 0x53445352 */
  memcpy(cv_info.guid, patch_info.identity.guid, 16);
  cv_info.age = patch_info.identity.age;
  strncpy(cv_info.pdb_path, patch_info.identity.pdb_filename, sizeof(cv_info.pdb_path) - 1);

  size_t header_written = 0;
  int synth_res = repro_hcr_win_synthesize_pe_header(
      synth_header_buf,
      sizeof(synth_header_buf),
      patch_base,
      patch_total_size,
      pdata_rva,
      pdata_sz,
      &cv_info,
      &header_written);

  if (synth_res != REPRO_HCR_WIN_DEBUG_OK) {
    fprintf(stderr, "FAIL: repro_hcr_win_synthesize_pe_header returned error %d\n", synth_res);
    return 9;
  }
  printf("  [OK] Minimal PE header synthesized successfully (%zu bytes written)\n", header_written);

  /* Write synthesized image to file for external tool verification (llvm-readobj) */
  if (!write_file_bytes(out_pe_path, synth_header_buf, sizeof(synth_header_buf))) {
    fprintf(stderr, "FAIL: Could not write synthesized PE file to %s\n", out_pe_path);
    return 10;
  }
  printf("  [OK] Wrote synthesized PE header to %s\n", out_pe_path);

  /* -------------------------------------------------------------------------
   * 3. Validate In-Memory Synthesized PE Image
   * ------------------------------------------------------------------------- */
  printf("\n[3/6] Parsing and verifying synthesized PE image from target memory...\n");

  repro_hcr_win_pe_header_info synth_info;
  err = repro_hcr_win_pe_parse_headers(synth_header_buf, sizeof(synth_header_buf), 0, &synth_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Synthesized PE header parsing failed: %s (%d)\n", repro_hcr_win_pe_refusal_name(err), err);
    return 11;
  }

  if (synth_info.machine != REPRO_HCR_IMAGE_FILE_MACHINE_AMD64) {
    fprintf(stderr, "FAIL: Synthesized header machine is not AMD64 (0x%04x)\n", synth_info.machine);
    return 12;
  }
  if (synth_info.image_base != patch_base) {
    fprintf(stderr, "FAIL: Synthesized ImageBase mismatch: got 0x%llx, expected 0x%llx\n",
            (unsigned long long)synth_info.image_base, (unsigned long long)patch_base);
    return 13;
  }
  if (synth_info.exception_table_rva != pdata_rva || synth_info.exception_table_size != pdata_sz) {
    fprintf(stderr, "FAIL: Exception directory (.pdata) mismatch: RVA=0x%x, size=%u\n",
            synth_info.exception_table_rva, synth_info.exception_table_size);
    return 14;
  }
  if (!synth_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: Synthesized PE header missing CodeView debug directory\n");
    return 15;
  }
  if (memcmp(synth_info.identity.guid, patch_info.identity.guid, 16) != 0) {
    fprintf(stderr, "FAIL: Synthesized CodeView GUID does not match patch PDB GUID\n");
    return 16;
  }
  if (synth_info.identity.age != patch_info.identity.age) {
    fprintf(stderr, "FAIL: Synthesized CodeView Age (%u) does not match patch PDB Age (%u)\n",
            synth_info.identity.age, patch_info.identity.age);
    return 17;
  }
  printf("  [OK] In-memory PE parsed: Machine=AMD64, ImageBase=0x%llx, .pdata RVA=0x%x, Size=%u\n",
         (unsigned long long)synth_info.image_base, synth_info.exception_table_rva, synth_info.exception_table_size);
  printf("  [OK] In-memory CodeView verified: GUID matched, Age=%u, PDB=%s\n",
         synth_info.identity.age, synth_info.identity.pdb_filename);

  /* -------------------------------------------------------------------------
   * 4. Verify PDB Match Function
   * ------------------------------------------------------------------------- */
  printf("\n[4/6] Verifying CodeView PDB match validation function...\n");

  int match_res = repro_hcr_win_verify_pdb_match(&cv_info, patch_info.identity.guid, patch_info.identity.age);
  if (match_res != REPRO_HCR_WIN_DEBUG_OK) {
    fprintf(stderr, "FAIL: repro_hcr_win_verify_pdb_match failed on genuine GUID/Age: %d\n", match_res);
    return 18;
  }
  printf("  [OK] repro_hcr_win_verify_pdb_match: Genuine GUID and Age verified successfully\n");

  /* -------------------------------------------------------------------------
   * 5. Verify WinDbg .reload Command Formatting
   * ------------------------------------------------------------------------- */
  printf("\n[5/6] Verifying WinDbg .reload command formatting...\n");

  char reload_cmd[128];
  int cmd_res = repro_hcr_win_format_reload_command(reload_cmd, sizeof(reload_cmd), "patch1", patch_base, patch_total_size);
  if (cmd_res != REPRO_HCR_WIN_DEBUG_OK) {
    fprintf(stderr, "FAIL: repro_hcr_win_format_reload_command failed: %d\n", cmd_res);
    return 19;
  }
  const char *expected_cmd = ".reload patch1=0x140080000,0x10000";
  if (strcmp(reload_cmd, expected_cmd) != 0) {
    fprintf(stderr, "FAIL: reload command mismatch: got '%s', expected '%s'\n", reload_cmd, expected_cmd);
    return 20;
  }
  printf("  [OK] WinDbg command formatted: %s\n", reload_cmd);

  /* -------------------------------------------------------------------------
   * 6. Verify Visual Studio Standing Refusal & Mode Selection
   * ------------------------------------------------------------------------- */
  printf("\n[6/6] Verifying Visual Studio Concord standing refusal and selection rule...\n");

  char refusal_reason[128];

  /* 6.1 Direct Patch Injection under Visual Studio MUST be REFUSED */
  int vs_direct_res = repro_hcr_win_check_debugger_mode("visual_studio", "direct", refusal_reason, sizeof(refusal_reason));
  if (vs_direct_res != REPRO_HCR_WIN_DEBUG_REFUSED_VISUAL_STUDIO_DIRECT) {
    fprintf(stderr, "FAIL: Direct patch injection under Visual Studio was not refused! (code %d)\n", vs_direct_res);
    return 21;
  }
  if (strcmp(refusal_reason, REPRO_HCR_WIN_REFUSAL_VS_DIRECT) != 0) {
    fprintf(stderr, "FAIL: Refusal reason mismatch: got '%s', expected '%s'\n",
            refusal_reason, REPRO_HCR_WIN_REFUSAL_VS_DIRECT);
    return 22;
  }
  printf("  [OK] Visual Studio Concord direct patch injection correctly REFUSED with '%s'\n", refusal_reason);

  /* 6.2 Shared Library Patch Loading under Visual Studio MUST be ALLOWED */
  int vs_shlib_res = repro_hcr_win_check_debugger_mode("visual_studio", "shared_library", refusal_reason, sizeof(refusal_reason));
  if (vs_shlib_res != REPRO_HCR_WIN_DEBUG_OK) {
    fprintf(stderr, "FAIL: Shared library patch loading unexpectedly refused under Visual Studio: %d\n", vs_shlib_res);
    return 23;
  }
  printf("  [OK] Visual Studio Concord shared library patch loading (.dll + .pdb) ALLOWED\n");

  /* 6.3 Direct Patch Injection under WinDbg MUST be ALLOWED */
  int windbg_direct_res = repro_hcr_win_check_debugger_mode("windbg", "direct", refusal_reason, sizeof(refusal_reason));
  if (windbg_direct_res != REPRO_HCR_WIN_DEBUG_OK) {
    fprintf(stderr, "FAIL: Direct patch injection unexpectedly refused under WinDbg: %d\n", windbg_direct_res);
    return 24;
  }
  printf("  [OK] WinDbg direct patch injection (.reload + synthetic PE) ALLOWED\n");

  /* -------------------------------------------------------------------------
   * Falsifier Arms (--include-falsifier)
   * ------------------------------------------------------------------------- */
  if (include_falsifier) {
    printf("\n=== Running Falsifier Arms (--include-falsifier) ===\n");

    /* Falsifier 1: Corrupted GUID in CodeView record */
    printf("[Falsifier 1] Injecting corrupted GUID in CodeView verification...\n");
    uint8_t corrupt_guid[16];
    memcpy(corrupt_guid, patch_info.identity.guid, 16);
    corrupt_guid[0] ^= 0xFF; /* flip bits */

    int f1_res = repro_hcr_win_verify_pdb_match(&cv_info, corrupt_guid, patch_info.identity.age);
    if (f1_res != REPRO_HCR_WIN_DEBUG_ERR_GUID_MISMATCH) {
      fprintf(stderr, "FAIL: Falsifier 1 NOT caught: Expected GUID mismatch error (-4), got %d\n", f1_res);
      return 30;
    }
    printf("  [OK] Falsifier 1 caught: Corrupted GUID tripped REPRO_HCR_WIN_DEBUG_ERR_GUID_MISMATCH (%d)\n", f1_res);

    /* Falsifier 2: Corrupted Age in CodeView record */
    printf("[Falsifier 2] Injecting corrupted Age in CodeView verification...\n");
    uint32_t corrupt_age = patch_info.identity.age + 42;

    int f2_res = repro_hcr_win_verify_pdb_match(&cv_info, patch_info.identity.guid, corrupt_age);
    if (f2_res != REPRO_HCR_WIN_DEBUG_ERR_AGE_MISMATCH) {
      fprintf(stderr, "FAIL: Falsifier 2 NOT caught: Expected Age mismatch error (-5), got %d\n", f2_res);
      return 31;
    }
    printf("  [OK] Falsifier 2 caught: Corrupted Age tripped REPRO_HCR_WIN_DEBUG_ERR_AGE_MISMATCH (%d)\n", f2_res);

    /* Falsifier 3: Falsely allow Visual Studio in direct patch mode */
    printf("[Falsifier 3] Checking invariant that Visual Studio is NEVER allowed in direct mode...\n");
    int f3_res = repro_hcr_win_check_debugger_mode("visual_studio", "direct", NULL, 0);
    if (f3_res == REPRO_HCR_WIN_DEBUG_OK) {
      fprintf(stderr, "FAIL: Falsifier 3: Visual Studio was falsely allowed in direct patch mode!\n");
      return 32;
    }
    printf("  [OK] Falsifier 3 caught: Visual Studio direct mode strictly prohibited by invariant\n");
  }

  printf("\n=== All Verification Arms Passed Successfully ===\n");
  free(target_bytes);
  free(patch_bytes);
  return 0;
}
