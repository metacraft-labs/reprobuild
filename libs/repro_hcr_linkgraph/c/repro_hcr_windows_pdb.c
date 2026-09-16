#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <dbghelp.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>

#include "repro_hcr_windows_pdb.h"

struct repro_hcr_windows_pdb_enum_state {
  const wchar_t *expected_name;
  uint64_t module_base;
  uint64_t first_rva;
  uint32_t first_size;
  uint32_t match_count;
  int invalid_address;
};

static SRWLOCK repro_hcr_windows_pdb_lock = SRWLOCK_INIT;

/* CodeView SymTagEnum value. Some MinGW dbghelp.h revisions omit cvconst.h. */
#define REPRO_HCR_SYM_TAG_FUNCTION 5UL

static BOOL CALLBACK repro_hcr_windows_pdb_enum_callback(
    PSYMBOL_INFOW symbol,
    ULONG symbol_size,
    PVOID opaque) {
  struct repro_hcr_windows_pdb_enum_state *state =
      (struct repro_hcr_windows_pdb_enum_state *)opaque;
  (void)symbol_size;
  if (symbol->Tag != REPRO_HCR_SYM_TAG_FUNCTION ||
      wcscmp(symbol->Name, state->expected_name) != 0) {
    return TRUE;
  }
  if (symbol->Address < state->module_base) {
    state->invalid_address = 1;
    return FALSE;
  }
  state->match_count += 1;
  if (state->match_count == 1) {
    state->first_rva = symbol->Address - state->module_base;
    state->first_size = symbol->Size;
  }
  return TRUE;
}

struct repro_hcr_windows_pdb_result repro_hcr_windows_pdb_resolve_function(
    const wchar_t *image_path,
    const wchar_t *search_path,
    const wchar_t *symbol_name) {
  struct repro_hcr_windows_pdb_result result;
  struct repro_hcr_windows_pdb_enum_state state;
  HANDLE process = GetCurrentProcess();
  DWORD64 module_base = 0;
  BOOL enum_ok;
  BOOL cleanup_ok;

  memset(&result, 0, sizeof(result));
  memset(&state, 0, sizeof(state));
  state.expected_name = symbol_name;

  AcquireSRWLockExclusive(&repro_hcr_windows_pdb_lock);
  if (!SymInitializeW(process, NULL, FALSE)) {
    result.status = REPRO_HCR_WINDOWS_PDB_INITIALIZE_FAILED;
    result.win32_error = GetLastError();
    goto release_lock;
  }
  SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME |
                SYMOPT_EXACT_SYMBOLS | SYMOPT_FAIL_CRITICAL_ERRORS);
  if (!SymSetSearchPathW(process, search_path)) {
    result.status = REPRO_HCR_WINDOWS_PDB_SEARCH_PATH_FAILED;
    result.win32_error = GetLastError();
    goto cleanup;
  }
  module_base = SymLoadModuleExW(
      process, NULL, image_path, NULL, 0, 0, NULL, 0);
  if (module_base == 0) {
    result.status = REPRO_HCR_WINDOWS_PDB_LOAD_FAILED;
    result.win32_error = GetLastError();
    goto cleanup;
  }
  state.module_base = (uint64_t)module_base;
  enum_ok = SymEnumSymbolsW(
      process, module_base, symbol_name,
      repro_hcr_windows_pdb_enum_callback, &state);
  if (!enum_ok && !state.invalid_address) {
    result.status = REPRO_HCR_WINDOWS_PDB_ENUMERATE_FAILED;
    result.win32_error = GetLastError();
    goto unload;
  }
  result.match_count = state.match_count;
  if (state.invalid_address) {
    result.status = REPRO_HCR_WINDOWS_PDB_INVALID_ADDRESS;
  } else if (state.match_count == 0) {
    result.status = REPRO_HCR_WINDOWS_PDB_SYMBOL_ABSENT;
  } else if (state.match_count != 1) {
    result.status = REPRO_HCR_WINDOWS_PDB_SYMBOL_AMBIGUOUS;
  } else {
    result.status = REPRO_HCR_WINDOWS_PDB_OK;
    result.rva = state.first_rva;
    result.function_size = state.first_size;
  }

unload:
  if (!SymUnloadModule64(process, module_base) && result.status == 0) {
    result.status = REPRO_HCR_WINDOWS_PDB_CLEANUP_FAILED;
    result.win32_error = GetLastError();
  }
cleanup:
  cleanup_ok = SymCleanup(process);
  if (!cleanup_ok && result.status == 0) {
    result.status = REPRO_HCR_WINDOWS_PDB_CLEANUP_FAILED;
    result.win32_error = GetLastError();
  }
release_lock:
  ReleaseSRWLockExclusive(&repro_hcr_windows_pdb_lock);
  return result;
}
