/*
 * Linux x86_64 ELF symbol resolution for the HCR provider (HLX-M1).
 *
 * Implements `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7:
 *
 *   §7.1 — there is deliberately NO `dlsym` path here. `dlsym` sees only
 *          `.dynsym`, i.e. exported dynamically-visible symbols, so it cannot
 *          see `static` or hidden functions, which are most of the ones worth
 *          hot-reloading. A resolver that silently succeeded for exported
 *          symbols only would hide that.
 *   §7.2 — the pipeline: `dl_iterate_phdr` gives `dlpi_addr`, which IS the load
 *          bias for PIE and ASLR alike (0 for a non-PIE main executable), and a
 *          symbol's runtime address is `dlpi_addr + st_value`. The symbol table
 *          itself is read from the object's file on disk, because `.symtab` is
 *          not loaded at runtime. `dlpi_name` is "" for the main executable, so
 *          that one is resolved through `/proc/self/exe`; the vDSO has no file
 *          and is skipped.
 *   §7.3 — build-id verification is MANDATORY and is performed BEFORE any
 *          symbol byte of an object is trusted. Reading a rebuilt file while an
 *          older image is mapped is the silent-memory-corruption case this
 *          check exists to prevent, and in a hot-reload workflow a rebuild is
 *          exactly what just happened.
 *   §7.4 — `STB_LOCAL` ambiguity: two translation units may each define a
 *          `static` function of the same name. A patch target is identified by
 *          (object identity, symbol name, `st_shndx`) and an under-determined
 *          name is REFUSED, never resolved to the first match.
 *
 * Beyond §7.2's list, and required by real binaries:
 *
 *   - `SHN_XINDEX` on both the section-header string table index and on
 *     individual symbols (`SHT_SYMTAB_SHNDX`), and the `e_shnum == 0` overflow
 *     where the real section count lives in `shdr[0].sh_size`.
 *   - Symbol versioning. `.symtab` may spell versions into the name
 *     (`memcpy@@GLIBC_2.14`), while `.dynsym` carries them out of band in
 *     `.gnu.version` with the names in `.gnu.version_d` / `.gnu.version_r`.
 *     Both are read: the suffix is stripped from the name so a caller can ask
 *     for `memcpy`, and when several versions of one name exist the DEFAULT
 *     one (the entry whose `.gnu.version` hidden bit is clear) is selected.
 *     If that still leaves more than one, the name is refused as ambiguous.
 *   - `STT_GNU_IFUNC` is REFUSED. Its `st_value` is a resolver, not the
 *     implementation, so patching there patches the wrong function — and doing
 *     it silently is worse than not doing it.
 *
 * Every refusal is named and distinct. A symbol that cannot be safely resolved
 * is refused by name; nothing here guesses.
 *
 * Trap note (Verification-Harness-Traps.md §9): a reader that fails to open a
 * stream and reports the failure as an ANSWER is a vacuous check. So a failure
 * to read an object's symbol table is NEVER reported as "the symbol is not
 * here". `repro_hcr_elf_resolve` prefers a hard object refusal over
 * `elf-symbol-not-found`, and `elf-symbol-table-absent` is its own refusal
 * rather than an empty result.
 *
 * All functions are `static` so this header can be included both by the agent
 * translation unit and by the test probe shim, which drives the SAME code.
 */

#ifndef REPRO_HCR_LINUX_ELF_SYMBOLS_H
#define REPRO_HCR_LINUX_ELF_SYMBOLS_H

/*
 * `dl_iterate_phdr` and `struct dl_phdr_info` live behind `__USE_GNU` in
 * glibc's <link.h>, so the INCLUDING translation unit must define _GNU_SOURCE
 * before it pulls in any libc header — defining it here would be too late.
 * Both includers do (`repro_hcr_agent.c` and the probe shim), and this is a
 * hard error rather than a silent fallback declaration so that a third
 * includer cannot end up with a subtly different `struct dl_phdr_info`.
 */
#if !defined(__USE_GNU) && !defined(__APPLE__)
#error "repro_hcr_linux_elf_symbols.h requires _GNU_SOURCE (for dl_iterate_phdr); define it at the top of the including translation unit"
#endif

/*
 * This header is a `static`-only library shared by two translation units that
 * use different subsets of it: the agent never needs the file-only entry point,
 * and the probe shim never needs the agent's convenience wrapper. Marking the
 * two top-level entry points maybe-unused keeps both TUs warning-clean without
 * either having to reference a function it has no business calling.
 */
#if defined(__GNUC__)
#define REPRO_HCR_ELF_MAYBE_UNUSED __attribute__((unused))
#else
#define REPRO_HCR_ELF_MAYBE_UNUSED
#endif

#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* ---------------------------------------------------------------------------
 * Refusal vocabulary (design §7.3, §7.4, and §4.3's "named and distinct" rule).
 * ------------------------------------------------------------------------- */

enum {
  REPRO_HCR_ELF_OK = 0,
  REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT = 1,
  REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_FOUND = 2,
  REPRO_HCR_ELF_REFUSED_SYMBOL_AMBIGUOUS = 3,
  REPRO_HCR_ELF_REFUSED_SYMBOL_IS_IFUNC = 4,
  REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_A_FUNCTION = 5,
  REPRO_HCR_ELF_REFUSED_SYMBOL_UNDEFINED = 6,
  REPRO_HCR_ELF_REFUSED_SYMBOL_TABLE_ABSENT = 7,
  REPRO_HCR_ELF_REFUSED_BUILD_ID_MISMATCH = 8,
  REPRO_HCR_ELF_REFUSED_BUILD_ID_ABSENT = 9,
  REPRO_HCR_ELF_REFUSED_OBJECT_IMAGE_REPLACED = 10,
  REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE = 11,
  REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED = 12,
  REPRO_HCR_ELF_REFUSED_NO_OBJECTS_SCANNED = 13
};

static const char *repro_hcr_elf_refusal_name(int code) {
  switch (code) {
    case REPRO_HCR_ELF_OK:
      return "ok";
    case REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT:
      return "elf-invalid-argument";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_FOUND:
      return "elf-symbol-not-found";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_AMBIGUOUS:
      return "elf-symbol-ambiguous";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_IS_IFUNC:
      return "elf-symbol-is-ifunc";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_A_FUNCTION:
      return "elf-symbol-not-a-function";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_UNDEFINED:
      return "elf-symbol-undefined";
    case REPRO_HCR_ELF_REFUSED_SYMBOL_TABLE_ABSENT:
      return "elf-symbol-table-absent";
    case REPRO_HCR_ELF_REFUSED_BUILD_ID_MISMATCH:
      return "elf-build-id-mismatch";
    case REPRO_HCR_ELF_REFUSED_BUILD_ID_ABSENT:
      return "elf-build-id-absent";
    case REPRO_HCR_ELF_REFUSED_OBJECT_IMAGE_REPLACED:
      return "elf-object-image-replaced";
    case REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE:
      return "elf-object-unreadable";
    case REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED:
      return "elf-object-malformed";
    case REPRO_HCR_ELF_REFUSED_NO_OBJECTS_SCANNED:
      return "elf-no-objects-scanned";
    default:
      return "elf-unknown-refusal";
  }
}

/*
 * Whether a refusal is a NEGATIVE answer derived from the scan having
 * completed — as opposed to a positive statement about the symbol itself.
 *
 * REVIEW 2026-09-10. All three of these say "having looked at everything, the
 * thing you asked for is not there", so all three are worthless if an object
 * could not be looked at. They must therefore yield to that object's own
 * refusal. Previously only `elf-symbol-not-found` did, which meant a
 * build-id mismatch in one object was silently discarded whenever another
 * object happened to hold a same-named variable or import — the same
 * failure-reported-as-answer trap, one level up.
 */
static int repro_hcr_elf_refusal_is_scan_negative(int refusal) {
  return refusal == REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_FOUND ||
         refusal == REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_A_FUNCTION ||
         refusal == REPRO_HCR_ELF_REFUSED_SYMBOL_UNDEFINED;
}

/* ---------------------------------------------------------------------------
 * Result shapes.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_ELF_PATH_MAX 256u
#define REPRO_HCR_ELF_VERSION_MAX 64u
#define REPRO_HCR_ELF_SECTION_NAME_MAX 64u
#define REPRO_HCR_ELF_MAX_CANDIDATES 8
#define REPRO_HCR_ELF_DETAIL_MAX 640u

typedef struct repro_hcr_elf_candidate {
  char object_path[REPRO_HCR_ELF_PATH_MAX];
  char version[REPRO_HCR_ELF_VERSION_MAX];
  /* Recorded at scan time because design §7.4's ambiguity diagnostic must name
   * the candidates, and by the time selection runs the object's file mapping
   * that holds the section-header string table is gone. */
  char section_name[REPRO_HCR_ELF_SECTION_NAME_MAX];
  /*
   * The `STT_FILE` symbol that precedes this one in `.symtab`, i.e. the source
   * translation unit that defined it.
   *
   * MEASURED CORRECTION TO DESIGN §7.4. The design identifies a patch target by
   * (object identity, symbol name, `st_shndx`). In a LINKED image that tuple
   * does not disambiguate: the linker merges every input `.text.helper` into
   * one output `.text`, so two `static helper` definitions from two translation
   * units share one `st_shndx` and the tuple selects both. `st_shndx` is the
   * right key inside an `ET_REL` object, which is where the design's reasoning
   * comes from, but the resolver reads `ET_EXEC`/`ET_DYN`. The `STT_FILE`
   * symbol is the key that works there — the ELF spec places it immediately
   * before the `STB_LOCAL` symbols of its file — and it is also the component a
   * human patch bundle can actually name.
   */
  char source_file[REPRO_HCR_ELF_PATH_MAX];
  uint64_t load_bias;
  uint64_t link_value; /* st_value, i.e. the link-time address */
  uint64_t runtime_address; /* load_bias + link_value (design §7.2 step 1) */
  uint64_t size;            /* st_size — authoritative on ELF (design §7.5) */
  uint32_t section_index;   /* st_shndx, already SHN_XINDEX-expanded */
  uint8_t bind;             /* STB_LOCAL / STB_GLOBAL / STB_WEAK */
  uint8_t symbol_type;      /* STT_FUNC or STT_GNU_IFUNC */
  uint8_t from_dynsym;      /* 1 when read from .dynsym, 0 from .symtab */
  uint8_t default_version;  /* 1 when the .gnu.version hidden bit is clear */
} repro_hcr_elf_candidate;

typedef struct repro_hcr_elf_resolution {
  int refusal;
  int candidate_count;    /* candidates recorded (capped by MAX_CANDIDATES) */
  int match_count;        /* distinct matches found, uncapped */
  int objects_seen;       /* objects dl_iterate_phdr reported */
  int objects_parsed;     /* objects whose symbol table was actually read */
  int objects_refused;    /* objects rejected before their symbols were read */
  int objects_skipped;    /* vDSO, and objects excluded by an object hint */
  /*
   * Names that MATCHED but were rejected, counted separately so that "there is
   * no such symbol" and "there is one, and it is not something you can patch"
   * stay distinguishable. Without these, a request for a global variable and a
   * request for a typo both come back `elf-symbol-not-found`.
   */
  int rejected_not_a_function; /* matched the name, but not STT_FUNC/IFUNC */
  int rejected_undefined;      /* matched, but SHN_UNDEF — imported, not here */
  repro_hcr_elf_candidate candidates[REPRO_HCR_ELF_MAX_CANDIDATES];
  uint64_t symbols_scanned;
  uint64_t runtime_address; /* valid only when refusal == REPRO_HCR_ELF_OK */
  /* HLX-M4: the chosen candidate's `st_size`. Authoritative on ELF (design
   * §7.5) and 0 when the symbol declares none, which callers must treat as
   * "extent unknown" rather than "empty function". */
  uint64_t runtime_size;
  char detail[REPRO_HCR_ELF_DETAIL_MAX];
} repro_hcr_elf_resolution;

typedef struct repro_hcr_elf_query {
  const char *symbol_name;
  /* NULL or "" matches any object. Otherwise the object's resolved path must
   * end with this string, which is how design §7.4's "object file identity"
   * component of a patch target is spelled on the wire. */
  const char *object_suffix;
  /* < 0 matches any section. Otherwise `st_shndx` must equal it — the third
   * component of design §7.4's (object, name, st_shndx) tuple. Kept because it
   * is the correct key inside an `ET_REL` object and under a link that really
   * does keep per-function sections; see `source_file` for why it is not
   * sufficient on its own in a linked image. */
  int section_index;
  /*
   * NULL or "" matches any translation unit. Otherwise the `STT_FILE` symbol
   * governing the candidate must end with this string. This is the component
   * that actually resolves design §7.4's `static`-collision case in a linked
   * image; see `repro_hcr_elf_candidate::source_file`.
   */
  const char *source_file;
  /*
   * 0 matches any address. Otherwise `st_value` must equal it exactly. The
   * last-resort key for a bundle that has already been told which definition it
   * means and needs to say so without ambiguity.
   */
  uint64_t link_value;
  /* 1 = design §7.3's mandatory build-id verification (the agent's setting).
   * 0 exists so a gate can measure what the check prevents; it must never be
   * the production value. */
  int require_build_id;
} repro_hcr_elf_query;

/* ---------------------------------------------------------------------------
 * Small helpers. No libc string formatting beyond snprintf into a fixed buffer.
 * ------------------------------------------------------------------------- */

static void repro_hcr_elf_copy_string(char *dst, size_t cap, const char *src) {
  size_t i = 0;
  if (dst == NULL || cap == 0) {
    return;
  }
  if (src != NULL) {
    for (; i + 1 < cap && src[i] != '\0'; ++i) {
      dst[i] = src[i];
    }
  }
  dst[i] = '\0';
}

/* Keeps the tail of a path when it does not fit, because the tail is the part
 * that identifies the object. A truncated head is marked with "…" spelled in
 * ASCII so the diagnostic never claims an exact path it did not record. */
static void repro_hcr_elf_copy_path(char *dst, size_t cap, const char *src) {
  size_t len;
  if (dst == NULL || cap == 0) {
    return;
  }
  if (src == NULL) {
    dst[0] = '\0';
    return;
  }
  len = strlen(src);
  if (len + 1 <= cap) {
    memcpy(dst, src, len + 1);
    return;
  }
  dst[0] = '.';
  dst[1] = '.';
  dst[2] = '.';
  memcpy(dst + 3, src + (len - (cap - 4)), cap - 4);
  dst[cap - 1] = '\0';
}

static int repro_hcr_elf_ends_with(const char *text, const char *suffix) {
  size_t text_len;
  size_t suffix_len;
  if (text == NULL || suffix == NULL) {
    return 0;
  }
  text_len = strlen(text);
  suffix_len = strlen(suffix);
  if (suffix_len == 0) {
    return 1;
  }
  if (suffix_len > text_len) {
    return 0;
  }
  return memcmp(text + (text_len - suffix_len), suffix, suffix_len) == 0;
}

/*
 * Length of `name` up to a symbol-version separator, per design §7.2 step 4.
 * `.symtab` spells versioned aliases as `memcpy@GLIBC_2.2.5` (non-default) or
 * `memcpy@@GLIBC_2.14` (default); the base name is everything before the first
 * '@'. Returns the base length and, when `version_out` is non-NULL, copies the
 * version text and reports whether it was the default (`@@`) spelling.
 */
static size_t repro_hcr_elf_base_name_length(const char *name,
                                             char *version_out,
                                             size_t version_cap,
                                             int *is_default_out) {
  size_t i = 0;
  if (version_out != NULL && version_cap > 0) {
    version_out[0] = '\0';
  }
  if (is_default_out != NULL) {
    *is_default_out = 1;
  }
  if (name == NULL) {
    return 0;
  }
  while (name[i] != '\0' && name[i] != '@') {
    i++;
  }
  if (name[i] == '@') {
    size_t vstart = i + 1;
    int is_default = 0;
    if (name[vstart] == '@') {
      is_default = 1;
      vstart++;
    }
    if (version_out != NULL) {
      repro_hcr_elf_copy_string(version_out, version_cap, name + vstart);
    }
    if (is_default_out != NULL) {
      *is_default_out = is_default;
    }
  }
  return i;
}

static int repro_hcr_elf_name_matches(const char *symbol_name,
                                      const char *requested) {
  size_t base_len;
  if (symbol_name == NULL || requested == NULL) {
    return 0;
  }
  base_len = repro_hcr_elf_base_name_length(symbol_name, NULL, 0, NULL);
  if (strlen(requested) != base_len) {
    return 0;
  }
  return memcmp(symbol_name, requested, base_len) == 0;
}

/* ---------------------------------------------------------------------------
 * A mapped, bounds-checked view of an object file on disk.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_elf_image {
  const uint8_t *base;
  size_t length;
} repro_hcr_elf_image;

static int repro_hcr_elf_map_file(const char *path,
                                  repro_hcr_elf_image *out) {
  int fd;
  struct stat st;
  void *mapped;

  if (path == NULL || out == NULL) {
    return REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT;
  }
  out->base = NULL;
  out->length = 0;

  fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE;
  }
  if (fstat(fd, &st) != 0 || st.st_size <= 0) {
    close(fd);
    return REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE;
  }
  mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (mapped == MAP_FAILED) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE;
  }
  out->base = (const uint8_t *)mapped;
  out->length = (size_t)st.st_size;
  return REPRO_HCR_ELF_OK;
}

static void repro_hcr_elf_unmap_file(repro_hcr_elf_image *image) {
  if (image != NULL && image->base != NULL) {
    munmap((void *)(uintptr_t)image->base, image->length);
    image->base = NULL;
    image->length = 0;
  }
}

/* Every read of file content goes through this. A truncated or hostile file
 * must produce a named refusal, never an out-of-bounds read. */
static const void *repro_hcr_elf_at(const repro_hcr_elf_image *image,
                                    uint64_t offset, uint64_t size) {
  if (image == NULL || image->base == NULL) {
    return NULL;
  }
  if (offset > (uint64_t)image->length) {
    return NULL;
  }
  if (size > (uint64_t)image->length - offset) {
    return NULL;
  }
  return image->base + offset;
}

static const char *repro_hcr_elf_string_at(const repro_hcr_elf_image *image,
                                           uint64_t table_offset,
                                           uint64_t table_size,
                                           uint64_t index) {
  const char *table;
  uint64_t i;
  if (index >= table_size) {
    return NULL;
  }
  table = (const char *)repro_hcr_elf_at(image, table_offset, table_size);
  if (table == NULL) {
    return NULL;
  }
  /* The table must be NUL-terminated within its own bounds for the string at
   * `index` to be safe to hand out. */
  for (i = index; i < table_size; ++i) {
    if (table[i] == '\0') {
      return table + index;
    }
  }
  return NULL;
}

/* ---------------------------------------------------------------------------
 * Section-header table, with the two overflow escapes real large binaries use.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_elf_sections {
  const Elf64_Shdr *headers;
  uint64_t count;      /* real count; `e_shnum == 0` resolves via shdr[0] */
  uint64_t shstrndx;   /* real index; SHN_XINDEX resolves via shdr[0].sh_link */
  uint64_t shstr_offset;
  uint64_t shstr_size;
} repro_hcr_elf_sections;

static int repro_hcr_elf_read_sections(const repro_hcr_elf_image *image,
                                       repro_hcr_elf_sections *out) {
  const Elf64_Ehdr *ehdr;
  const Elf64_Shdr *shdr;
  uint64_t count;
  uint64_t shstrndx;

  memset(out, 0, sizeof(*out));
  ehdr = (const Elf64_Ehdr *)repro_hcr_elf_at(image, 0, sizeof(Elf64_Ehdr));
  if (ehdr == NULL) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }
  if (memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0 ||
      ehdr->e_ident[EI_CLASS] != ELFCLASS64 ||
      ehdr->e_ident[EI_DATA] != ELFDATA2LSB) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }
  if (ehdr->e_shoff == 0 || ehdr->e_shentsize != sizeof(Elf64_Shdr)) {
    /* No section headers at all. `.symtab` and `.dynsym` are both reached
     * through them, so this is a refusal and not "zero symbols". */
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }
  shdr = (const Elf64_Shdr *)repro_hcr_elf_at(image, ehdr->e_shoff,
                                              sizeof(Elf64_Shdr));
  if (shdr == NULL) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }

  /* `e_shnum == 0` means the real count did not fit in 16 bits and lives in
   * the reserved section-header entry. An 84 MB C++ binary is exactly the kind
   * of input that reaches this, so it is handled rather than assumed away. */
  count = ehdr->e_shnum != 0 ? (uint64_t)ehdr->e_shnum : shdr[0].sh_size;
  if (count == 0) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }
  /*
   * REVIEW 2026-09-10. In the `e_shnum == 0` path `count` is an unconstrained
   * 64-bit field read straight from the file, and `count * sizeof(Elf64_Shdr)`
   * WRAPS for any count >= 2^58 — a crafted `sh_size` of 0x0400000000000000
   * makes the product exactly 0, so the bounds check below passes and
   * `out->count` is then set to 2^58. Every later `i < sections->count` loop
   * would walk a 64-byte mapping to that count and read off the end of it.
   * Bound the count against the file BEFORE multiplying; the division cannot
   * overflow and `e_shoff` was already validated by the single-header read
   * above.
   */
  if (count > (uint64_t)(image->length - ehdr->e_shoff) / sizeof(Elf64_Shdr)) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }
  shdr = (const Elf64_Shdr *)repro_hcr_elf_at(
      image, ehdr->e_shoff, count * sizeof(Elf64_Shdr));
  if (shdr == NULL) {
    return REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED;
  }

  shstrndx = (uint64_t)ehdr->e_shstrndx;
  if (shstrndx == SHN_XINDEX) {
    shstrndx = shdr[0].sh_link;
  }
  out->headers = shdr;
  out->count = count;
  out->shstrndx = shstrndx;
  if (shstrndx < count && shdr[shstrndx].sh_type == SHT_STRTAB) {
    out->shstr_offset = shdr[shstrndx].sh_offset;
    out->shstr_size = shdr[shstrndx].sh_size;
  }
  return REPRO_HCR_ELF_OK;
}

static const char *repro_hcr_elf_section_name(
    const repro_hcr_elf_image *image, const repro_hcr_elf_sections *sections,
    uint64_t index) {
  if (index >= sections->count || sections->shstr_size == 0) {
    return NULL;
  }
  return repro_hcr_elf_string_at(image, sections->shstr_offset,
                                 sections->shstr_size,
                                 sections->headers[index].sh_name);
}

/* ---------------------------------------------------------------------------
 * Build-id (design §7.3).
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_ELF_BUILD_ID_MAX 64u

typedef struct repro_hcr_elf_build_id {
  uint8_t bytes[REPRO_HCR_ELF_BUILD_ID_MAX];
  uint32_t length;
} repro_hcr_elf_build_id;

/*
 * Scan a byte range of ELF notes for NT_GNU_BUILD_ID with owner "GNU".
 * x86_64 ELF notes are 4-byte aligned in both name and descriptor padding.
 */
static int repro_hcr_elf_scan_notes(const uint8_t *notes, uint64_t size,
                                    repro_hcr_elf_build_id *out) {
  uint64_t offset = 0;
  if (notes == NULL) {
    return 0;
  }
  while (offset + sizeof(Elf64_Nhdr) <= size) {
    Elf64_Nhdr header;
    uint64_t name_offset;
    uint64_t desc_offset;
    uint64_t next;
    memcpy(&header, notes + offset, sizeof(header));
    name_offset = offset + sizeof(Elf64_Nhdr);
    desc_offset = name_offset + ((header.n_namesz + 3u) & ~3u);
    next = desc_offset + ((header.n_descsz + 3u) & ~3u);
    if (next < offset || next > size) {
      return 0;
    }
    if (header.n_type == NT_GNU_BUILD_ID && header.n_namesz == 4 &&
        memcmp(notes + name_offset, "GNU", 4) == 0 && header.n_descsz > 0 &&
        header.n_descsz <= REPRO_HCR_ELF_BUILD_ID_MAX) {
      out->length = header.n_descsz;
      memcpy(out->bytes, notes + desc_offset, header.n_descsz);
      return 1;
    }
    offset = next;
  }
  return 0;
}

static int repro_hcr_elf_file_build_id(const repro_hcr_elf_image *image,
                                       const repro_hcr_elf_sections *sections,
                                       repro_hcr_elf_build_id *out) {
  uint64_t i;
  memset(out, 0, sizeof(*out));
  for (i = 0; i < sections->count; ++i) {
    const Elf64_Shdr *sh = &sections->headers[i];
    const uint8_t *notes;
    if (sh->sh_type != SHT_NOTE) {
      continue;
    }
    notes = (const uint8_t *)repro_hcr_elf_at(image, sh->sh_offset, sh->sh_size);
    if (notes == NULL) {
      continue;
    }
    if (repro_hcr_elf_scan_notes(notes, sh->sh_size, out)) {
      return 1;
    }
  }
  return 0;
}

/*
 * The build-id as the RUNNING process sees it: walk the object's own program
 * headers, which `dl_iterate_phdr` handed us, and read PT_NOTE out of the live
 * mapping at `load_bias + p_vaddr`. This is the half that describes the bytes
 * actually executing; the file half above describes what a rebuild left on
 * disk. Design §7.3 is the comparison of the two.
 */
static int repro_hcr_elf_mapped_build_id(uint64_t load_bias,
                                         const ElfW(Phdr) * phdr,
                                         uint16_t phnum,
                                         repro_hcr_elf_build_id *out) {
  uint16_t i;
  memset(out, 0, sizeof(*out));
  if (phdr == NULL) {
    return 0;
  }
  for (i = 0; i < phnum; ++i) {
    if (phdr[i].p_type != PT_NOTE) {
      continue;
    }
    if (repro_hcr_elf_scan_notes(
            (const uint8_t *)(uintptr_t)(load_bias + phdr[i].p_vaddr),
            phdr[i].p_memsz, out)) {
      return 1;
    }
  }
  return 0;
}

static void repro_hcr_elf_format_build_id(const repro_hcr_elf_build_id *id,
                                          char *out, size_t cap) {
  static const char digits[] = "0123456789abcdef";
  size_t i;
  size_t written = 0;
  if (out == NULL || cap == 0) {
    return;
  }
  for (i = 0; i < id->length && written + 3 <= cap; ++i) {
    out[written++] = digits[id->bytes[i] >> 4];
    out[written++] = digits[id->bytes[i] & 0x0fu];
  }
  out[written] = '\0';
}

/* ---------------------------------------------------------------------------
 * Symbol-version tables (`.gnu.version`, `.gnu.version_d`, `.gnu.version_r`).
 *
 * `.dynsym` names carry no `@version` suffix; the version lives in a parallel
 * `Elf64_Half` array whose values index either a verdef (defined here) or a
 * verneed (needed from elsewhere). Bit 0x8000 marks a NON-default (hidden)
 * version. When several `.dynsym` entries share a base name — which is exactly
 * what versioned symbols look like — the default one is the one a caller means.
 * ------------------------------------------------------------------------- */

#define REPRO_HCR_ELF_VERSYM_HIDDEN 0x8000u
#define REPRO_HCR_ELF_VER_NDX_LOCAL 0u
#define REPRO_HCR_ELF_VER_NDX_GLOBAL 1u

typedef struct repro_hcr_elf_version_tables {
  const uint16_t *versym; /* one entry per dynsym symbol, or NULL */
  uint64_t versym_count;
  const Elf64_Shdr *verdef;
  const Elf64_Shdr *verneed;
  uint64_t strtab_offset;
  uint64_t strtab_size;
} repro_hcr_elf_version_tables;

/* Resolve a version index to its name, searching verdef then verneed. */
static void repro_hcr_elf_version_name(
    const repro_hcr_elf_image *image,
    const repro_hcr_elf_version_tables *tables, uint16_t index, char *out,
    size_t cap) {
  uint16_t plain = (uint16_t)(index & (uint16_t)~REPRO_HCR_ELF_VERSYM_HIDDEN);
  if (out != NULL && cap > 0) {
    out[0] = '\0';
  }
  if (plain <= REPRO_HCR_ELF_VER_NDX_GLOBAL) {
    return;
  }
  if (tables->verdef != NULL) {
    uint64_t offset = tables->verdef->sh_offset;
    uint64_t remaining = tables->verdef->sh_size;
    uint32_t entries = tables->verdef->sh_info;
    uint32_t i;
    for (i = 0; i < entries; ++i) {
      const Elf64_Verdef *vd =
          (const Elf64_Verdef *)repro_hcr_elf_at(image, offset,
                                                 sizeof(Elf64_Verdef));
      if (vd == NULL) {
        break;
      }
      if (vd->vd_ndx == plain && vd->vd_cnt > 0) {
        const Elf64_Verdaux *aux = (const Elf64_Verdaux *)repro_hcr_elf_at(
            image, offset + vd->vd_aux, sizeof(Elf64_Verdaux));
        if (aux != NULL) {
          const char *name = repro_hcr_elf_string_at(
              image, tables->strtab_offset, tables->strtab_size, aux->vda_name);
          repro_hcr_elf_copy_string(out, cap, name);
        }
        return;
      }
      if (vd->vd_next == 0 || vd->vd_next > remaining) {
        break;
      }
      offset += vd->vd_next;
      remaining -= vd->vd_next;
    }
  }
  if (tables->verneed != NULL) {
    uint64_t offset = tables->verneed->sh_offset;
    uint64_t remaining = tables->verneed->sh_size;
    uint32_t entries = tables->verneed->sh_info;
    uint32_t i;
    for (i = 0; i < entries; ++i) {
      const Elf64_Verneed *vn = (const Elf64_Verneed *)repro_hcr_elf_at(
          image, offset, sizeof(Elf64_Verneed));
      uint64_t aux_offset;
      uint16_t j;
      if (vn == NULL) {
        break;
      }
      aux_offset = offset + vn->vn_aux;
      for (j = 0; j < vn->vn_cnt; ++j) {
        const Elf64_Vernaux *aux = (const Elf64_Vernaux *)repro_hcr_elf_at(
            image, aux_offset, sizeof(Elf64_Vernaux));
        if (aux == NULL) {
          break;
        }
        if (aux->vna_other == plain) {
          const char *name = repro_hcr_elf_string_at(
              image, tables->strtab_offset, tables->strtab_size, aux->vna_name);
          repro_hcr_elf_copy_string(out, cap, name);
          return;
        }
        if (aux->vna_next == 0) {
          break;
        }
        aux_offset += aux->vna_next;
      }
      if (vn->vn_next == 0 || vn->vn_next > remaining) {
        break;
      }
      offset += vn->vn_next;
      remaining -= vn->vn_next;
    }
  }
}

/* ---------------------------------------------------------------------------
 * Object scanning.
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_elf_scan_state {
  const repro_hcr_elf_query *query;
  repro_hcr_elf_resolution *result;
  int first_object_refusal;
  char first_object_refusal_detail[REPRO_HCR_ELF_DETAIL_MAX];
} repro_hcr_elf_scan_state;

static void repro_hcr_elf_note_object_refusal(repro_hcr_elf_scan_state *state,
                                              int refusal,
                                              const char *path,
                                              const char *why) {
  state->result->objects_refused += 1;
  if (state->first_object_refusal != REPRO_HCR_ELF_OK) {
    return;
  }
  state->first_object_refusal = refusal;
  snprintf(state->first_object_refusal_detail,
           sizeof(state->first_object_refusal_detail), "%s: %s%s%s",
           repro_hcr_elf_refusal_name(refusal), path != NULL ? path : "?",
           why != NULL && why[0] != '\0' ? " — " : "",
           why != NULL ? why : "");
}

/*
 * Record a candidate, deduplicating on design §7.4's identity tuple
 * (object, `st_shndx`, `st_value`). Two names for one address in one object —
 * a weak alias, or the same symbol reached through both a versioned and an
 * unversioned spelling — are ONE patch target, not an ambiguity.
 */
static void repro_hcr_elf_record_candidate(repro_hcr_elf_resolution *result,
                                           const repro_hcr_elf_candidate *c) {
  int i;
  for (i = 0; i < result->candidate_count; ++i) {
    if (result->candidates[i].link_value == c->link_value &&
        result->candidates[i].section_index == c->section_index &&
        strcmp(result->candidates[i].object_path, c->object_path) == 0) {
      /* Prefer the default-versioned spelling's metadata if we see it later. */
      if (c->default_version && !result->candidates[i].default_version) {
        result->candidates[i] = *c;
      }
      return;
    }
  }
  result->match_count += 1;
  if (result->candidate_count < REPRO_HCR_ELF_MAX_CANDIDATES) {
    result->candidates[result->candidate_count] = *c;
    result->candidate_count += 1;
  }
}

static void repro_hcr_elf_scan_symbol_table(
    const repro_hcr_elf_image *image, const repro_hcr_elf_sections *sections,
    uint64_t symtab_index, const repro_hcr_elf_version_tables *versions,
    int from_dynsym, const char *object_path, uint64_t load_bias,
    repro_hcr_elf_scan_state *state) {
  const Elf64_Shdr *symtab = &sections->headers[symtab_index];
  const Elf64_Shdr *strtab;
  const Elf64_Sym *symbols;
  const uint32_t *xindex = NULL;
  uint64_t xindex_count = 0;
  uint64_t count;
  uint64_t i;
  /* The `STT_FILE` symbol currently in force. The ELF spec places it before
   * the `STB_LOCAL` symbols of its translation unit, so a single forward pass
   * in table order attributes each local to its source file. */
  char current_source_file[REPRO_HCR_ELF_PATH_MAX];

  current_source_file[0] = '\0';

  /*
   * REVIEW 2026-09-10 — the three returns below used to be bare.
   *
   * `repro_hcr_elf_scan_object` increments `objects_parsed` BEFORE calling
   * this, so a bare return here reported "1 object parsed, 0 refused, 0 symbol
   * records read" and let `repro_hcr_elf_select` answer
   * `elf-symbol-not-found`. That is precisely the failure-reported-as-answer
   * shape of Verification-Harness-Traps.md §9 and the vacuous-check pattern
   * this header's own preamble forbids: a reader that could not OPEN the table
   * must not report that the symbol is not IN it. Each one now names the
   * defect, so the refusal override at the end of `repro_hcr_elf_resolve`
   * surfaces `elf-object-malformed` instead.
   */
  if (symtab->sh_entsize != sizeof(Elf64_Sym)) {
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
        "symbol table sh_entsize is not sizeof(Elf64_Sym)");
    return;
  }
  if (symtab->sh_link == 0 || symtab->sh_link >= sections->count) {
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
        "symbol table sh_link does not name a string table section");
    return;
  }
  strtab = &sections->headers[symtab->sh_link];
  if (strtab->sh_type != SHT_STRTAB) {
    /*
     * Without this the names read below are whatever bytes happen to live at
     * `sh_offset` — garbage that matches nothing, which again surfaces as
     * "not found" rather than "unreadable".
     */
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
        "symbol table sh_link names a section that is not SHT_STRTAB");
    return;
  }
  count = symtab->sh_size / sizeof(Elf64_Sym);
  if (count == 0) {
    /*
     * A real symbol table always holds at least the STN_UNDEF entry, so a
     * zero-length one is a structural defect and not an empty answer.
     */
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
        "symbol table is empty; it does not even hold the STN_UNDEF entry");
    return;
  }
  symbols = (const Elf64_Sym *)repro_hcr_elf_at(image, symtab->sh_offset,
                                                count * sizeof(Elf64_Sym));
  if (symbols == NULL) {
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
        "symbol table extends past the end of the file");
    return;
  }

  /* SHN_XINDEX: a symbol whose section index does not fit in 16 bits carries
   * SHN_XINDEX (0xffff) and its real index lives at the same ordinal in the
   * SHT_SYMTAB_SHNDX section that links to this symbol table. */
  for (i = 0; i < sections->count; ++i) {
    if (sections->headers[i].sh_type == SHT_SYMTAB_SHNDX &&
        sections->headers[i].sh_link == symtab_index) {
      xindex_count = sections->headers[i].sh_size / sizeof(uint32_t);
      xindex = (const uint32_t *)repro_hcr_elf_at(
          image, sections->headers[i].sh_offset, xindex_count * sizeof(uint32_t));
      if (xindex == NULL) {
        xindex_count = 0;
      }
      break;
    }
  }

  for (i = 0; i < count; ++i) {
    const Elf64_Sym *sym = &symbols[i];
    const char *name;
    uint8_t type;
    uint32_t shndx;
    int via_xindex;
    repro_hcr_elf_candidate candidate;
    int name_is_default = 1;
    char name_version[REPRO_HCR_ELF_VERSION_MAX];

    state->result->symbols_scanned += 1;

    type = (uint8_t)ELF64_ST_TYPE(sym->st_info);
    if (type == STT_FILE) {
      /*
       * An UNNAMED STT_FILE is not noise to be skipped — it is the linker's
       * terminator, and it means "the STB_LOCAL symbols after me belong to no
       * source file". Measured: a shared library's hidden-visibility functions
       * are localized by the linker and emitted after exactly such a
       * terminator, so skipping it (as the `st_name == 0` fast path below
       * would) leaves the previous file symbol in force and attributes them to
       * whichever object happened to come last — `crtendS.o`, in the case that
       * caught this. That is a diagnostic stating something false, which is
       * worse than stating nothing.
       */
      name = sym->st_name == 0
                 ? ""
                 : repro_hcr_elf_string_at(image, strtab->sh_offset,
                                           strtab->sh_size, sym->st_name);
      repro_hcr_elf_copy_path(current_source_file, sizeof(current_source_file),
                              name);
      continue;
    }

    if (sym->st_name == 0) {
      continue;
    }
    name = repro_hcr_elf_string_at(image, strtab->sh_offset, strtab->sh_size,
                                   sym->st_name);
    if (name == NULL) {
      continue;
    }
    if (!repro_hcr_elf_name_matches(name, state->query->symbol_name)) {
      continue;
    }
    if (type != STT_FUNC && type != STT_GNU_IFUNC) {
      /* The name exists here; it just is not a function. Recorded rather than
       * skipped so the refusal can say which of the two it is. */
      state->result->rejected_not_a_function += 1;
      continue;
    }
    if (state->query->link_value != 0 &&
        sym->st_value != state->query->link_value) {
      continue;
    }
    /*
     * `STT_FILE` governs only the STB_LOCAL symbols that follow it. Globals
     * are emitted after the whole local block, so they inherit whatever file
     * symbol happened to come last — attributing one to a source file would be
     * a diagnostic that lies. A source-file hint therefore also requires the
     * candidate to be local, which is exactly design §7.4's case.
     */
    if (state->query->source_file != NULL &&
        state->query->source_file[0] != '\0' &&
        (ELF64_ST_BIND(sym->st_info) != STB_LOCAL ||
         !repro_hcr_elf_ends_with(current_source_file,
                                  state->query->source_file))) {
      continue;
    }

    shndx = sym->st_shndx;
    via_xindex = 0;
    if (shndx == SHN_XINDEX) {
      if (i < xindex_count) {
        shndx = xindex[i];
        via_xindex = 1;
      } else {
        /* The escape was used but the table that resolves it is missing.
         * Refusing is the only honest answer; guessing an index would put the
         * jump in an unrelated section. */
        repro_hcr_elf_note_object_refusal(
            state, REPRO_HCR_ELF_REFUSED_OBJECT_MALFORMED, object_path,
            "symbol uses SHN_XINDEX but SHT_SYMTAB_SHNDX does not cover it");
        continue;
      }
    }
    /*
     * The reserved range [SHN_LORESERVE, SHN_HIRESERVE] applies to the RAW
     * 16-bit `st_shndx`. After SHN_XINDEX expansion the value is an ordinary
     * section index that may sit anywhere, including exactly on SHN_ABS's or
     * SHN_COMMON's numeric value — measured, a 66,013-section object has real
     * sections at those indices. Testing the reserved range after expansion
     * would drop those symbols with no diagnostic at all.
     */
    if (shndx == SHN_UNDEF) {
      /* An undefined FUNC is an IMPORT — this object calls it, some other
       * object defines it. Not a patch target here, and worth saying so. */
      state->result->rejected_undefined += 1;
      continue;
    }
    if (!via_xindex && shndx >= SHN_LORESERVE) {
      continue;
    }
    if (state->query->section_index >= 0 &&
        shndx != (uint32_t)state->query->section_index) {
      continue;
    }

    memset(&candidate, 0, sizeof(candidate));
    repro_hcr_elf_copy_path(candidate.object_path,
                            sizeof(candidate.object_path), object_path);
    (void)repro_hcr_elf_base_name_length(name, name_version,
                                         sizeof(name_version),
                                         &name_is_default);
    repro_hcr_elf_copy_string(candidate.version, sizeof(candidate.version),
                              name_version);
    candidate.default_version = (uint8_t)(name_is_default ? 1 : 0);
    candidate.load_bias = load_bias;
    candidate.link_value = sym->st_value;
    candidate.runtime_address = load_bias + sym->st_value;
    candidate.size = sym->st_size;
    candidate.section_index = shndx;
    candidate.bind = (uint8_t)ELF64_ST_BIND(sym->st_info);
    candidate.symbol_type = type;
    candidate.from_dynsym = (uint8_t)(from_dynsym ? 1 : 0);
    repro_hcr_elf_copy_string(
        candidate.section_name, sizeof(candidate.section_name),
        repro_hcr_elf_section_name(image, sections, shndx));
    if (candidate.bind == STB_LOCAL) {
      repro_hcr_elf_copy_path(candidate.source_file,
                              sizeof(candidate.source_file),
                              current_source_file);
    }

    /* `.dynsym` keeps the version out of band, so consult `.gnu.version`. */
    if (from_dynsym && versions->versym != NULL && i < versions->versym_count) {
      uint16_t vs = versions->versym[i];
      candidate.default_version =
          (uint8_t)((vs & REPRO_HCR_ELF_VERSYM_HIDDEN) == 0 ? 1 : 0);
      repro_hcr_elf_version_name(image, versions, vs, candidate.version,
                                 sizeof(candidate.version));
    }

    repro_hcr_elf_record_candidate(state->result, &candidate);
  }
}

static void repro_hcr_elf_scan_object(const char *object_path,
                                      uint64_t load_bias,
                                      const ElfW(Phdr) * phdr, uint16_t phnum,
                                      repro_hcr_elf_scan_state *state) {
  repro_hcr_elf_image image;
  repro_hcr_elf_sections sections;
  repro_hcr_elf_version_tables versions;
  repro_hcr_elf_build_id file_id;
  repro_hcr_elf_build_id mapped_id;
  int rc;
  uint64_t i;
  uint64_t symtab_index = 0;
  uint64_t dynsym_index = 0;
  int have_symtab = 0;
  int have_dynsym = 0;

  if (state->query->object_suffix != NULL &&
      state->query->object_suffix[0] != '\0' &&
      !repro_hcr_elf_ends_with(object_path, state->query->object_suffix)) {
    state->result->objects_skipped += 1;
    return;
  }

  rc = repro_hcr_elf_map_file(object_path, &image);
  if (rc != REPRO_HCR_ELF_OK) {
    repro_hcr_elf_note_object_refusal(state, rc, object_path,
                                      "object file could not be mapped");
    return;
  }

  rc = repro_hcr_elf_read_sections(&image, &sections);
  if (rc != REPRO_HCR_ELF_OK) {
    repro_hcr_elf_note_object_refusal(state, rc, object_path,
                                      "section headers unusable");
    repro_hcr_elf_unmap_file(&image);
    return;
  }

  /*
   * Design §7.3 — verify BEFORE trusting a single symbol byte of this file.
   * A file that no longer describes the mapped image yields addresses that are
   * wrong but plausible, and patching a wrong address writes a jump into the
   * middle of an unrelated function.
   */
  if (state->query->require_build_id) {
    int have_file = repro_hcr_elf_file_build_id(&image, &sections, &file_id);
    int have_mapped =
        repro_hcr_elf_mapped_build_id(load_bias, phdr, phnum, &mapped_id);
    if (!have_file || !have_mapped) {
      repro_hcr_elf_note_object_refusal(
          state, REPRO_HCR_ELF_REFUSED_BUILD_ID_ABSENT, object_path,
          !have_file ? "no .note.gnu.build-id in the file on disk"
                     : "no NT_GNU_BUILD_ID in the mapped PT_NOTE");
      repro_hcr_elf_unmap_file(&image);
      return;
    }
    if (file_id.length != mapped_id.length ||
        memcmp(file_id.bytes, mapped_id.bytes, file_id.length) != 0) {
      char file_hex[2 * REPRO_HCR_ELF_BUILD_ID_MAX + 1];
      char mapped_hex[2 * REPRO_HCR_ELF_BUILD_ID_MAX + 1];
      char why[REPRO_HCR_ELF_DETAIL_MAX];
      repro_hcr_elf_format_build_id(&file_id, file_hex, sizeof(file_hex));
      repro_hcr_elf_format_build_id(&mapped_id, mapped_hex, sizeof(mapped_hex));
      snprintf(why, sizeof(why), "on disk %s, mapped %s", file_hex, mapped_hex);
      repro_hcr_elf_note_object_refusal(
          state, REPRO_HCR_ELF_REFUSED_BUILD_ID_MISMATCH, object_path, why);
      repro_hcr_elf_unmap_file(&image);
      return;
    }
  }

  memset(&versions, 0, sizeof(versions));
  for (i = 0; i < sections.count; ++i) {
    switch (sections.headers[i].sh_type) {
      case SHT_SYMTAB:
        if (!have_symtab) {
          symtab_index = i;
          have_symtab = 1;
        }
        break;
      case SHT_DYNSYM:
        if (!have_dynsym) {
          dynsym_index = i;
          have_dynsym = 1;
        }
        break;
      case SHT_GNU_verdef:
        versions.verdef = &sections.headers[i];
        break;
      case SHT_GNU_verneed:
        versions.verneed = &sections.headers[i];
        break;
      default:
        break;
    }
  }

  if (!have_symtab && !have_dynsym) {
    /* Trap 9: reporting this as "the symbol is not in this object" would be a
     * wrong answer with no diagnostic attached. It is a refusal. */
    repro_hcr_elf_note_object_refusal(
        state, REPRO_HCR_ELF_REFUSED_SYMBOL_TABLE_ABSENT, object_path,
        "neither .symtab nor .dynsym is present");
    repro_hcr_elf_unmap_file(&image);
    return;
  }

  state->result->objects_parsed += 1;

  /*
   * Design §7.2 step 3: `.symtab`/`.strtab` preferred, `.dynsym`/`.dynstr` as
   * the fallback for a stripped binary. `.symtab` is a superset in practice —
   * it carries the `static` and hidden functions `.dynsym` cannot — so when
   * both are present only `.symtab` is scanned. Scanning both would report
   * every exported function twice and turn design §7.4's ambiguity refusal
   * into a false positive on ordinary binaries.
   */
  if (have_symtab) {
    repro_hcr_elf_scan_symbol_table(&image, &sections, symtab_index, &versions,
                                    0, object_path, load_bias, state);
  } else {
    const Elf64_Shdr *dynsym = &sections.headers[dynsym_index];
    for (i = 0; i < sections.count; ++i) {
      if (sections.headers[i].sh_type == SHT_GNU_versym &&
          sections.headers[i].sh_link == dynsym_index) {
        versions.versym_count = sections.headers[i].sh_size / sizeof(uint16_t);
        versions.versym = (const uint16_t *)repro_hcr_elf_at(
            &image, sections.headers[i].sh_offset,
            versions.versym_count * sizeof(uint16_t));
        if (versions.versym == NULL) {
          versions.versym_count = 0;
        }
        break;
      }
    }
    if (dynsym->sh_link < sections.count) {
      versions.strtab_offset = sections.headers[dynsym->sh_link].sh_offset;
      versions.strtab_size = sections.headers[dynsym->sh_link].sh_size;
    }
    repro_hcr_elf_scan_symbol_table(&image, &sections, dynsym_index, &versions,
                                    1, object_path, load_bias, state);
  }

  repro_hcr_elf_unmap_file(&image);
}

/* ---------------------------------------------------------------------------
 * `dl_iterate_phdr` driver (design §7.2 steps 1 and 2).
 * ------------------------------------------------------------------------- */

typedef struct repro_hcr_elf_iterate_context {
  repro_hcr_elf_scan_state *state;
  int main_executable_seen;
} repro_hcr_elf_iterate_context;

static int repro_hcr_elf_is_vdso(const char *name) {
  /* The vDSO is a kernel-provided mapping with no file behind it. Skipping it
   * is explicit rather than incidental so that a failure to open it is never
   * mistaken for a real object being unreadable. */
  if (name == NULL) {
    return 0;
  }
  return strncmp(name, "linux-vdso", 10) == 0 ||
         strncmp(name, "linux-gate", 10) == 0;
}

static int repro_hcr_elf_iterate_callback(struct dl_phdr_info *info,
                                          size_t size, void *data) {
  repro_hcr_elf_iterate_context *context =
      (repro_hcr_elf_iterate_context *)data;
  repro_hcr_elf_scan_state *state = context->state;
  char exe_path[REPRO_HCR_ELF_PATH_MAX];
  const char *path;

  (void)size;
  state->result->objects_seen += 1;

  if (repro_hcr_elf_is_vdso(info->dlpi_name)) {
    state->result->objects_skipped += 1;
    return 0;
  }

  if (info->dlpi_name == NULL || info->dlpi_name[0] == '\0') {
    /*
     * Design §7.2 step 2: `dlpi_name` is "" for the main executable, which is
     * resolved through `/proc/self/exe`.
     *
     * `readlink` rather than opening "/proc/self/exe" directly, and this is the
     * consequential choice: opening the magic link would always reach the
     * ORIGINAL inode, so the build-id check could never fire for the main
     * executable and §7.3's whole purpose would be defeated for the one object
     * a hot-reload workflow is most likely to have rebuilt. `readlink` names
     * the path, which is what a rebuild replaces — and the kernel appends
     * " (deleted)" when the inode behind it is gone, which is itself proof the
     * on-disk file is not the mapped image and is refused by name.
     */
    ssize_t written =
        readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (written <= 0) {
      repro_hcr_elf_note_object_refusal(
          state, REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE, "/proc/self/exe",
          "readlink failed for the main executable");
      return 0;
    }
    exe_path[written] = '\0';
    if (repro_hcr_elf_ends_with(exe_path, " (deleted)")) {
      exe_path[written - 10] = '\0';
      repro_hcr_elf_note_object_refusal(
          state, REPRO_HCR_ELF_REFUSED_OBJECT_IMAGE_REPLACED, exe_path,
          "the running image's file was replaced or removed since exec");
      return 0;
    }
    path = exe_path;
    context->main_executable_seen = 1;
  } else {
    path = info->dlpi_name;
  }

  repro_hcr_elf_scan_object(path, (uint64_t)info->dlpi_addr, info->dlpi_phdr,
                            info->dlpi_phnum, state);
  return 0;
}

/* ---------------------------------------------------------------------------
 * Candidate selection (design §7.2 step 5, §7.4).
 * ------------------------------------------------------------------------- */

static void repro_hcr_elf_describe_candidates(repro_hcr_elf_resolution *result,
                                              const char *symbol_name) {
  int i;
  size_t used;
  used = (size_t)snprintf(result->detail, sizeof(result->detail),
                          "%d candidates for \"%s\":", result->match_count,
                          symbol_name != NULL ? symbol_name : "");
  for (i = 0; i < result->candidate_count && used + 1 < sizeof(result->detail);
       ++i) {
    const repro_hcr_elf_candidate *c = &result->candidates[i];
    int n = snprintf(result->detail + used, sizeof(result->detail) - used,
                     " [%s%s%s shndx=%u(%s) st_value=0x%llx bind=%s%s%s]",
                     c->object_path,
                     c->source_file[0] != '\0' ? " from " : "", c->source_file,
                     (unsigned)c->section_index, c->section_name,
                     (unsigned long long)c->link_value,
                     c->bind == STB_LOCAL
                         ? "LOCAL"
                         : (c->bind == STB_WEAK ? "WEAK" : "GLOBAL"),
                     c->version[0] != '\0' ? " version=" : "", c->version);
    if (n < 0) {
      break;
    }
    used += (size_t)n;
  }
  if (result->match_count > result->candidate_count &&
      used + 1 < sizeof(result->detail)) {
    snprintf(result->detail + used, sizeof(result->detail) - used,
             " (+%d more not recorded)",
             result->match_count - result->candidate_count);
  }
}

static int repro_hcr_elf_select(repro_hcr_elf_resolution *result,
                                const repro_hcr_elf_query *query) {
  int i;
  int default_versioned = 0;
  int chosen = -1;

  if (result->match_count == 0) {
    /*
     * Filled here rather than at the call site so that BOTH entry points
     * produce a diagnostic. A refusal that carries an empty detail is the
     * shape Verification-Harness-Traps.md §9 warns about: it makes "could not
     * read" and "genuinely absent" indistinguishable to whoever reads it.
     *
     * And "absent" is itself three different answers, which is why the
     * rejection counters exist. A name that is present as a variable, and a
     * name that is present only as an import, are both very different from a
     * name nobody has ever heard of — and collapsing them would send whoever
     * is debugging a failed patch looking for a typo that is not there.
     */
    if (result->rejected_not_a_function > 0) {
      snprintf(result->detail, sizeof(result->detail),
               "\"%s\" exists but is not a function: %d symbol(s) with that "
               "name are neither STT_FUNC nor STT_GNU_IFUNC",
               query->symbol_name != NULL ? query->symbol_name : "",
               result->rejected_not_a_function);
      return REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_A_FUNCTION;
    }
    if (result->rejected_undefined > 0) {
      snprintf(result->detail, sizeof(result->detail),
               "\"%s\" appears only as an UNDEFINED symbol in %d place(s) — "
               "it is imported by the objects scanned, not defined in any of "
               "them, so there is no entry here to patch",
               query->symbol_name != NULL ? query->symbol_name : "",
               result->rejected_undefined);
      return REPRO_HCR_ELF_REFUSED_SYMBOL_UNDEFINED;
    }
    snprintf(result->detail, sizeof(result->detail),
             "\"%s\" is in none of the %d object(s) parsed of %d seen "
             "(%llu symbol records read, %d object(s) refused; there is no "
             "dlsym fallback by design §7.1)",
             query->symbol_name != NULL ? query->symbol_name : "",
             result->objects_parsed, result->objects_seen,
             (unsigned long long)result->symbols_scanned,
             result->objects_refused);
    return REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_FOUND;
  }

  /*
   * Symbol versioning: when several entries share a base name, the DEFAULT
   * version is the one an unqualified request means. Non-default versions are
   * compatibility aliases and are not silently patched.
   */
  for (i = 0; i < result->candidate_count; ++i) {
    if (result->candidates[i].default_version) {
      default_versioned += 1;
      if (chosen < 0) {
        chosen = i;
      }
    }
  }
  if (default_versioned == 0) {
    chosen = 0;
    default_versioned = result->candidate_count;
  }

  if (default_versioned > 1 || result->match_count > result->candidate_count) {
    /*
     * Design §7.4: refuse rather than take the first match. Several
     * translation units can each define a `static` function with this name and
     * picking one of them is a coin flip that corrupts the other.
     */
    repro_hcr_elf_describe_candidates(result, query->symbol_name);
    return REPRO_HCR_ELF_REFUSED_SYMBOL_AMBIGUOUS;
  }

  if (result->candidates[chosen].symbol_type == STT_GNU_IFUNC) {
    /*
     * Design §7.2 step 5. `st_value` names a RESOLVER whose return value is the
     * implementation actually called. Patching there patches the selection
     * logic, not the function, and the caller would observe no change at all
     * after a "successful" patch.
     */
    snprintf(result->detail, sizeof(result->detail),
             "\"%s\" is STT_GNU_IFUNC in %s; st_value=0x%llx is its resolver, "
             "not its implementation",
             query->symbol_name != NULL ? query->symbol_name : "",
             result->candidates[chosen].object_path,
             (unsigned long long)result->candidates[chosen].link_value);
    return REPRO_HCR_ELF_REFUSED_SYMBOL_IS_IFUNC;
  }

  result->runtime_address = result->candidates[chosen].runtime_address;
  result->runtime_size = result->candidates[chosen].size;
  if (chosen != 0) {
    repro_hcr_elf_candidate swap = result->candidates[0];
    result->candidates[0] = result->candidates[chosen];
    result->candidates[chosen] = swap;
  }
  repro_hcr_elf_describe_candidates(result, query->symbol_name);
  return REPRO_HCR_ELF_OK;
}

/* ---------------------------------------------------------------------------
 * Entry point.
 * ------------------------------------------------------------------------- */

static int repro_hcr_elf_resolve(const repro_hcr_elf_query *query,
                                 repro_hcr_elf_resolution *out) {
  repro_hcr_elf_scan_state state;
  repro_hcr_elf_iterate_context context;

  if (out == NULL) {
    return REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT;
  }
  memset(out, 0, sizeof(*out));
  if (query == NULL || query->symbol_name == NULL ||
      query->symbol_name[0] == '\0') {
    out->refusal = REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT;
    repro_hcr_elf_copy_string(out->detail, sizeof(out->detail),
                              "no symbol name was supplied");
    return out->refusal;
  }

  memset(&state, 0, sizeof(state));
  state.query = query;
  state.result = out;
  state.first_object_refusal = REPRO_HCR_ELF_OK;

  context.state = &state;
  context.main_executable_seen = 0;
  dl_iterate_phdr(repro_hcr_elf_iterate_callback, &context);

  if (out->objects_seen == 0) {
    /* dl_iterate_phdr reported nothing at all. That is not "no symbol"; it is
     * a broken environment, and must be loud. */
    out->refusal = REPRO_HCR_ELF_REFUSED_NO_OBJECTS_SCANNED;
    repro_hcr_elf_copy_string(out->detail, sizeof(out->detail),
                              "dl_iterate_phdr reported no loaded objects");
    return out->refusal;
  }

  out->refusal = repro_hcr_elf_select(out, query);

  if (repro_hcr_elf_refusal_is_scan_negative(out->refusal) &&
      state.first_object_refusal != REPRO_HCR_ELF_OK) {
    /*
     * Trap 9 again, and the reason this branch exists: an object we could not
     * read is not evidence that the symbol is absent. Reporting "not found"
     * here would make "the build-id did not match" and "you asked for a
     * function that does not exist" indistinguishable. The object's own
     * refusal wins.
     */
    out->refusal = state.first_object_refusal;
    repro_hcr_elf_copy_string(out->detail, sizeof(out->detail),
                              state.first_object_refusal_detail);
    return out->refusal;
  }

  return out->refusal;
}

/*
 * Resolve inside ONE named file, without `dl_iterate_phdr`.
 *
 * This is the same parser, symbol selection, versioning, `SHN_XINDEX` and
 * ambiguity logic the live path runs — only the enumeration of loaded objects
 * is replaced by a caller-supplied path and bias. It exists so a gate can drive
 * the parser against a binary this process has not loaded (an 84 MB stripped
 * C++ executable, for instance) and so cross-checks against `readelf` are
 * possible at all.
 *
 * It is NOT the production entry point and cannot be: with no live mapping
 * there is no `PT_NOTE` to compare a build-id against, so design §7.3's check
 * is not available here and `require_build_id` must be 0. The returned address
 * is therefore `load_bias + st_value` for whatever bias the caller asserts.
 */
REPRO_HCR_ELF_MAYBE_UNUSED static int repro_hcr_elf_resolve_in_file(const char *object_path,
                                         uint64_t load_bias,
                                         const repro_hcr_elf_query *query,
                                         repro_hcr_elf_resolution *out) {
  repro_hcr_elf_scan_state state;
  repro_hcr_elf_query effective;

  if (out == NULL) {
    return REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT;
  }
  memset(out, 0, sizeof(*out));
  if (query == NULL || object_path == NULL || query->symbol_name == NULL ||
      query->symbol_name[0] == '\0') {
    out->refusal = REPRO_HCR_ELF_REFUSED_INVALID_ARGUMENT;
    repro_hcr_elf_copy_string(out->detail, sizeof(out->detail),
                              "no object path or symbol name was supplied");
    return out->refusal;
  }
  effective = *query;
  effective.object_suffix = NULL;
  effective.require_build_id = 0;

  memset(&state, 0, sizeof(state));
  state.query = &effective;
  state.result = out;
  state.first_object_refusal = REPRO_HCR_ELF_OK;

  out->objects_seen = 1;
  repro_hcr_elf_scan_object(object_path, load_bias, NULL, 0, &state);

  out->refusal = repro_hcr_elf_select(out, &effective);
  if (repro_hcr_elf_refusal_is_scan_negative(out->refusal) &&
      state.first_object_refusal != REPRO_HCR_ELF_OK) {
    out->refusal = state.first_object_refusal;
    repro_hcr_elf_copy_string(out->detail, sizeof(out->detail),
                              state.first_object_refusal_detail);
  }
  return out->refusal;
}

/*
 * The most recent symbol-resolution refusal, so the agent can put the NAMED
 * cause on the wire. Without this a build-id mismatch, an ambiguous `static`
 * name, an IFUNC and a genuinely absent function all reach the coordinator as
 * "target symbol was not found in process", which is the one report that makes
 * all four indistinguishable.
 */
static int repro_hcr_elf_last_symbol_refusal = REPRO_HCR_ELF_OK;

/* Optional sink for the resolved symbol's `st_size`. A pointer rather than an
 * extra parameter so the two existing call sites and the probe shim keep their
 * signatures; the agent points it at its own variable before resolving. */
static uint64_t *repro_hcr_elf_last_resolved_size = NULL;

REPRO_HCR_ELF_MAYBE_UNUSED static const char *repro_hcr_elf_last_symbol_refusal_name(void) {
  return repro_hcr_elf_refusal_name(repro_hcr_elf_last_symbol_refusal);
}

/*
 * Convenience wrapper used by the agent: resolve a bare name in any object,
 * with build-id verification on, and return the runtime address or 0.
 * `refusal_out` always receives the named refusal so the caller can put it on
 * the wire rather than reporting a generic failure.
 */
REPRO_HCR_ELF_MAYBE_UNUSED static uint64_t repro_hcr_elf_resolve_function_address(const char *symbol_name,
                                                       int *refusal_out) {
  repro_hcr_elf_query query;
  repro_hcr_elf_resolution resolution;
  int rc;

  memset(&query, 0, sizeof(query));
  query.symbol_name = symbol_name;
  query.object_suffix = NULL;
  query.section_index = -1;
  query.require_build_id = 1;

  rc = repro_hcr_elf_resolve(&query, &resolution);
  if (refusal_out != NULL) {
    *refusal_out = rc;
  }
  /* HLX-M4 needs the EXTENT, not just the entry: on-stack detection (§6.2 step
   * 5) asks whether any parked thread's PC or return address lies inside the
   * function about to be patched, which is a range question. `st_size` is
   * authoritative on ELF (design §7.5), so this is a real bound and not an
   * estimate — but it can be 0 for a hand-written asm symbol, and the caller
   * must treat 0 as "extent unknown" rather than as "empty function". */
  if (repro_hcr_elf_last_resolved_size != NULL) {
    *repro_hcr_elf_last_resolved_size =
        rc == REPRO_HCR_ELF_OK ? resolution.runtime_size : 0;
  }
  return rc == REPRO_HCR_ELF_OK ? resolution.runtime_address : 0;
}

#endif /* REPRO_HCR_LINUX_ELF_SYMBOLS_H */
