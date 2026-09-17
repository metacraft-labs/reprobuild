/*
 * The replacement body for the HLX-M5 gates, compiled by the gate into a REAL
 * relocatable object with `-g`, and used THREE ways from that one object:
 *
 *   * `.text.hcr_lx_m5_patch_body` supplies the bytes that are copied into the
 *     provider's patch page;
 *   * `.eh_frame` supplies the COMPILER-GENERATED CIE/FDE that is relocated to
 *     the live patch address and registered with the runtime unwinder
 *     (design §8.2 — not a synthetic template);
 *   * the whole object is the ELF `ET_REL` symfile handed to the GDB JIT
 *     interface, which is why it is compiled with `-g`: without `.debug_line`
 *     a debugger can name the function but cannot resolve a source line inside
 *     it, and resolving a source line is what the symfile gate asserts.
 *
 * The body takes its callee as a PARAMETER rather than calling a named
 * function. That is not a stylistic choice: a call to a named function emits an
 * `R_X86_64_PLT32` relocation, and bytes with a relocation in them are not
 * position-independent and cannot be dropped into a provider-owned page. The
 * gate asserts the relocation count of this section is 0, so the constraint is
 * measured rather than assumed.
 *
 * The arithmetic either side of the call is deliberate too. It gives the body a
 * live value across the call, so the compiler must actually establish a frame
 * and describe it in `.eh_frame`, and it prevents the call from becoming a tail
 * call — a tail call would leave no frame for a debugger to resolve and would
 * quietly make the backtrace gate assert something easier than it claims.
 */

int hcr_lx_m5_patch_body(void (*reached)(void)) {
  int accumulator = 5;
  reached();
  accumulator += 72;
  return accumulator; /* 77 */
}
