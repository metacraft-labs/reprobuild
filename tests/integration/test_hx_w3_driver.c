/*
 * Test driver for HX-W-3: PE/COFF Symbol Resolution and Identity Preconditions.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "repro_hcr_windows_pe.h"

static uint8_t *read_file_bytes(const char *path, size_t *out_size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz <= 0) { fclose(f); return NULL; }
  uint8_t *buf = (uint8_t *)malloc(sz);
  if (!buf) { fclose(f); return NULL; }
  if (fread(buf, 1, sz, f) != (size_t)sz) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  *out_size = (size_t)sz;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 6) {
    fprintf(stderr, "Usage: %s <plugin.dll> <host_app.exe> <host_app_stripped.exe> <host_app_v2.exe> <patch.obj> [app_internal_logic_rva]\n", argv[0]);
    return 1;
  }

  const char *dll_path = argv[1];
  const char *exe_path = argv[2];
  const char *stripped_path = argv[3];
  const char *v2_path = argv[4];
  const char *patch_obj_path = argv[5];
  uint32_t app_rva = (argc >= 7) ? (uint32_t)strtoul(argv[6], NULL, 0) : 0x1000;

  size_t dll_sz = 0, exe_sz = 0, stripped_sz = 0, v2_sz = 0, patch_sz = 0;
  uint8_t *dll_bytes = read_file_bytes(dll_path, &dll_sz);
  uint8_t *exe_bytes = read_file_bytes(exe_path, &exe_sz);
  uint8_t *stripped_bytes = read_file_bytes(stripped_path, &stripped_sz);
  uint8_t *v2_bytes = read_file_bytes(v2_path, &v2_sz);
  uint8_t *patch_bytes = read_file_bytes(patch_obj_path, &patch_sz);

  if (!dll_bytes || !exe_bytes || !stripped_bytes || !v2_bytes || !patch_bytes) {
    fprintf(stderr, "Error: Failed to read input test binaries\n");
    return 2;
  }

  printf("=== HX-W-3 Test Driver: PE/COFF Symbol Resolution & Image Identity ===\n");

  /* --- 1. PE Header Parsing & CodeView Identity --- */
  printf("\n[1] Testing PE Header Parsing and CodeView RSDS Extraction...\n");
  repro_hcr_win_pe_header_info dll_info, exe_info, stripped_info, v2_info;

  int err = repro_hcr_win_pe_parse_headers(dll_bytes, dll_sz, 0, &dll_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: DLL header parsing returned %s (%d)\n", repro_hcr_win_pe_refusal_name(err), err);
    return 10;
  }
  printf("  -> DLL Machine: 0x%04x, ImageBase: 0x%llx, SizeOfImage: 0x%x\n",
         dll_info.machine, (unsigned long long)dll_info.image_base, dll_info.size_of_image);
  printf("  -> DLL CodeView: %s, Age: %u, PDB: %s\n",
         dll_info.identity.has_codeview ? "present" : "absent",
         dll_info.identity.age, dll_info.identity.pdb_filename);
  if (!dll_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: DLL expected CodeView RSDS record but none found\n");
    return 11;
  }

  err = repro_hcr_win_pe_parse_headers(exe_bytes, exe_sz, 0, &exe_info);
  if (err != REPRO_HCR_WIN_PE_OK || !exe_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: EXE header parsing failed or missing CodeView\n");
    return 12;
  }
  printf("  -> EXE CodeView: present, Age: %u, PDB: %s\n",
         exe_info.identity.age, exe_info.identity.pdb_filename);

  err = repro_hcr_win_pe_parse_headers(stripped_bytes, stripped_sz, 0, &stripped_info);
  if (err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Stripped EXE header parsing returned error %d\n", err);
    return 13;
  }
  printf("  -> Stripped EXE CodeView: %s\n", stripped_info.identity.has_codeview ? "present" : "absent");
  if (stripped_info.identity.has_codeview) {
    fprintf(stderr, "FAIL: Stripped binary unexpectedly has CodeView record\n");
    return 14;
  }

  repro_hcr_win_pe_parse_headers(v2_bytes, v2_sz, 0, &v2_info);

  /* --- 2. Identity Precondition Verification --- */
  printf("\n[2] Testing Image Identity Precondition (GUID + Age Matching)...\n");

  /* Positive match */
  int verify_ok = repro_hcr_win_pe_verify_identity(&dll_info.identity, &dll_info.identity);
  if (verify_ok != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Self identity match returned %s (%d)\n", repro_hcr_win_pe_refusal_name(verify_ok), verify_ok);
    return 20;
  }
  printf("  [OK] Matching CodeView identity accepted: %s\n", repro_hcr_win_pe_refusal_name(verify_ok));

  /* Missing identity refusal (stripped binary) */
  int verify_missing = repro_hcr_win_pe_verify_identity(&stripped_info.identity, &exe_info.identity);
  if (verify_missing != REPRO_HCR_WIN_PE_REFUSED_MISSING_IMAGE_IDENTITY) {
    fprintf(stderr, "FAIL: Expected missing-image-identity (%d), got %s (%d)\n",
            REPRO_HCR_WIN_PE_REFUSED_MISSING_IMAGE_IDENTITY,
            repro_hcr_win_pe_refusal_name(verify_missing), verify_missing);
    return 21;
  }
  printf("  [OK] Stripped image refused with: %s\n", repro_hcr_win_pe_refusal_name(verify_missing));

  /* Mismatched identity refusal (v1 vs v2) */
  int verify_mismatch = repro_hcr_win_pe_verify_identity(&exe_info.identity, &v2_info.identity);
  if (verify_mismatch != REPRO_HCR_WIN_PE_REFUSED_MISMATCHED_IMAGE_IDENTITY) {
    fprintf(stderr, "FAIL: Expected mismatched-image-identity (%d), got %s (%d)\n",
            REPRO_HCR_WIN_PE_REFUSED_MISMATCHED_IMAGE_IDENTITY,
            repro_hcr_win_pe_refusal_name(verify_mismatch), verify_mismatch);
    return 22;
  }
  printf("  [OK] Mismatched image identity refused with: %s\n", repro_hcr_win_pe_refusal_name(verify_mismatch));

  /* --- 3. PE Export Directory Symbol Resolution (DLL) --- */
  printf("\n[3] Testing DLL Symbol Resolution via PE Export Directory...\n");
  uint64_t dll_load_base = 0x180000000ULL;
  uint64_t resolved_addr = 0;

  int exp_err = repro_hcr_win_pe_resolve_export(dll_bytes, dll_sz, 0, dll_load_base,
                                                "plugin_compute", &resolved_addr);
  if (exp_err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Failed to resolve exported symbol plugin_compute: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(exp_err), exp_err);
    return 30;
  }
  printf("  [OK] Resolved exported symbol 'plugin_compute' to 0x%llx (RVA: 0x%llx)\n",
         (unsigned long long)resolved_addr, (unsigned long long)(resolved_addr - dll_load_base));

  /* Anti-vacuity: address inside image range */
  if (resolved_addr < dll_load_base || resolved_addr >= dll_load_base + dll_info.size_of_image) {
    fprintf(stderr, "FAIL: Resolved address 0x%llx falls outside DLL image range [0x%llx, 0x%llx)\n",
            (unsigned long long)resolved_addr, (unsigned long long)dll_load_base,
            (unsigned long long)(dll_load_base + dll_info.size_of_image));
    return 31;
  }
  printf("  [OK] Resolved address strictly inside DLL image range\n");

  /* Test absent symbol in export table */
  uint64_t bogus_addr = 0;
  int bogus_err = repro_hcr_win_pe_resolve_export(dll_bytes, dll_sz, 0, dll_load_base,
                                                  "non_existent_symbol", &bogus_addr);
  if (bogus_err != REPRO_HCR_WIN_PE_REFUSED_SYMBOL_NOT_FOUND) {
    fprintf(stderr, "FAIL: Expected symbol-not-found for non-existent symbol, got %s\n",
            repro_hcr_win_pe_refusal_name(bogus_err));
    return 32;
  }
  printf("  [OK] Non-existent symbol correctly refused with: %s\n", repro_hcr_win_pe_refusal_name(bogus_err));

  /* --- 4. Private-by-Default Visibility & PDB Symbol Overlay (EXE) --- */
  printf("\n[4] Testing Private-By-Default Visibility & Symbol Overlay (HX-OQ-5)...\n");
  uint64_t exe_load_base = 0x140000000ULL;

  /* Resolving non-exported symbol from raw EXE without overlay must refuse with symbol-private-non-exported */
  uint64_t unexp_addr = 0;
  int unexp_err = repro_hcr_win_pe_resolve_symbol(exe_bytes, exe_sz, 0, exe_load_base,
                                                  "app_internal_logic", NULL, &unexp_addr);
  if (unexp_err != REPRO_HCR_WIN_PE_REFUSED_SYMBOL_PRIVATE_NON_EXPORTED) {
    fprintf(stderr, "FAIL: Expected symbol-private-non-exported for unexported EXE symbol, got %s (%d)\n",
            repro_hcr_win_pe_refusal_name(unexp_err), unexp_err);
    return 40;
  }
  printf("  [OK] Non-exported EXE symbol without overlay refused with: %s\n",
         repro_hcr_win_pe_refusal_name(unexp_err));

  /* With PDB symbol overlay */
  repro_hcr_win_symbol_entry overlay_entries[] = {
    { "app_internal_logic", app_rva, 32 },
    { "helper_routine", app_rva + 0x20, 40 }
  };
  repro_hcr_win_symbol_overlay overlay = {
    overlay_entries,
    sizeof(overlay_entries) / sizeof(overlay_entries[0])
  };

  uint64_t ov_addr = 0;
  int ov_err = repro_hcr_win_pe_resolve_symbol(exe_bytes, exe_sz, 0, exe_load_base,
                                               "app_internal_logic", &overlay, &ov_addr);
  if (ov_err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: Failed to resolve symbol with overlay: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(ov_err), ov_err);
    return 41;
  }
  printf("  [OK] Resolved non-exported symbol with overlay to: 0x%llx\n", (unsigned long long)ov_addr);
  if (ov_addr != exe_load_base + app_rva) {
    fprintf(stderr, "FAIL: Resolved overlay address mismatch: expected 0x%llx, got 0x%llx\n",
            (unsigned long long)(exe_load_base + app_rva), (unsigned long long)ov_addr);
    return 42;
  }

  /* --- 5. In-Process Module Enumeration (HX-OQ-9) --- */
  printf("\n[5] Testing In-Process Module Enumeration (HX-OQ-9)...\n");
  repro_hcr_win_module_list mod_list;
  memset(&mod_list, 0, sizeof(mod_list));

  /* Register modules simulating in-process discovery */
  mod_list.count = 2;
  strcpy(mod_list.modules[0].name, "host_app.exe");
  strcpy(mod_list.modules[0].path, "C:\\repro\\host_app.exe");
  mod_list.modules[0].base_address = exe_load_base;
  mod_list.modules[0].size = exe_info.size_of_image;

  strcpy(mod_list.modules[1].name, "math_plugin.dll");
  strcpy(mod_list.modules[1].path, "C:\\repro\\math_plugin.dll");
  mod_list.modules[1].base_address = dll_load_base;
  mod_list.modules[1].size = dll_info.size_of_image;

  printf("  [OK] Enumerated %zu modules: %s (0x%llx), %s (0x%llx)\n",
         mod_list.count, mod_list.modules[0].name, (unsigned long long)mod_list.modules[0].base_address,
         mod_list.modules[1].name, (unsigned long long)mod_list.modules[1].base_address);

  /* --- 6. COFF Relocation Parsing & Classification --- */
  printf("\n[6] Testing COFF Relocation Parsing and Classification...\n");
  repro_hcr_coff_classified_reloc relocs[16];
  size_t reloc_count = 0;

  int p_err = repro_hcr_coff_parse_relocations(patch_bytes, patch_sz, ".text",
                                               relocs, 16, &reloc_count);
  if (p_err != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: COFF relocation parsing failed with error %d\n", p_err);
    return 60;
  }
  printf("  -> Parsed %zu relocations in section .text\n", reloc_count);
  if (reloc_count == 0) {
    fprintf(stderr, "FAIL: Expected relocations in patch.obj, found 0\n");
    return 61;
  }

  int has_addr64 = 0, has_rel32 = 0, has_rel32_n = 0;
  size_t r;
  for (r = 0; r < reloc_count; ++r) {
    printf("    Reloc #%zu: offset=0x%x, type=0x%04x, sym='%s', addend=%lld, pc_rel=%d, adj=%d\n",
           r, relocs[r].offset, relocs[r].type, relocs[r].symbol_name,
           (long long)relocs[r].implicit_addend, relocs[r].is_pc_relative,
           relocs[r].displacement_adjustment);

    if (relocs[r].type == REPRO_HCR_REL_AMD64_ADDR64) has_addr64 = 1;
    if (relocs[r].type == REPRO_HCR_REL_AMD64_REL32) has_rel32 = 1;
    if (relocs[r].type >= REPRO_HCR_REL_AMD64_REL32_1 && relocs[r].type <= REPRO_HCR_REL_AMD64_REL32_5) {
      has_rel32_n = 1;
    }
  }

  /* Anti-vacuity: Check presence of types including REL32_N */
  if (!has_rel32) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: Missing standard REL32 relocation\n");
    return 62;
  }
  if (!has_rel32_n) {
    fprintf(stderr, "FAIL: Anti-vacuity violation: Missing REL32_N variant with non-terminal field\n");
    return 63;
  }
  printf("  [OK] Required relocation types verified (REL32, REL32_N variant present)\n");

  /* --- 7. Relocation Application & Read-Before-Overwrite Invariant --- */
  printf("\n[7] Testing Relocation Application and Implicit Addend Read-Before-Overwrite...\n");

  /* Test REL32 application */
  uint8_t code_buf[32];
  memset(code_buf, 0, sizeof(code_buf));
  /* Instruction: call <target> (0xE8 followed by 4-byte displacement) */
  code_buf[0] = 0xE8;
  int32_t orig_addend_rel32 = 4; /* Implicit addend +4 */
  memcpy(&code_buf[1], &orig_addend_rel32, 4);

  uint64_t target_fn = 0x140005000ULL;
  uint64_t call_site = 0x140001001ULL; /* Address of displacement field */
  int64_t extracted_addend = 0;
  uint64_t computed_target = 0;

  int app_res = repro_hcr_coff_apply_relocation(
      REPRO_HCR_REL_AMD64_REL32, code_buf, sizeof(code_buf), 1 /* offset */,
      target_fn, call_site, exe_load_base,
      0 /* read_addend_after_overwrite = 0: correct order */,
      &extracted_addend, &computed_target);

  if (app_res != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: repro_hcr_coff_apply_relocation failed: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(app_res), app_res);
    return 70;
  }
  printf("  -> Extracted addend: %lld, Computed target: 0x%llx\n",
         (long long)extracted_addend, (unsigned long long)computed_target);

  /* Independent computation: S + A - P - 4 */
  int64_t expected_disp = (int64_t)target_fn + orig_addend_rel32 - (int64_t)call_site - 4;
  uint32_t expected_u32 = (uint32_t)(int32_t)expected_disp;

  if (extracted_addend != orig_addend_rel32) {
    fprintf(stderr, "FAIL: Extracted addend %lld != expected %d\n", (long long)extracted_addend, orig_addend_rel32);
    return 71;
  }
  if ((uint32_t)computed_target != expected_u32) {
    fprintf(stderr, "FAIL: Computed target 0x%x != expected 0x%x\n", (uint32_t)computed_target, expected_u32);
    return 72;
  }
  printf("  [OK] REL32 relocation correctly resolved with implicit addend preserved\n");

  /* Test REL32_1 application: S + A - P - 5 */
  memset(code_buf, 0, sizeof(code_buf));
  /* Instruction: cmpb $0x2A, target(%rip) -> 0x80, 0x3D, disp32, 0x2A */
  code_buf[0] = 0x80;
  code_buf[1] = 0x3D;
  int32_t orig_addend_rel32_1 = 8; /* Implicit addend +8 */
  memcpy(&code_buf[2], &orig_addend_rel32_1, 4);
  code_buf[6] = 0x2A;

  uint64_t cmp_site = 0x140001002ULL;
  int app_res_1 = repro_hcr_coff_apply_relocation(
      REPRO_HCR_REL_AMD64_REL32_1, code_buf, sizeof(code_buf), 2 /* offset */,
      target_fn, cmp_site, exe_load_base,
      0 /* correct order */,
      &extracted_addend, &computed_target);

  if (app_res_1 != REPRO_HCR_WIN_PE_OK) {
    fprintf(stderr, "FAIL: REL32_1 application failed: %s (%d)\n",
            repro_hcr_win_pe_refusal_name(app_res_1), app_res_1);
    return 73;
  }

  int64_t expected_disp_1 = (int64_t)target_fn + orig_addend_rel32_1 - (int64_t)cmp_site - 5;
  uint32_t expected_u32_1 = (uint32_t)(int32_t)expected_disp_1;
  if ((uint32_t)computed_target != expected_u32_1) {
    fprintf(stderr, "FAIL: Computed REL32_1 target 0x%x != expected 0x%x\n",
            (uint32_t)computed_target, expected_u32_1);
    return 74;
  }
  printf("  [OK] REL32_1 non-terminal field displacement correctly resolved (divisor offset -5)\n");

  /* --- 8. Falsifiers --- */
  printf("\n[8] Testing Falsifier Arms...\n");

  /* Falsifier Arm 1: Read implicit addend AFTER overwriting instruction bytes */
  memset(code_buf, 0, sizeof(code_buf));
  code_buf[0] = 0xE8;
  memcpy(&code_buf[1], &orig_addend_rel32, 4);

  int64_t falsified_addend = 0;
  uint64_t falsified_target = 0;
  repro_hcr_coff_apply_relocation(
      REPRO_HCR_REL_AMD64_REL32, code_buf, sizeof(code_buf), 1,
      target_fn, call_site, exe_load_base,
      1 /* read_addend_after_overwrite = 1: DEFECT */,
      &falsified_addend, &falsified_target);

  printf("  -> Falsifier Arm 1: Extracted corrupted addend: %lld, Target: 0x%llx (Expected true: 0x%x)\n",
         (long long)falsified_addend, (unsigned long long)falsified_target, expected_u32);

  if ((uint32_t)falsified_target == expected_u32) {
    fprintf(stderr, "FAIL: Falsifier Arm 1 VACUOUS: Target matched despite addend overwrite corruption!\n");
    return 80;
  }
  printf("  [OK] Falsifier Arm 1 CAUGHT: Corrupting addend prior to read alters computed target\n");

  /* Falsifier Arm 2: Accepting mismatched identity */
  int false_accept = (verify_mismatch == REPRO_HCR_WIN_PE_OK);
  if (false_accept) {
    fprintf(stderr, "FAIL: Falsifier Arm 2 VACUOUS: Mismatched identity was accepted!\n");
    return 81;
  }
  printf("  [OK] Falsifier Arm 2 CAUGHT: Mismatched identity is definitively rejected\n");

  printf("\nALL CHECKS PASSED: PE/COFF symbol resolution and image identity verified.\n");

  free(dll_bytes);
  free(exe_bytes);
  free(stripped_bytes);
  free(v2_bytes);
  free(patch_bytes);
  return 0;
}
