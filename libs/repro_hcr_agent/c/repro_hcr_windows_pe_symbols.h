#ifndef REPRO_HCR_WINDOWS_PE_SYMBOLS_H
#define REPRO_HCR_WINDOWS_PE_SYMBOLS_H

#if !defined(_WIN32) || !defined(_M_X64)
#error "repro_hcr_windows_pe_symbols.h requires Windows x86_64"
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdint.h>
#include <string.h>

enum repro_hcr_windows_pe_status {
  REPRO_HCR_WINDOWS_PE_OK = 0,
  REPRO_HCR_WINDOWS_PE_INVALID_ARGUMENT = 1,
  REPRO_HCR_WINDOWS_PE_INVALID_IMAGE = 2,
  REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_MISSING = 3,
  REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_CONFLICT = 4,
  REPRO_HCR_WINDOWS_PE_SNAPSHOT_FAILED = 5,
  REPRO_HCR_WINDOWS_PE_ENUMERATION_FAILED = 6,
  REPRO_HCR_WINDOWS_PE_MODULE_ABSENT = 7,
  REPRO_HCR_WINDOWS_PE_MODULE_AMBIGUOUS = 8,
  REPRO_HCR_WINDOWS_PE_RETAIN_FAILED = 9,
  REPRO_HCR_WINDOWS_PE_REVALIDATION_FAILED = 10,
  REPRO_HCR_WINDOWS_PE_RVA_OUT_OF_RANGE = 11,
  REPRO_HCR_WINDOWS_PE_RELEASE_FAILED = 12
};

struct repro_hcr_windows_pdb_identity {
  uint8_t guid[16];
  uint32_t age;
};

struct repro_hcr_windows_retained_module {
  HMODULE handle;
  uintptr_t base;
  uint32_t image_size;
  struct repro_hcr_windows_pdb_identity identity;
  wchar_t path[MAX_PATH];
};

static int repro_hcr_windows_pe_range_ok(
    uint32_t image_size, uint32_t offset, uint32_t length) {
  return offset <= image_size && length <= image_size - offset;
}

static int repro_hcr_windows_pdb_identity_equal(
    const struct repro_hcr_windows_pdb_identity *left,
    const struct repro_hcr_windows_pdb_identity *right) {
  return left->age == right->age &&
      memcmp(left->guid, right->guid, sizeof(left->guid)) == 0;
}

static enum repro_hcr_windows_pe_status
repro_hcr_windows_pe_identity_at_base(
    uintptr_t base,
    uint32_t snapshot_image_size,
    struct repro_hcr_windows_pdb_identity *identity,
    uint32_t *verified_image_size) {
  const IMAGE_DOS_HEADER *dos;
  const IMAGE_NT_HEADERS64 *nt;
  const IMAGE_DATA_DIRECTORY *directory;
  const IMAGE_DEBUG_DIRECTORY *debug;
  uint32_t image_size;
  uint32_t count;
  uint32_t index;
  int found = 0;

  if (base == 0 || identity == NULL || verified_image_size == NULL ||
      snapshot_image_size < sizeof(IMAGE_DOS_HEADER)) {
    return REPRO_HCR_WINDOWS_PE_INVALID_ARGUMENT;
  }
  dos = (const IMAGE_DOS_HEADER *)base;
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
      !repro_hcr_windows_pe_range_ok(
          snapshot_image_size, (uint32_t)dos->e_lfanew,
          (uint32_t)sizeof(IMAGE_NT_HEADERS64))) {
    return REPRO_HCR_WINDOWS_PE_INVALID_IMAGE;
  }
  nt = (const IMAGE_NT_HEADERS64 *)(base + (uint32_t)dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_DEBUG) {
    return REPRO_HCR_WINDOWS_PE_INVALID_IMAGE;
  }
  image_size = nt->OptionalHeader.SizeOfImage;
  if (image_size == 0 || image_size > snapshot_image_size) {
    return REPRO_HCR_WINDOWS_PE_INVALID_IMAGE;
  }
  directory = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];
  if (directory->VirtualAddress == 0 ||
      directory->Size < sizeof(IMAGE_DEBUG_DIRECTORY) ||
      directory->Size % sizeof(IMAGE_DEBUG_DIRECTORY) != 0 ||
      !repro_hcr_windows_pe_range_ok(
          image_size, directory->VirtualAddress, directory->Size)) {
    return REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_MISSING;
  }
  debug = (const IMAGE_DEBUG_DIRECTORY *)(base + directory->VirtualAddress);
  count = directory->Size / (uint32_t)sizeof(IMAGE_DEBUG_DIRECTORY);
  for (index = 0; index < count; ++index) {
    const uint8_t *record;
    struct repro_hcr_windows_pdb_identity candidate;
    if (debug[index].Type != IMAGE_DEBUG_TYPE_CODEVIEW ||
        debug[index].AddressOfRawData == 0 ||
        debug[index].SizeOfData < 25 ||
        !repro_hcr_windows_pe_range_ok(
            image_size, debug[index].AddressOfRawData,
            debug[index].SizeOfData)) {
      continue;
    }
    record = (const uint8_t *)(base + debug[index].AddressOfRawData);
    if (memcmp(record, "RSDS", 4) != 0) {
      continue;
    }
    memcpy(candidate.guid, record + 4, sizeof(candidate.guid));
    memcpy(&candidate.age, record + 20, sizeof(candidate.age));
    if (found && !repro_hcr_windows_pdb_identity_equal(identity, &candidate)) {
      return REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_CONFLICT;
    }
    if (!found) {
      *identity = candidate;
      found = 1;
    }
  }
  if (!found) {
    return REPRO_HCR_WINDOWS_PE_CODEVIEW_IDENTITY_MISSING;
  }
  *verified_image_size = image_size;
  return REPRO_HCR_WINDOWS_PE_OK;
}

static enum repro_hcr_windows_pe_status
repro_hcr_windows_pe_retain_module(
    const struct repro_hcr_windows_pdb_identity *expected,
    struct repro_hcr_windows_retained_module *result) {
  HANDLE snapshot = INVALID_HANDLE_VALUE;
  MODULEENTRY32W entry;
  MODULEENTRY32W match;
  DWORD last_error;
  unsigned int retry;
  uint32_t match_count = 0;
  enum repro_hcr_windows_pe_status status;
  HMODULE retained = NULL;

  if (expected == NULL || result == NULL) {
    return REPRO_HCR_WINDOWS_PE_INVALID_ARGUMENT;
  }
  memset(result, 0, sizeof(*result));
  memset(&match, 0, sizeof(match));
  for (retry = 0; retry < 64; ++retry) {
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    if (snapshot != INVALID_HANDLE_VALUE) {
      break;
    }
    if (GetLastError() != ERROR_BAD_LENGTH) {
      return REPRO_HCR_WINDOWS_PE_SNAPSHOT_FAILED;
    }
  }
  if (snapshot == INVALID_HANDLE_VALUE) {
    return REPRO_HCR_WINDOWS_PE_SNAPSHOT_FAILED;
  }
  memset(&entry, 0, sizeof(entry));
  entry.dwSize = sizeof(entry);
  if (!Module32FirstW(snapshot, &entry)) {
    CloseHandle(snapshot);
    return REPRO_HCR_WINDOWS_PE_ENUMERATION_FAILED;
  }
  do {
    struct repro_hcr_windows_pdb_identity candidate;
    uint32_t image_size = 0;
    status = repro_hcr_windows_pe_identity_at_base(
        (uintptr_t)entry.modBaseAddr, entry.modBaseSize, &candidate, &image_size);
    if (status == REPRO_HCR_WINDOWS_PE_OK &&
        repro_hcr_windows_pdb_identity_equal(expected, &candidate)) {
      match_count += 1;
      if (match_count == 1) {
        match = entry;
      }
    }
  } while (Module32NextW(snapshot, &entry));
  last_error = GetLastError();
  CloseHandle(snapshot);
  if (last_error != ERROR_NO_MORE_FILES) {
    return REPRO_HCR_WINDOWS_PE_ENUMERATION_FAILED;
  }
  if (match_count == 0) {
    return REPRO_HCR_WINDOWS_PE_MODULE_ABSENT;
  }
  if (match_count != 1) {
    return REPRO_HCR_WINDOWS_PE_MODULE_AMBIGUOUS;
  }
  if (!GetModuleHandleExW(
          GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
          (LPCWSTR)(uintptr_t)match.modBaseAddr, &retained)) {
    return REPRO_HCR_WINDOWS_PE_RETAIN_FAILED;
  }
  result->handle = retained;
  result->base = (uintptr_t)retained;
  result->image_size = match.modBaseSize;
  result->identity = *expected;
  wcsncpy_s(result->path, MAX_PATH, match.szExePath, _TRUNCATE);
  if (result->base != (uintptr_t)match.modBaseAddr) {
    FreeLibrary(retained);
    memset(result, 0, sizeof(*result));
    return REPRO_HCR_WINDOWS_PE_REVALIDATION_FAILED;
  }
  {
    struct repro_hcr_windows_pdb_identity revalidated;
    uint32_t verified_size = 0;
    status = repro_hcr_windows_pe_identity_at_base(
        result->base, result->image_size, &revalidated, &verified_size);
    if (status != REPRO_HCR_WINDOWS_PE_OK ||
        !repro_hcr_windows_pdb_identity_equal(expected, &revalidated)) {
      FreeLibrary(retained);
      memset(result, 0, sizeof(*result));
      return REPRO_HCR_WINDOWS_PE_REVALIDATION_FAILED;
    }
    result->image_size = verified_size;
    result->identity = revalidated;
  }
  return REPRO_HCR_WINDOWS_PE_OK;
}

static enum repro_hcr_windows_pe_status
repro_hcr_windows_pe_resolve_rva(
    const struct repro_hcr_windows_retained_module *module,
    uint64_t rva,
    uintptr_t *address) {
  if (module == NULL || module->handle == NULL || address == NULL) {
    return REPRO_HCR_WINDOWS_PE_INVALID_ARGUMENT;
  }
  if (rva >= module->image_size || rva > UINTPTR_MAX - module->base) {
    return REPRO_HCR_WINDOWS_PE_RVA_OUT_OF_RANGE;
  }
  *address = module->base + (uintptr_t)rva;
  return REPRO_HCR_WINDOWS_PE_OK;
}

static enum repro_hcr_windows_pe_status
repro_hcr_windows_pe_release_module(
    struct repro_hcr_windows_retained_module *module) {
  if (module == NULL || module->handle == NULL) {
    return REPRO_HCR_WINDOWS_PE_INVALID_ARGUMENT;
  }
  if (!FreeLibrary(module->handle)) {
    return REPRO_HCR_WINDOWS_PE_RELEASE_FAILED;
  }
  memset(module, 0, sizeof(*module));
  return REPRO_HCR_WINDOWS_PE_OK;
}

#endif
