#ifndef REPRO_HCR_DISPATCH_TABLE_C
#define REPRO_HCR_DISPATCH_TABLE_C

#include "repro_hcr_dispatch_table.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32) || defined(_WIN64)
#include <windows.h>
#include <tlhelp32.h>
#else
#include <dlfcn.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#endif

#if defined(__linux__)
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif
#include <link.h>
#include <elf.h>
#endif

#define REPRO_HCR_DISPATCH_MAX_ROLLBACK_ENTRIES 1024

static repro_hcr_dispatch_rollback_entry_t s_rollback_log[REPRO_HCR_DISPATCH_MAX_ROLLBACK_ENTRIES];
static size_t s_rollback_count = 0;
static uint64_t s_active_tx_id = 0;
static uint64_t s_next_tx_id = 1;
#if defined(_WIN32)
static SRWLOCK s_dispatch_mutex = SRWLOCK_INIT;
static void repro_hcr_dispatch_lock(void) {
  AcquireSRWLockExclusive(&s_dispatch_mutex);
}
static void repro_hcr_dispatch_unlock(void) {
  ReleaseSRWLockExclusive(&s_dispatch_mutex);
}
static void repro_hcr_dispatch_store_pointer(void **slot, void *value) {
  (void)InterlockedExchangePointer((PVOID volatile *)slot, value);
}
#else
static pthread_mutex_t s_dispatch_mutex = PTHREAD_MUTEX_INITIALIZER;
static void repro_hcr_dispatch_lock(void) {
  (void)pthread_mutex_lock(&s_dispatch_mutex);
}
static void repro_hcr_dispatch_unlock(void) {
  (void)pthread_mutex_unlock(&s_dispatch_mutex);
}
static void repro_hcr_dispatch_store_pointer(void **slot, void *value) {
  __atomic_store_n(slot, value, __ATOMIC_RELEASE);
}
#endif

/*
 * Memory protection transition helper.
 */
int repro_hcr_dispatch_make_writable(
    void *addr, size_t size, void **out_page, size_t *out_page_size, int *out_was_writable) {
  if (addr == NULL || size == 0) {
    return -1;
  }

#if defined(_WIN32)
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  long page_size = (long)si.dwPageSize;
#else
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) page_size = 4096;
#endif

  uintptr_t p = (uintptr_t)addr;
  uintptr_t page_start = p & ~((uintptr_t)page_size - 1);
  uintptr_t page_end = (p + size + page_size - 1) & ~((uintptr_t)page_size - 1);
  size_t total = page_end - page_start;

  if (out_page) *out_page = (void *)page_start;
  if (out_page_size) *out_page_size = total;

#if defined(__APPLE__)
  vm_address_t region_addr = (vm_address_t)page_start;
  vm_size_t region_size = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object_name = MACH_PORT_NULL;
  kern_return_t kr = vm_region_64(mach_task_self(), &region_addr, &region_size,
                                  VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                  &count, &object_name);
  if (kr == KERN_SUCCESS && (info.protection & VM_PROT_WRITE)) {
    if (out_was_writable) *out_was_writable = 1;
    return 0;
  }
  if (out_was_writable) *out_was_writable = 0;

  kr = vm_protect(mach_task_self(), (vm_address_t)page_start, (vm_size_t)total,
                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr != KERN_SUCCESS) {
    if (mprotect((void *)page_start, total, PROT_READ | PROT_WRITE) != 0) {
      return -1;
    }
  }
  return 0;
#elif defined(__linux__)
  if (out_was_writable) *out_was_writable = 0;
  if (mprotect((void *)page_start, total, PROT_READ | PROT_WRITE) != 0) {
    return -1;
  }
  return 0;
#elif defined(_WIN32)
  DWORD old_prot;
  if (!VirtualProtect((void *)page_start, total, PAGE_READWRITE, &old_prot)) {
    return -1;
  }
  if (out_was_writable) {
    *out_was_writable = (old_prot == PAGE_READWRITE || old_prot == PAGE_EXECUTE_READWRITE) ? 1 : 0;
  }
  return 0;
#else
  return -1;
#endif
}

int repro_hcr_dispatch_restore_protection(void *page, size_t page_size, int was_writable) {
  if (page == NULL || page_size == 0 || was_writable) {
    return 0;
  }
#if defined(__APPLE__)
  if (mprotect(page, page_size, PROT_READ) != 0) {
    vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)page_size,
               FALSE, VM_PROT_READ);
  }
  return 0;
#elif defined(__linux__)
  return mprotect(page, page_size, PROT_READ);
#elif defined(_WIN32)
  DWORD dummy;
  VirtualProtect(page, page_size, PAGE_READONLY, &dummy);
  return 0;
#else
  return -1;
#endif
}

/*
 * Transactional Rollback Log.
 */
uint64_t repro_hcr_dispatch_begin_transaction(void) {
  repro_hcr_dispatch_lock();
  if (s_next_tx_id == 0) {
    s_next_tx_id = 1;
  }
  uint64_t tx = s_next_tx_id++;
  s_active_tx_id = tx;
  repro_hcr_dispatch_unlock();
  return tx;
}

uint64_t repro_hcr_dispatch_active_transaction(void) {
  repro_hcr_dispatch_lock();
  uint64_t tx = s_active_tx_id;
  repro_hcr_dispatch_unlock();
  return tx;
}

void repro_hcr_dispatch_set_active_transaction(uint64_t tx_id) {
  repro_hcr_dispatch_lock();
  s_active_tx_id = tx_id;
  repro_hcr_dispatch_unlock();
}

int repro_hcr_dispatch_record_entry(
    uint64_t tx_id,
    repro_hcr_dispatch_kind_t kind,
    void **slot_addr,
    void *original_target,
    void *patched_target,
    const char *symbol_name,
    int slot_index) {
  if (slot_addr == NULL) {
    return -1;
  }
  repro_hcr_dispatch_lock();
  if (s_rollback_count >= REPRO_HCR_DISPATCH_MAX_ROLLBACK_ENTRIES) {
    repro_hcr_dispatch_unlock();
    return -2;
  }
  repro_hcr_dispatch_rollback_entry_t *entry = &s_rollback_log[s_rollback_count++];
  entry->tx_id = tx_id;
  entry->kind = kind;
  entry->slot_addr = slot_addr;
  entry->original_target = original_target;
  entry->patched_target = patched_target;
  entry->slot_index = slot_index;
  if (symbol_name != NULL) {
    size_t symbol_length = strlen(symbol_name);
    if (symbol_length >= sizeof(entry->symbol_name)) {
      symbol_length = sizeof(entry->symbol_name) - 1;
    }
    memcpy(entry->symbol_name, symbol_name, symbol_length);
    entry->symbol_name[symbol_length] = '\0';
  } else {
    entry->symbol_name[0] = '\0';
  }
  repro_hcr_dispatch_unlock();
  return 0;
}

static int rollback_single_entry_internal(const repro_hcr_dispatch_rollback_entry_t *entry) {
  if (entry == NULL || entry->slot_addr == NULL) {
    return -1;
  }
  void *page = NULL;
  size_t page_size = 0;
  int was_writable = 0;
  if (repro_hcr_dispatch_make_writable(entry->slot_addr, sizeof(void *), &page, &page_size, &was_writable) != 0) {
    return -2;
  }
  repro_hcr_dispatch_store_pointer(entry->slot_addr, entry->original_target);
  repro_hcr_dispatch_restore_protection(page, page_size, was_writable);
  return 0;
}

int repro_hcr_dispatch_rollback_transaction(uint64_t tx_id) {
  repro_hcr_dispatch_lock();
  int rolled_back = 0;
  if (s_rollback_count > 0) {
    size_t i = s_rollback_count;
    while (i > 0) {
      i--;
      if (s_rollback_log[i].tx_id == tx_id) {
        rollback_single_entry_internal(&s_rollback_log[i]);
        rolled_back++;
        for (size_t j = i; j + 1 < s_rollback_count; ++j) {
          s_rollback_log[j] = s_rollback_log[j + 1];
        }
        s_rollback_count--;
      }
    }
  }
  if (s_active_tx_id == tx_id) {
    s_active_tx_id = 0;
  }
  repro_hcr_dispatch_unlock();
  return rolled_back;
}

int repro_hcr_dispatch_rollback_all(void) {
  repro_hcr_dispatch_lock();
  int rolled_back = 0;
  if (s_rollback_count > 0) {
    size_t i = s_rollback_count;
    while (i > 0) {
      i--;
      rollback_single_entry_internal(&s_rollback_log[i]);
      rolled_back++;
    }
    s_rollback_count = 0;
  }
  s_active_tx_id = 0;
  repro_hcr_dispatch_unlock();
  return rolled_back;
}

int repro_hcr_dispatch_commit_transaction(uint64_t tx_id) {
  repro_hcr_dispatch_lock();
  if (s_rollback_count > 0) {
    size_t i = s_rollback_count;
    while (i > 0) {
      i--;
      if (s_rollback_log[i].tx_id == tx_id) {
        for (size_t j = i; j + 1 < s_rollback_count; ++j) {
          s_rollback_log[j] = s_rollback_log[j + 1];
        }
        s_rollback_count--;
      }
    }
  }
  if (s_active_tx_id == tx_id) {
    s_active_tx_id = 0;
  }
  repro_hcr_dispatch_unlock();
  return 0;
}

size_t repro_hcr_dispatch_rollback_log_count(void) {
  repro_hcr_dispatch_lock();
  size_t c = s_rollback_count;
  repro_hcr_dispatch_unlock();
  return c;
}

void repro_hcr_dispatch_clear_rollback_log(void) {
  repro_hcr_dispatch_lock();
  s_rollback_count = 0;
  s_active_tx_id = 0;
  repro_hcr_dispatch_unlock();
}

/*
 * Mach-O Lazy Symbol Pointer Patching.
 */
int repro_hcr_patch_macho_lazy_symbol_tx(
    uint64_t tx_id,
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
#if defined(__APPLE__)
  if (symbol_name == NULL || symbol_name[0] == '\0') {
    return -1;
  }
  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; ++i) {
    const char *name = _dyld_get_image_name(i);
    if (image_name_filter != NULL && image_name_filter[0] != '\0') {
      if (!name || strstr(name, image_name_filter) == NULL) {
        continue;
      }
    }
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
    if (!hdr || hdr->magic != MH_MAGIC_64) {
      continue;
    }
    intptr_t slide = _dyld_get_image_vmaddr_slide(i);

    const struct segment_command_64 *seg_linkedit = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    const uint8_t *cur = ((const uint8_t *)hdr) + sizeof(struct mach_header_64);
    for (uint32_t c = 0; c < hdr->ncmds; ++c) {
      const struct load_command *lc = (const struct load_command *)cur;
      if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__LINKEDIT") == 0) {
          seg_linkedit = seg;
        }
      } else if (lc->cmd == LC_SYMTAB) {
        symtab_cmd = (const struct symtab_command *)lc;
      } else if (lc->cmd == LC_DYSYMTAB) {
        dysymtab_cmd = (const struct dysymtab_command *)lc;
      }
      cur += lc->cmdsize;
    }

    if (!seg_linkedit || !symtab_cmd || !dysymtab_cmd) {
      continue;
    }

    uintptr_t linkedit_base = (uintptr_t)seg_linkedit->vmaddr + slide - seg_linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);
    const uint32_t *indirect_symtab = (const uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = ((const uint8_t *)hdr) + sizeof(struct mach_header_64);
    for (uint32_t c = 0; c < hdr->ncmds; ++c) {
      const struct load_command *lc = (const struct load_command *)cur;
      if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sects = (const struct section_64 *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; ++s) {
          const struct section_64 *sec = &sects[s];
          uint32_t st = sec->flags & SECTION_TYPE;
          if (st == S_LAZY_SYMBOL_POINTERS || st == S_NON_LAZY_SYMBOL_POINTERS ||
              strncmp(sec->sectname, "__la_symbol_ptr", 15) == 0) {
            void **ptrs = (void **)(sec->addr + slide);
            size_t nptrs = sec->size / sizeof(void *);
            uint32_t ind_off = sec->reserved1;
            for (size_t j = 0; j < nptrs; ++j) {
              if (ind_off + j >= dysymtab_cmd->nindirectsyms) break;
              uint32_t sym_idx = indirect_symtab[ind_off + j];
              if (sym_idx == INDIRECT_SYMBOL_LOCAL || sym_idx == INDIRECT_SYMBOL_ABS ||
                  (sym_idx & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) != 0) {
                continue;
              }
              if (sym_idx >= symtab_cmd->nsyms) continue;
              uint32_t str_idx = symtab[sym_idx].n_un.n_strx;
              if (str_idx >= symtab_cmd->strsize) continue;
              const char *sname = strtab + str_idx;
              bool match = (strcmp(sname, symbol_name) == 0);
              if (!match && sname[0] == '_' && strcmp(sname + 1, symbol_name) == 0) match = true;
              if (!match && symbol_name[0] == '_' && strcmp(sname, symbol_name + 1) == 0) match = true;

              if (match) {
                void **slot = &ptrs[j];
                void *old_val = *slot;
                if (out_old_target) {
                  *out_old_target = old_val;
                }
                void *page = NULL;
                size_t page_size = 0;
                int was_writable = 0;
                if (repro_hcr_dispatch_make_writable(slot, sizeof(void *), &page, &page_size, &was_writable) != 0) {
                  return -2;
                }
                repro_hcr_dispatch_store_pointer(slot, new_target);
                repro_hcr_dispatch_restore_protection(page, page_size, was_writable);

                repro_hcr_dispatch_record_entry(tx_id, REPRO_HCR_DISPATCH_MACHO_LAZY_SYMBOL_PTR,
                                                slot, old_val, new_target, symbol_name, (int)j);
                return 0;
              }
            }
          }
        }
      }
      cur += lc->cmdsize;
    }
  }
  return -1;
#else
  (void)tx_id; (void)image_name_filter; (void)symbol_name; (void)new_target; (void)out_old_target;
  return -1;
#endif
}

int repro_hcr_patch_macho_lazy_symbol(
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
  uint64_t tx = repro_hcr_dispatch_active_transaction();
  if (tx == 0) tx = 1;
  return repro_hcr_patch_macho_lazy_symbol_tx(tx, image_name_filter, symbol_name, new_target, out_old_target);
}

/*
 * Linux ELF .got.plt Patching.
 */
#if defined(__linux__)
struct elf_got_patch_context {
  uint64_t tx_id;
  const char *image_name_filter;
  const char *symbol_name;
  void *new_target;
  void **out_old_target;
  int patched;
};

static int elf_got_patch_callback(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  struct elf_got_patch_context *ctx = (struct elf_got_patch_context *)data;
  if (ctx->patched) return 1;

  if (ctx->image_name_filter && ctx->image_name_filter[0] != '\0') {
    if (!info->dlpi_name || strstr(info->dlpi_name, ctx->image_name_filter) == NULL) {
      return 0;
    }
  }

  const ElfW(Dyn) *dyn = NULL;
  for (int i = 0; i < info->dlpi_phnum; ++i) {
    if (info->dlpi_phdr[i].p_type == PT_DYNAMIC) {
      dyn = (const ElfW(Dyn) *)(info->dlpi_addr + info->dlpi_phdr[i].p_vaddr);
      break;
    }
  }
  if (!dyn) return 0;

  const ElfW(Rela) *rela = NULL;
  size_t relasz = 0;
  const ElfW(Sym) *symtab = NULL;
  const char *strtab = NULL;

  for (const ElfW(Dyn) *d = dyn; d->d_tag != DT_NULL; ++d) {
    if (d->d_tag == DT_JMPREL) {
      rela = (const ElfW(Rela) *)d->d_un.d_ptr;
    } else if (d->d_tag == DT_PLTRELSZ) {
      relasz = d->d_un.d_val;
    } else if (d->d_tag == DT_SYMTAB) {
      symtab = (const ElfW(Sym) *)d->d_un.d_ptr;
    } else if (d->d_tag == DT_STRTAB) {
      strtab = (const char *)d->d_un.d_ptr;
    }
  }

  if (!rela || !symtab || !strtab || relasz == 0) return 0;

  if ((uintptr_t)strtab < info->dlpi_addr && info->dlpi_addr != 0) {
    strtab = (const char *)((uintptr_t)strtab + info->dlpi_addr);
  }
  if ((uintptr_t)symtab < info->dlpi_addr && info->dlpi_addr != 0) {
    symtab = (const ElfW(Sym) *)((uintptr_t)symtab + info->dlpi_addr);
  }
  if ((uintptr_t)rela < info->dlpi_addr && info->dlpi_addr != 0) {
    rela = (const ElfW(Rela) *)((uintptr_t)rela + info->dlpi_addr);
  }

  size_t count = relasz / sizeof(ElfW(Rela));
  for (size_t i = 0; i < count; ++i) {
    uint32_t sym_idx = ELF64_R_SYM(rela[i].r_info);
    const char *name = strtab + symtab[sym_idx].st_name;
    if (strcmp(name, ctx->symbol_name) == 0) {
      void **got_slot = (void **)(info->dlpi_addr + rela[i].r_offset);
      void *old_val = *got_slot;
      if (ctx->out_old_target) {
        *ctx->out_old_target = old_val;
      }
      void *page = NULL;
      size_t page_size = 0;
      int was_writable = 0;
      if (repro_hcr_dispatch_make_writable(got_slot, sizeof(void *), &page, &page_size, &was_writable) != 0) {
        return 0;
      }
      repro_hcr_dispatch_store_pointer(got_slot, ctx->new_target);
      repro_hcr_dispatch_restore_protection(page, page_size, was_writable);

      repro_hcr_dispatch_record_entry(ctx->tx_id, REPRO_HCR_DISPATCH_ELF_GOT_PLT,
                                      got_slot, old_val, ctx->new_target, ctx->symbol_name, (int)i);
      ctx->patched = 1;
      return 1;
    }
  }
  return 0;
}
#endif

int repro_hcr_patch_elf_got_plt_tx(
    uint64_t tx_id,
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
#if defined(__linux__)
  if (symbol_name == NULL || symbol_name[0] == '\0') {
    return -1;
  }
  struct elf_got_patch_context ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.tx_id = tx_id;
  ctx.image_name_filter = image_name_filter;
  ctx.symbol_name = symbol_name;
  ctx.new_target = new_target;
  ctx.out_old_target = out_old_target;
  ctx.patched = 0;

  dl_iterate_phdr(elf_got_patch_callback, &ctx);
  return ctx.patched ? 0 : -1;
#else
  (void)tx_id; (void)image_name_filter; (void)symbol_name; (void)new_target; (void)out_old_target;
  return -1;
#endif
}

int repro_hcr_patch_elf_got_plt(
    const char *image_name_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
  uint64_t tx = repro_hcr_dispatch_active_transaction();
  if (tx == 0) tx = 1;
  return repro_hcr_patch_elf_got_plt_tx(tx, image_name_filter, symbol_name, new_target, out_old_target);
}

/*
 * Windows PE IAT Patching.
 */
#if defined(_WIN32)
static int repro_hcr_ascii_contains_case_insensitive(
    const char *haystack, const char *needle) {
  size_t needle_len;
  if (needle == NULL || needle[0] == '\0') {
    return 1;
  }
  if (haystack == NULL) {
    return 0;
  }
  needle_len = strlen(needle);
  while (*haystack != '\0') {
    if (_strnicmp(haystack, needle, needle_len) == 0) {
      return 1;
    }
    ++haystack;
  }
  return 0;
}

static int repro_hcr_pe_range_valid(
    size_t image_size, uint64_t offset, size_t length) {
  return offset <= image_size && length <= image_size - (size_t)offset;
}

static int repro_hcr_patch_pe_module_iat(
    uint64_t tx_id,
    const MODULEENTRY32 *module,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
  uint8_t *base;
  size_t image_size;
  IMAGE_DOS_HEADER *dos;
  IMAGE_NT_HEADERS64 *nt;
  IMAGE_DATA_DIRECTORY imports;
  size_t descriptor_count;
  size_t descriptor_index;

  if (module == NULL || module->modBaseAddr == NULL ||
      module->modBaseSize < sizeof(IMAGE_DOS_HEADER)) {
    return -1;
  }
  base = (uint8_t *)module->modBaseAddr;
  image_size = (size_t)module->modBaseSize;
  dos = (IMAGE_DOS_HEADER *)base;
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
      !repro_hcr_pe_range_valid(
          image_size, (uint64_t)dos->e_lfanew, sizeof(IMAGE_NT_HEADERS64))) {
    return -1;
  }
  nt = (IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
      nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_IMPORT) {
    return -1;
  }
  imports = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if (imports.VirtualAddress == 0 || imports.Size < sizeof(IMAGE_IMPORT_DESCRIPTOR) ||
      !repro_hcr_pe_range_valid(
          image_size, imports.VirtualAddress, imports.Size)) {
    return -1;
  }
  descriptor_count = imports.Size / sizeof(IMAGE_IMPORT_DESCRIPTOR);
  for (descriptor_index = 0; descriptor_index < descriptor_count;
       ++descriptor_index) {
    IMAGE_IMPORT_DESCRIPTOR *descriptor =
        (IMAGE_IMPORT_DESCRIPTOR *)(base + imports.VirtualAddress) +
        descriptor_index;
    IMAGE_THUNK_DATA64 *names;
    IMAGE_THUNK_DATA64 *slots;
    size_t thunk_index;
    if (descriptor->Name == 0 && descriptor->FirstThunk == 0) {
      break;
    }
    if (descriptor->OriginalFirstThunk == 0 || descriptor->FirstThunk == 0 ||
        !repro_hcr_pe_range_valid(
            image_size, descriptor->OriginalFirstThunk,
            sizeof(IMAGE_THUNK_DATA64)) ||
        !repro_hcr_pe_range_valid(
            image_size, descriptor->FirstThunk,
            sizeof(IMAGE_THUNK_DATA64))) {
      continue;
    }
    names = (IMAGE_THUNK_DATA64 *)(base + descriptor->OriginalFirstThunk);
    slots = (IMAGE_THUNK_DATA64 *)(base + descriptor->FirstThunk);
    for (thunk_index = 0;; ++thunk_index) {
      uint64_t name_offset = descriptor->OriginalFirstThunk +
          thunk_index * sizeof(IMAGE_THUNK_DATA64);
      uint64_t slot_offset = descriptor->FirstThunk +
          thunk_index * sizeof(IMAGE_THUNK_DATA64);
      IMAGE_IMPORT_BY_NAME *import_name;
      const char *name;
      size_t name_capacity;
      void **slot;
      void *old_target;
      void *page = NULL;
      size_t page_size = 0;
      int was_writable = 0;
      int record_status;
      if (!repro_hcr_pe_range_valid(
              image_size, name_offset, sizeof(IMAGE_THUNK_DATA64)) ||
          !repro_hcr_pe_range_valid(
              image_size, slot_offset, sizeof(IMAGE_THUNK_DATA64))) {
        break;
      }
      if (names[thunk_index].u1.AddressOfData == 0) {
        break;
      }
      if (IMAGE_SNAP_BY_ORDINAL64(names[thunk_index].u1.Ordinal)) {
        continue;
      }
      if (!repro_hcr_pe_range_valid(
              image_size, names[thunk_index].u1.AddressOfData,
              sizeof(IMAGE_IMPORT_BY_NAME))) {
        continue;
      }
      import_name = (IMAGE_IMPORT_BY_NAME *)(
          base + names[thunk_index].u1.AddressOfData);
      name = (const char *)import_name->Name;
      name_capacity = image_size -
          (size_t)names[thunk_index].u1.AddressOfData -
          offsetof(IMAGE_IMPORT_BY_NAME, Name);
      if (memchr(name, '\0', name_capacity) == NULL ||
          strcmp(name, symbol_name) != 0) {
        continue;
      }
      slot = (void **)&slots[thunk_index].u1.Function;
      old_target = *slot;
      if (repro_hcr_dispatch_make_writable(
              slot, sizeof(void *), &page, &page_size, &was_writable) != 0) {
        return -2;
      }
      repro_hcr_dispatch_store_pointer(slot, new_target);
      (void)repro_hcr_dispatch_restore_protection(
          page, page_size, was_writable);
      record_status = repro_hcr_dispatch_record_entry(
          tx_id, REPRO_HCR_DISPATCH_PE_IAT, slot, old_target, new_target,
          symbol_name, (int)thunk_index);
      if (record_status != 0) {
        if (repro_hcr_dispatch_make_writable(
                slot, sizeof(void *), &page, &page_size, &was_writable) == 0) {
          repro_hcr_dispatch_store_pointer(slot, old_target);
          (void)repro_hcr_dispatch_restore_protection(
              page, page_size, was_writable);
        }
        return -3;
      }
      if (out_old_target != NULL) {
        *out_old_target = old_target;
      }
      return 0;
    }
  }
  return -1;
}
#endif

int repro_hcr_patch_pe_iat_tx(
    uint64_t tx_id,
    const char *module_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
#if defined(_WIN32)
  HANDLE snapshot;
  MODULEENTRY32 module;
  int status = -1;
  if (symbol_name == NULL || symbol_name[0] == '\0' || new_target == NULL) {
    return -1;
  }
  snapshot = CreateToolhelp32Snapshot(
      TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
  if (snapshot == INVALID_HANDLE_VALUE) {
    return -2;
  }
  memset(&module, 0, sizeof(module));
  module.dwSize = sizeof(module);
  if (Module32First(snapshot, &module)) {
    do {
      if (!repro_hcr_ascii_contains_case_insensitive(
              module.szModule, module_filter) &&
          !repro_hcr_ascii_contains_case_insensitive(
              module.szExePath, module_filter)) {
        continue;
      }
      status = repro_hcr_patch_pe_module_iat(
          tx_id, &module, symbol_name, new_target, out_old_target);
      if (status == 0 || status < -1) {
        break;
      }
    } while (Module32Next(snapshot, &module));
  }
  CloseHandle(snapshot);
  return status;
#else
  (void)tx_id; (void)module_filter; (void)symbol_name; (void)new_target; (void)out_old_target;
  return -1;
#endif
}

int repro_hcr_patch_pe_iat(
    const char *module_filter,
    const char *symbol_name,
    void *new_target,
    void **out_old_target) {
  uint64_t tx = repro_hcr_dispatch_active_transaction();
  if (tx == 0) tx = 1;
  return repro_hcr_patch_pe_iat_tx(tx, module_filter, symbol_name, new_target, out_old_target);
}

/*
 * C++ Vtable Interception.
 */
void **repro_hcr_discover_vtable_from_instance(void *class_instance) {
  if (class_instance == NULL) {
    return NULL;
  }
  return *(void ***)class_instance;
}

void **repro_hcr_find_vtable_by_symbol(const char *mangled_vtable_symbol) {
  if (mangled_vtable_symbol == NULL || mangled_vtable_symbol[0] == '\0') {
    return NULL;
  }
#if defined(_WIN32)
  return NULL;
#else
  void *sym = dlsym(RTLD_DEFAULT, mangled_vtable_symbol);
  if (!sym && mangled_vtable_symbol[0] == '_') {
    sym = dlsym(RTLD_DEFAULT, mangled_vtable_symbol + 1);
  }
  if (!sym) {
    char buf[256];
    snprintf(buf, sizeof(buf), "_%s", mangled_vtable_symbol);
    sym = dlsym(RTLD_DEFAULT, buf);
  }
  if (!sym) {
    char buf[256];
    snprintf(buf, sizeof(buf), "__%s", mangled_vtable_symbol[0] == '_' ? mangled_vtable_symbol + 1 : mangled_vtable_symbol);
    sym = dlsym(RTLD_DEFAULT, buf);
  }
  if (!sym) {
    return NULL;
  }
  /* In Itanium C++ ABI, vtable symbol points to offset_to_top; vptr is offset by 2 * sizeof(void*) */
  return (void **)((char *)sym + 2 * sizeof(void *));
#endif
}

int repro_hcr_patch_vtable_slot_tx(
    uint64_t tx_id,
    void **vptr,
    int slot_index,
    void *new_method,
    void **out_old_method) {
  if (vptr == NULL || slot_index < 0) {
    return -1;
  }
  void **slot = &vptr[slot_index];
  void *old_val = *slot;
  if (out_old_method) {
    *out_old_method = old_val;
  }
  void *page = NULL;
  size_t page_size = 0;
  int was_writable = 0;
  if (repro_hcr_dispatch_make_writable(slot, sizeof(void *), &page, &page_size, &was_writable) != 0) {
    return -2;
  }
  repro_hcr_dispatch_store_pointer(slot, new_method);
  repro_hcr_dispatch_restore_protection(page, page_size, was_writable);

  repro_hcr_dispatch_record_entry(tx_id, REPRO_HCR_DISPATCH_CPP_VTABLE,
                                  slot, old_val, new_method, "", slot_index);
  return 0;
}

int repro_hcr_patch_vtable_slot(
    void **vptr,
    int slot_index,
    void *new_method,
    void **out_old_method) {
  uint64_t tx = repro_hcr_dispatch_active_transaction();
  if (tx == 0) tx = 1;
  return repro_hcr_patch_vtable_slot_tx(tx, vptr, slot_index, new_method, out_old_method);
}

int repro_hcr_patch_vtable_method_tx(
    uint64_t tx_id,
    void **vptr,
    size_t max_slots,
    void *old_method,
    void *new_method,
    int *out_slot_index) {
  if (vptr == NULL || old_method == NULL) {
    return -1;
  }
  for (size_t i = 0; i < max_slots; ++i) {
    if (vptr[i] == old_method) {
      if (out_slot_index) *out_slot_index = (int)i;
      return repro_hcr_patch_vtable_slot_tx(tx_id, vptr, (int)i, new_method, NULL);
    }
  }
  return -1;
}

int repro_hcr_patch_vtable_method(
    void **vptr,
    size_t max_slots,
    void *old_method,
    void *new_method,
    int *out_slot_index) {
  uint64_t tx = repro_hcr_dispatch_active_transaction();
  if (tx == 0) tx = 1;
  return repro_hcr_patch_vtable_method_tx(tx, vptr, max_slots, old_method, new_method, out_slot_index);
}

#endif /* REPRO_HCR_DISPATCH_TABLE_C */
