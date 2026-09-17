/*
 * Linux x86_64 unwinding and debugger integration for the HCR provider
 * (HLX-M5).
 *
 * Implements `reprobuild-specs/HCR/Linux-ELF-Provider.md` §8 and
 * `HCR/Debugger-Integration.md` §1, §2, §5, §8.3 for the ELF profile.
 *
 * Two independent mechanisms live here, and confusing them is the fastest way
 * to write a gate that proves nothing:
 *
 *   1. `.eh_frame` registration answers the RUNTIME unwinder — `backtrace()`,
 *      `_Unwind_Backtrace`, exception propagation. A patch body is an
 *      anonymous mapping inside no object's `PT_LOAD`, so the
 *      `dl_iterate_phdr` / `PT_GNU_EH_FRAME` path can never find it and the
 *      registered-objects list is the only one that can answer (design §8.2).
 *   2. The GDB JIT symfile answers the DEBUGGER. GDB and LLDB do not consult
 *      `__register_frame` at all; they parse the registered ELF themselves.
 *      A backtrace taken in GDB is therefore fixed by (2), and a backtrace
 *      taken by the process itself is fixed by (1).
 *
 * WHAT IS RELOCATED, AND WHY IT IS NOT A TEMPLATE. Both mechanisms consume the
 * bytes the COMPILER produced for the patch body — its `.eh_frame` CIE/FDE and
 * its `.debug_*` sections — and move them to the live patch address. Design
 * §8.2 is explicit that a synthetic minimal CIE/FDE (what the macOS prototype
 * patches at fixed offsets 0x1c/0x24) describes the wrong frame layout for any
 * real function and would corrupt exactly the backtraces this file exists to
 * protect. Nothing here fabricates unwind data. Every refusal below is named,
 * and a payload that cannot be relocated is refused rather than approximated.
 *
 * `HLX-OQ-4` — the `__register_frame` ABI split — is resolved here by
 * PROBE-AND-VERIFY rather than by identifying the library. Measured on this
 * host (2026-09-17, gcc 15.2.0 / libgcc_s, clang 21.1.8 / LLVM libunwind
 * 21.1.8, x86_64, glibc 2.42):
 *
 *   convention               libgcc    LLVM libunwind
 *   __register_frame(CIE..)  found     NOT found ("FDE is really a CIE")
 *   __register_frame(FDE)    found     found
 *
 * So the per-FDE convention is the one that works under both, and it is tried
 * first. It is still VERIFIED with `_Unwind_Find_FDE` after every registration
 * — a cached decision that stopped being true would otherwise corrupt every
 * subsequent backtrace silently, which is the exact failure mode `HLX-OQ-4`
 * names. If the first convention does not answer, the registration is undone
 * and the whole-section convention is tried and verified in the same way; if
 * neither answers, the patch is refused. `dladdr` was rejected as the
 * detection: it cannot see a statically linked unwinder, and it reports which
 * library provides the symbol rather than which argument that symbol wants.
 *
 * All functions are `static` so this header can be included both by the agent
 * translation unit and by the test probe shim, which drives the SAME code.
 * It must be included AFTER `repro_hcr_linux_x86_64.h`, whose
 * `repro_hcr_lx_map_patch_page_near` places the retained `.eh_frame` copy
 * within `rel32` of the body (see `PLACEMENT` below).
 */

#ifndef REPRO_HCR_LINUX_UNWIND_H
#define REPRO_HCR_LINUX_UNWIND_H

#include <elf.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__GNUC__)
#define REPRO_HCR_LXU_MAYBE_UNUSED __attribute__((unused))
#else
#define REPRO_HCR_LXU_MAYBE_UNUSED
#endif

/* ---------------------------------------------------------------------------
 * Refusals. Distinct and named, so a gate can assert WHICH one happened rather
 * than that "something failed".
 * ------------------------------------------------------------------------- */
enum {
  REPRO_HCR_LXU_OK = 0,
  REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT = -1,
  REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED = -2,
  REPRO_HCR_LXU_REFUSED_NO_CIE = -3,
  REPRO_HCR_LXU_REFUSED_NO_FDE = -4,
  REPRO_HCR_LXU_REFUSED_UNSUPPORTED_AUGMENTATION = -5,
  REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING = -6,
  REPRO_HCR_LXU_REFUSED_METADATA_UNPLACEABLE = -7,
  REPRO_HCR_LXU_REFUSED_REGISTER_FRAME_UNAVAILABLE = -8,
  REPRO_HCR_LXU_REFUSED_FDE_NOT_FOUND = -9,
  REPRO_HCR_LXU_REFUSED_METADATA_TOO_LARGE = -10,
  REPRO_HCR_LXU_REFUSED_TOO_MANY_FDES = -11,
  REPRO_HCR_LXU_REFUSED_REGISTRY_FULL = -12,
  REPRO_HCR_LXU_REFUSED_NOT_ELF_REL = -13,
  REPRO_HCR_LXU_REFUSED_NO_TEXT_SECTION = -14,
  REPRO_HCR_LXU_REFUSED_RELOCATION_UNSUPPORTED = -15,
  REPRO_HCR_LXU_REFUSED_SYMBOL_NOT_IN_OBJECT = -16,
  REPRO_HCR_LXU_REFUSED_COMPRESSED_DEBUG_SECTION = -17
};

REPRO_HCR_LXU_MAYBE_UNUSED
static const char *repro_hcr_lxu_refusal_name(int code) {
  switch (code) {
  case REPRO_HCR_LXU_OK: return "ok";
  case REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT: return "invalid-argument";
  case REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED:
    return "unwind-metadata-truncated";
  case REPRO_HCR_LXU_REFUSED_NO_CIE: return "unwind-metadata-no-cie";
  case REPRO_HCR_LXU_REFUSED_NO_FDE: return "unwind-metadata-no-fde";
  case REPRO_HCR_LXU_REFUSED_UNSUPPORTED_AUGMENTATION:
    return "unwind-metadata-unsupported-augmentation";
  case REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING:
    return "unwind-metadata-unsupported-fde-encoding";
  case REPRO_HCR_LXU_REFUSED_METADATA_UNPLACEABLE:
    return "unwind-metadata-unplaceable";
  case REPRO_HCR_LXU_REFUSED_REGISTER_FRAME_UNAVAILABLE:
    return "unwind-register-frame-unavailable";
  case REPRO_HCR_LXU_REFUSED_FDE_NOT_FOUND:
    return "unwind-fde-not-found-after-registration";
  case REPRO_HCR_LXU_REFUSED_METADATA_TOO_LARGE:
    return "unwind-metadata-too-large";
  case REPRO_HCR_LXU_REFUSED_TOO_MANY_FDES: return "unwind-metadata-too-many-fdes";
  case REPRO_HCR_LXU_REFUSED_REGISTRY_FULL: return "unwind-registry-full";
  case REPRO_HCR_LXU_REFUSED_NOT_ELF_REL: return "debug-object-not-elf-rel";
  case REPRO_HCR_LXU_REFUSED_NO_TEXT_SECTION: return "debug-object-no-text-section";
  case REPRO_HCR_LXU_REFUSED_RELOCATION_UNSUPPORTED:
    return "debug-object-unsupported-relocation";
  case REPRO_HCR_LXU_REFUSED_SYMBOL_NOT_IN_OBJECT:
    return "debug-object-symbol-not-found";
  case REPRO_HCR_LXU_REFUSED_COMPRESSED_DEBUG_SECTION:
    return "debug-object-compressed-debug-section";
  default: return "unknown-refusal";
  }
}

/* ---------------------------------------------------------------------------
 * The unwinder entry points.
 *
 * `__attribute__((weak))` on ELF, replacing the Mach-O `weak_import` the macOS
 * arm uses — same null-check pattern, different spelling (design §8.2). The
 * `__unw_add_dynamic_eh_frame_section` branch the macOS arm tries first is
 * DELIBERATELY ABSENT: the deliverable removes it, and keeping it would also
 * have made the ABI question unanswerable, because that symbol exists only in
 * LLVM libunwind and a process that has it is exactly the process whose
 * `__register_frame` convention we most need to establish.
 *
 * `_Unwind_Find_FDE` is the verification instrument and is exported by BOTH
 * unwinders (measured: `libgcc_s.so.1` and LLVM `libunwind.so.1` each define
 * it). Its `struct dwarf_eh_bases` is declared locally rather than pulled from
 * `<unwind.h>`, which does not declare this function at all.
 * ------------------------------------------------------------------------- */
struct repro_hcr_lxu_dwarf_eh_bases {
  void *tbase;
  void *dbase;
  void *func;
};

extern void __register_frame(const void *) __attribute__((weak));
extern void __deregister_frame(const void *) __attribute__((weak));
extern const void *_Unwind_Find_FDE(const void *,
                                    struct repro_hcr_lxu_dwarf_eh_bases *)
    __attribute__((weak));

/* DWARF exception-header pointer encodings (`DW_EH_PE_*`). */
#define REPRO_HCR_LXU_PE_ABSPTR 0x00
#define REPRO_HCR_LXU_PE_ULEB128 0x01
#define REPRO_HCR_LXU_PE_UDATA2 0x02
#define REPRO_HCR_LXU_PE_UDATA4 0x03
#define REPRO_HCR_LXU_PE_UDATA8 0x04
#define REPRO_HCR_LXU_PE_SLEB128 0x09
#define REPRO_HCR_LXU_PE_SDATA2 0x0a
#define REPRO_HCR_LXU_PE_SDATA4 0x0b
#define REPRO_HCR_LXU_PE_SDATA8 0x0c
#define REPRO_HCR_LXU_PE_PCREL 0x10
#define REPRO_HCR_LXU_PE_INDIRECT 0x80
#define REPRO_HCR_LXU_PE_OMIT 0xff

#define REPRO_HCR_LXU_MAX_FDES 16
#define REPRO_HCR_LXU_MAX_REGISTRATIONS 64

/* The registration convention, i.e. what `__register_frame` wants. */
enum {
  REPRO_HCR_LXU_CONVENTION_UNKNOWN = 0,
  REPRO_HCR_LXU_CONVENTION_SINGLE_FDE = 1,
  REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION = 2
};

REPRO_HCR_LXU_MAYBE_UNUSED
static const char *repro_hcr_lxu_convention_name(int convention) {
  switch (convention) {
  case REPRO_HCR_LXU_CONVENTION_SINGLE_FDE: return "single-fde";
  case REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION: return "whole-section";
  default: return "undetermined";
  }
}

typedef struct repro_hcr_lxu_eh_plan {
  uint32_t fde_count;
  uint32_t fde_offset[REPRO_HCR_LXU_MAX_FDES];
  uint32_t location_field_offset[REPRO_HCR_LXU_MAX_FDES];
  uint8_t fde_encoding;
  int refusal;
} repro_hcr_lxu_eh_plan;

typedef struct repro_hcr_lxu_registration {
  int used;
  uint64_t payload_address;
  uint64_t payload_length;   /* bytes actually written                    */
  uint64_t mapped_length;    /* bytes mapped, a whole number of pages     */
  uint32_t fde_count;
  uint32_t fde_offset[REPRO_HCR_LXU_MAX_FDES];
  int convention;
} repro_hcr_lxu_registration;

static repro_hcr_lxu_registration
    repro_hcr_lxu_registry[REPRO_HCR_LXU_MAX_REGISTRATIONS];

/*
 * The convention this process's unwinder was MEASURED to want, cached after the
 * first successful registration. It is a cache, not a decision: every
 * registration still verifies with `_Unwind_Find_FDE` and falls back to the
 * other convention if the cached one does not answer.
 */
static int repro_hcr_lxu_convention = REPRO_HCR_LXU_CONVENTION_UNKNOWN;

/* Counters a gate can read to tell "the cheap path was taken" from "the
 * fallback rescued it", and to prove the probe ran at all. */
static uint64_t repro_hcr_lxu_probe_attempts = 0;
static uint64_t repro_hcr_lxu_fallback_attempts = 0;

/* ---------------------------------------------------------------------------
 * Little-endian fixed-width accessors. The payload is an x86_64 ELF section, so
 * these are not generic — they are LSB by construction and say so.
 * ------------------------------------------------------------------------- */
static uint32_t repro_hcr_lxu_read_u32(const uint8_t *p) {
  uint32_t v;
  memcpy(&v, p, sizeof(v));
  return v;
}

static void repro_hcr_lxu_write_u32(uint8_t *p, uint32_t v) {
  memcpy(p, &v, sizeof(v));
}

static void repro_hcr_lxu_write_u64(uint8_t *p, uint64_t v) {
  memcpy(p, &v, sizeof(v));
}

/* ULEB/SLEB readers that cannot run off the end of the buffer. */
static int repro_hcr_lxu_read_uleb(const uint8_t *buf, size_t len, size_t *pos,
                                   uint64_t *out) {
  uint64_t result = 0;
  unsigned shift = 0;
  while (*pos < len) {
    uint8_t byte = buf[(*pos)++];
    if (shift < 64) {
      result |= ((uint64_t)(byte & 0x7fu)) << shift;
    }
    shift += 7;
    if ((byte & 0x80u) == 0) {
      *out = result;
      return 0;
    }
  }
  return -1;
}

static int repro_hcr_lxu_skip_sleb(const uint8_t *buf, size_t len,
                                   size_t *pos) {
  while (*pos < len) {
    uint8_t byte = buf[(*pos)++];
    if ((byte & 0x80u) == 0) {
      return 0;
    }
  }
  return -1;
}

/* Size in bytes of a fixed-width `DW_EH_PE_*` value format, or 0 for the
 * variable-width and unsupported ones. */
static size_t repro_hcr_lxu_encoding_size(uint8_t encoding) {
  switch (encoding & 0x0fu) {
  case REPRO_HCR_LXU_PE_ABSPTR: return 8;
  case REPRO_HCR_LXU_PE_UDATA2:
  case REPRO_HCR_LXU_PE_SDATA2: return 2;
  case REPRO_HCR_LXU_PE_UDATA4:
  case REPRO_HCR_LXU_PE_SDATA4: return 4;
  case REPRO_HCR_LXU_PE_UDATA8:
  case REPRO_HCR_LXU_PE_SDATA8: return 8;
  default: return 0;
  }
}

/* ---------------------------------------------------------------------------
 * `repro_hcr_lxu_plan_eh_frame` — walk a compiler-generated `.eh_frame`
 * section and record where every FDE, and every FDE's `initial_location`
 * field, is.
 *
 * The walk is the ONLY way to find those fields: their offsets depend on the
 * CIE's augmentation string, its `code_alignment_factor` / return-address
 * register (both LEB128, so variable width) and the FDE pointer encoding that
 * the `R` augmentation carries. The macOS arm's fixed 0x1c/0x24 offsets happen
 * to be right for one hand-written 64-byte template and are wrong for
 * everything a compiler emits.
 * ------------------------------------------------------------------------- */
REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_plan_eh_frame(const uint8_t *bytes, size_t len,
                                       repro_hcr_lxu_eh_plan *plan) {
  size_t offset = 0;
  uint8_t fde_encoding = REPRO_HCR_LXU_PE_ABSPTR;
  int saw_cie = 0;

  if (bytes == NULL || plan == NULL || len < 8) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  memset(plan, 0, sizeof(*plan));
  plan->fde_encoding = REPRO_HCR_LXU_PE_ABSPTR;

  while (offset + 4 <= len) {
    uint32_t length = repro_hcr_lxu_read_u32(bytes + offset);
    size_t body;
    size_t end;
    uint32_t cie_id;

    if (length == 0) {
      break; /* the zero-length terminator */
    }
    if (length == 0xffffffffu) {
      /* 64-bit DWARF. No x86_64 compiler emits it into `.eh_frame`; refusing
       * is honest, guessing the field widths is not. */
      return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
    }
    body = offset + 4;
    if (length > len - body) {
      return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
    }
    end = body + length;
    if (body + 4 > end) {
      return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
    }
    cie_id = repro_hcr_lxu_read_u32(bytes + body);

    if (cie_id == 0) {
      /* CIE */
      size_t pos = body + 4;
      uint8_t version;
      const char *augmentation;
      size_t aug_start;
      uint64_t scratch;

      if (pos >= end) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      version = bytes[pos++];
      if (version != 1 && version != 3 && version != 4) {
        return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_AUGMENTATION;
      }
      aug_start = pos;
      while (pos < end && bytes[pos] != 0) {
        ++pos;
      }
      if (pos >= end) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      augmentation = (const char *)(bytes + aug_start);
      ++pos; /* the NUL */

      if (version == 4) {
        /* address_size, segment_selector_size */
        if (pos + 2 > end) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        pos += 2;
      }
      if (repro_hcr_lxu_read_uleb(bytes, end, &pos, &scratch) != 0) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      if (repro_hcr_lxu_skip_sleb(bytes, end, &pos) != 0) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      if (version == 1) {
        if (pos >= end) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        ++pos; /* return address register, a single ubyte in version 1 */
      } else if (repro_hcr_lxu_read_uleb(bytes, end, &pos, &scratch) != 0) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }

      if (augmentation[0] == 'z') {
        size_t aug_data_end;
        const char *c;
        if (repro_hcr_lxu_read_uleb(bytes, end, &pos, &scratch) != 0) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        if (scratch > (uint64_t)(end - pos)) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        aug_data_end = pos + (size_t)scratch;
        for (c = augmentation + 1; *c != 0; ++c) {
          if (*c == 'R') {
            if (pos >= aug_data_end) {
              return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
            }
            fde_encoding = bytes[pos++];
          } else if (*c == 'S') {
            /* signal frame; carries no augmentation data */
          } else {
            /*
             * 'P' (personality routine) and 'L' (LSDA) each carry an ENCODED
             * POINTER that a relocatable object leaves to a relocation we
             * cannot resolve in-process. A patch body that needs either is
             * refused by name rather than registered with a dangling pointer
             * in its CIE.
             */
            return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_AUGMENTATION;
          }
        }
        pos = aug_data_end;
      }
      saw_cie = 1;
      plan->fde_encoding = fde_encoding;
    } else {
      /* FDE */
      size_t pos = body + 4;
      size_t value_size;
      if (!saw_cie) {
        return REPRO_HCR_LXU_REFUSED_NO_CIE;
      }
      if (fde_encoding == REPRO_HCR_LXU_PE_OMIT ||
          (fde_encoding & REPRO_HCR_LXU_PE_INDIRECT) != 0) {
        return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
      }
      value_size = repro_hcr_lxu_encoding_size(fde_encoding);
      if (value_size == 0) {
        return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
      }
      if (pos + 2 * value_size > end) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      if (plan->fde_count >= REPRO_HCR_LXU_MAX_FDES) {
        return REPRO_HCR_LXU_REFUSED_TOO_MANY_FDES;
      }
      plan->fde_offset[plan->fde_count] = (uint32_t)offset;
      plan->location_field_offset[plan->fde_count] = (uint32_t)pos;
      plan->fde_count += 1;
    }
    offset = end;
  }

  if (!saw_cie) {
    return REPRO_HCR_LXU_REFUSED_NO_CIE;
  }
  if (plan->fde_count == 0) {
    return REPRO_HCR_LXU_REFUSED_NO_FDE;
  }
  return REPRO_HCR_LXU_OK;
}

/*
 * Rewrite one FDE's `initial_location` / `address_range` in a buffer that is
 * ALREADY at its final runtime address — `pcrel` is relative to the field, so
 * the relocation cannot be done before the copy is placed.
 */
static int repro_hcr_lxu_relocate_fde(uint8_t *buffer, size_t field_offset,
                                      uint8_t encoding, uint64_t code_address,
                                      uint64_t code_size) {
  size_t value_size = repro_hcr_lxu_encoding_size(encoding);
  uint8_t *field = buffer + field_offset;
  uint64_t base = 0;
  int64_t delta;

  if (value_size == 0) {
    return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
  }
  if ((encoding & 0x70u) == REPRO_HCR_LXU_PE_PCREL) {
    base = (uint64_t)(uintptr_t)field;
  } else if ((encoding & 0x70u) != 0) {
    /* textrel / datarel / funcrel / aligned: none of them can be resolved for
     * a body that belongs to no object. */
    return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
  }
  delta = (int64_t)code_address - (int64_t)base;

  switch (value_size) {
  case 4:
    if (delta < -2147483648LL || delta > 2147483647LL) {
      return REPRO_HCR_LXU_REFUSED_METADATA_UNPLACEABLE;
    }
    if (code_size > 0xffffffffull) {
      return REPRO_HCR_LXU_REFUSED_METADATA_UNPLACEABLE;
    }
    repro_hcr_lxu_write_u32(field, (uint32_t)(int32_t)delta);
    repro_hcr_lxu_write_u32(field + 4, (uint32_t)code_size);
    return REPRO_HCR_LXU_OK;
  case 8:
    repro_hcr_lxu_write_u64(field, (uint64_t)delta);
    repro_hcr_lxu_write_u64(field + 8, code_size);
    return REPRO_HCR_LXU_OK;
  case 2:
    /* A 16-bit location field cannot describe a 64-bit address space. */
    return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
  default:
    return REPRO_HCR_LXU_REFUSED_UNSUPPORTED_FDE_ENCODING;
  }
}

REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_fde_found(uint64_t pc) {
  struct repro_hcr_lxu_dwarf_eh_bases bases;
  if (_Unwind_Find_FDE == NULL) {
    /* No instrument. Report "not found" rather than "found": a verifier that
     * answers yes when it cannot see is the silent self-pass this campaign
     * keeps finding. */
    return 0;
  }
  memset(&bases, 0, sizeof(bases));
  return _Unwind_Find_FDE((const void *)(uintptr_t)pc, &bases) != NULL;
}

static void repro_hcr_lxu_register_by_convention(
    const repro_hcr_lxu_registration *record, int convention) {
  uint8_t *base = (uint8_t *)(uintptr_t)record->payload_address;
  uint32_t i;
  if (convention == REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION) {
    __register_frame(base);
    return;
  }
  for (i = 0; i < record->fde_count; ++i) {
    __register_frame(base + record->fde_offset[i]);
  }
}

static void repro_hcr_lxu_deregister_by_convention(
    const repro_hcr_lxu_registration *record, int convention) {
  uint8_t *base = (uint8_t *)(uintptr_t)record->payload_address;
  uint32_t i;
  if (__deregister_frame == NULL) {
    return;
  }
  if (convention == REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION) {
    __deregister_frame(base);
    return;
  }
  for (i = record->fde_count; i > 0; --i) {
    __deregister_frame(base + record->fde_offset[i - 1]);
  }
}

/* ---------------------------------------------------------------------------
 * PLACEMENT.
 *
 * The retained `.eh_frame` copy is mapped NEAR the patch body, not malloc'd.
 * The reason is arithmetic, not tidiness: compilers emit the FDE pointer
 * encoding `DW_EH_PE_pcrel|sdata4` (0x1b), so `initial_location` is a SIGNED
 * 32-BIT displacement from the field to the code. A fresh `mmap(NULL, ...)`
 * lands in the shared-library region while the patch body is within +/-2 GiB of
 * the target's text; on a PIE process those two are tens of terabytes apart and
 * the displacement does not fit.
 *
 * MEASURED 2026-09-17 REVIEW, with the numbers rather than the slogan, because
 * the first draft of this comment said "every single registration" and that is
 * true of only one of the two allocators:
 *
 *   mmap(NULL, ...)      12-39 TiB from `main`, NEVER fits int32 (3 of 3 runs)
 *   malloc(<= 64 KiB)    0.14-0.64 GB from `main`, FITS — glibc serves it from
 *                        the `brk` heap, which the kernel places just above the
 *                        executable
 *   malloc(>= 128 KiB)   ~12.9 TiB from `main`, does NOT fit — over
 *                        M_MMAP_THRESHOLD glibc switches to mmap
 *
 * So a small `malloc` would often work by accident and would fail the day the
 * section grew past 128 KiB or the heap moved. Mapping NEAR the body is what
 * makes the displacement a property of the allocator rather than of the
 * allocation size, and that is the reason to do it — not that every other
 * choice fails outright.
 *
 * `repro_hcr_lx_map_patch_page_near` is the allocator HLX-M2 already uses to
 * put a patch body within `rel32` of its window, and it answers the same
 * question here. The displacement is checked afterwards anyway and refuses
 * `unwind-metadata-unplaceable` rather than truncating.
 * ------------------------------------------------------------------------- */
REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_register_eh_frame(const uint8_t *bytes, uint64_t size,
                                           uint64_t code_address,
                                           uint64_t code_size,
                                           uint64_t *out_payload_address,
                                           uint32_t *out_fde_count,
                                           int *out_convention) {
  repro_hcr_lxu_eh_plan plan;
  repro_hcr_lxu_registration *record = NULL;
  size_t page_size = repro_hcr_lx_page_size();
  size_t mapped_length;
  uint8_t *buffer;
  int index;
  int rc;
  uint32_t i;
  int first_convention;
  int second_convention;

  if (out_payload_address != NULL) {
    *out_payload_address = 0;
  }
  if (out_fde_count != NULL) {
    *out_fde_count = 0;
  }
  if (out_convention != NULL) {
    *out_convention = REPRO_HCR_LXU_CONVENTION_UNKNOWN;
  }
  if (bytes == NULL || size == 0 || code_address == 0 || code_size == 0) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  if (__register_frame == NULL) {
    return REPRO_HCR_LXU_REFUSED_REGISTER_FRAME_UNAVAILABLE;
  }

  rc = repro_hcr_lxu_plan_eh_frame(bytes, (size_t)size, &plan);
  if (rc != REPRO_HCR_LXU_OK) {
    return rc;
  }

  for (index = 0; index < REPRO_HCR_LXU_MAX_REGISTRATIONS; ++index) {
    if (!repro_hcr_lxu_registry[index].used) {
      record = &repro_hcr_lxu_registry[index];
      break;
    }
  }
  if (record == NULL) {
    return REPRO_HCR_LXU_REFUSED_REGISTRY_FULL;
  }

  /* Room for the section plus a zero-length terminator, which libgcc's walk
   * needs and which a section extracted from a `.o` does not carry. */
  if (size + 4 > (uint64_t)(16 * page_size)) {
    return REPRO_HCR_LXU_REFUSED_METADATA_TOO_LARGE;
  }
  mapped_length = (size_t)(((size + 4) + page_size - 1) / page_size) * page_size;
  buffer = (uint8_t *)repro_hcr_lx_map_patch_page_near(code_address,
                                                       mapped_length);
  if (buffer == NULL) {
    return REPRO_HCR_LXU_REFUSED_METADATA_UNPLACEABLE;
  }
  memcpy(buffer, bytes, (size_t)size);
  memset(buffer + size, 0, mapped_length - (size_t)size);

  memset(record, 0, sizeof(*record));
  record->payload_address = (uint64_t)(uintptr_t)buffer;
  record->payload_length = size + 4;
  record->mapped_length = mapped_length;
  record->fde_count = plan.fde_count;
  for (i = 0; i < plan.fde_count; ++i) {
    record->fde_offset[i] = plan.fde_offset[i];
  }

  for (i = 0; i < plan.fde_count; ++i) {
    rc = repro_hcr_lxu_relocate_fde(buffer, plan.location_field_offset[i],
                                    plan.fde_encoding, code_address, code_size);
    if (rc != REPRO_HCR_LXU_OK) {
      repro_hcr_lx_unmap(buffer, mapped_length);
      return rc;
    }
  }

  /*
   * HLX-OQ-4, resolved by probe-and-verify. The convention that worked last
   * time is tried first (or the per-FDE one, which is the convention MEASURED
   * to work under both unwinders); if `_Unwind_Find_FDE` cannot then find the
   * body, the registration is undone and the other convention is tried and
   * verified the same way.
   */
  first_convention = repro_hcr_lxu_convention != REPRO_HCR_LXU_CONVENTION_UNKNOWN
                         ? repro_hcr_lxu_convention
                         : REPRO_HCR_LXU_CONVENTION_SINGLE_FDE;
#if defined(REPRO_HCR_HLX_M5_FALSIFY_WHOLE_SECTION_FIRST)
  /*
   * FALSIFIER ARM (HLX-M5). Tries the WHOLE-SECTION convention first — the one
   * `Debugger-Integration.md` §5.1 attributes to libgcc and the one that a
   * "just call `__register_frame(section)`" implementation would use. Under
   * libgcc nothing changes, which is precisely why guessing survives testing on
   * one toolchain. Under LLVM libunwind the first attempt must FAIL and the
   * fallback must rescue it, so this arm's signature is
   * `fallbackAttempts == 1` on the libunwind build and `0` on the libgcc one.
   * The provider never defines it.
   */
  first_convention = REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION;
#endif
  second_convention =
      first_convention == REPRO_HCR_LXU_CONVENTION_SINGLE_FDE
          ? REPRO_HCR_LXU_CONVENTION_WHOLE_SECTION
          : REPRO_HCR_LXU_CONVENTION_SINGLE_FDE;

  repro_hcr_lxu_probe_attempts += 1;
  repro_hcr_lxu_register_by_convention(record, first_convention);
#if defined(REPRO_HCR_HLX_M5_FALSIFY_SKIP_VERIFICATION)
  /*
   * FALSIFIER ARM (HLX-M5). Removes the `_Unwind_Find_FDE` verification and
   * nothing else, so the chosen convention is BELIEVED rather than measured.
   * This is the pre-milestone state `HLX-OQ-4` describes in one line: "guessing
   * wrong corrupts every backtrace, silently". Combined with the arm above, the
   * libunwind build must report a successful registration AND a runtime
   * backtrace that stops at the patch page — success on status, red on bytes.
   * The provider never defines it.
   */
  (void)second_convention;
  record->convention = first_convention;
  repro_hcr_lxu_convention = record->convention;
  record->used = 1;
  if (out_payload_address != NULL) {
    *out_payload_address = record->payload_address;
  }
  if (out_fde_count != NULL) {
    *out_fde_count = record->fde_count;
  }
  if (out_convention != NULL) {
    *out_convention = record->convention;
  }
  return REPRO_HCR_LXU_OK;
#else
  if (repro_hcr_lxu_fde_found(code_address)) {
    record->convention = first_convention;
  } else {
    repro_hcr_lxu_fallback_attempts += 1;
    repro_hcr_lxu_deregister_by_convention(record, first_convention);
    repro_hcr_lxu_register_by_convention(record, second_convention);
    if (!repro_hcr_lxu_fde_found(code_address)) {
      repro_hcr_lxu_deregister_by_convention(record, second_convention);
      repro_hcr_lx_unmap(buffer, mapped_length);
      memset(record, 0, sizeof(*record));
      return REPRO_HCR_LXU_REFUSED_FDE_NOT_FOUND;
    }
    record->convention = second_convention;
  }

  repro_hcr_lxu_convention = record->convention;
  record->used = 1;
  if (out_payload_address != NULL) {
    *out_payload_address = record->payload_address;
  }
  if (out_fde_count != NULL) {
    *out_fde_count = record->fde_count;
  }
  if (out_convention != NULL) {
    *out_convention = record->convention;
  }
  return REPRO_HCR_LXU_OK;
#endif /* REPRO_HCR_HLX_M5_FALSIFY_SKIP_VERIFICATION */
}

/*
 * Paired deregistration (design §11, Debugger-Integration §5.4). A rolled-back
 * patch that leaves its FDE registered makes the unwinder describe code that is
 * no longer live — and the mapping is released only AFTER the unwinder has been
 * told to forget it, never before.
 */
REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_unregister_eh_frame(uint64_t payload_address) {
  int index;
  if (payload_address == 0) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  for (index = 0; index < REPRO_HCR_LXU_MAX_REGISTRATIONS; ++index) {
    repro_hcr_lxu_registration *record = &repro_hcr_lxu_registry[index];
    if (!record->used || record->payload_address != payload_address) {
      continue;
    }
    repro_hcr_lxu_deregister_by_convention(record, record->convention);
    repro_hcr_lx_unmap((void *)(uintptr_t)record->payload_address,
                       (size_t)record->mapped_length);
    memset(record, 0, sizeof(*record));
    return REPRO_HCR_LXU_OK;
  }
  return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
}

/* ---------------------------------------------------------------------------
 * GDB JIT symfile: an ELF `ET_REL` rebased onto the live patch address.
 *
 * Replaces the Mach-O `section_64.addr` rebase and `ARM64_RELOC_UNSIGNED` walk
 * of the macOS arm (design §8.3). Two things happen:
 *
 *   1. Every `SHF_ALLOC` section is given an `sh_addr`, with the section that
 *      holds the patched function placed EXACTLY at the live patch address and
 *      the rest laid out after it. The layout of the others is fictional in the
 *      sense that nothing is mapped there — but it must be CONSISTENT, because
 *      `.eh_frame`'s FDE pointers are `pcrel` and are computed against
 *      `sh_addr(.eh_frame)`. A debugger that unwinds the patched frame does it
 *      from these bytes, not from `__register_frame`.
 *   2. Relocations against `.debug_*` and `.eh_frame` are APPLIED in place, and
 *      the relocation sections are then retired to `SHT_NULL` so that no
 *      consumer applies them a second time. GDB reads a relocatable object's
 *      debug sections through BFD's relocated-contents path when relocations
 *      are present; applying and then retiring them makes the bytes GDB sees
 *      independent of that behaviour instead of dependent on it.
 *
 * GDB is stricter than LLDB about a malformed JIT symfile (design §8.3), so
 * every bound below is checked against the buffer length before it is used.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_lxu_symfile_evidence {
  uint32_t text_section_index;
  uint64_t text_section_address;
  uint64_t symbol_value;
  int32_t applied_relocations;
  uint32_t retired_relocation_sections;
  uint32_t allocated_sections;
} repro_hcr_lxu_symfile_evidence;

static uint64_t repro_hcr_lxu_align_up(uint64_t value, uint64_t alignment) {
  if (alignment <= 1) {
    return value;
  }
  return (value + alignment - 1) & ~(alignment - 1);
}

REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_rebase_elf_debug_object(
    uint8_t *bytes, uint64_t size, uint64_t code_address,
    const char *symbol_name, repro_hcr_lxu_symfile_evidence *out) {
  Elf64_Ehdr *ehdr;
  Elf64_Shdr *shdr;
  uint64_t section_count;
  uint64_t i;
  uint64_t text_index = 0;
  uint64_t symbol_value = 0;
  int found_text = 0;
  uint64_t cursor;
  Elf64_Shdr *symtab = NULL;
  const Elf64_Sym *symbols = NULL;
  uint64_t symbol_count = 0;
  const char *strings = NULL;
  uint64_t strings_size = 0;
  const char *section_names = NULL;
  uint64_t section_names_size = 0;

  if (bytes == NULL || out == NULL || size < sizeof(Elf64_Ehdr)) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  memset(out, 0, sizeof(*out));

  ehdr = (Elf64_Ehdr *)(void *)bytes;
  if (memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0 ||
      ehdr->e_ident[EI_CLASS] != ELFCLASS64 ||
      ehdr->e_ident[EI_DATA] != ELFDATA2LSB || ehdr->e_type != ET_REL ||
      ehdr->e_machine != EM_X86_64 ||
      ehdr->e_shentsize != sizeof(Elf64_Shdr) || ehdr->e_shoff == 0) {
    return REPRO_HCR_LXU_REFUSED_NOT_ELF_REL;
  }
  if (ehdr->e_shoff > size ||
      sizeof(Elf64_Shdr) > (size - ehdr->e_shoff)) {
    return REPRO_HCR_LXU_REFUSED_NOT_ELF_REL;
  }
  shdr = (Elf64_Shdr *)(void *)(bytes + ehdr->e_shoff);
  section_count = ehdr->e_shnum != 0 ? (uint64_t)ehdr->e_shnum : shdr[0].sh_size;
  if (section_count == 0 ||
      section_count > (size - ehdr->e_shoff) / sizeof(Elf64_Shdr)) {
    return REPRO_HCR_LXU_REFUSED_NOT_ELF_REL;
  }

  /* Every section's file extent must lie inside the buffer before anything is
   * read through it. */
  for (i = 0; i < section_count; ++i) {
    if (shdr[i].sh_type == SHT_NOBITS) {
      continue;
    }
    if (shdr[i].sh_offset > size || shdr[i].sh_size > size - shdr[i].sh_offset) {
      return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
    }
  }

  {
    uint64_t shstrndx = ehdr->e_shstrndx;
    if (shstrndx == SHN_XINDEX) {
      shstrndx = shdr[0].sh_link;
    }
    if (shstrndx != SHN_UNDEF && shstrndx < section_count &&
        shdr[shstrndx].sh_type == SHT_STRTAB) {
      section_names = (const char *)(bytes + shdr[shstrndx].sh_offset);
      section_names_size = shdr[shstrndx].sh_size;
    }
  }

  for (i = 0; i < section_count; ++i) {
    if (shdr[i].sh_type == SHT_SYMTAB) {
      symtab = &shdr[i];
      break;
    }
  }
  if (symtab != NULL && symtab->sh_entsize == sizeof(Elf64_Sym) &&
      symtab->sh_link < section_count) {
    symbols = (const Elf64_Sym *)(const void *)(bytes + symtab->sh_offset);
    symbol_count = symtab->sh_size / sizeof(Elf64_Sym);
    strings = (const char *)(bytes + shdr[symtab->sh_link].sh_offset);
    strings_size = shdr[symtab->sh_link].sh_size;
  }

  /*
   * Which section holds the patched function. Asked of the SYMBOL TABLE first,
   * by name, because an object may hold several `.text.*` sections and picking
   * the first executable one would rebase the wrong body onto the live address
   * — silently, and with the debugger then describing the wrong code.
   */
  if (symbol_name != NULL && symbol_name[0] != '\0' && symbols != NULL &&
      strings != NULL) {
    for (i = 1; i < symbol_count; ++i) {
      uint64_t name_offset = symbols[i].st_name;
      if (name_offset == 0 || name_offset >= strings_size) {
        continue;
      }
      if (ELF64_ST_TYPE(symbols[i].st_info) != STT_FUNC) {
        continue;
      }
      if (strcmp(strings + name_offset, symbol_name) != 0) {
        continue;
      }
      if (symbols[i].st_shndx == SHN_UNDEF ||
          symbols[i].st_shndx >= section_count) {
        continue;
      }
      text_index = symbols[i].st_shndx;
      symbol_value = symbols[i].st_value;
      found_text = 1;
      break;
    }
    if (!found_text) {
      return REPRO_HCR_LXU_REFUSED_SYMBOL_NOT_IN_OBJECT;
    }
  }
  if (!found_text) {
    for (i = 1; i < section_count; ++i) {
      if ((shdr[i].sh_flags & SHF_EXECINSTR) != 0 && shdr[i].sh_size > 0) {
        text_index = i;
        found_text = 1;
        break;
      }
    }
  }
  if (!found_text) {
    return REPRO_HCR_LXU_REFUSED_NO_TEXT_SECTION;
  }

  /* Lay out the allocatable sections: the patched body EXACTLY at the live
   * address, everything else consistently after it. */
  shdr[text_index].sh_addr = code_address;
  out->allocated_sections = 1;
  cursor = code_address + shdr[text_index].sh_size;
  for (i = 1; i < section_count; ++i) {
    if (i == text_index || (shdr[i].sh_flags & SHF_ALLOC) == 0 ||
        shdr[i].sh_size == 0) {
      continue;
    }
    cursor = repro_hcr_lxu_align_up(cursor, shdr[i].sh_addralign);
    shdr[i].sh_addr = cursor;
    cursor += shdr[i].sh_size;
    out->allocated_sections += 1;
  }

  /* Apply the relocations that name those addresses. */
  for (i = 1; i < section_count; ++i) {
    Elf64_Shdr *rel = &shdr[i];
    Elf64_Shdr *target;
    const char *target_name = "";
    uint64_t entry_count;
    uint64_t r;
    int relevant;

    if (rel->sh_type != SHT_RELA || rel->sh_entsize != sizeof(Elf64_Rela)) {
      continue;
    }
    if (rel->sh_info == 0 || rel->sh_info >= section_count) {
      continue;
    }
    if (symbols == NULL || rel->sh_link != (uint64_t)(symtab - shdr)) {
      continue;
    }
    target = &shdr[rel->sh_info];
    if (section_names != NULL && target->sh_name < section_names_size) {
      target_name = section_names + target->sh_name;
    }
    relevant = (strncmp(target_name, ".debug", 6) == 0) ||
               (strcmp(target_name, ".eh_frame") == 0);
    if (!relevant) {
      continue;
    }
    if (target->sh_type == SHT_NOBITS) {
      continue;
    }
    /*
     * `SHF_COMPRESSED` (what `gcc -gz` and several distributions' default
     * specs produce) puts a `Elf64_Chdr` and a zlib/zstd stream where the
     * relocation offsets say the debug bytes are. Relocating into that stream
     * would corrupt it, and the corruption would surface as WRONG LINE NUMBERS
     * rather than as an error — which is the failure this whole milestone
     * exists to prevent. Refused by name; the patch object must be compiled
     * `-gz=none`.
     */
    if ((target->sh_flags & SHF_COMPRESSED) != 0) {
      return REPRO_HCR_LXU_REFUSED_COMPRESSED_DEBUG_SECTION;
    }

    entry_count = rel->sh_size / sizeof(Elf64_Rela);
    for (r = 0; r < entry_count; ++r) {
      const Elf64_Rela *entry =
          (const Elf64_Rela *)(const void *)(bytes + rel->sh_offset +
                                             r * sizeof(Elf64_Rela));
      uint64_t sym_index = ELF64_R_SYM(entry->r_info);
      uint32_t type = (uint32_t)ELF64_R_TYPE(entry->r_info);
      uint64_t value = 0;
      uint8_t *place;
      uint64_t place_address;

      if (type == R_X86_64_NONE) {
        continue;
      }
      if (entry->r_offset > target->sh_size ||
          target->sh_size - entry->r_offset < 4) {
        return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
      }
      place = bytes + target->sh_offset + entry->r_offset;
      place_address = target->sh_addr + entry->r_offset;

      if (sym_index != 0) {
        const Elf64_Sym *sym;
        if (sym_index >= symbol_count) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        sym = &symbols[sym_index];
        if (sym->st_shndx == SHN_ABS) {
          value = sym->st_value;
        } else if (sym->st_shndx == SHN_UNDEF) {
          /* An undefined symbol in a debug relocation cannot be resolved in
           * process; leave the field as the compiler left it rather than
           * writing a wrong address. */
          continue;
        } else if (sym->st_shndx < section_count) {
          value = shdr[sym->st_shndx].sh_addr + sym->st_value;
        } else {
          continue;
        }
      }

      switch (type) {
      case R_X86_64_64:
        if (target->sh_size - entry->r_offset < 8) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        repro_hcr_lxu_write_u64(place, value + (uint64_t)entry->r_addend);
        break;
      case R_X86_64_32:
      case R_X86_64_32S:
        repro_hcr_lxu_write_u32(place,
                                (uint32_t)(value + (uint64_t)entry->r_addend));
        break;
      case R_X86_64_PC32:
        repro_hcr_lxu_write_u32(
            place, (uint32_t)(uint64_t)((int64_t)value + entry->r_addend -
                                        (int64_t)place_address));
        break;
      case R_X86_64_PC64:
        if (target->sh_size - entry->r_offset < 8) {
          return REPRO_HCR_LXU_REFUSED_METADATA_TRUNCATED;
        }
        repro_hcr_lxu_write_u64(
            place, (uint64_t)((int64_t)value + entry->r_addend -
                              (int64_t)place_address));
        break;
      case R_X86_64_16:
      case R_X86_64_8:
        return REPRO_HCR_LXU_REFUSED_RELOCATION_UNSUPPORTED;
      default:
        return REPRO_HCR_LXU_REFUSED_RELOCATION_UNSUPPORTED;
      }
      out->applied_relocations += 1;
    }

    /* Retire the section so nothing applies it twice. `SHT_NULL` is an
     * inactive section header: legal, ignored by every reader, and unlike
     * truncating `sh_size` it also drops the `SEC_RELOC` flag BFD would
     * otherwise derive. */
    rel->sh_type = SHT_NULL;
    rel->sh_size = 0;
    rel->sh_info = 0;
    rel->sh_link = 0;
    out->retired_relocation_sections += 1;
  }

  out->text_section_index = (uint32_t)text_index;
  out->text_section_address = code_address;
  out->symbol_value = code_address + symbol_value;
  return REPRO_HCR_LXU_OK;
}

/* ---------------------------------------------------------------------------
 * The GDB JIT interface itself.
 *
 * The protocol is Linux-origin and ports 1:1 from the macOS arm (design §8.3):
 * same descriptor layout, same linked-list splice, same `action_flag`
 * handshake, same `noinline` hook GDB and LLDB put a breakpoint on.
 *
 * OWNERSHIP. Design §8.3 records that both agents emit `__jit_debug_descriptor`
 * and `__jit_debug_register_code` — `repro_hcr_agent.c` under
 * `REPRO_HCR_TARGET_APPLE_ARM64`, and `debug_unwind.nim` from its `{.emit.}`
 * block — so linking the C and Nim agents into one binary produces duplicate
 * symbols. The Linux port picks the C agent, and this header is where that
 * single definition lives. `debug_unwind.nim` keeps its emit block guarded to
 * macOS arm64 and reaches these symbols through `importc` on Linux, so a Nim
 * binary that links the agent has ONE descriptor rather than two.
 *
 * Include this header from exactly one translation unit per binary — the agent,
 * or the test shim that stands in for it. That is the same rule the other
 * `static`-only provider headers follow; these two symbols are the only
 * non-`static` things in the file, and they are non-`static` because the
 * debugger looks them up BY NAME in the target's symbol table.
 * ------------------------------------------------------------------------- */

enum {
  REPRO_HCR_LXU_JIT_NOACTION = 0,
  REPRO_HCR_LXU_JIT_REGISTER_FN = 1,
  REPRO_HCR_LXU_JIT_UNREGISTER_FN = 2
};

struct repro_hcr_lxu_jit_code_entry {
  struct repro_hcr_lxu_jit_code_entry *next_entry;
  struct repro_hcr_lxu_jit_code_entry *prev_entry;
  const char *symfile_addr;
  uint64_t symfile_size;
};

struct repro_hcr_lxu_jit_descriptor {
  uint32_t version;
  uint32_t action_flag;
  struct repro_hcr_lxu_jit_code_entry *relevant_entry;
  struct repro_hcr_lxu_jit_code_entry *first_entry;
};

/* `repro_hcr_lxu_jit_code_entry` must be the FIRST member: the rollback hook
 * is handed the entry address and recovers the record by casting back. */
struct repro_hcr_lxu_jit_record {
  struct repro_hcr_lxu_jit_code_entry entry;
  uint8_t *debug_bytes;
  uint64_t debug_size;
};

__attribute__((used, visibility("default")))
struct repro_hcr_lxu_jit_descriptor __jit_debug_descriptor = {
    1, REPRO_HCR_LXU_JIT_NOACTION, 0, 0};

/*
 * GDB and LLDB set a breakpoint on this function by name, so it must survive
 * inlining and must not be discarded. The `volatile` asm barrier keeps the
 * descriptor stores from being sunk past the call the debugger is watching.
 */
__attribute__((noinline, used, visibility("default")))
void __jit_debug_register_code(void) {
  __asm__ volatile("" ::: "memory");
}

static uint64_t repro_hcr_lxu_jit_register_calls = 0;
static uint64_t repro_hcr_lxu_jit_unregister_calls = 0;

REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_register_jit_symfile(
    const uint8_t *bytes, uint64_t size, uint64_t code_address,
    const char *symbol_name, uint64_t *out_entry_address,
    repro_hcr_lxu_symfile_evidence *out) {
  struct repro_hcr_lxu_jit_record *record;
  uint8_t *copy;
  int rc;

  if (out_entry_address != NULL) {
    *out_entry_address = 0;
  }
  if (bytes == NULL || size == 0 || out == NULL) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }

  record = (struct repro_hcr_lxu_jit_record *)calloc(1, sizeof(*record));
  if (record == NULL) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  copy = (uint8_t *)malloc((size_t)size);
  if (copy == NULL) {
    free(record);
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  memcpy(copy, bytes, (size_t)size);

  /* Rebase BEFORE the entry is spliced in: a debugger that read the list
   * between the splice and the rebase would parse an object claiming the
   * link-time address 0 for the patched body. */
  rc = repro_hcr_lxu_rebase_elf_debug_object(copy, size, code_address,
                                             symbol_name, out);
  if (rc != REPRO_HCR_LXU_OK) {
    free(copy);
    free(record);
    return rc;
  }

  record->debug_bytes = copy;
  record->debug_size = size;
  record->entry.symfile_addr = (const char *)copy;
  record->entry.symfile_size = size;

  record->entry.next_entry = __jit_debug_descriptor.first_entry;
  record->entry.prev_entry = NULL;
  if (__jit_debug_descriptor.first_entry != NULL) {
    __jit_debug_descriptor.first_entry->prev_entry = &record->entry;
  }
  __jit_debug_descriptor.first_entry = &record->entry;
  __jit_debug_descriptor.relevant_entry = &record->entry;
  __jit_debug_descriptor.action_flag = REPRO_HCR_LXU_JIT_REGISTER_FN;
  repro_hcr_lxu_jit_register_calls += 1;
  __jit_debug_register_code();

  if (out_entry_address != NULL) {
    *out_entry_address = (uint64_t)(uintptr_t)&record->entry;
  }
  return REPRO_HCR_LXU_OK;
}

/*
 * Paired unregistration (design §8.3). The pre-existing code defined
 * `REPRO_HCR_JIT_UNREGISTER_FN` and never used it, leaking a descriptor entry
 * per patch and — worse than the leak — leaving the debugger describing code a
 * rollback has already taken out of the control flow.
 */
REPRO_HCR_LXU_MAYBE_UNUSED
static int repro_hcr_lxu_unregister_jit_symfile(uint64_t entry_address) {
  struct repro_hcr_lxu_jit_code_entry *target;
  struct repro_hcr_lxu_jit_record *record;

  if (entry_address == 0) {
    return REPRO_HCR_LXU_REFUSED_INVALID_ARGUMENT;
  }
  target = (struct repro_hcr_lxu_jit_code_entry *)(uintptr_t)entry_address;

  if (target->prev_entry != NULL) {
    target->prev_entry->next_entry = target->next_entry;
  } else if (__jit_debug_descriptor.first_entry == target) {
    __jit_debug_descriptor.first_entry = target->next_entry;
  }
  if (target->next_entry != NULL) {
    target->next_entry->prev_entry = target->prev_entry;
  }
  target->prev_entry = NULL;
  target->next_entry = NULL;

  __jit_debug_descriptor.relevant_entry = target;
  __jit_debug_descriptor.action_flag = REPRO_HCR_LXU_JIT_UNREGISTER_FN;
  repro_hcr_lxu_jit_unregister_calls += 1;
  __jit_debug_register_code();
  __jit_debug_descriptor.relevant_entry = NULL;
  __jit_debug_descriptor.action_flag = REPRO_HCR_LXU_JIT_NOACTION;

  record = (struct repro_hcr_lxu_jit_record *)target;
  free(record->debug_bytes);
  record->debug_bytes = NULL;
  free(record);
  return REPRO_HCR_LXU_OK;
}

#endif /* REPRO_HCR_LINUX_UNWIND_H */
