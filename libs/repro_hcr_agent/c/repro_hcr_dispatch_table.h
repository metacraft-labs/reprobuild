#ifndef REPRO_HCR_DISPATCH_TABLE_H
#define REPRO_HCR_DISPATCH_TABLE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32) && defined(REPRO_HCR_AGENT_BUILD_DLL)
#define REPRO_HCR_DISPATCH_API __declspec(dllexport)
#else
#define REPRO_HCR_DISPATCH_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Dispatch redirection kinds (§1, §3, §4, §5).
 */
typedef enum repro_hcr_dispatch_kind {
  REPRO_HCR_DISPATCH_MACHO_LAZY_SYMBOL_PTR = 1,
  REPRO_HCR_DISPATCH_ELF_GOT_PLT           = 2,
  REPRO_HCR_DISPATCH_CPP_VTABLE            = 3,
  REPRO_HCR_DISPATCH_PE_IAT                = 4
} repro_hcr_dispatch_kind_t;

/*
 * Transactional rollback log entry.
 */
typedef struct repro_hcr_dispatch_rollback_entry {
  uint64_t tx_id;
  repro_hcr_dispatch_kind_t kind;
  void **slot_addr;
  void *original_target;
  void *patched_target;
  char symbol_name[128];
  int slot_index;
} repro_hcr_dispatch_rollback_entry_t;

/*
 * Memory protection helpers:
 * - On Darwin: vm_protect with VM_PROT_COPY and mprotect fallback
 * - On Linux: mprotect
 * - On Windows: VirtualProtect
 */
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_make_writable(
    void *addr, size_t size, void **out_page, size_t *out_page_size, int *out_was_writable);
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_restore_protection(
    void *page, size_t page_size, int was_writable);

/*
 * Transactional Rollback Log:
 * - begin: allocates and sets active transaction ID
 * - record: registers an entry in the rollback log
 * - rollback_transaction: rolls back entries for tx_id in reverse order
 * - rollback_all: rolls back all entries in the log in reverse order
 * - commit_transaction: commits entries for tx_id (purges from log)
 * - count: returns number of active rollback entries in log
 */
REPRO_HCR_DISPATCH_API uint64_t repro_hcr_dispatch_begin_transaction(void);
REPRO_HCR_DISPATCH_API uint64_t repro_hcr_dispatch_active_transaction(void);
REPRO_HCR_DISPATCH_API void repro_hcr_dispatch_set_active_transaction(uint64_t tx_id);
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_record_entry(
    uint64_t tx_id,
    repro_hcr_dispatch_kind_t kind,
    void **slot_addr,
    void *original_target,
    void *patched_target,
    const char *symbol_name,
    int slot_index);
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_rollback_transaction(uint64_t tx_id);
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_rollback_all(void);
REPRO_HCR_DISPATCH_API int repro_hcr_dispatch_commit_transaction(uint64_t tx_id);
REPRO_HCR_DISPATCH_API size_t repro_hcr_dispatch_rollback_log_count(void);
REPRO_HCR_DISPATCH_API void repro_hcr_dispatch_clear_rollback_log(void);

/*
 * Mach-O Lazy Symbol Pointer Interception (__la_symbol_ptr).
 * Walks loaded images, finds section in __DATA or __DATA_CONST, maps indirect
 * symbol table indices, atomically stores new_target, and records rollback entry.
 */
REPRO_HCR_DISPATCH_API int repro_hcr_patch_macho_lazy_symbol(
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_macho_lazy_symbol_tx(
    uint64_t tx_id,
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);

/*
 * Linux ELF .got.plt Patching.
 * Walks loaded shared objects via dl_iterate_phdr, finds DT_PLTGOT / DT_JMPREL,
 * locates the relocation slot matching symbol_name, updates with memory protection,
 * and records rollback entry.
 */
REPRO_HCR_DISPATCH_API int repro_hcr_patch_elf_got_plt(
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_elf_got_plt_tx(
    uint64_t tx_id,
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);

/*
 * Windows PE IAT Patching.
 */
REPRO_HCR_DISPATCH_API int repro_hcr_patch_pe_iat(
    const char *module_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_pe_iat_tx(
    uint64_t tx_id,
    const char *module_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target);

/*
 * C++ Vtable Interception.
 * Supports Itanium C++ ABI:
 * - discover_vtable_from_instance: reads object's vptr at offset 0
 * - find_vtable_by_symbol: looks up _ZTV... symbol and offsets by 2 * sizeof(void*)
 * - patch_vtable_slot: atomically stores new method in vptr[slot_index]
 * - patch_vtable_method: scans vptr for old_method and patches slot
 */
REPRO_HCR_DISPATCH_API void **repro_hcr_discover_vtable_from_instance(
    void *class_instance);
REPRO_HCR_DISPATCH_API void **repro_hcr_find_vtable_by_symbol(
    const char *mangled_vtable_symbol);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_vtable_slot(
    void **vptr,
    int slot_index,
    void *new_method,
    void **out_old_method);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_vtable_slot_tx(
    uint64_t tx_id,
    void **vptr,
    int slot_index,
    void *new_method,
    void **out_old_method);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_vtable_method(
    void **vptr,
    size_t max_slots,
    void *old_method,
    void *new_method,
    int *out_slot_index);
REPRO_HCR_DISPATCH_API int repro_hcr_patch_vtable_method_tx(
    uint64_t tx_id,
    void **vptr,
    size_t max_slots,
    void *old_method,
    void *new_method,
    int *out_slot_index);

#ifdef __cplusplus
}
#endif

#endif /* REPRO_HCR_DISPATCH_TABLE_H */
