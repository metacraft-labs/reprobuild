#ifndef REPRO_HCR_WINDOWS_PDB_H
#define REPRO_HCR_WINDOWS_PDB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum repro_hcr_windows_pdb_status {
  REPRO_HCR_WINDOWS_PDB_OK = 0,
  REPRO_HCR_WINDOWS_PDB_INITIALIZE_FAILED = 1,
  REPRO_HCR_WINDOWS_PDB_SEARCH_PATH_FAILED = 2,
  REPRO_HCR_WINDOWS_PDB_LOAD_FAILED = 3,
  REPRO_HCR_WINDOWS_PDB_ENUMERATE_FAILED = 4,
  REPRO_HCR_WINDOWS_PDB_SYMBOL_ABSENT = 5,
  REPRO_HCR_WINDOWS_PDB_SYMBOL_AMBIGUOUS = 6,
  REPRO_HCR_WINDOWS_PDB_INVALID_ADDRESS = 7,
  REPRO_HCR_WINDOWS_PDB_CLEANUP_FAILED = 8
};

struct repro_hcr_windows_pdb_result {
  uint32_t status;
  uint32_t match_count;
  uint32_t win32_error;
  uint32_t function_size;
  uint64_t rva;
};

/*
 * DbgHelp documents its API as single-threaded.  This function serializes the
 * complete initialize/load/enumerate/unload/cleanup transaction internally.
 * image_path names the PE whose matching PDB is in search_path.  symbol_name
 * is filtered again in the callback, so wildcard syntax never broadens the
 * accepted result.  Only SymTagFunction records count.
 */
struct repro_hcr_windows_pdb_result repro_hcr_windows_pdb_resolve_function(
    const wchar_t *image_path,
    const wchar_t *search_path,
    const wchar_t *symbol_name);

#ifdef __cplusplus
}
#endif

#endif
