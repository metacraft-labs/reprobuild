/*
 * HLX-M5 fixture: unwinding and debugger integration on Linux x86_64.
 *
 * Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8,
 * `HCR/Debugger-Integration.md` §1, §2, §5, §8.3.
 * Milestone: `HCR-Linux-ELF-Provider.milestones.org`, HLX-M5.
 *
 * `allowed_mocks: none`. Everything below is real:
 *
 *   * a real patchable victim in a real process, compiled by a real compiler
 *     with the real patchable build profile;
 *   * the PRODUCTION transaction (`repro_hcr_lx_txn_prepare` / `_commit` /
 *     `_rollback` in `repro_hcr_linux_x86_64.h`) and the PRODUCTION
 *     registration (`repro_hcr_lxu_*` in `repro_hcr_linux_unwind.h`), both
 *     included here as the same `static` code the live agent runs — this file
 *     is a second CALLER of that code, never a second copy of it;
 *   * a real compiler-generated `.eh_frame` and a real relocatable object,
 *     read out of a real `.o` the gate just built;
 *   * the process's real unwinder, asked through `_Unwind_Find_FDE` and
 *     through `_Unwind_Backtrace`.
 *
 * WHY THERE ARE TWO MECHANISMS AND TWO CONTROLS. `.eh_frame` registration
 * answers the RUNTIME unwinder; the GDB JIT symfile answers the DEBUGGER. They
 * are independent, and a fixture that registers both and then observes one
 * would credit the wrong mechanism. So `--no-eh-frame` and `--no-jit` are
 * separate levers, and each gate arm turns off exactly the one whose effect it
 * is measuring.
 *
 * The levers REMOVE a registration. They do not simulate a failure, reroute a
 * call, or substitute a stub — the rest of the run is byte-for-byte the same
 * code path, which is what makes the control a control.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "repro_hcr_linux_x86_64.h"
#include "repro_hcr_linux_elf_symbols.h"
#include "repro_hcr_linux_unwind.h"

/* The three host primitives the provider headers forward-declare and leave to
 * the including translation unit, exactly as `repro_hcr_agent.c` and
 * `repro_hcr_linux_x86_64_probe.c` supply them. */
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
  mapped = mmap(hint, length, prot, MAP_PRIVATE | MAP_ANONYMOUS | extra_flags,
                -1, 0);
  return mapped == MAP_FAILED ? NULL : mapped;
}

static int repro_hcr_lx_unmap(void *address, size_t length) {
  return munmap(address, length);
}

/* ---- the call chain ------------------------------------------------------
 *
 * `reached` is where a debugger puts its breakpoint. The patched frame then
 * sits in the MIDDLE of the stack with resolvable frames above it (`reached`)
 * and below it (`level1`..`level3`, `main`), which is what the backtrace gate
 * has to be able to see. A fixture that trapped inside the patched body itself
 * would only ever exercise "frames below".
 *
 * `noipa` for the reason every fixture in this campaign gives: at -O2 GCC's
 * interprocedural analysis would otherwise fold these away and the entry would
 * never be executed. The arithmetic after each call stops the call becoming a
 * tail call, which would erase the very frame under test.
 */
typedef void (*hcr_lx_m5_reached_fn)(void);

static volatile int hcr_lx_m5_reached_count = 0;

__attribute__((noinline, noipa, used)) void hcr_lx_m5_reached(void) {
  hcr_lx_m5_reached_count += 1;
  __asm__ volatile("" ::: "memory");
}

__attribute__((noinline, noipa, used)) int hcr_lx_m5_victim(
    hcr_lx_m5_reached_fn reached) {
  int accumulator = 4;
  reached();
  accumulator += 7;
  return accumulator; /* 11 */
}

__attribute__((noinline, noipa, used)) int hcr_lx_m5_level1(
    hcr_lx_m5_reached_fn reached) {
  int value = hcr_lx_m5_victim(reached);
  return value * 2 + 1;
}

__attribute__((noinline, noipa, used)) int hcr_lx_m5_level2(
    hcr_lx_m5_reached_fn reached) {
  int value = hcr_lx_m5_level1(reached);
  return value + 3;
}

__attribute__((noinline, noipa, used)) int hcr_lx_m5_level3(
    hcr_lx_m5_reached_fn reached) {
  int value = hcr_lx_m5_level2(reached);
  return value + 5;
}

/* ---- in-process unwind observation ---------------------------------------
 *
 * The runtime half of this milestone is answered by the process's OWN
 * unwinder, so the fixture asks it directly rather than inferring anything
 * from the debugger. `_Unwind_Backtrace` is the same entry point a C++
 * exception, `backtrace(3)` and a crash handler all go through.
 */
struct _Unwind_Context;
typedef int (*repro_hcr_m5_trace_fn)(struct _Unwind_Context *, void *);
extern int _Unwind_Backtrace(repro_hcr_m5_trace_fn, void *) __attribute__((weak));
extern uintptr_t _Unwind_GetIP(struct _Unwind_Context *) __attribute__((weak));

#define HCR_LX_M5_MAX_TRACE 64

typedef struct {
  uint64_t pc[HCR_LX_M5_MAX_TRACE];
  int count;
} hcr_lx_m5_trace;

static int hcr_lx_m5_trace_step(struct _Unwind_Context *context, void *opaque) {
  hcr_lx_m5_trace *trace = (hcr_lx_m5_trace *)opaque;
  if (trace->count >= HCR_LX_M5_MAX_TRACE) {
    return 1; /* _URC_FOREIGN_EXCEPTION_CAUGHT — any non-zero stops the walk */
  }
  trace->pc[trace->count++] = (uint64_t)_Unwind_GetIP(context);
  return 0;
}

static hcr_lx_m5_trace hcr_lx_m5_last_trace;
static uint64_t hcr_lx_m5_patch_body_address = 0;
static uint64_t hcr_lx_m5_patch_body_size = 0;

/* Taken from inside `hcr_lx_m5_reached`, i.e. from the frame ABOVE the patched
 * one, so the walk has to cross the patch page to reach `main`. */
static void hcr_lx_m5_capture_trace(void) {
  memset(&hcr_lx_m5_last_trace, 0, sizeof(hcr_lx_m5_last_trace));
  if (_Unwind_Backtrace == NULL || _Unwind_GetIP == NULL) {
    return;
  }
  (void)_Unwind_Backtrace(hcr_lx_m5_trace_step, &hcr_lx_m5_last_trace);
}

static void hcr_lx_m5_reached_and_trace(void) {
  hcr_lx_m5_reached();
  hcr_lx_m5_capture_trace();
}

static int hcr_lx_m5_trace_crosses_patch(void) {
  int i;
  if (hcr_lx_m5_patch_body_address == 0) {
    return 0;
  }
  for (i = 0; i < hcr_lx_m5_last_trace.count; ++i) {
    uint64_t pc = hcr_lx_m5_last_trace.pc[i];
    if (pc >= hcr_lx_m5_patch_body_address &&
        pc < hcr_lx_m5_patch_body_address + hcr_lx_m5_patch_body_size) {
      return 1;
    }
  }
  return 0;
}

/*
 * Symbolise the captured PCs, so the gate can assert the CHAIN rather than a
 * frame count. A truncated walk still returns a count; only the names say
 * whether the walk crossed the patch page and reached `main`.
 *
 * `dladdr` is the right instrument here and not a shortcut: the fixture is
 * linked `-rdynamic`, so these functions are in `.dynsym` and `dladdr` answers
 * from the process's own loader data. A PC inside the patch page belongs to no
 * object and correctly symbolises to nothing, which is itself the observation
 * that the walk got there.
 */
static void hcr_lx_m5_print_trace_json(void) {
  int i;
  printf("[");
  for (i = 0; i < hcr_lx_m5_last_trace.count; ++i) {
    uint64_t pc = hcr_lx_m5_last_trace.pc[i];
    const char *name = "";
    Dl_info info;
    int in_patch = hcr_lx_m5_patch_body_address != 0 &&
                   pc >= hcr_lx_m5_patch_body_address &&
                   pc < hcr_lx_m5_patch_body_address +
                            hcr_lx_m5_patch_body_size;
    if (!in_patch && dladdr((void *)(uintptr_t)pc, &info) != 0 &&
        info.dli_sname != NULL) {
      name = info.dli_sname;
    }
    printf("%s{\"pc\":\"0x%llx\",\"symbol\":\"%s\",\"inPatchBody\":%s}",
           i == 0 ? "" : ",", (unsigned long long)pc,
           in_patch ? "hcr-lx-m5-patch-body" : name,
           in_patch ? "true" : "false");
  }
  printf("]");
}

/* ---- file input ---------------------------------------------------------- */

static uint8_t *hcr_lx_m5_read_file(const char *path, size_t *out_size) {
  FILE *handle = fopen(path, "rb");
  uint8_t *buffer;
  long size;
  if (handle == NULL) {
    return NULL;
  }
  if (fseek(handle, 0, SEEK_END) != 0) {
    fclose(handle);
    return NULL;
  }
  size = ftell(handle);
  if (size <= 0 || fseek(handle, 0, SEEK_SET) != 0) {
    fclose(handle);
    return NULL;
  }
  buffer = (uint8_t *)malloc((size_t)size);
  if (buffer == NULL) {
    fclose(handle);
    return NULL;
  }
  if (fread(buffer, 1, (size_t)size, handle) != (size_t)size) {
    free(buffer);
    fclose(handle);
    return NULL;
  }
  fclose(handle);
  *out_size = (size_t)size;
  return buffer;
}

static int hcr_lx_m5_hex_nibble(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
  if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
  return -1;
}

static uint8_t *hcr_lx_m5_bytes_from_hex(const char *hex, size_t *out_len) {
  size_t length = strlen(hex);
  size_t i;
  uint8_t *bytes;
  if (length == 0 || (length % 2) != 0) {
    return NULL;
  }
  bytes = (uint8_t *)malloc(length / 2);
  if (bytes == NULL) {
    return NULL;
  }
  for (i = 0; i < length; i += 2) {
    int hi = hcr_lx_m5_hex_nibble(hex[i]);
    int lo = hcr_lx_m5_hex_nibble(hex[i + 1]);
    if (hi < 0 || lo < 0) {
      free(bytes);
      return NULL;
    }
    bytes[i / 2] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = length / 2;
  return bytes;
}

/* ---- the run ------------------------------------------------------------- */

typedef struct {
  const char *mode;
  int patch;
  int register_eh_frame;
  int register_jit;
  int rollback;
} hcr_lx_m5_options;

static void hcr_lx_m5_usage(void) {
  fprintf(stderr,
          "usage: hcr_lx_m5_target <mode> <body-hex> <eh-frame-file> "
          "<debug-object-file> <symbol>\n"
          "  modes: registered | no-eh-frame | no-jit | unregistered | "
          "unpatched | rollback\n");
}

int main(int argc, char **argv) {
  hcr_lx_m5_options options;
  uint8_t *body = NULL;
  size_t body_len = 0;
  uint8_t *eh_frame = NULL;
  size_t eh_frame_len = 0;
  uint8_t *debug_object = NULL;
  size_t debug_object_len = 0;
  const char *symbol;
  uint64_t entry_address;
  uint64_t sled_address;
  void *dispatch = NULL;
  uint64_t eh_payload = 0;
  uint32_t fde_count = 0;
  int convention = REPRO_HCR_LXU_CONVENTION_UNKNOWN;
  uint64_t jit_entry = 0;
  repro_hcr_lxu_symfile_evidence symfile;
  int eh_rc = REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  int jit_rc = REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  int recorded_eh = 0;
  int recorded_jit = 0;
  int result;
  int fde_found_before;
  int fde_found_after;
  int rollback_rc = 0;
  int unregister_attempts = 0;
  int fde_found_after_rollback = -1;

  if (argc < 6) {
    hcr_lx_m5_usage();
    return 2;
  }
  memset(&options, 0, sizeof(options));
  memset(&symfile, 0, sizeof(symfile));
  options.mode = argv[1];
  if (strcmp(options.mode, "registered") == 0) {
    options.patch = 1; options.register_eh_frame = 1; options.register_jit = 1;
  } else if (strcmp(options.mode, "no-eh-frame") == 0) {
    options.patch = 1; options.register_eh_frame = 0; options.register_jit = 1;
  } else if (strcmp(options.mode, "no-jit") == 0) {
    options.patch = 1; options.register_eh_frame = 1; options.register_jit = 0;
  } else if (strcmp(options.mode, "unregistered") == 0) {
    options.patch = 1;
  } else if (strcmp(options.mode, "unpatched") == 0) {
    /* nothing on */
  } else if (strcmp(options.mode, "rollback") == 0) {
    options.patch = 1; options.register_eh_frame = 1; options.register_jit = 1;
    options.rollback = 1;
  } else {
    hcr_lx_m5_usage();
    return 2;
  }

  body = hcr_lx_m5_bytes_from_hex(argv[2], &body_len);
  if (body == NULL) {
    fprintf(stderr, "hcr_lx_m5: patch body hex is not valid\n");
    return 3;
  }
  eh_frame = hcr_lx_m5_read_file(argv[3], &eh_frame_len);
  if (eh_frame == NULL) {
    fprintf(stderr, "hcr_lx_m5: cannot read .eh_frame payload: %s\n", argv[3]);
    return 3;
  }
  debug_object = hcr_lx_m5_read_file(argv[4], &debug_object_len);
  if (debug_object == NULL) {
    fprintf(stderr, "hcr_lx_m5: cannot read debug object: %s\n", argv[4]);
    return 3;
  }
  symbol = argv[5];

  entry_address = (uint64_t)(uintptr_t)&hcr_lx_m5_victim;
  sled_address = repro_hcr_elf_sled_address_for_entry(entry_address);

  /* The rollback path is the one HLX-M3 wired and could not reach. The hooks
   * are installed exactly as the agent installs them — the same two functions,
   * not wrappers around them. */
  repro_hcr_lx_unregister_jit_hook = repro_hcr_lxu_unregister_jit_symfile;
  repro_hcr_lx_unregister_eh_frame_hook = repro_hcr_lxu_unregister_eh_frame;

  fde_found_before = 0;

  if (options.patch) {
    dispatch = repro_hcr_lx_apply_direct_patch_at(entry_address, sled_address,
                                                  body, body_len);
    if (dispatch == NULL) {
      fprintf(stderr, "hcr_lx_m5: patch refused: %s\n",
              repro_hcr_lx_refusal_name(repro_hcr_lx_last_report.refusal));
      return 4;
    }
    hcr_lx_m5_patch_body_address = (uint64_t)(uintptr_t)dispatch;
    hcr_lx_m5_patch_body_size = (uint64_t)body_len;

    /* Asked BEFORE any registration, so "the unwinder found the body" cannot
     * be true for free: a patch page belongs to no object, so this must be 0
     * here or the whole measurement is meaningless. */
    fde_found_before = repro_hcr_lxu_fde_found(hcr_lx_m5_patch_body_address);

    if (options.register_eh_frame) {
      eh_rc = repro_hcr_lxu_register_eh_frame(
          eh_frame, (uint64_t)eh_frame_len, hcr_lx_m5_patch_body_address,
          (uint64_t)body_len, &eh_payload, &fde_count, &convention);
      if (eh_rc == REPRO_HCR_LXU_OK) {
        recorded_eh = repro_hcr_lx_txn_record_registration(
            hcr_lx_m5_patch_body_address, 0, eh_payload);
      }
    }
    if (options.register_jit) {
      jit_rc = repro_hcr_lxu_register_jit_symfile(
          debug_object, (uint64_t)debug_object_len,
          hcr_lx_m5_patch_body_address, symbol, &jit_entry, &symfile);
      if (jit_rc == REPRO_HCR_LXU_OK) {
        recorded_jit = repro_hcr_lx_txn_record_registration(
            hcr_lx_m5_patch_body_address, jit_entry, 0);
      }
    }
  }

  fde_found_after = repro_hcr_lxu_fde_found(hcr_lx_m5_patch_body_address);

  /* The chain runs AFTER registration, so a debugger attached to this process
   * has already seen `__jit_debug_register_code` fire by the time the
   * breakpoint in `hcr_lx_m5_reached` is hit. */
  result = hcr_lx_m5_level3(hcr_lx_m5_reached_and_trace);

  char register_frame_object[128];
  char register_frame_symbol[128];
  register_frame_object[0] = '\0';
  register_frame_symbol[0] = '\0';

  if (options.rollback) {
    rollback_rc = repro_hcr_lx_txn_rollback(&repro_hcr_lx_last_txn);
    unregister_attempts = repro_hcr_lx_last_txn.unregister_attempts;
    fde_found_after_rollback =
        repro_hcr_lxu_fde_found(hcr_lx_m5_patch_body_address);
  }

  /* HLX-OQ-4's REJECTED candidate, measured rather than argued.
   *
   * `dladdr` was the cheapest way to decide which unwinder is in the process:
   * ask which shared object `__register_frame` lives in. The design rejected it
   * partly because it CANNOT SEE A STATICALLY LINKED UNWINDER, and until this
   * date that was an argument rather than a measurement — both arms of the
   * detection gate linked their unwinder dynamically.
   *
   * These two fields are what makes it a measurement. With a dynamically linked
   * unwinder `dladdr` names `libgcc_s.so.1` or `libunwind.so.1` and a
   * library-identifying detection would work. With the unwinder linked
   * statically the same call names THE MAIN EXECUTABLE — the same answer for
   * both toolchains — so there is nothing left to tell them apart, which is
   * exactly the world probe-and-verify was chosen for. */
  {
    Dl_info rf_info;
    if (__register_frame != NULL &&
        dladdr((void *)(uintptr_t)__register_frame, &rf_info) != 0) {
      if (rf_info.dli_fname != NULL) {
        const char *slash = strrchr(rf_info.dli_fname, '/');
        snprintf(register_frame_object, sizeof(register_frame_object), "%s",
                 slash != NULL ? slash + 1 : rf_info.dli_fname);
      }
      if (rf_info.dli_sname != NULL) {
        snprintf(register_frame_symbol, sizeof(register_frame_symbol), "%s",
                 rf_info.dli_sname);
      }
    }
  }

  printf(
      "{\"mode\":\"%s\",\"result\":%d,\"reachedCount\":%d,"
      "\"entry\":\"0x%llx\",\"sled\":\"0x%llx\",\"dispatch\":\"0x%llx\","
      "\"bodySize\":%llu,"
      "\"ehFrameBytes\":%llu,\"ehFrameRefusal\":\"%s\","
      "\"ehFramePayload\":\"0x%llx\",\"fdeCount\":%u,"
      "\"registerFrameConvention\":\"%s\","
      "\"probeAttempts\":%llu,\"fallbackAttempts\":%llu,"
      "\"fdeFoundBeforeRegistration\":%s,\"fdeFoundAfterRegistration\":%s,"
      "\"debugObjectBytes\":%llu,\"jitRefusal\":\"%s\","
      "\"jitEntry\":\"0x%llx\",\"jitDescriptor\":\"0x%llx\","
      "\"jitFirstEntry\":\"0x%llx\",\"jitActionFlag\":%u,"
      "\"jitRegisterCalls\":%llu,\"jitUnregisterCalls\":%llu,"
      "\"symfileTextSection\":%u,\"symfileTextAddress\":\"0x%llx\","
      "\"symfileSymbolValue\":\"0x%llx\",\"symfileRelocations\":%d,"
      "\"symfileRetiredRelocSections\":%u,\"symfileAllocatedSections\":%u,"
      "\"recordedEhFrameOnSite\":%d,\"recordedJitOnSite\":%d,"
      "\"unwindTraceFrames\":%d,\"unwindCrossesPatch\":%s,"
      "\"rolledBack\":%d,\"rollbackRc\":%d,\"unregisterAttempts\":%d,"
      "\"fdeFoundAfterRollback\":%d,"
      "\"registerFrameAvailable\":%s,"
      "\"dladdrRegisterFrameObject\":\"%s\","
      "\"dladdrRegisterFrameSymbol\":\"%s\","
      "\"unwindTrace\":",
      options.mode, result, hcr_lx_m5_reached_count,
      (unsigned long long)entry_address, (unsigned long long)sled_address,
      (unsigned long long)hcr_lx_m5_patch_body_address,
      (unsigned long long)hcr_lx_m5_patch_body_size,
      (unsigned long long)eh_frame_len, repro_hcr_lxu_refusal_name(eh_rc),
      (unsigned long long)eh_payload, fde_count,
      repro_hcr_lxu_convention_name(convention),
      (unsigned long long)repro_hcr_lxu_probe_attempts,
      (unsigned long long)repro_hcr_lxu_fallback_attempts,
      fde_found_before ? "true" : "false", fde_found_after ? "true" : "false",
      (unsigned long long)debug_object_len, repro_hcr_lxu_refusal_name(jit_rc),
      (unsigned long long)jit_entry,
      (unsigned long long)(uintptr_t)&__jit_debug_descriptor,
      (unsigned long long)(uintptr_t)__jit_debug_descriptor.first_entry,
      __jit_debug_descriptor.action_flag,
      (unsigned long long)repro_hcr_lxu_jit_register_calls,
      (unsigned long long)repro_hcr_lxu_jit_unregister_calls,
      symfile.text_section_index,
      (unsigned long long)symfile.text_section_address,
      (unsigned long long)symfile.symbol_value, symfile.applied_relocations,
      symfile.retired_relocation_sections, symfile.allocated_sections,
      recorded_eh, recorded_jit, hcr_lx_m5_last_trace.count,
      hcr_lx_m5_trace_crosses_patch() ? "true" : "false", options.rollback,
      rollback_rc, unregister_attempts, fde_found_after_rollback,
      (__register_frame != NULL) ? "true" : "false",
      register_frame_object, register_frame_symbol);
  hcr_lx_m5_print_trace_json();
  printf("}\n");
  fflush(stdout);

  free(body);
  free(eh_frame);
  free(debug_object);
  return 0;
}
