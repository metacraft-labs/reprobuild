/*
 * HLX-M1 `STB_LOCAL` ambiguity fixture (design §7.4).
 *
 * Two translation units in one executable each define a `static` function
 * called `hcr_lx_ambiguous_helper`. The fixture asks the PRODUCTION resolver
 * for that name four ways and prints what each returns, alongside the two real
 * addresses the process reports for the two definitions.
 *
 * The four qualifications are the point of the fixture, because they are not
 * equally good and the design assumed the wrong one:
 *
 *   "bare"       — name only. Must be REFUSED; picking either definition is a
 *                  coin flip that corrupts the other.
 *   "by-shndx"   — (object, name, st_shndx), which is the tuple design §7.4
 *                  specifies. MEASURED: still ambiguous. The linker merges
 *                  every input `.text.hcr_lx_ambiguous_helper` into one output
 *                  `.text`, so both definitions share one `st_shndx` and the
 *                  tuple selects both. It is the right key inside an `ET_REL`
 *                  object — which is where the design's reasoning comes from —
 *                  but the resolver reads a LINKED image.
 *   "by-file"    — (object, name, STT_FILE). Resolves. The ELF spec places the
 *                  `STT_FILE` symbol immediately before the `STB_LOCAL`
 *                  symbols of its translation unit, so this is the component
 *                  that actually answers "which `static` did you mean".
 *   "by-value"   — (object, name, st_value). Resolves. The exact key, for a
 *                  bundle that has already been told which definition it wants.
 */

#if !defined(_GNU_SOURCE)
#define _GNU_SOURCE 1
#endif

#include <stdio.h>
#include <string.h>

#include "hcr_lx_elf_fixture.h"
#include "repro_hcr_linux_elf_symbols.h"

static void emit_json_string(const char *value) {
  putchar('"');
  for (; value != NULL && *value != '\0'; ++value) {
    unsigned char c = (unsigned char)*value;
    if (c == '"' || c == '\\') {
      putchar('\\');
      putchar((int)c);
    } else if (c < 0x20) {
      printf("\\u%04x", (unsigned)c);
    } else {
      putchar((int)c);
    }
  }
  putchar('"');
}

static void ask(const char *label, const char *source_file, int section_index,
                unsigned long long link_value, int first) {
  repro_hcr_elf_query query;
  repro_hcr_elf_resolution resolution;
  int rc;
  int i;

  memset(&query, 0, sizeof(query));
  query.symbol_name = "hcr_lx_ambiguous_helper";
  query.object_suffix = "hcr-lx-amb-probe";
  query.source_file = source_file;
  query.section_index = section_index;
  query.link_value = (uint64_t)link_value;
  query.require_build_id = 1;

  rc = repro_hcr_elf_resolve(&query, &resolution);

  if (!first) {
    printf(",\n");
  }
  printf("    {\"label\":");
  emit_json_string(label);
  printf(",\"refusal\":%d,\"refusalName\":", rc);
  emit_json_string(repro_hcr_elf_refusal_name(rc));
  printf(",\"resolvedAddress\":%llu,\"matchCount\":%d,\"candidateCount\":%d",
         (unsigned long long)resolution.runtime_address, resolution.match_count,
         resolution.candidate_count);
  printf(",\"detail\":");
  emit_json_string(resolution.detail);
  printf(",\"candidates\":[");
  for (i = 0; i < resolution.candidate_count; ++i) {
    const repro_hcr_elf_candidate *c = &resolution.candidates[i];
    if (i > 0) {
      printf(",");
    }
    printf("{\"sourceFile\":");
    emit_json_string(c->source_file);
    printf(",\"sectionIndex\":%u,\"sectionName\":", (unsigned)c->section_index);
    emit_json_string(c->section_name);
    printf(",\"linkValue\":%llu,\"runtimeAddress\":%llu,\"bind\":%d}",
           (unsigned long long)c->link_value,
           (unsigned long long)c->runtime_address, (int)c->bind);
  }
  printf("]}");
}

int main(void) {
  unsigned long long alpha = hcr_lx_alpha_helper_address();
  unsigned long long beta = hcr_lx_beta_helper_address();
  unsigned int alpha_section = 0;
  unsigned long long alpha_link_value = 0;

  /* Both definitions must really be reachable and really be different, or the
   * whole fixture is describing a collision that does not exist. */
  if (hcr_lx_alpha_call() != 101 || hcr_lx_beta_call() != 202) {
    fprintf(stderr, "ambiguity fixture: the two helpers are not distinct\n");
    return 3;
  }
  if (alpha == beta) {
    fprintf(stderr, "ambiguity fixture: both helpers report one address\n");
    return 3;
  }

  /* Learn alpha's section and st_value from the resolver's own candidate list,
   * so the qualified queries below use values that came out of the real symbol
   * table rather than anything this fixture computed. */
  {
    repro_hcr_elf_query query;
    repro_hcr_elf_resolution resolution;
    int i;
    memset(&query, 0, sizeof(query));
    query.symbol_name = "hcr_lx_ambiguous_helper";
    query.object_suffix = "hcr-lx-amb-probe";
    query.section_index = -1;
    query.require_build_id = 1;
    (void)repro_hcr_elf_resolve(&query, &resolution);
    for (i = 0; i < resolution.candidate_count; ++i) {
      if (resolution.candidates[i].runtime_address == alpha) {
        alpha_section = resolution.candidates[i].section_index;
        alpha_link_value = resolution.candidates[i].link_value;
      }
    }
    if (alpha_link_value == 0) {
      fprintf(stderr,
              "ambiguity fixture: the resolver listed no candidate at alpha's "
              "address; the collision was not observed at all\n");
      return 3;
    }
  }

  printf("{\n");
  printf("  \"schemaId\": \"reprobuild.hcr.hlx-m1.static-local-ambiguity.v1\",\n");
  printf("  \"alphaAddress\": %llu,\n", alpha);
  printf("  \"betaAddress\": %llu,\n", beta);
  printf("  \"alphaSectionIndex\": %u,\n", alpha_section);
  printf("  \"alphaLinkValue\": %llu,\n", alpha_link_value);
  printf("  \"queries\": [\n");

  ask("bare", NULL, -1, 0, 1);
  ask("by-shndx", NULL, (int)alpha_section, 0, 0);
  ask("by-file-alpha", "hcr_lx_amb_alpha.c", -1, 0, 0);
  ask("by-file-beta", "hcr_lx_amb_beta.c", -1, 0, 0);
  ask("by-value-alpha", NULL, -1, alpha_link_value, 0);

  printf("\n  ]\n}\n");
  return 0;
}
