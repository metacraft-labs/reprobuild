/*
 * Test-facing shim over `repro_hcr_linux_elf_symbols.h` (HLX-M1).
 *
 * The resolver's functions are `static` inside that header so the agent
 * translation unit exports no surface it does not need. This shim includes the
 * SAME header — the same code the live agent runs, not a reimplementation —
 * and re-exports it so the HLX-M1 gates can drive it directly.
 *
 * No mocks: every function below forwards to the production implementation.
 * In particular `repro_hcr_elf_probe_resolve` is the live `dl_iterate_phdr`
 * path against this process's own real loaded objects, and
 * `repro_hcr_elf_probe_resolve_in_file` is the same parser pointed at a file,
 * which is how a gate reaches a binary this process has not loaded.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#if defined(__linux__) && defined(__x86_64__)

#include <stddef.h>
#include <stdint.h>

#include "repro_hcr_linux_elf_symbols.h"

/*
 * One resolution's worth of output, flattened so Nim can read it without
 * mirroring the C struct layout. `last` is process-global because a gate runs
 * one query at a time and then reads the answer, exactly as the agent does.
 */
static repro_hcr_elf_resolution repro_hcr_elf_probe_last;

static int repro_hcr_elf_probe_run(const char *symbol_name,
                                   const char *object_suffix,
                                   const char *source_file, int section_index,
                                   unsigned long long link_value,
                                   int require_build_id,
                                   const char *object_path,
                                   unsigned long long load_bias) {
  repro_hcr_elf_query query;
  memset(&query, 0, sizeof(query));
  query.symbol_name = symbol_name;
  query.object_suffix =
      (object_suffix != NULL && object_suffix[0] != '\0') ? object_suffix : NULL;
  query.source_file =
      (source_file != NULL && source_file[0] != '\0') ? source_file : NULL;
  query.section_index = section_index;
  query.link_value = (uint64_t)link_value;
  query.require_build_id = require_build_id;
  if (object_path != NULL && object_path[0] != '\0') {
    return repro_hcr_elf_resolve_in_file(object_path, (uint64_t)load_bias,
                                         &query, &repro_hcr_elf_probe_last);
  }
  return repro_hcr_elf_resolve(&query, &repro_hcr_elf_probe_last);
}

int repro_hcr_elf_probe_resolve(const char *symbol_name,
                                const char *object_suffix,
                                const char *source_file, int section_index,
                                unsigned long long link_value,
                                int require_build_id) {
  return repro_hcr_elf_probe_run(symbol_name, object_suffix, source_file,
                                 section_index, link_value, require_build_id,
                                 NULL, 0);
}

int repro_hcr_elf_probe_resolve_in_file(const char *object_path,
                                        unsigned long long load_bias,
                                        const char *symbol_name,
                                        const char *source_file,
                                        int section_index,
                                        unsigned long long link_value) {
  return repro_hcr_elf_probe_run(symbol_name, NULL, source_file, section_index,
                                 link_value, 0, object_path, load_bias);
}

const char *repro_hcr_elf_probe_refusal_name(int code) {
  return repro_hcr_elf_refusal_name(code);
}

unsigned long long repro_hcr_elf_probe_runtime_address(void) {
  return (unsigned long long)repro_hcr_elf_probe_last.runtime_address;
}

int repro_hcr_elf_probe_match_count(void) {
  return repro_hcr_elf_probe_last.match_count;
}

int repro_hcr_elf_probe_candidate_count(void) {
  return repro_hcr_elf_probe_last.candidate_count;
}

int repro_hcr_elf_probe_objects_seen(void) {
  return repro_hcr_elf_probe_last.objects_seen;
}

int repro_hcr_elf_probe_objects_parsed(void) {
  return repro_hcr_elf_probe_last.objects_parsed;
}

int repro_hcr_elf_probe_objects_refused(void) {
  return repro_hcr_elf_probe_last.objects_refused;
}

int repro_hcr_elf_probe_objects_skipped(void) {
  return repro_hcr_elf_probe_last.objects_skipped;
}

unsigned long long repro_hcr_elf_probe_symbols_scanned(void) {
  return (unsigned long long)repro_hcr_elf_probe_last.symbols_scanned;
}

const char *repro_hcr_elf_probe_detail(void) {
  return repro_hcr_elf_probe_last.detail;
}

/* Candidate accessors. `index` out of range yields a zero/empty answer, and
 * every gate that uses these asserts `candidate_count` first. */
static const repro_hcr_elf_candidate *repro_hcr_elf_probe_candidate(int index) {
  if (index < 0 || index >= repro_hcr_elf_probe_last.candidate_count) {
    return NULL;
  }
  return &repro_hcr_elf_probe_last.candidates[index];
}

unsigned long long repro_hcr_elf_probe_candidate_link_value(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? 0ull : (unsigned long long)c->link_value;
}

unsigned long long repro_hcr_elf_probe_candidate_runtime_address(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? 0ull : (unsigned long long)c->runtime_address;
}

unsigned long long repro_hcr_elf_probe_candidate_size(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? 0ull : (unsigned long long)c->size;
}

unsigned int repro_hcr_elf_probe_candidate_section_index(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? 0u : (unsigned int)c->section_index;
}

const char *repro_hcr_elf_probe_candidate_section_name(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? "" : c->section_name;
}

const char *repro_hcr_elf_probe_candidate_source_file(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? "" : c->source_file;
}

const char *repro_hcr_elf_probe_candidate_object_path(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? "" : c->object_path;
}

const char *repro_hcr_elf_probe_candidate_version(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? "" : c->version;
}

int repro_hcr_elf_probe_candidate_default_version(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? 0 : (int)c->default_version;
}

int repro_hcr_elf_probe_candidate_bind(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? -1 : (int)c->bind;
}

int repro_hcr_elf_probe_candidate_from_dynsym(int index) {
  const repro_hcr_elf_candidate *c = repro_hcr_elf_probe_candidate(index);
  return c == NULL ? -1 : (int)c->from_dynsym;
}

/* Refusal-code constants, exported so a gate asserts against the production
 * enum rather than re-declaring numbers that could drift out of step. */
int repro_hcr_elf_probe_code_ok(void) { return REPRO_HCR_ELF_OK; }
int repro_hcr_elf_probe_code_not_found(void) {
  return REPRO_HCR_ELF_REFUSED_SYMBOL_NOT_FOUND;
}
int repro_hcr_elf_probe_code_ambiguous(void) {
  return REPRO_HCR_ELF_REFUSED_SYMBOL_AMBIGUOUS;
}
int repro_hcr_elf_probe_code_ifunc(void) {
  return REPRO_HCR_ELF_REFUSED_SYMBOL_IS_IFUNC;
}
int repro_hcr_elf_probe_code_build_id_mismatch(void) {
  return REPRO_HCR_ELF_REFUSED_BUILD_ID_MISMATCH;
}
int repro_hcr_elf_probe_code_build_id_absent(void) {
  return REPRO_HCR_ELF_REFUSED_BUILD_ID_ABSENT;
}
int repro_hcr_elf_probe_code_image_replaced(void) {
  return REPRO_HCR_ELF_REFUSED_OBJECT_IMAGE_REPLACED;
}
int repro_hcr_elf_probe_code_symbol_table_absent(void) {
  return REPRO_HCR_ELF_REFUSED_SYMBOL_TABLE_ABSENT;
}
int repro_hcr_elf_probe_code_object_unreadable(void) {
  return REPRO_HCR_ELF_REFUSED_OBJECT_UNREADABLE;
}

/* Keeps the agent-facing wrapper referenced from this translation unit so the
 * shared header compiles here without an unused-function diagnostic, and so
 * the exact entry point the agent calls is itself covered by a gate. */
unsigned long long repro_hcr_elf_probe_resolve_function_address(
    const char *symbol_name, int *refusal_out) {
  return (unsigned long long)repro_hcr_elf_resolve_function_address(symbol_name,
                                                                    refusal_out);
}

const char *repro_hcr_elf_probe_last_symbol_refusal_name(void) {
  return repro_hcr_elf_last_symbol_refusal_name();
}

#endif /* __linux__ && __x86_64__ */
