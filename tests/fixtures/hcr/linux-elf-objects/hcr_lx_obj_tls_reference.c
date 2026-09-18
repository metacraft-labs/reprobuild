/*
 * HLX-M8 fixture: a translation unit that REFERENCES an existing thread-local
 * and DEFINES none.
 *
 * `HCR/Linux-ELF-Provider.md` §9 draws the line here and nowhere else:
 *
 *   "A patch body that references a *new* thread-local variable cannot get a
 *    slot: initial-exec and local-exec offsets are assigned at link time from
 *    the module's PT_TLS, and there is no room to extend it in a running
 *    process. The provider therefore refuses patches that introduce new TLS
 *    variables. Patches that reference *existing* TLS variables are fine."
 *
 * In ELF terms that is `st_shndx`: a DEFINED `STT_TLS` symbol lives in this
 * object's own `.tdata`/`.tbss` and needs a slot that cannot be allocated; an
 * UNDEFINED one resolves against a slot the running module already has.
 *
 * `hcr_lx_obj_gen1.c` / `gen2.c` are the other half of the pair — they define
 * `static __thread int hcr_lx_obj_thread_local_slot`, so they must be refused
 * `elf-new-tls-variable` where this file must not be. Without both halves the
 * refusal would be indistinguishable from "any TLS at all is refused", which
 * is precisely what §9 does NOT say.
 */

/* Defined in some other translation unit of the running program. This object
 * gets an UNDEFINED STT_TLS symbol and a TLS relocation, and no `.tdata` or
 * `.tbss` of its own. */
extern __thread int hcr_lx_obj_existing_thread_local;

int hcr_lx_obj_reads_existing_thread_local(int value) {
  hcr_lx_obj_existing_thread_local += value;
  return hcr_lx_obj_existing_thread_local;
}
