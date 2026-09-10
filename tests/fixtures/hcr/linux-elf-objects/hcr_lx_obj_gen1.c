/*
 * Generation one of the HLX-M1 ELF `ET_REL` object-parsing fixture.
 *
 * Compiled to a real relocatable object by a real compiler. Each function is
 * here to put a specific, named feature into the object's relocation and
 * section tables, so the gate is classifying real compiler output rather than
 * hand-written bytes:
 *
 *   unchanged_leaf        no relocations at all — the diff must call it
 *                         unchanged against generation two.
 *   changed_leaf          body differs between generations, no relocations —
 *                         isolates "the code changed" from "a relocation
 *                         changed".
 *   calls_external        R_X86_64_PLT32 to a function defined elsewhere.
 *                         The supported-direct case.
 *   takes_address         R_X86_64_64 into `.data.rel.ro`/`.data` — an
 *                         absolute 64-bit address, also supported-direct.
 *   reads_global          R_X86_64_PC32 to a defined object.
 *   uses_thread_local     a TLS relocation, which HLX-M1 does NOT support and
 *                         which must therefore appear as a STRUCTURED reason
 *                         rather than being silently dropped from the plan.
 */

extern int hcr_lx_obj_external(int value);

int hcr_lx_obj_global_counter = 7;
static __thread int hcr_lx_obj_thread_local_slot;

int hcr_lx_obj_unchanged_leaf(int value) { return value * 3 + 1; }

int hcr_lx_obj_changed_leaf(int value) { return value + 11; }

int hcr_lx_obj_calls_external(int value) {
  return hcr_lx_obj_external(value) + 1;
}

typedef int (*hcr_lx_obj_fn)(int);
hcr_lx_obj_fn hcr_lx_obj_table[] = {hcr_lx_obj_unchanged_leaf,
                                    hcr_lx_obj_changed_leaf};

int hcr_lx_obj_takes_address(int value) {
  return (int)(long)(void *)hcr_lx_obj_table[value & 1];
}

int hcr_lx_obj_reads_global(int value) {
  return hcr_lx_obj_global_counter + value;
}

int hcr_lx_obj_uses_thread_local(int value) {
  hcr_lx_obj_thread_local_slot += value;
  return hcr_lx_obj_thread_local_slot;
}
